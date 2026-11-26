local M = {}

local dap = require('dap')
local cache = require('devcontainers.cache')
local cli = require('devcontainers.cli')
local docker = require('devcontainers.docker')
local log = require('devcontainers.log').dap

local listeners_installed = false

---@param path string
---@param from string
---@param to string
---@return string?
local function replace_prefix(path, from, to)
    if path == from then
        return to
    end
    local prefix = from
    if not vim.endswith(prefix, '/') then
        prefix = prefix .. '/'
    end
    if vim.startswith(path, prefix) then
        return to .. path:sub(#from + 1)
    end
    return nil
end

---@param uri string
---@return string? container
---@return string? path
local function parse_container_uri(uri)
    local scheme = uri:match('^([a-zA-Z]+[a-zA-Z0-9.+-]*):')
    if scheme ~= 'docker' and scheme ~= 'podman' then
        return nil, nil
    end
    local container, path = uri:match('^[a-zA-Z]+[a-zA-Z0-9.+-]*://?/?([^/]+)(/.*)')
    if container and path then
        return container, path
    end
    return nil, nil
end

---@param workspace_dir string
---@return { host_to_container: fun(path: string): string?, container_to_host: fun(path: string): string? }
local function make_mappers(workspace_dir)
    local info = cache.get(workspace_dir)
    local remote_dir = info.remote_dir
    local container_name = info.container_name
    if vim.startswith(container_name, '/') then
        container_name = container_name:sub(2)
    end

    local function host_to_container(path)
        if type(path) ~= 'string' or path == '' then
            return nil
        end

        local container, container_path = parse_container_uri(path)
        if container and container_path then
            local name = container
            if vim.startswith(name, '/') then
                name = name:sub(2)
            end
            if name == container_name then
                return container_path
            end
            return nil
        end

        return replace_prefix(path, workspace_dir, remote_dir)
    end

    local function container_to_host(path)
        if type(path) ~= 'string' or path == '' then
            return nil
        end
        local mapped = replace_prefix(path, remote_dir, workspace_dir)
        if mapped then
            return mapped
        end
        if vim.startswith(path, '/') then
            return docker.uri_from_container_name(info.container_name, vim.fs.normalize(path))
        end
        return nil
    end

    return {
        host_to_container = host_to_container,
        container_to_host = container_to_host,
    }
end

local mappers_cache = {}

---@param session dap.Session
---@return string?
local function get_workspace_dir(session)
    local dc = session.config and session.config._devcontainers
    return dc and dc.workspace_dir
end

---@param session dap.Session
---@return { host_to_container: fun(path: string): string?, container_to_host: fun(path: string): string? }?
local function get_mappers(session)
    local workspace_dir = get_workspace_dir(session)
    if not workspace_dir then
        return nil
    end
    if not mappers_cache[workspace_dir] then
        local ok, mappers = pcall(make_mappers, workspace_dir)
        if not ok then
            log.error('Failed to create DAP path mappers for %s: %s', workspace_dir, mappers)
            return nil
        end
        mappers_cache[workspace_dir] = mappers
    end
    return mappers_cache[workspace_dir]
end

---@param session dap.Session
---@return boolean
local function is_devcontainer_session(session)
    return get_workspace_dir(session) ~= nil
end

---@param source dap.Source|nil
---@param map fun(path: string): string?
local function map_source(source, map)
    if type(source) ~= 'table' or type(source.path) ~= 'string' then
        return
    end
    local mapped = map(source.path)
    if mapped and mapped ~= source.path then
        log.trace('map source.path: %s -> %s', source.path, mapped)
        source.path = mapped
    end
end

---@param command string
---@param arguments any
---@param map fun(path: string): string?
---@return any
local function map_request_args(command, arguments, map)
    if type(arguments) ~= 'table' then
        return arguments
    end

    if command == 'setBreakpoints' then
        map_source(arguments.source, map)
    end

    return arguments
end

---@param session dap.Session
function M.attach_session(session)
    if session._devcontainers_request_wrapped then
        return
    end
    if not is_devcontainer_session(session) then
        return
    end

    local mappers = get_mappers(session)
    if not mappers then
        return
    end

    session._devcontainers_request_wrapped = true
    local orig_request = session.request
    function session:request(command, arguments, on_result)
        if is_devcontainer_session(self) then
            local m = get_mappers(self)
            if m then
                arguments = map_request_args(command, arguments, m.host_to_container)
            end
        end
        return orig_request(self, command, arguments, on_result)
    end

    local handlers = session.handlers
    local reverse_requests = handlers and handlers.reverse_requests
    local orig_run_in_terminal = reverse_requests and reverse_requests.runInTerminal
    if type(orig_run_in_terminal) == 'function' then
        reverse_requests.runInTerminal = function(s, request)
            if is_devcontainer_session(s) then
                local workspace_dir = get_workspace_dir(s)
                local m = get_mappers(s)
                local args = request.arguments
                if workspace_dir and m and type(args) == 'table' and type(args.args) == 'table' and #args.args > 0 then
                    local container_workdir
                    if type(args.cwd) == 'string' and args.cwd ~= '' then
                        container_workdir = m.host_to_container(args.cwd) or args.cwd
                    end

                    local cmd_args = {}
                    if container_workdir and container_workdir ~= '' then
                        table.insert(cmd_args, '--workdir')
                        table.insert(cmd_args, container_workdir)
                    end
                    table.insert(cmd_args, '--')
                    vim.list_extend(cmd_args, args.args)

                    args.args = cli.cmd(workspace_dir, 'exec', unpack(cmd_args))
                    args.cwd = workspace_dir
                end
            end
            return orig_run_in_terminal(s, request)
        end
    end

    log.debug('Wrapped session.request for devcontainer DAP session: %s', get_workspace_dir(session))
end

local RESPONSE_SOURCE_PATHS = {
    stackTrace = function(response, map)
        for _, frame in ipairs(response.stackFrames or {}) do
            map_source(frame.source, map)
        end
    end,
    scopes = function(response, map)
        for _, scope in ipairs(response.scopes or {}) do
            map_source(scope.source, map)
        end
    end,
    setBreakpoints = function(response, map)
        for _, bp in ipairs(response.breakpoints or {}) do
            map_source(bp.source, map)
        end
    end,
}

local EVENT_SOURCE_PATHS = {
    event_breakpoint = function(body, map)
        local breakpoint = body.breakpoint
        if type(breakpoint) == 'table' then
            map_source(breakpoint.source, map)
        end
    end,
    event_output = function(body, map)
        map_source(body.source, map)
    end,
}

function M.ensure_listeners()
    if listeners_installed then
        return
    end
    listeners_installed = true

    dap.listeners.after.initialize['devcontainers'] = function(session)
        if is_devcontainer_session(session) then
            M.attach_session(session)
        end
    end

    for command, visit in pairs(RESPONSE_SOURCE_PATHS) do
        dap.listeners.before[command]['devcontainers'] = function(session, err, response)
            if err or not is_devcontainer_session(session) or type(response) ~= 'table' then
                return
            end
            local mappers = get_mappers(session)
            if not mappers then
                return
            end
            visit(response, mappers.container_to_host)
        end
    end

    for event, visit in pairs(EVENT_SOURCE_PATHS) do
        dap.listeners.before[event]['devcontainers'] = function(session, body)
            if not is_devcontainer_session(session) or type(body) ~= 'table' then
                return
            end
            local mappers = get_mappers(session)
            if not mappers then
                return
            end
            visit(body, mappers.container_to_host)
        end
    end

    log.debug('Installed devcontainers DAP listeners')
end

--- Mark config as devcontainer-mapped and ensure listeners are installed.
---@param config dap.Configuration
---@param workspace_dir string
function M.mark_config(config, workspace_dir)
    M.ensure_listeners()
    config._devcontainers = vim.tbl_extend('force', config._devcontainers or {}, {
        workspace_dir = workspace_dir,
    })
end

return M
