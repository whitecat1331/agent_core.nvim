---@mod tests.profiles_spec Unit tests for agent_core.profiles.

local h = require("tests.harness")
local Profiles = require("agent_core.profiles")

h.describe("profiles", function()
  h.it("exposes four default profiles", function()
    h.equals(4, #Profiles.all())
  end)

  h.it("find resolves a profile by name", function()
    local p = Profiles.find("Claude")
    h.truthy(p, "Claude profile should exist")
    h.equals("claude", p.provider)
  end)

  h.it("find returns nil for unknown names", function()
    h.equals(nil, Profiles.find("nonexistent"))
  end)

  h.it("DeepSeek (local) is excluded from autoswitch", function()
    local p = Profiles.find("DeepSeek (local)")
    h.truthy(p, "local profile should exist")
    h.equals(false, p.autoswitch)
  end)

  h.it("cloud profiles are autoswitch-eligible", function()
    for _, name in ipairs({ "DeepSeek (cloud)", "Gemini", "Claude" }) do
      local p = Profiles.find(name)
      h.truthy(p.autoswitch, name .. " should be autoswitch-eligible")
    end
  end)
end)
