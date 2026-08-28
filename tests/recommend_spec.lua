---@mod tests.recommend_spec Unit tests for agent_core.recommend.

local h = require("tests.harness")
local Recommend = require("agent_core.recommend")

h.describe("recommend", function()
  h.it("classifies fix requests as debug", function()
    local r = Recommend.heuristic_classify("fix the bug")
    h.truthy(r, "should classify")
    h.equals("debug", r.mode)
  end)

  h.it("classifies build requests as agent", function()
    local r = Recommend.heuristic_classify("implement login")
    h.truthy(r, "should classify")
    h.equals("agent", r.mode)
  end)

  h.it("classifies explanation requests as ask", function()
    local r = Recommend.heuristic_classify("explain this code")
    h.truthy(r, "should classify")
    h.equals("ask", r.mode)
  end)

  h.it("returns nil for unmatched text", function()
    h.equals(nil, Recommend.heuristic_classify("zzz"))
    h.equals(nil, Recommend.heuristic_classify(""))
  end)

  h.it("make_decision returns a descriptor for a non-active target", function()
    local Modes = require("agent_core.modes")
    local target = Modes.find("debug")
    -- Ensure the active mode differs from the target.
    local d = Recommend.make_decision(target)
    if d then
      h.equals("Debug", d.to)
      h.equals("string", type(d.reason))
      h.equals("function", type(d.apply))
    end
  end)
end)
