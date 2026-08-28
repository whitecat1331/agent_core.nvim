---@mod tests.policy_spec Unit tests for agent_core.policy.

local h = require("tests.harness")
local Policy = require("agent_core.policy")
local core = require("agent_core")

h.describe("policy", function()
  h.it("defaults to balanced/any/act_first", function()
    local s = Policy.get_active()
    h.equals("balanced", s.model_policy)
    h.equals("any", s.trust_scope)
    h.equals("act_first", s.caution)
  end)

  h.it("default policy allows everything and keeps the classifier on", function()
    local p = Policy.apply({ model_policy = "balanced", trust_scope = "any", caution = "act_first" })
    h.equals(true, p.classifier_allowed)
    h.equals(false, p.expand_destructive)
    h.equals(false, p.trim_loops)
    h.equals(3, #p.allowed_trusts)
  end)

  h.it("trust_scope local narrows allowed trusts and disables the classifier", function()
    local p = Policy.apply({ trust_scope = "local" })
    h.equals(1, #p.allowed_trusts)
    h.equals("local", p.allowed_trusts[1])
    h.equals(false, p.classifier_allowed)
  end)

  h.it("cheap disables the classifier and trims loops", function()
    local p = Policy.apply({ model_policy = "cheap", trust_scope = "any" })
    h.equals(false, p.classifier_allowed)
    h.equals(true, p.trim_loops)
  end)

  h.it("ask_first expands destructive tools and biases plan/ask", function()
    local p = Policy.apply({ caution = "ask_first" })
    h.equals(true, p.expand_destructive)
    h.truthy(p.mode_bonus("plan") > 0, "plan boosted")
    h.truthy(p.mode_bonus("ask") > 0, "ask boosted")
    h.equals(0, p.mode_bonus("agent"))
  end)

  h.it("good biases plan and prefers reasoning/high tier", function()
    local p = Policy.apply({ model_policy = "good" })
    h.truthy(p.mode_bonus("plan") > 0, "plan boosted")
    h.equals(0, p.mode_bonus("agent"))

    local reasoning =
      { trust = "third-party-cloud", quality_tier = "high", reasoning = true, latency = "low", cost = "metered" }
    local plain =
      { trust = "third-party-cloud", quality_tier = "high", reasoning = false, latency = "low", cost = "metered" }
    h.truthy(p.score(reasoning) > p.score(plain), "reasoning outranks plain")
  end)

  h.it("score filters out disallowed trust tiers", function()
    local p = Policy.apply({ trust_scope = "local" })
    local cloud = { trust = "third-party-cloud", quality_tier = "high", latency = "low", cost = "metered" }
    h.equals(-math.huge, p.score(cloud))
  end)

  h.it("good hard-filters low quality tiers", function()
    local p = Policy.apply({ model_policy = "good" })
    local tiny = { trust = "local", quality_tier = "low", latency = "low", cost = "free" }
    h.equals(-math.huge, p.score(tiny))
  end)

  h.it("cheap prefers free over metered", function()
    local p = Policy.apply({ model_policy = "cheap" })
    local free = { trust = "local", quality_tier = "medium", latency = "medium", cost = "free" }
    local metered = { trust = "third-party-cloud", quality_tier = "high", latency = "low", cost = "metered" }
    h.truthy(p.score(free) > p.score(metered), "free outranks metered under cheap")
  end)

  h.it("cheap ranks numeric cost fields (free over expensive)", function()
    local p = Policy.apply({ model_policy = "cheap" })
    local free = { trust = "local", cost_in_per_1m = 0, cost_out_per_1m = 0, quality_score = 0.4 }
    local expensive = { trust = "third-party-cloud", cost_in_per_1m = 3, cost_out_per_1m = 15, quality_score = 0.9 }
    h.truthy(p.score(free) > p.score(expensive), "free outranks expensive under cheap")
  end)

  h.it("good ranks numeric quality_score", function()
    local p = Policy.apply({ model_policy = "good" })
    local high = { trust = "third-party-cloud", quality_score = 0.9, latency = "low" }
    local low = { trust = "third-party-cloud", quality_score = 0.6, latency = "low" }
    h.truthy(p.score(high) > p.score(low), "higher quality_score ranks first")
  end)

  h.it("good hard-filters below the numeric quality floor", function()
    local p = Policy.apply({ model_policy = "good" })
    local weak = { trust = "local", quality_score = 0.3 }
    h.equals(-math.huge, p.score(weak))
  end)

  h.it("fast hard-filters high latency_hint and ranks measured latency", function()
    local p = Policy.apply({ model_policy = "fast" })
    local slow = { trust = "third-party-cloud", latency_hint = "high" }
    h.equals(-math.huge, p.score(slow))

    local fast = { trust = "local", latency_ms = 150, latency_hint = "low" }
    local slowish = { trust = "local", latency_ms = 4000, latency_hint = "low" }
    h.truthy(p.score(fast) > p.score(slowish), "measured low latency ranks first")
  end)

  h.it("alias expands to the three knobs", function()
    local saved = vim.deepcopy(core.config.policy)
    core.config.policy = { path = vim.fn.tempname() }
    Policy.alias("privacy")
    local s = Policy.get_active()
    h.equals("balanced", s.model_policy)
    h.equals("private", s.trust_scope)
    h.equals("act_first", s.caution)
    core.config.policy = saved
  end)

  h.it("set_knob rejects unknown knobs and values", function()
    local _, err = Policy.set_knob("nope", "x")
    h.truthy(err ~= nil, "unknown knob errors")
    local _, err2 = Policy.set_knob("model_policy", "nope")
    h.truthy(err2 ~= nil, "invalid value errors")
  end)

  h.it("effective_destructive_tools expands under ask_first", function()
    local saved = vim.deepcopy(core.config.policy)
    core.config.policy = { path = vim.fn.tempname() }
    Policy.set({ caution = "act_first" })
    local base = Policy.effective_destructive_tools()
    h.truthy(vim.tbl_contains(base, "bash"), "base includes bash")
    h.falsy(vim.tbl_contains(base, "create"), "act_first does not expand create")

    Policy.set({ caution = "ask_first" })
    local expanded = Policy.effective_destructive_tools()
    h.truthy(vim.tbl_contains(expanded, "create"), "ask_first expands create")
    h.truthy(#expanded > #base, "ask_first list is larger")
    core.config.policy = saved
  end)
end)
