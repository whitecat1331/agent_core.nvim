---@mod tests.bestofn_spec Unit tests for agent_core.bestofn profile resolution.

local h = require("tests.harness")
local BestOfN = require("agent_core.bestofn")

h.describe("bestofn", function()
  h.it("resolve_profiles returns a list of eligible profiles", function()
    local profiles = BestOfN.resolve_profiles()
    h.truthy(type(profiles) == "table", "resolve_profiles should return a table")
    for _, p in ipairs(profiles) do
      h.truthy(p.name and p.name ~= "", "each profile should have a name")
    end
  end)

  h.it("resolve_profiles only returns autoswitch-enabled profiles by default", function()
    local profiles = BestOfN.resolve_profiles()
    for _, p in ipairs(profiles) do
      h.truthy(p.autoswitch ~= false, "default resolution excludes autoswitch = false")
      h.truthy(p.provider and p.model, "eligible profiles have a provider and model")
    end
  end)
end)
