---@mod tests.registry_spec Unit tests for agent_core.registry.

local h = require("tests.harness")
local Registry = require("agent_core.registry")
local core = require("agent_core")

h.describe("registry", function()
  h.it("infer_fim recognizes FIM-trained model families", function()
    h.equals(true, Registry.infer_fim("deepseek-coder:6.7b"))
    h.equals(true, Registry.infer_fim("codellama:7b"))
    h.equals(true, Registry.infer_fim("qwen2.5-coder:7b"))
    h.equals(false, Registry.infer_fim("llama3.2"))
    h.equals(false, Registry.infer_fim("deepseek-r1"))
  end)

  h.it("infer_reasoning recognizes reasoning model families", function()
    h.equals(true, Registry.infer_reasoning("deepseek-r1:7b"))
    h.equals(true, Registry.infer_reasoning("qwen2.5-reasoner"))
    h.equals(false, Registry.infer_reasoning("deepseek-coder:6.7b"))
    h.equals(false, Registry.infer_reasoning("llama3.2"))
  end)

  h.it("infer_quality_tier maps size to low/medium/high", function()
    local gb = 1024 * 1024 * 1024
    h.equals("low", Registry.infer_quality_tier(1 * gb))
    h.equals("medium", Registry.infer_quality_tier(5 * gb))
    h.equals("high", Registry.infer_quality_tier(20 * gb))
    h.equals("medium", Registry.infer_quality_tier(nil))
  end)

  h.it("is_vision detects vision models and rejects text-only models", function()
    h.equals(true, Registry.is_vision("llava:13b"))
    h.equals(true, Registry.is_vision("gpt-4o"))
    h.equals(false, Registry.is_vision("deepseek-chat"))
    h.equals(false, Registry.is_vision("qwen2.5-coder:7b-instruct"))
    h.equals(false, Registry.is_vision(""))
    h.equals(false, Registry.is_vision(nil))
  end)

  h.it("parse_ollama_tags maps /api/tags JSON to tagged entries", function()
    local body = vim.fn.json_encode({
      models = {
        { name = "deepseek-coder:6.7b", size = 4040753920 },
        { name = "deepseek-r1:7b", size = 4700000000 },
        { name = "llama3.2", size = 2019391488 },
      },
    })
    local entries = Registry.parse_ollama_tags(body, "http://127.0.0.1:11434")
    h.equals(3, #entries)

    local coder = nil
    local r1 = nil
    for _, e in ipairs(entries) do
      if e.name == "deepseek-coder:6.7b" then
        coder = e
      elseif e.name == "deepseek-r1:7b" then
        r1 = e
      end
    end
    h.truthy(coder, "coder entry present")
    h.equals("local", coder.trust)
    h.equals("free", coder.cost)
    h.equals(true, coder.fim)
    h.equals(false, coder.reasoning)
    h.equals("medium", coder.quality_tier)
    h.contains(coder.roles, "completion")

    h.truthy(r1, "r1 entry present")
    h.equals(false, r1.fim)
    h.equals(true, r1.reasoning)
  end)

  h.it("parse_ollama_tags returns empty for malformed input", function()
    h.equals(0, #Registry.parse_ollama_tags("not json"))
    h.equals(0, #Registry.parse_ollama_tags('{"nope":true}'))
  end)

  h.it("normalize fills default tags", function()
    local e = Registry.normalize({ name = "x", provider = "ollama", model = "deepseek-coder:6.7b" })
    h.equals("local", e.trust)
    h.equals("free", e.cost)
    h.equals("medium", e.latency)
    h.equals(false, e.fim)
  end)

  h.it("for_role(primary) includes every declared chat profile", function()
    local names = {}
    for _, e in ipairs(Registry.for_role("primary")) do
      names[e.name] = true
    end
    h.truthy(names["DeepSeek (cloud)"], "DeepSeek cloud primary")
    h.truthy(names["DeepSeek (local)"], "DeepSeek local primary")
    h.truthy(names["Gemini"], "Gemini primary")
    h.truthy(names["Claude"], "Claude primary")
  end)

  h.it("by_trust separates cloud from local", function()
    local cloud = {}
    for _, e in ipairs(Registry.by_trust("third-party-cloud")) do
      cloud[e.name] = true
    end
    h.truthy(cloud["DeepSeek (cloud)"], "DeepSeek cloud")
    h.truthy(cloud["Claude"], "Claude")
    h.falsy(cloud["DeepSeek (local)"], "local profile not in cloud tier")
  end)

  h.it("add rejects third-party-cloud without confirmation", function()
    local saved = vim.deepcopy(core.config.registry)
    local tmp = vim.fn.tempname()
    core.config.registry = { path = tmp }
    local _, err = Registry.add({ name = "ext", provider = "openai", model = "gpt", trust = "third-party-cloud" })
    h.truthy(err ~= nil and err:find("confirm", 1, true) ~= nil, "requires confirm")
    core.config.registry = saved
  end)

  h.it("add/remove round-trips a private-remote entry", function()
    local saved = vim.deepcopy(core.config.registry)
    local tmp = vim.fn.tempname()
    core.config.registry = { path = tmp }
    local e, err = Registry.add({
      name = "gpu-box",
      provider = "ollama",
      model = "deepseek-coder:6.7b",
      endpoint = "http://100.64.0.2:11434",
      trust = "private-remote",
    })
    h.truthy(e ~= nil, tostring(err))
    h.equals("private-remote", Registry.find("gpu-box").trust)
    h.equals(true, Registry.remove("gpu-box"))
    h.equals(nil, Registry.find("gpu-box"))
    core.config.registry = saved
  end)

  h.it("parse_ollama_tags stamps endpoint + private-remote trust for remote hosts", function()
    local body = vim.fn.json_encode({
      models = {
        { name = "deepseek-coder:6.7b", size = 4040753920 },
      },
    })
    local entries = Registry.parse_ollama_tags(body, "http://100.64.0.2:11434")
    h.equals(1, #entries)
    h.equals("http://100.64.0.2:11434", entries[1].endpoint)
    h.equals("private-remote", entries[1].trust)
  end)

  h.it("default_ollama_trust maps loopback to local and remote to private-remote", function()
    h.equals("local", Registry.default_ollama_trust("http://127.0.0.1:11434"))
    h.equals("local", Registry.default_ollama_trust("http://localhost:11434"))
    h.equals("private-remote", Registry.default_ollama_trust("http://100.64.0.2:11434"))
  end)

  h.it("ollama_endpoints includes loopback plus declared remotes (deduplicated)", function()
    local saved = vim.deepcopy(core.config.registry)
    core.config.registry = vim.tbl_deep_extend("force", {}, saved or {}, {
      setup_path = vim.fn.tempname(),
      ollama_endpoint = "http://127.0.0.1:11434",
      ollama_endpoints = { "http://100.64.0.2:11434", "http://127.0.0.1:11434" },
    })
    local eps = Registry.ollama_endpoints()
    h.equals(2, #eps)
    h.equals("http://127.0.0.1:11434", eps[1])
    h.equals("http://100.64.0.2:11434", eps[2])
    core.config.registry = saved
  end)

  h.it("set_enabled persists a setup.json override and entry_enabled reflects it", function()
    local saved = vim.deepcopy(core.config.registry)
    core.config.registry = { setup_path = vim.fn.tempname() }

    local ok, err = Registry.set_enabled("Claude", false)
    h.equals(true, ok, tostring(err))
    local entry = { name = "Claude", provider = "claude", model = "x", api_key_name = "ANTHROPIC_API_KEY" }
    h.equals(false, Registry.entry_enabled(entry), "disabled override wins over env key")

    Registry.set_enabled("Claude", true)
    h.equals(true, Registry.entry_enabled(entry), "enabled override applied")

    core.config.registry = saved
  end)

  h.it("add/remove_ollama_endpoint persists and ollama_endpoints merges them", function()
    local saved = vim.deepcopy(core.config.registry)
    core.config.registry = {
      setup_path = vim.fn.tempname(),
      ollama_endpoint = "http://127.0.0.1:11434",
    }

    local ok, err = Registry.add_ollama_endpoint("http://100.64.0.2:11434")
    h.equals(true, ok, tostring(err))

    local eps = Registry.ollama_endpoints()
    h.equals(2, #eps)
    h.equals("http://127.0.0.1:11434", eps[1])
    h.equals("http://100.64.0.2:11434", eps[2])

    -- Duplicate add is rejected.
    local ok2, err2 = Registry.add_ollama_endpoint("http://100.64.0.2:11434")
    h.equals(false, ok2)
    h.truthy(err2 ~= nil, "duplicate add errors")

    local ok3 = Registry.remove_ollama_endpoint("http://100.64.0.2:11434")
    h.equals(true, ok3)
    h.equals(1, #Registry.ollama_endpoints())

    core.config.registry = saved
  end)

  h.it("entry_enabled gives persisted setup override precedence over env", function()
    local saved = vim.deepcopy(core.config.registry)
    core.config.registry = vim.tbl_deep_extend("force", {}, saved or {}, { setup_path = vim.fn.tempname() })
    Registry.save_setup_state({ enabled = { ["Claude"] = false } })

    local entry = { name = "Claude", provider = "claude", model = "x", api_key_name = "ANTHROPIC_API_KEY" }
    -- Even with a key in env, the persisted override (false) wins.
    h.equals(false, Registry.entry_enabled(entry))

    Registry.save_setup_state({ enabled = { ["Claude"] = true } })
    h.equals(true, Registry.entry_enabled(entry))
    core.config.registry = saved
  end)

  h.it("entry_enabled marks ollama as enabled without a key", function()
    local e = { name = "local", provider = "ollama", model = "x" }
    h.equals(true, Registry.entry_enabled(e))
  end)

  h.it("catalog augments chat entries with authoritative flags", function()
    local claude = Registry.find("Claude")
    h.truthy(claude ~= nil, "Claude present in registry")
    h.equals(0.86, claude.quality_score)
    h.equals(3.0, claude.cost_in_per_1m)
    h.equals(15.0, claude.cost_out_per_1m)
    h.equals(true, claude.reasoning)
    h.equals(false, claude.fim)
  end)

  h.it("chat_entries preserves a custom profile's endpoint", function()
    local saved = vim.deepcopy(core.config.profiles)
    core.config.profiles = {
      extra = {
        {
          name = "Remote Agent",
          provider = "ollama",
          model = "qwen2.5-coder:7b-instruct",
          endpoint = "http://100.64.0.2:11434",
          trust = "private-remote",
          system_prompt = "remote",
          autoswitch = true,
        },
      },
    }
    local e = Registry.find("Remote Agent")
    h.truthy(e, "custom profile surfaces in registry")
    h.equals("http://100.64.0.2:11434", e.endpoint)
    h.equals("private-remote", e.trust)
    core.config.profiles = saved
  end)

  h.it("catalog-only chat models surface in the registry (primary role)", function()
    local names = {}
    for _, e in ipairs(Registry.for_role("primary")) do
      names[e.name] = true
    end
    h.truthy(names["OpenAI"], "GPT-4o is now the declared OpenAI profile")
    h.truthy(names["Claude Haiku"], "Claude Haiku surfaced from catalog")
    h.truthy(names["DeepSeek Reasoner"], "DeepSeek Reasoner surfaced from catalog")
  end)

  h.it("eligible_models returns enabled primary/classifier entries", function()
    local saved = vim.deepcopy(core.config.registry)
    core.config.registry = { setup_path = vim.fn.tempname() }
    local names = {}
    for _, e in ipairs(Registry.eligible_models()) do
      names[e.name] = true
    end
    h.truthy(names["DeepSeek (local)"], "local Ollama always eligible")
    h.falsy(names["Claude"], "cloud profile without a key is not eligible")

    Registry.set_enabled("Claude", true)
    local names2 = {}
    for _, e in ipairs(Registry.eligible_models()) do
      names2[e.name] = true
    end
    h.truthy(names2["Claude"], "Claude eligible after enable override")
    core.config.registry = saved
  end)

  h.it("active_model/set_active_model round-trips and clears", function()
    local saved = vim.deepcopy(core.config.registry)
    core.config.registry = { setup_path = vim.fn.tempname() }
    h.equals(nil, Registry.active_model())
    Registry.set_active_model("openai", "gpt-4o-mini")
    local am = Registry.active_model()
    h.equals("openai", am.provider)
    h.equals("gpt-4o-mini", am.model)
    Registry.set_active_model("openai", nil)
    h.equals(nil, Registry.active_model())
    Registry.set_active_model("openai", "gpt-4o-mini")
    Registry.set_active_model(nil, nil)
    h.equals(nil, Registry.active_model(), "set_active_model(nil, nil) also clears")
    core.config.registry = saved
  end)
end)
