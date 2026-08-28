---@mod tests.setup_spec Unit tests for agent_core.setup.

local h = require("tests.harness")
local Setup = require("agent_core.setup")
local core = require("agent_core")
local Registry = require("agent_core.registry")

h.describe("setup", function()
  h.it("needs_setup is true without setup.json or an active profile", function()
    local saved = vim.deepcopy(core.config.registry)
    core.config.registry = vim.tbl_deep_extend("force", {}, saved or {}, { setup_path = vim.fn.tempname() })
    h.equals(true, Setup.needs_setup())
    core.config.registry = saved
  end)

  h.it("detect returns provider key presence and ollama endpoints", function()
    local d = Setup.detect()
    h.truthy(d.providers ~= nil, "providers table present")
    h.truthy(d.providers.claude ~= nil, "claude detected")
    h.truthy(d.providers.openai ~= nil, "openai detected")
    h.truthy(d.providers.gemini ~= nil, "gemini detected")
    h.truthy(d.providers.deepseek ~= nil, "deepseek detected")
    h.equals("ANTHROPIC_API_KEY", d.providers.claude.api_key_name)
    h.truthy(type(d.ollama_endpoints) == "table", "endpoints list present")
  end)

  h.it("form_model returns chat rows with derived tags and enabled flags", function()
    local m = Setup.form_model()
    h.truthy(#m.rows > 0, "rows present")
    local claude = nil
    for _, r in ipairs(m.rows) do
      if r.name == "Claude" then
        claude = r
      end
    end
    h.truthy(claude, "Claude row present")
    h.equals("claude", claude.provider)
    h.equals(false, claude.fim)
    h.truthy(type(claude.enabled) == "boolean", "enabled is boolean")
  end)

  h.it("default_suggestion prefers an enabled cloud profile over local", function()
    local s = Setup.default_suggestion({
      { name = "DeepSeek (local)", provider = "ollama", model = "deepseek-coder:1.3b" },
      { name = "Claude", provider = "claude", model = "x", enabled = true },
    })
    h.equals("balanced", s.model_policy)
    h.equals("any", s.trust_scope)
    h.equals("act_first", s.caution)
    h.equals("Claude", s.default_profile)
  end)

  h.it("default_suggestion falls back to local when no cloud is enabled", function()
    local s = Setup.default_suggestion({
      { name = "DeepSeek (local)", provider = "ollama", model = "deepseek-coder:1.3b" },
    })
    h.equals("DeepSeek (local)", s.default_profile)
  end)

  h.it("parse_suggestion parses a clean JSON object", function()
    local s = Setup.parse_suggestion(
      '{"model_policy":"cheap","trust_scope":"private","caution":"ask_first","default_profile":"Claude"}'
    )
    h.equals("cheap", s.model_policy)
    h.equals("private", s.trust_scope)
    h.equals("ask_first", s.caution)
    h.equals("Claude", s.default_profile)
  end)

  h.it("parse_suggestion tolerates prose and clamps invalid knobs", function()
    local s = Setup.parse_suggestion(
      'Here is my choice:\n```json\n{"model_policy":"nope","trust_scope":"local","caution":"ask_first"}\n```'
    )
    h.equals("balanced", s.model_policy) -- clamped to a valid value
    h.equals("local", s.trust_scope)
    h.equals("ask_first", s.caution)
  end)

  h.it("parse_suggestion returns nil + err for garbage", function()
    local s, err = Setup.parse_suggestion("no json here")
    h.equals(nil, s)
    h.truthy(err ~= nil, "error present")
  end)

  h.it("bootstrap_suggest degrades to deterministic defaults without avante", function()
    local done = false
    Setup.bootstrap_suggest({
      {
        name = "Claude",
        provider = "claude",
        model = "x",
        cost = "metered",
        quality_tier = "high",
        trust = "third-party-cloud",
        fim = false,
        reasoning = true,
      },
    }, function(s, err)
      done = true
      h.truthy(s, "suggestion returned")
      h.equals("balanced", s.model_policy)
      h.equals("any", s.trust_scope)
      h.equals("act_first", s.caution)
    end)
    h.truthy(done, "callback invoked synchronously")
  end)

  h.it("save persists enabled set, keys, and endpoints", function()
    local saved_reg = vim.deepcopy(core.config.registry)
    core.config.registry = vim.tbl_deep_extend("force", {}, saved_reg or {}, { setup_path = vim.fn.tempname() })

    local Keys = require("agent_core.keys")
    local Profiles = require("agent_core.profiles")
    local stored = {}
    local saved_set = Keys.set
    local saved_switch = Profiles.switch
    local saved_active = Profiles.get_active
    Keys.set = function(name, key)
      stored[name] = key
    end
    Profiles.switch = function() end
    Profiles.get_active = function()
      return "Claude"
    end

    Setup.save({
      enabled = { ["Claude"] = true, ["Gemini"] = false },
      keys = { ["Claude"] = "sk-test" },
      endpoints = { "http://gpu:11434" },
      bootstrap = false,
    })

    local state = Registry.load_setup_state()
    h.equals(true, state.enabled["Claude"])
    h.equals(false, state.enabled["Gemini"])
    h.equals("sk-test", stored["Claude"])
    h.same({ "http://gpu:11434" }, state.ollama_endpoints)

    Keys.set = saved_set
    Profiles.switch = saved_switch
    Profiles.get_active = saved_active
    core.config.registry = saved_reg
  end)
end)
