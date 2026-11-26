local function reset_module(name)
  package.loaded[name] = nil
end

local function fresh_dap()
  reset_module('devcontainers.dap')

  local listeners = {
    before = setmetatable({}, {
      __index = function(t, k)
        t[k] = {}
        return t[k]
      end,
    }),
    after = setmetatable({}, {
      __index = function(t, k)
        t[k] = {}
        return t[k]
      end,
    }),
  }

  package.loaded['dap'] = {
    listeners = listeners,
  }

  package.loaded['devcontainers.cache'] = {
    get = function(workspace_dir)
      return {
        remote_dir = '/workspaces/project',
        container_name = '/my-container',
        workspace_dir = workspace_dir,
      }
    end,
  }

  package.loaded['devcontainers.log'] = {
    dap = {
      trace = function() end,
      debug = function() end,
      warn = function() end,
      error = function() end,
    },
  }

  package.loaded['devcontainers.docker'] = {
    uri_from_container_name = function(container_name, abspath)
      local name = container_name
      if vim.startswith(name, '/') then
        name = name:sub(2)
      end
      return 'docker:///' .. name .. abspath
    end,
  }

  package.loaded['devcontainers.cli'] = {
    cmd = function(workspace_dir, subcommand, ...)
      local args = { 'devcontainer', subcommand, '--workspace-folder', workspace_dir }
      for _, v in ipairs({ ... }) do
        table.insert(args, v)
      end
      return args
    end,
  }

  local dap_mod = require('devcontainers.dap')
  return dap_mod, listeners
end

local function make_session(workspace_dir)
  return {
    config = {
      _devcontainers = {
        workspace_dir = workspace_dir,
      },
    },
    request = function(self, command, arguments, on_result)
      self._last_request = { command = command, arguments = arguments, on_result = on_result }
      return 'orig'
    end,
  }
end

describe('devcontainers.dap', function()
  local dap_mod, listeners

  before_each(function()
    dap_mod, listeners = fresh_dap()
  end)

  it('does not install listeners for non-devcontainer sessions', function()
    dap_mod.ensure_listeners()
    local session = { config = {}, request = function() end }
    local response = {
      stackFrames = {
        { source = { path = '/workspaces/project/main.c' } },
      },
    }

    listeners.before.stackTrace.devcontainers(session, nil, response)
    assert.equals('/workspaces/project/main.c', response.stackFrames[1].source.path)
  end)

  it('maps stackTrace response paths from container to host', function()
    dap_mod.ensure_listeners()
    local session = make_session('/home/user/project')
    local response = {
      stackFrames = {
        { source = { path = '/workspaces/project/src/main.c' } },
        { source = { path = '/usr/include/stdio.h' } },
      },
    }

    listeners.before.stackTrace.devcontainers(session, nil, response)

    assert.equals('/home/user/project/src/main.c', response.stackFrames[1].source.path)
    assert.equals('docker:///my-container/usr/include/stdio.h', response.stackFrames[2].source.path)
  end)

  it('maps unmapped container paths to docker URIs', function()
    dap_mod.ensure_listeners()
    local session = make_session('/home/user/project')
    local body = { source = { path = '/opt/vendor/lib.c' } }

    listeners.before.event_output.devcontainers(session, body)

    assert.equals('docker:///my-container/opt/vendor/lib.c', body.source.path)
  end)

  it('maps scopes response source paths from container to host', function()
    dap_mod.ensure_listeners()
    local session = make_session('/home/user/project')
    local response = {
      scopes = {
        { source = { path = '/workspaces/project/src/main.c' } },
      },
    }

    listeners.before.scopes.devcontainers(session, nil, response)
    assert.equals('/home/user/project/src/main.c', response.scopes[1].source.path)
  end)

  it('maps setBreakpoints response breakpoint source paths from container to host', function()
    dap_mod.ensure_listeners()
    local session = make_session('/home/user/project')
    local response = {
      breakpoints = {
        { source = { path = '/workspaces/project/src/main.c' } },
      },
    }

    listeners.before.setBreakpoints.devcontainers(session, nil, response)
    assert.equals('/home/user/project/src/main.c', response.breakpoints[1].source.path)
  end)

  it('maps event_breakpoint source path from container to host', function()
    dap_mod.ensure_listeners()
    local session = make_session('/home/user/project')
    local body = {
      breakpoint = { source = { path = '/workspaces/project/src/main.c' } },
    }

    listeners.before.event_breakpoint.devcontainers(session, body)
    assert.equals('/home/user/project/src/main.c', body.breakpoint.source.path)
  end)

  it('maps event_output source path from container to host', function()
    dap_mod.ensure_listeners()
    local session = make_session('/home/user/project')
    local body = { source = { path = '/workspaces/project/src/main.c' } }

    listeners.before.event_output.devcontainers(session, body)
    assert.equals('/home/user/project/src/main.c', body.source.path)
  end)

  it('wraps session.request and maps setBreakpoints args host to container', function()
    dap_mod.ensure_listeners()
    local session = make_session('/home/user/project')

    listeners.after.initialize.devcontainers(session)

    local args = { source = { path = '/home/user/project/src/main.c' } }
    local result = session:request('setBreakpoints', args, function() end)

    assert.equals('orig', result)
    assert.equals('/workspaces/project/src/main.c', session._last_request.arguments.source.path)
  end)

  it('maps docker host URI to container path on setBreakpoints', function()
    dap_mod.ensure_listeners()
    local session = make_session('/home/user/project')

    listeners.after.initialize.devcontainers(session)

    local args = { source = { path = 'docker:///my-container/workspaces/project/src/main.c' } }
    session:request('setBreakpoints', args, function() end)

    assert.equals('/workspaces/project/src/main.c', session._last_request.arguments.source.path)
  end)

  it('maps podman host URI to container path on setBreakpoints', function()
    dap_mod.ensure_listeners()
    local session = make_session('/home/user/project')

    listeners.after.initialize.devcontainers(session)

    local args = { source = { path = 'podman:///my-container/workspaces/project/src/main.c' } }
    session:request('setBreakpoints', args, function() end)

    assert.equals('/workspaces/project/src/main.c', session._last_request.arguments.source.path)
  end)

  it('does not wrap or map when session is not devcontainer', function()
    dap_mod.ensure_listeners()
    local session = {
      config = {},
      request = function(self, command, arguments)
        self._last_request = { command = command, arguments = arguments }
      end,
    }

    listeners.after.initialize.devcontainers(session)

    local args = { source = { path = '/home/user/project/src/main.c' } }
    session:request('setBreakpoints', args)
    assert.equals('/home/user/project/src/main.c', session._last_request.arguments.source.path)
  end)

  it('ensure_listeners is idempotent', function()
    dap_mod.ensure_listeners()
    local first = listeners.before.stackTrace.devcontainers
    dap_mod.ensure_listeners()
    assert.equals(first, listeners.before.stackTrace.devcontainers)
  end)

  it('wraps runInTerminal to exec in devcontainer', function()
    dap_mod.ensure_listeners()
    local session = make_session('/home/user/project')
    session.handlers = {
      reverse_requests = {
        runInTerminal = function(_, _)
          return { success = true }
        end,
      },
    }

    listeners.after.initialize.devcontainers(session)

    local request = {
      command = 'runInTerminal',
      arguments = {
        kind = 'integrated',
        cwd = '/home/user/project',
        args = { 'python', 'app.py' },
      },
    }

    local result = session.handlers.reverse_requests.runInTerminal(session, request)

    assert.is_true(result.success)
    assert.equals('/home/user/project', request.arguments.cwd)
    assert.same({
      'devcontainer', 'exec', '--workspace-folder', '/home/user/project',
      '--workdir', '/workspaces/project',
      '--', 'python', 'app.py',
    }, request.arguments.args)
  end)
end)
