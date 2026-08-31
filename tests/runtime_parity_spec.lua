---@mod tests.runtime_parity_spec End-to-end parity tests for the owned runtime.
---@brief [[
--- Phase 7 Cursor-parity hardening: prove the two gaps the retired runtime couldn't close.
---   1. N sessions on N different models stream concurrently (per-session
---      provider/model, not a process-global).
---   2. run_agent model override creates a subagent session on the overridden
---      model, and non-worktree subagents fan out in parallel.
---   3. The Agents Window grid holds N panes with per-pane model indicators.
---   4. The active session's model can switch mid-flight (next turn picks it up).
--- Concurrency is exercised with vim.defer_fn + vim.wait so the assertions are
--- deterministic under the headless harness.
---@brief ]]

local h = require("tests.harness")
local Providers = require("agent_core.runtime.providers")
local Session = require("agent_core.runtime.session")
local Runtime = require("agent_core.runtime")
local MT = require("agent_core.multitask")
local UI = require("agent_core.runtime.ui")

h.describe("runtime parity: concurrent multi-model sessions", function()
  h.it("runs three sessions on three models concurrently", function()
    local original = Providers.stream
    local started, completed = 0, 0
    local seen = {}
    Providers.stream = function(opts)
      started = started + 1
      seen[opts.model] = (seen[opts.model] or 0) + 1
      -- Defer completion so all three streams overlap in time.
      vim.defer_fn(function()
        completed = completed + 1
        opts.on_stop({ text = "done", tool_calls = {} })
      end, 10)
      return true, nil
    end

    local done = 0
    for _, model in ipairs({ "m1", "m2", "m3" }) do
      Session.new({ provider = "deepseek", model = model }):run({
        user_input = "go",
        tools = {},
        on_complete = function()
          done = done + 1
        end,
      })
    end

    -- All three streams started before any completed → true concurrency, not
    -- sequential execution.
    h.equals(3, started, "all three sessions started")
    h.equals(0, completed, "none completed before all started (concurrent)")

    local waited = vim.wait(2000, function()
      return completed == 3
    end, 10)
    Providers.stream = original

    h.truthy(waited, "all sessions completed within the wait window")
    h.equals(3, done)
    h.equals(1, seen.m1, "m1 streamed exactly once")
    h.equals(1, seen.m2, "m2 streamed exactly once")
    h.equals(1, seen.m3, "m3 streamed exactly once")
  end)
end)

h.describe("runtime parity: mid-flight model switch", function()
  h.it("switches the active session's model between turns", function()
    Runtime._sessions = {}
    Runtime._active = 0

    local original = Providers.stream
    local seen = {}
    Providers.stream = function(opts)
      seen[#seen + 1] = opts.model
      opts.on_stop({ text = "ok", tool_calls = {} })
      return true, nil
    end

    local s = Runtime.create_session({ provider = "deepseek", model = "m1" })
    s:run({ user_input = "one", tools = {}, on_complete = function() end })

    local ok, err = Runtime.model(nil, "m2")
    h.equals(nil, err)
    h.truthy(ok)

    s:run({ user_input = "two", tools = {}, on_complete = function() end })

    Providers.stream = original
    Runtime._sessions = {}
    Runtime._active = 0

    h.equals("m1", seen[1], "first turn used the original model")
    h.equals("m2", seen[2], "next turn picked up the switched model")
  end)
end)

h.describe("runtime parity: run_agent model override", function()
  h.it("spawns a subagent on the overridden model", function()
    local original = Providers.stream
    local seen_model = nil
    Providers.stream = function(opts)
      seen_model = opts.model
      opts.on_stop({ text = "subagent done", tool_calls = {} })
      return true, nil
    end

    local result, err
    MT.run_agent_tool().func({ prompt = "do x", profile = "Claude", model = "claude-custom" }, {
      on_complete = function(r, e)
        result = r
        err = e
      end,
    })

    Providers.stream = original

    h.equals("claude-custom", seen_model, "subagent streamed with the overridden model")
    h.equals(nil, err)
    h.truthy(result ~= nil)
  end)

  h.it("fans out two non-worktree subagents in parallel", function()
    local original = Providers.stream
    local started, completed = 0, 0
    Providers.stream = function(opts)
      started = started + 1
      vim.defer_fn(function()
        completed = completed + 1
        opts.on_stop({ text = "done", tool_calls = {} })
      end, 10)
      return true, nil
    end

    local done = 0
    local function launch()
      MT.run_agent_tool().func({ prompt = "task", profile = "Claude" }, {
        on_complete = function()
          done = done + 1
        end,
      })
    end
    launch()
    launch()

    -- Both subagents started before either completed → parallel fan-out.
    h.equals(2, started, "both subagents started")
    h.equals(0, completed, "neither completed before both started (parallel)")

    local waited = vim.wait(2000, function()
      return completed == 2
    end, 10)
    Providers.stream = original

    h.truthy(waited, "both subagents completed")
    h.equals(2, done)
  end)
end)

h.describe("runtime parity: Agents Window grid", function()
  h.it("holds N panes with per-pane model indicators and focus switching", function()
    UI.panes = {}
    UI.active_index = 0
    UI.winids = {}

    for i, model in ipairs({ "m1", "m2", "m3" }) do
      UI.add({
        id = "s" .. i,
        title = "T" .. i,
        provider = "deepseek",
        model = model,
        status = "idle",
        on_text = nil,
      })
    end

    h.equals(3, #UI.panes)
    for i, pane in ipairs(UI.panes) do
      h.truthy(pane.model_label:find("m" .. i, 1, true) ~= nil, "pane " .. i .. " shows its model")
    end

    -- Focus round-trip: next() wraps, focus() selects a specific pane.
    UI.focus(2)
    h.equals(2, UI.active_index)
    UI.next()
    h.equals(3, UI.active_index)
    UI.next()
    h.equals(1, UI.active_index, "next wraps around to the first pane")

    -- Cleanup scratch buffers so they don't leak across tests.
    for _, pane in ipairs(UI.panes) do
      vim.api.nvim_buf_delete(pane.bufnr, { force = true })
    end
    UI.panes = {}
    UI.active_index = 0
    UI.winids = {}
  end)
end)
