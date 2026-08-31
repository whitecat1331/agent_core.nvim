---@mod tests.autoswitch_spec Unit tests for agent_core.autoswitch.

local h = require("tests.harness")
local Autoswitch = require("agent_core.autoswitch")

h.describe("autoswitch", function()
  h.it("routes implementation work to DeepSeek (cloud)", function()
    local r = Autoswitch.heuristic_classify("implement the login feature")
    h.truthy(r, "should classify")
    h.equals("DeepSeek (cloud)", r.profile)
  end)

  h.it("routes summarization to Gemini", function()
    local r = Autoswitch.heuristic_classify("summarize this long document")
    h.truthy(r, "should classify")
    h.equals("Gemini", r.profile)
  end)

  h.it("routes security review to Claude", function()
    local r = Autoswitch.heuristic_classify("review the security and architecture")
    h.truthy(r, "should classify")
    h.equals("Claude", r.profile)
  end)

  h.it("routes private/offline work to a custom GPU Ollama agent", function()
    local core = require("agent_core")
    local saved = vim.deepcopy(core.config.profiles)
    core.config.profiles = {
      extra = {
        {
          name = "GPU Ollama (qwen2.5-coder)",
          provider = "ollama",
          model = "qwen2.5-coder:7b-instruct",
          endpoint = "http://10.0.1.85:11434",
          trust = "private-remote",
          system_prompt = "private GPU box",
          autoswitch = true,
          keywords = { { "private", 2 }, { "offline", 2 }, "confidential", "sensitive" },
          when_to_use = "private, offline, or sensitive coding",
        },
      },
    }
    local r = Autoswitch.heuristic_classify("keep this confidential and do not upload it anywhere")
    h.truthy(r, "should classify")
    h.equals("GPU Ollama (qwen2.5-coder)", r.profile)
    core.config.profiles = saved
  end)

  h.it("returns nil for unmatched text", function()
    h.equals(nil, Autoswitch.heuristic_classify("zzz"))
    h.equals(nil, Autoswitch.heuristic_classify(""))
  end)
end)
