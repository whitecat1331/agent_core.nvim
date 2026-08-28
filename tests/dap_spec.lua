---@mod tests.dap_spec Unit tests for agent_core.dap (the nvim-dap debugger bridge).

local h = require("tests.harness")
local Dap = require("agent_core.dap")

--- Build a fake nvim-dap session whose `request` answers stackTrace/scopes/
--- variables/evaluate synchronously from canned data.
---@return table
local function make_fake_session()
  local calls = {}
  local session = {
    current_frame = { id = 100, name = "main", source = { path = "/a.py", name = "a.py" }, line = 12 },
    stopped_thread_id = 1,
  }
  session.set_breakpoints = function() end
  session.request = function(_, command, args, cb)
    calls[#calls + 1] = { command = command, args = args }
    if command == "stackTrace" then
      cb(nil, {
        stackFrames = {
          { id = 100, name = "main", source = { path = "/a.py", name = "a.py" }, line = 12, column = 1 },
          { id = 99, name = "caller", source = { path = "/a.py", name = "a.py" }, line = 5, column = 1 },
        },
      })
    elseif command == "scopes" then
      cb(nil, {
        scopes = {
          { name = "Locals", variablesReference = 200, expensive = false },
          { name = "Globals", variablesReference = 201, expensive = true },
        },
      })
    elseif command == "variables" then
      cb(nil, {
        variables = {
          { name = "x", value = "42", type = "int", variablesReference = 0, evaluateName = "x" },
        },
      })
    elseif command == "evaluate" then
      cb(nil, { result = "42", variablesReference = 0, type = "int" })
    else
      cb(nil, {})
    end
  end
  session.calls = calls
  return session
end

--- Build a fake nvim-dap module (with optional active session).
---@param session table|nil
---@return table
local function make_fake_dap(session)
  local dap = {
    adapters = { codelldb = {}, debugpy = {} },
    configurations = {
      python = {
        { name = "Python: current file", type = "debugpy", request = "launch" },
        { name = "Python: pytest", type = "debugpy", request = "launch" },
      },
    },
    listeners = {
      after = {
        event_stopped = {},
        event_terminated = {},
        event_exited = {},
        event_output = {},
      },
    },
  }
  dap.session = function()
    return session
  end
  dap.continue = function() end
  dap.step_over = function() end
  dap.step_into = function() end
  dap.step_out = function() end
  dap.pause = function() end
  dap.terminate = function() end
  dap.disconnect = function() end
  dap.restart = function() end
  dap.run = function() end
  dap.clear_breakpoints = function() end
  return dap
end

--- Install a fake dap module and reset the bridge's cached state.
---@param session table|nil
---@return table dap
local function install_fake_dap(session)
  local dap = make_fake_dap(session)
  package.loaded["dap"] = dap
  Dap.state.dap = nil
  Dap.state.listeners_registered = false
  Dap.state.pending = {}
  Dap.state.last_snapshot = nil
  Dap.state.output = ""
  return dap
end

--- Uninstall the fake dap so get_dap() reports "not installed".
local function uninstall_fake_dap()
  package.loaded["dap"] = nil
  Dap.state.dap = nil
  Dap.state.listeners_registered = false
  Dap.state.pending = {}
  Dap.state.last_snapshot = nil
  Dap.state.output = ""
end

h.describe("dap", function()
  h.it("get_dap returns nil when nvim-dap is not installed", function()
    uninstall_fake_dap()
    h.equals(nil, Dap.get_dap())
  end)

  h.it("get_dap caches the module and registers listeners", function()
    local dap = install_fake_dap(make_fake_session())
    h.equals(dap, Dap.get_dap())
    h.equals(Dap._on_stopped, dap.listeners.after.event_stopped["agent_core.dap"])
    h.equals(Dap._on_terminated, dap.listeners.after.event_terminated["agent_core.dap"])
    h.equals(Dap._on_exited, dap.listeners.after.event_exited["agent_core.dap"])
    h.equals(Dap._on_output, dap.listeners.after.event_output["agent_core.dap"])
  end)

  h.it("setup merges config.dap into M.config (and preserves defaults)", function()
    local core = require("agent_core")
    local saved_core_dap = core.config.dap
    local saved_dap_config = vim.deepcopy(Dap.config)
    core.config.dap = { max_frames = 3, max_variables = 7 }
    Dap.setup()
    h.equals(3, Dap.config.max_frames, "custom max_frames should be applied")
    h.equals(7, Dap.config.max_variables, "custom max_variables should be applied")
    h.equals(15000, Dap.config.timeout_ms, "unspecified defaults should be preserved")
    core.config.dap = saved_core_dap
    Dap.config = saved_dap_config
  end)

  h.it("format_frame falls back to source name when path is missing", function()
    local f = Dap.format_frame({ id = 1, name = "f", source = { name = "only-name.py" }, line = 3 })
    h.equals("only-name.py", f.source)
    h.equals("f", f.name)
    h.equals(3, f.line)
  end)

  h.it("format_frames caps at max_frames", function()
    local frames = {}
    for i = 1, 30 do
      frames[#frames + 1] = { id = i, name = "f" .. i, source = { path = "/a.py" }, line = i }
    end
    h.equals(Dap.config.max_frames, #Dap.format_frames(frames))
  end)

  h.it("format_variables caps at max_variables and normalises fields", function()
    local vars = {}
    for i = 1, 150 do
      vars[#vars + 1] = { name = "v" .. i, value = tostring(i), variablesReference = 0 }
    end
    local out = Dap.format_variables(vars)
    h.equals(Dap.config.max_variables, #out)
    h.equals("v1", out[1].name)
    h.equals("1", out[1].value)
  end)

  h.it("list_adapters returns a sorted list", function()
    install_fake_dap(make_fake_session())
    h.same({ "codelldb", "debugpy" }, Dap.list_adapters())
  end)

  h.it("list_configs summarises launch configs for a filetype", function()
    install_fake_dap(make_fake_session())
    local cfgs = Dap.list_configs("python")
    h.equals(2, #cfgs)
    h.equals("Python: current file", cfgs[1].name)
    h.equals("debugpy", cfgs[1].type)
  end)

  h.it("resolve_config resolves by name and returns inline tables unchanged", function()
    install_fake_dap(make_fake_session())
    local c = Dap.resolve_config("Python: current file")
    h.truthy(c and c.type == "debugpy", "named config should resolve")
    local inline = { name = "x", type = "codelldb", request = "launch" }
    h.equals(inline, Dap.resolve_config(inline))
  end)

  h.it("serialize_stop builds a paused snapshot with frames, scopes, and locals", function()
    local session = make_fake_session()
    install_fake_dap(session)
    local snap
    Dap.serialize_stop(session, { reason = "breakpoint", threadId = 1 }, function(s, err)
      h.equals(nil, err)
      snap = s
    end)
    h.truthy(snap, "snapshot should be produced")
    h.equals("paused", snap.kind)
    h.equals("breakpoint", snap.reason)
    h.equals(2, #snap.frames)
    h.equals("main", snap.top_frame.name)
    h.equals("/a.py", snap.top_frame.source)
    h.equals(2, #snap.scopes)
    h.equals(1, #snap.scopes[1].variables)
    h.equals("x", snap.scopes[1].variables[1].name)
    h.equals(0, #snap.scopes[2].variables, "expensive scopes should not auto-expand")
  end)

  h.it("evaluate returns the expression result", function()
    local session = make_fake_session()
    install_fake_dap(session)
    local out
    Dap.evaluate(session, "1 + 1", 100, function(result, err)
      h.equals(nil, err)
      out = result
    end)
    h.equals("42", out.result)
  end)

  h.it("wait_for_stop rejects when nvim-dap is missing", function()
    uninstall_fake_dap()
    local got
    Dap.wait_for_stop(function() end, function(_, err)
      got = err
    end)
    h.truthy(got and got:find("not installed", 1, true), "should report nvim-dap missing")
  end)

  h.it("wait_for_stop resolves on a synthetic stop event", function()
    local session = make_fake_session()
    install_fake_dap(session)
    local snap
    Dap.wait_for_stop(function() end, function(s, err)
      h.equals(nil, err)
      snap = s
    end)
    Dap._on_stopped(session, { reason = "breakpoint", threadId = 1 })
    h.truthy(snap, "snapshot should be resolved")
    h.equals("paused", snap.kind)
  end)

  h.it("wait_for_stop resolves on a terminate event", function()
    local session = make_fake_session()
    install_fake_dap(session)
    local snap
    Dap.wait_for_stop(function() end, function(s, err)
      h.equals(nil, err)
      snap = s
    end)
    Dap._on_terminated(session, {})
    h.equals("terminated", snap.kind)
  end)

  h.it("wait_for_stop resolves with an error when the command throws", function()
    install_fake_dap(make_fake_session())
    local err
    Dap.wait_for_stop(function()
      error("boom")
    end, function(_, e)
      err = e
    end)
    h.truthy(err and err:find("boom", 1, true), "command error should propagate")
  end)

  h.it("_on_output accumulates console output", function()
    install_fake_dap(make_fake_session())
    Dap._on_output(nil, { output = "hello " })
    Dap._on_output(nil, { output = "world" })
    h.equals("hello world", Dap.output())
  end)

  h.it("tools reject a missing on_complete", function()
    local tool = Dap.debug_continue_tool()
    local ok = pcall(tool.func, {}, {})
    h.truthy(ok, "missing on_complete should not raise")
  end)

  h.it("debug_list_adapters reports available adapters", function()
    install_fake_dap(make_fake_session())
    local tool = Dap.debug_list_adapters_tool()
    local result
    tool.func({}, {
      on_complete = function(r, err)
        h.equals(nil, err)
        result = r
      end,
    })
    h.truthy(result:find("codelldb", 1, true), "result should list codelldb")
    h.truthy(result:find("debugpy", 1, true), "result should list debugpy")
  end)

  h.it("debug_get_state errors without an active session", function()
    install_fake_dap(nil)
    local tool = Dap.debug_get_state_tool()
    local err
    tool.func({}, {
      on_complete = function(_, e)
        err = e
      end,
    })
    h.truthy(err and err:find("no active", 1, true), "should report no active session")
  end)

  h.it("debug_evaluate evaluates in the paused frame", function()
    install_fake_dap(make_fake_session())
    local tool = Dap.debug_evaluate_tool()
    local result
    tool.func({ expression = "1 + 1" }, {
      on_complete = function(r, err)
        h.equals(nil, err)
        result = r
      end,
    })
    h.truthy(result:find("42", 1, true), "evaluate result should contain the value")
  end)

  h.it("debug_set_breakpoint requires a file", function()
    install_fake_dap(make_fake_session())
    local tool = Dap.debug_set_breakpoint_tool()
    local err
    tool.func({}, {
      on_complete = function(_, e)
        err = e
      end,
    })
    h.truthy(err and err:find("file is required", 1, true), "should report file required")
  end)

  h.it("debug_continue errors without an active session", function()
    install_fake_dap(nil)
    local tool = Dap.debug_continue_tool()
    local err
    tool.func({}, {
      on_complete = function(_, e)
        err = e
      end,
    })
    h.truthy(err and err:find("no active debug session", 1, true), "should report no active session")
  end)

  h.it("render_snapshot formats a paused snapshot as text", function()
    local text = Dap.render_snapshot({
      kind = "paused",
      reason = "breakpoint",
      threadId = 1,
      top_frame = { name = "main", source = "/a.py", line = 12 },
      frames = { { name = "main", source = "/a.py", line = 12 } },
      scopes = { { name = "Locals", expensive = false, variables = { { name = "x", value = "42", type = "int" } } } },
    })
    h.truthy(text:find("Paused at /a.py:12", 1, true), "should include location")
    h.truthy(text:find("x = 42", 1, true), "should include locals")
  end)
end)
