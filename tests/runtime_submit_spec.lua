---@mod tests.runtime_submit_spec Unit tests for runtime.submit slash/context dispatch.

local h = require("tests.harness")
local runtime = require("agent_core.runtime")
local Modes = require("agent_core.modes")
local Profiles = require("agent_core.profiles")
local Slash = require("agent_core.runtime.slash")
local Keys = require("agent_core.keys")

-- Saved package.loaded entries for the turn-path stubs.
local saved_ui, saved_runner, saved_mcp

--- Stub the UI, system-prompt assembly, and MCP bridge so the turn path is
--- reachable headlessly without spawning providers or servers.
local function install_turn_stubs()
  saved_ui = package.loaded["agent_core.runtime.ui"]
  saved_runner = package.loaded["agent_core.runner"]
  saved_mcp = package.loaded["agent_core.runtime.mcp"]
  local calls = { run = {} }
  package.loaded["agent_core.runtime.ui"] = {
    find = function()
      return nil
    end,
    add = function(session)
      return session
    end,
    run = function(pane, text, opts)
      calls.run[#calls.run + 1] = { pane = pane, text = text, opts = opts }
    end,
    open = function() end,
  }
  package.loaded["agent_core.runner"] = {
    build_system_prompt = function()
      return ""
    end,
  }
  package.loaded["agent_core.runtime.mcp"] = { config = { enabled = false } }
  return calls
end

local function uninstall_turn_stubs()
  package.loaded["agent_core.runtime.ui"] = saved_ui
  package.loaded["agent_core.runner"] = saved_runner
  package.loaded["agent_core.runtime.mcp"] = saved_mcp
end

local function snapshot_state()
  return {
    sessions = runtime._sessions,
    active = runtime._active,
    g_mode = vim.g.agent_mode,
    g_mode_prompt = vim.g.agent_mode_prompt,
    g_profile = vim.g.agent_active_profile,
    g_persona = vim.g.agent_persona,
  }
end

local function restore_state(s)
  runtime._sessions = s.sessions
  runtime._active = s.active
  vim.g.agent_mode = s.g_mode
  vim.g.agent_mode_prompt = s.g_mode_prompt
  vim.g.agent_active_profile = s.g_profile
  vim.g.agent_persona = s.g_persona
end

local function with_temp_keys(fn)
  local saved = Keys.path()
  local tmp = vim.fn.tempname()
  Keys.set_path(tmp)
  local ok, err = pcall(fn)
  Keys.set_path(saved)
  vim.fn.delete(tmp)
  if not ok then
    error(err, 0)
  end
end

h.describe("runtime.submit dispatch", function()
  h.it("/mode switches the active mode", function()
    local s = snapshot_state()
    with_temp_keys(function()
      runtime.submit("/mode agent")
      h.equals("agent", Modes.get_active())
    end)
    restore_state(s)
  end)

  h.it("/profile switches the active profile", function()
    local s = snapshot_state()
    local saved_prompt = Keys.prompt
    Keys.prompt = function() end -- no key stored; avoid the blocking vim.ui.input prompt
    with_temp_keys(function()
      runtime.submit("/profile Claude")
      h.equals("Claude", Profiles.get_active())
    end)
    Keys.prompt = saved_prompt
    restore_state(s)
  end)

  h.it("/workflow runs the named workflow definition", function()
    local W = require("agent_core.runtime.workflows")
    local saved_list, saved_run = W.list, W.run
    local tmpfile = vim.fn.tempname()
    local f = io.open(tmpfile, "w")
    f:write("step: hello")
    f:close()
    W.list = function()
      return { { name = "triage", path = tmpfile } }
    end
    local run_args
    W.run = function(def, ctx, cb)
      run_args = { def = def, ctx = ctx }
      cb(nil)
    end
    runtime.submit("/workflow triage")
    h.truthy(run_args, "workflow.run should be invoked")
    h.equals("step: hello", run_args.def)
    W.list = saved_list
    W.run = saved_run
    vim.fn.delete(tmpfile)
  end)

  h.it("/agent submits to a fresh session", function()
    local calls = install_turn_stubs()
    local s = snapshot_state()
    with_temp_keys(function()
      local session = runtime.submit("/agent do x")
      h.truthy(session, "a session should be created")
      h.equals(1, #calls.run)
      h.equals("do x", calls.run[1].text)
    end)
    restore_state(s)
    uninstall_turn_stubs()
  end)

  h.it("/plan switches mode and submits the prompt", function()
    local calls = install_turn_stubs()
    local s = snapshot_state()
    with_temp_keys(function()
      runtime.submit("/plan build y")
      h.equals("plan", Modes.get_active())
      h.equals(1, #calls.run)
      h.equals("build y", calls.run[1].text)
    end)
    restore_state(s)
    uninstall_turn_stubs()
  end)

  h.it("plain prompt expands @file variables into the turn", function()
    local calls = install_turn_stubs()
    local s = snapshot_state()
    local saved_file = Slash.resolvers.file
    Slash.resolvers.file = function(arg)
      return "FILE_CONTENT:" .. tostring(arg)
    end
    with_temp_keys(function()
      runtime.submit("read @file:notes.txt")
      h.equals(1, #calls.run)
      h.equals("read FILE_CONTENT:notes.txt", calls.run[1].text)
    end)
    Slash.resolvers.file = saved_file
    restore_state(s)
    uninstall_turn_stubs()
  end)

  h.it("a plain prompt runs exactly one turn when MCP is disabled", function()
    local calls = install_turn_stubs()
    local s = snapshot_state()
    with_temp_keys(function()
      runtime.submit("hello world")
      h.equals(1, #calls.run, "exactly one turn should run")
      h.equals("hello world", calls.run[1].text)
    end)
    restore_state(s)
    uninstall_turn_stubs()
  end)
end)
