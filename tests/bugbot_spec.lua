---@mod tests.bugbot_spec Unit tests for agent_core.bugbot pure helpers.

local h = require("tests.harness")
local Bugbot = require("agent_core.bugbot")

h.describe("bugbot", function()
  h.it("chunk_diff preserves all lines", function()
    local diff = table.concat({ "line one", "line two", "line three", "line four" }, "\n")
    local chunks = Bugbot.chunk_diff(diff, 1000)
    h.equals(1, #chunks)
    local joined = table.concat(chunks, "\n")
    h.equals(diff, joined)
  end)

  h.it("chunk_diff splits into multiple chunks under a max size", function()
    local diff = table.concat({ "aaaa", "bbbb", "cccc", "dddd" }, "\n")
    local chunks = Bugbot.chunk_diff(diff, 10)
    h.truthy(#chunks > 1, "should split into multiple chunks")
    for _, c in ipairs(chunks) do
      h.truthy(#c <= 10 + 1, "chunk should respect max size")
    end
  end)

  h.it("parse_findings parses a JSON array", function()
    local findings = Bugbot.parse_findings([[ [ {"severity":"high","file":"a.lua","title":"x"} ] ]])
    h.equals(1, #findings)
    h.equals("high", findings[1].severity)
    h.equals("a.lua", findings[1].file)
  end)

  h.it("parse_findings returns empty for non-JSON", function()
    h.equals(0, #Bugbot.parse_findings("not json at all"))
  end)

  h.it("parse_findings returns empty for invalid JSON", function()
    h.equals(0, #Bugbot.parse_findings("{invalid"))
  end)
end)
