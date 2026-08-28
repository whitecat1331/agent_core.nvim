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

  h.it("returns nil for unmatched text", function()
    h.equals(nil, Autoswitch.heuristic_classify("zzz"))
    h.equals(nil, Autoswitch.heuristic_classify(""))
  end)
end)
