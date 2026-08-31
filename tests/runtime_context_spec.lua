---@mod tests.runtime_context_spec Unit tests for owned context editing + compaction.

local h = require("tests.harness")
local Context = require("agent_core.runtime.context")

local function msg(role, content)
  return { role = role, content = content }
end

h.describe("runtime.context token estimation", function()
  h.it("estimates text by chars-per-token", function()
    h.equals(1, Context.estimate_text("abcd", 0.25))
    h.equals(2, Context.estimate_text("abcde", 0.25))
    h.equals(0, Context.estimate_text(""))
    h.equals(0, Context.estimate_text(nil))
  end)

  h.it("estimates a message including role overhead", function()
    h.equals(Context.estimate_text("abcd", 0.25) + 4, Context.estimate_message(msg("user", "abcd"), 0.25))
  end)

  h.it("sums total tokens across messages", function()
    local msgs = { msg("user", "abcd"), msg("assistant", "efgh") }
    h.equals(2 + 8, Context.total_tokens(msgs, 0.25))
  end)
end)

h.describe("runtime.context compaction policy", function()
  local cfg = { soft_threshold = 10, hard_threshold = 20, tokens_per_char = 1, keep_last_turns = 1 }

  h.it("returns nil under the soft threshold", function()
    h.equals(nil, Context.should_compact({ msg("user", "hi") }, cfg))
  end)

  h.it("returns soft between thresholds", function()
    -- one message = 2 chars + 4 overhead = 6 tokens; two messages = 12 tokens
    h.equals("soft", Context.should_compact({ msg("user", "hi"), msg("assistant", "ok") }, cfg))
  end)

  h.it("returns hard above the hard threshold", function()
    local msgs = {}
    for _ = 1, 8 do
      msgs[#msgs + 1] = msg("user", "hello") -- 5 + 4 = 9 tokens each
    end
    h.equals("hard", Context.should_compact(msgs, cfg))
  end)
end)

h.describe("runtime.context keep_recent", function()
  h.it("splits older from the last N turns", function()
    local msgs = {
      msg("user", "a"),
      msg("assistant", "b"),
      msg("user", "c"),
      msg("assistant", "d"),
    }
    local older, recent = Context.keep_recent(msgs, 1)
    h.equals(2, #older)
    h.equals(2, #recent)
    h.equals("c", recent[1].content)
    h.equals("d", recent[2].content)
  end)
end)

h.describe("runtime.context hard_truncate", function()
  h.it("drops oldest non-system messages until under threshold", function()
    local msgs = { { role = "system", content = "sys" } }
    for i = 1, 10 do
      msgs[#msgs + 1] = msg("user", string.rep("x", 10)) -- 10 + 4 = 14 tokens
    end
    local out = Context.hard_truncate(msgs, { hard_threshold = 60, tokens_per_char = 1 })
    h.truthy(Context.total_tokens(out, 1) <= 60)
    h.equals("system", out[1].role)
  end)

  h.it("preserves the system message at the front", function()
    local out = Context.hard_truncate(
      { { role = "system", content = "s" }, msg("user", "aaaaaaaaaa") },
      { hard_threshold = 5, tokens_per_char = 1 }
    )
    h.equals("system", out[1].role)
  end)
end)

h.describe("runtime.context build_compaction_request", function()
  h.it("emits a summary prompt with the older turns", function()
    local req = Context.build_compaction_request({
      msg("user", "fix the bug"),
      msg("assistant", "on it"),
      msg("user", "also the tests"),
    }, { keep_last_turns = 1 })
    h.matches("Summarize the conversation", req.prompt)
    h.matches("fix the bug", req.prompt)
    h.truthy(req.system)
  end)

  h.it("carries the cheaper compaction provider/model", function()
    local req = Context.build_compaction_request({ msg("user", "x") }, {
      keep_last_turns = 1,
      compaction_provider = "gemini",
      compaction_model = "gemini-2.0-flash",
    })
    h.equals("gemini", req.provider)
    h.equals("gemini-2.0-flash", req.model)
  end)
end)

h.describe("runtime.context edit", function()
  h.it("drops a message by index", function()
    local out = Context.edit({ msg("user", "a"), msg("assistant", "b") }, { { index = 1, op = "drop" } })
    h.equals(1, #out)
    h.equals("assistant", out[1].role)
  end)

  h.it("drops the first message matching a predicate", function()
    local out = Context.edit(
      { msg("user", "a"), msg("assistant", "b"), msg("assistant", "c") },
      { { find = { role = "assistant" }, op = "drop" } }
    )
    h.equals(2, #out)
    h.equals("c", out[2].content)
  end)

  h.it("truncates a message's content", function()
    local out = Context.edit({ msg("user", "0123456789") }, { { index = 1, op = "truncate", max_chars = 4 } })
    h.equals("0123", out[1].content)
  end)

  h.it("does not mutate the input list", function()
    local input = { msg("user", "a") }
    Context.edit(input, { { index = 1, op = "drop" } })
    h.equals(1, #input)
  end)
end)
