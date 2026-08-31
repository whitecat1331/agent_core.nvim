---@mod tests.multitask_spec Unit tests for agent_core.multitask (pure resolution).

local h = require("tests.harness")
local MT = require("agent_core.multitask")
local Profiles = require("agent_core.profiles")

h.describe("multitask override resolution", function()
  h.it("resolves a named profile", function()
    local p, err = MT.resolve_override_profile({ profile = "Claude" })
    h.equals(nil, err)
    h.truthy(p, "Claude profile should resolve")
    h.equals("claude", p.provider)
  end)

  h.it("overrides model on a named profile without mutating it", function()
    local before = Profiles.find("Claude")
    local original_model = before.model
    local p, err = MT.resolve_override_profile({ profile = "Claude", model = "claude-custom" })
    h.equals(nil, err)
    h.equals("claude-custom", p.model)
    h.equals(original_model, before.model, "original profile model must be unchanged")
  end)

  h.it("errors on an unknown profile", function()
    local p, err = MT.resolve_override_profile({ profile = "nonexistent" })
    h.equals(nil, p)
    h.truthy(err ~= nil, "unknown profile should error")
  end)

  h.it("returns nil,nil when no override is requested", function()
    local p, err = MT.resolve_override_profile({})
    h.equals(nil, p)
    h.equals(nil, err)
  end)

  h.it("errors on a bare model override with no active profile", function()
    local p, err = MT.resolve_override_profile({ model = "some-model" })
    h.equals(nil, p)
    h.truthy(err ~= nil, "bare model override without an active profile should error")
  end)

  h.it("run_agent tool declares profile and model params", function()
    local tool = MT.run_agent_tool()
    h.truthy(tool, "run_agent tool should exist")
    local names = {}
    for _, f in ipairs(tool.param.fields) do
      names[f.name] = true
    end
    h.truthy(names.profile, "profile param should be declared")
    h.truthy(names.model, "model param should be declared")
  end)
end)
