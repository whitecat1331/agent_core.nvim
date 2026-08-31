---@mod tests.catalog_spec Unit tests for agent_core.catalog.

local h = require("tests.harness")
local Catalog = require("agent_core.catalog")

h.describe("catalog", function()
  h.it("lookup_model resolves a bundled entry by provider + model", function()
    local c = Catalog.lookup_model("deepseek", "deepseek-chat")
    h.truthy(c, "deepseek-chat present")
    h.equals("deepseek-chat", c.model)
    h.equals("DEEPSEEK_API_KEY", c.api_key_name)
    h.equals(0.27, c.cost_in_per_1m)
    h.equals(1.1, c.cost_out_per_1m)
  end)

  h.it("lookup_model returns nil for unknown models", function()
    h.equals(nil, Catalog.lookup_model("nope", "nope"))
    h.equals(nil, Catalog.lookup_model("deepseek", "not-a-model"))
    h.equals(nil, Catalog.lookup_model(nil, nil))
  end)

  h.it("lookup returns every model for a provider", function()
    local claude = Catalog.lookup("claude")
    h.truthy(#claude >= 2, "claude has multiple models")
    local names = {}
    for _, c in ipairs(claude) do
      names[c.model] = true
    end
    h.truthy(names["claude-sonnet-4-5-20250929"], "sonnet present")
  end)

  h.it("known_providers returns distinct sorted providers", function()
    local p = Catalog.known_providers()
    h.contains(p, "claude")
    h.contains(p, "openai")
    h.contains(p, "gemini")
    h.contains(p, "deepseek")
    h.contains(p, "ollama")
  end)

  h.it("cost_tier buckets per-1M cost", function()
    h.equals("free", Catalog.cost_tier(nil, nil))
    h.equals("free", Catalog.cost_tier(0, 0))
    h.equals("cheap", Catalog.cost_tier(0.2, 0.3))
    h.equals("metered", Catalog.cost_tier(1, 2))
    h.equals("expensive", Catalog.cost_tier(3, 15))
  end)

  h.it("quality_tier buckets a score and falls back to size", function()
    h.equals("high", Catalog.quality_tier(0.9))
    h.equals("medium", Catalog.quality_tier(0.6))
    h.equals("low", Catalog.quality_tier(0.3))
    local gb = 1024 * 1024 * 1024
    h.equals("low", Catalog.quality_tier(nil, 1 * gb))
    h.equals("medium", Catalog.quality_tier(nil, 5 * gb))
    h.equals("high", Catalog.quality_tier(nil, 20 * gb))
    h.equals("medium", Catalog.quality_tier(nil, nil))
  end)

  h.it("augment attaches numeric/authoritative fields without clobbering metadata", function()
    local e = {
      name = "MyDeek",
      provider = "deepseek",
      model = "deepseek-chat",
      roles = { "primary" },
      trust = "third-party-cloud",
      api_key_name = "DEEPSEEK_API_KEY",
      endpoint = "http://example.test",
    }
    Catalog.augment(e)
    h.equals(0.27, e.cost_in_per_1m)
    h.equals(1.1, e.cost_out_per_1m)
    h.equals(0.72, e.quality_score)
    h.equals("metered", e.cost)
    h.equals("medium", e.quality_tier)
    h.equals(false, e.fim)
    h.equals(false, e.reasoning)
    h.equals(128000, e.context_window)
    -- Security/metadata fields untouched.
    h.same({ "primary" }, e.roles)
    h.equals("third-party-cloud", e.trust)
    h.equals("DEEPSEEK_API_KEY", e.api_key_name)
    h.equals("http://example.test", e.endpoint)
    h.equals("MyDeek", e.name)
  end)

  h.it("augment leaves an entry unchanged when the catalog lacks the model", function()
    local e = { name = "x", provider = "ollama", model = "mystery-model", fim = true, cost = "free" }
    Catalog.augment(e)
    h.equals(nil, e.cost_in_per_1m)
    h.equals(nil, e.quality_score)
    h.equals(true, e.fim)
    h.equals("free", e.cost)
  end)

  h.it("bundled snapshot has a version and models", function()
    local b = Catalog.bundled()
    h.truthy(b.version ~= nil, "versioned")
    h.truthy(#b.models > 0, "non-empty")
  end)

  h.it("agent entries carry routing fields, catalog-only entries do not", function()
    local claude = Catalog.lookup_model("claude", "claude-sonnet-4-5-20250929")
    h.truthy(claude.system_prompt ~= nil and claude.system_prompt ~= "", "agent has a persona")
    h.truthy(#claude.keywords > 0, "agent has routing keywords")
    h.truthy(claude.when_to_use ~= nil and claude.when_to_use ~= "", "agent has when_to_use")

    local haiku = Catalog.lookup_model("claude", "claude-haiku-4-5-20251001")
    h.equals(nil, haiku.system_prompt, "catalog-only model has no persona")
    h.equals(nil, haiku.keywords, "catalog-only model has no keywords")
  end)

  h.it("GPU Ollama agent is not bundled (moved to user profiles.json)", function()
    h.equals(nil, Catalog.lookup_model("ollama", "qwen2.5-coder:7b-instruct"))
  end)
end)
