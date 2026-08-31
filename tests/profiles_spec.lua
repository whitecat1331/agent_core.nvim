---@mod tests.profiles_spec Unit tests for agent_core.profiles.

local h = require("tests.harness")
local Profiles = require("agent_core.profiles")
local Registry = require("agent_core.registry")
local core = require("agent_core")

h.describe("profiles", function()
  h.it("exposes five default profiles", function()
    h.equals(5, #Profiles.defaults)
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
    for _, name in ipairs({ "DeepSeek (cloud)", "Gemini", "Claude", "OpenAI" }) do
      local p = Profiles.find(name)
      h.truthy(p.autoswitch, name .. " should be autoswitch-eligible")
    end
  end)

  h.it("catalog-only models do not become profiles", function()
    for _, name in ipairs({ "Claude Haiku", "GPT-4o mini", "Gemini 2.5 Pro", "DeepSeek Reasoner", "Qwen2.5-Coder 7B", "CodeLlama 7B" }) do
      h.equals(nil, Profiles.find(name), name .. " should stay catalog-only")
    end
  end)

  h.it("custom profiles merge into all() with provider-based defaults", function()
    local saved = vim.deepcopy(core.config.profiles)
    core.config.profiles = {
      extra = {
        {
          name = "GPU Ollama (qwen2.5-coder)",
          provider = "ollama",
          model = "qwen2.5-coder:7b-instruct",
          endpoint = "http://10.0.1.85:11434",
          trust = "private-remote",
          system_prompt = "You are a coding assistant on a private GPU box.",
          autoswitch = true,
          keywords = { { "private", 2 }, "offline" },
          when_to_use = "private, offline, or sensitive coding",
        },
      },
    }
    local p = Profiles.find("GPU Ollama (qwen2.5-coder)")
    h.truthy(p, "custom profile should surface")
    h.equals(true, p.autoswitch)
    h.equals("ollama", p.provider)
    h.equals("qwen2.5-coder:7b-instruct", p.model)
    h.equals("private-remote", p.trust)
    h.equals("http://10.0.1.85:11434", p.endpoint)
    h.equals("free", p.cost, "ollama cost defaulted")
    h.equals("medium", p.quality_tier, "ollama quality tier defaulted")
    h.truthy(p.keywords ~= nil and #p.keywords > 0, "custom keywords preserved")
    core.config.profiles = saved
  end)

  h.it("custom profiles never override defaults (base wins by name)", function()
    local saved = vim.deepcopy(core.config.profiles)
    core.config.profiles = {
      extra = {
        {
          name = "Claude",
          provider = "claude",
          model = "claude-haiku-4-5-20251001",
          system_prompt = "should not override",
          autoswitch = true,
        },
      },
    }
    local p = Profiles.find("Claude")
    h.equals("claude-sonnet-4-5-20250929", p.model, "default Claude wins over same-name custom")
    core.config.profiles = saved
  end)

  h.it("a full-array config.profiles still appends custom profiles", function()
    local saved = vim.deepcopy(core.config.profiles)
    core.config.profiles = {
      { name = "Only", provider = "openai", model = "gpt-4o", system_prompt = "x", autoswitch = true },
      extra = {
        { name = "Extra Agent", provider = "ollama", model = "m1", system_prompt = "y", autoswitch = true },
      },
    }
    local names = vim.tbl_map(function(p)
      return p.name
    end, Profiles.all())
    h.contains(names, "Only")
    h.contains(names, "Extra Agent")
    core.config.profiles = saved
  end)

  h.it("find_by_provider maps a provider to its profile", function()
    h.equals("OpenAI", Profiles.find_by_provider("openai").name)
    h.equals("Claude", Profiles.find_by_provider("claude").name)
    h.equals(nil, Profiles.find_by_provider("no-such-provider"))
  end)

  h.it("effective_model falls back to p.model when no override matches", function()
    local saved = vim.deepcopy(core.config.registry)
    core.config.registry = { setup_path = vim.fn.tempname() }
    local p = Profiles.find("Claude")
    h.equals(p.model, Profiles.effective_model(p))
    core.config.registry = saved
  end)

  h.it("effective_model honors a matching provider override", function()
    local saved = vim.deepcopy(core.config.registry)
    core.config.registry = { setup_path = vim.fn.tempname() }
    Registry.set_active_model("claude", "claude-haiku-4-5-20251001")
    local p = Profiles.find("Claude")
    h.equals("claude-haiku-4-5-20251001", Profiles.effective_model(p))
    -- A different provider's profile is unaffected.
    h.equals("gemini-2.0-flash", Profiles.effective_model(Profiles.find("Gemini")))
    core.config.registry = saved
  end)

  h.it("get_persona returns the active profile persona global", function()
    vim.g.agent_persona = "SENIOR"
    h.equals("SENIOR", Profiles.get_persona())
    vim.g.agent_persona = nil
    h.equals("", Profiles.get_persona())
  end)

  h.it("every default profile declares a system_prompt persona", function()
    for _, p in ipairs(Profiles.defaults) do
      h.truthy(type(p.system_prompt) == "string" and p.system_prompt ~= "", p.name .. " should declare a persona")
    end
  end)

  h.it("switch_cmd switches directly by name", function()
    local saved = Profiles.switch
    local switched
    Profiles.switch = function(p)
      switched = p
    end
    Profiles.switch_cmd("Claude")
    h.truthy(switched, "switch called")
    h.equals("Claude", switched.name)
    Profiles.switch = saved
  end)

  h.it("switch_cmd warns on an unknown name", function()
    local saved = Profiles.switch
    local called = false
    Profiles.switch = function()
      called = true
    end
    Profiles.switch_cmd("no-such-profile")
    h.falsy(called, "switch must not run for an unknown name")
    Profiles.switch = saved
  end)

  h.it("clear_model_override reverts to the profile default model", function()
    local saved = vim.deepcopy(core.config.registry)
    local saved_get_active = Profiles.get_active
    core.config.registry = { setup_path = vim.fn.tempname() }
    Profiles.get_active = function()
      return "Claude"
    end

    local p = Profiles.find("Claude")
    Registry.set_active_model("claude", "claude-haiku-4-5-20251001")
    h.equals("claude-haiku-4-5-20251001", Profiles.effective_model(p))

    Profiles.clear_model_override()
    h.equals(p.model, Profiles.effective_model(p), "override cleared back to default")
    h.equals(p.model, vim.g.agent_active_model)

    Profiles.get_active = saved_get_active
    core.config.registry = saved
  end)
end)
