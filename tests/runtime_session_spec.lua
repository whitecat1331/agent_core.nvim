---@mod tests.runtime_session_spec Unit tests for the owned session + tool dispatch.

local h = require("tests.harness")
local Tools = require("agent_core.runtime.tools")
local Session = require("agent_core.runtime.session")
local Providers = require("agent_core.runtime.providers")

h.describe("runtime.tools registry", function()
  h.it("registers and looks up tools by name", function()
    Tools.clear()
    Tools.register({ name = "alpha", func = function() end })
    Tools.register({ name = "beta", func = function() end })
    h.truthy(Tools.get("alpha"))
    h.falsy(Tools.get("nope"))
    h.equals(2, #Tools.all())
    Tools.clear()
  end)

  h.it("register_all accepts a list", function()
    Tools.clear()
    Tools.register_all({ { name = "a", func = function() end }, { name = "b", func = function() end } })
    h.equals(2, #Tools.all())
    Tools.clear()
  end)

  h.it("descriptors normalize registered tools", function()
    Tools.clear()
    Tools.register({
      name = "run",
      description = "run a thing",
      param = { type = "table", fields = { { name = "cmd", type = "string" } } },
      func = function() end,
    })
    local d = Tools.descriptors()
    h.equals(1, #d)
    h.equals("run", d[1].name)
    Tools.clear()
  end)
end)

h.describe("runtime.tools execute", function()
  h.it("collapses a synchronous result into on_complete", function()
    local tool = {
      name = "sync",
      func = function(_, _)
        return "done", nil
      end,
    }
    Tools.execute(tool, {}, {
      on_complete = function(result, err)
        h.equals("done", result)
        h.falsy(err)
      end,
    })
  end)

  h.it("collapses a synchronous error into on_complete", function()
    local tool = {
      name = "err",
      func = function(_, _)
        return nil, "boom"
      end,
    }
    Tools.execute(tool, {}, {
      on_complete = function(result, err)
        h.falsy(result)
        h.equals("boom", err)
      end,
    })
  end)

  h.it("supports the async on_complete style", function()
    local tool = {
      name = "async",
      func = function(_, opts)
        vim.defer_fn(function()
          opts.on_complete("late", nil)
        end, 10)
      end,
    }
    Tools.execute(tool, {}, {
      on_complete = function(result, err)
        h.equals("late", result)
        h.falsy(err)
      end,
    })
  end)

  h.it("is idempotent when a tool both returns and calls on_complete", function()
    local count = 0
    local tool = {
      name = "double",
      func = function(_, opts)
        opts.on_complete("first", nil)
        return "second", nil
      end,
    }
    Tools.execute(tool, {}, {
      on_complete = function(result, _)
        count = count + 1
        h.equals("first", result)
      end,
    })
    h.equals(1, count)
  end)

  h.it("reports unknown tools", function()
    Tools.clear()
    Tools.execute_by_name("missing", {}, {
      on_complete = function(result, err)
        h.falsy(result)
        h.matches("unknown tool", err)
      end,
    })
  end)
end)

h.describe("runtime.session", function()
  h.it("holds per-session provider/model fields", function()
    local s = Session.new({ provider = "deepseek", model = "deepseek-chat" })
    h.equals("deepseek", s.provider)
    h.equals("deepseek-chat", s.model)
    h.equals("idle", s.status)
  end)

  h.it("runs a native tool-calling loop end to end", function()
    local original_stream = Providers.stream
    -- Mock the provider: first turn returns a tool call (attempt_completion),
    -- second turn returns plain text and no tools.
    local turn = 0
    Providers.stream = function(opts)
      turn = turn + 1
      if turn == 1 then
        opts.on_chunk("calling")
        opts.on_stop({
          text = "calling",
          tool_calls = { { id = "t1", name = "attempt_completion", arguments = '{"result":"finished task"}' } },
        })
      else
        opts.on_chunk("ok")
        opts.on_stop({ text = "ok", tool_calls = {} })
      end
      return true, nil
    end

    local s = Session.new({ provider = "deepseek", model = "deepseek-chat" })
    local seen = {}
    local done = false
    s:run({
      user_input = "do the thing",
      tools = {},
      on_messages_add = function(msgs)
        for _, m in ipairs(msgs) do
          seen[#seen + 1] = m
        end
      end,
      on_complete = function(err)
        done = true
        h.falsy(err)
      end,
    })

    Providers.stream = original_stream

    h.equals(true, done)
    h.equals("done", s.status)
    -- The loop emits: assistant(tool_calls) + tool result + assistant(final).
    local roles = {}
    for _, m in ipairs(seen) do
      roles[#roles + 1] = m.role
    end
    h.contains(roles, "assistant")
    h.contains(roles, "tool")
    h.equals(2, turn)
  end)

  h.it("propagates a provider error to on_complete", function()
    local original_stream = Providers.stream
    Providers.stream = function(opts)
      opts.on_stop({ error = "upstream down" })
      return true, nil
    end
    local s = Session.new({ provider = "deepseek", model = "deepseek-chat" })
    local err = nil
    s:run({
      user_input = "x",
      tools = {},
      on_complete = function(e)
        err = e
      end,
    })
    Providers.stream = original_stream
    h.equals("upstream down", err)
  end)

  h.it("stops after max_iterations", function()
    local original_stream = Providers.stream
    Providers.stream = function(opts)
      opts.on_stop({ text = "", tool_calls = { { id = "t1", name = "loop", arguments = "{}" } } })
      return true, nil
    end
    local s = Session.new({ provider = "deepseek", model = "deepseek-chat" })
    local err = nil
    s:run({
      user_input = "x",
      tools = {
        {
          name = "loop",
          func = function(_, opts)
            opts.on_complete("again", nil)
          end,
        },
      },
      max_iterations = 2,
      on_complete = function(e)
        err = e
      end,
    })
    Providers.stream = original_stream
    h.matches("max iterations", err)
  end)

  h.it("cancel stops an in-flight run and finishes with cancelled", function()
    local original_stream = Providers.stream
    local captured = nil
    Providers.stream = function(opts)
      captured = opts
      return true, nil
    end
    local s = Session.new({ provider = "deepseek", model = "deepseek-chat" })
    local err = "no-callback"
    s:run({
      user_input = "x",
      tools = {},
      on_complete = function(e)
        err = e
      end,
    })
    h.equals("running", s.status)
    h.truthy(captured ~= nil and captured.on_handle ~= nil, "on_handle should be provided")
    -- Simulate the transport handing back a cancellable handle.
    captured.on_handle({ stop = function() end })
    h.truthy(s:cancel(), "cancel should report true while running")
    h.equals("cancelled", s.status)
    h.equals("cancelled", err)
    Providers.stream = original_stream
  end)

  h.it("cancel is a no-op when the session is idle", function()
    local s = Session.new({ provider = "deepseek", model = "deepseek-chat" })
    h.equals("idle", s.status)
    h.falsy(s:cancel(), "cancel should be a no-op while idle")
  end)
end)
