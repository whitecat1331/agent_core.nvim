local M = {}

--- Default profiles. Each bundles provider + model + API key + optional persona.
--- `api_key_name` is the env var avante reads; never put real keys here (they
--- live in agent_keys.json, managed by agent_core.keys).
M.defaults = {
  {
    name = "DeepSeek (cloud)",
    provider = "deepseek",
    model = "deepseek-chat",
    api_key_name = "DEEPSEEK_API_KEY",
    description = "Main coding model via DeepSeek cloud",
  },
  {
    name = "DeepSeek (local)",
    provider = "ollama",
    model = "deepseek-coder:1.3b",
    description = "Local Ollama deepseek-coder (offline)",
  },
  {
    name = "Gemini",
    provider = "gemini",
    model = "gemini-2.0-flash",
    api_key_name = "GEMINI_API_KEY",
    description = "Google Gemini Flash",
  },
}

function M.all()
  local cfg = require("agent_core").config
  return cfg.profiles or M.defaults
end

function M.find(name)
  for _, p in ipairs(M.all()) do
    if p.name == name then
      return p
    end
  end
end

function M.get_active()
  return require("agent_core.keys").get_active()
end

--- Apply a profile: export API key, set persona, switch provider + model.
function M.switch(profile)
  local Keys = require("agent_core.keys")

  -- 1. API key -> env (avante reads DEEPSEEK_API_KEY / AVANTE_DEEPSEEK_API_KEY)
  -- Resolution order: explicit profile key > environment > agent_keys.json.
  if profile.api_key_name and profile.api_key_name ~= "" then
    local key = profile.api_key or os.getenv(profile.api_key_name) or Keys.get(profile.name)
    if key and key ~= "" then
      vim.fn.setenv(profile.api_key_name, key)
      vim.fn.setenv("AVANTE_" .. profile.api_key_name, key)
    else
      -- No stored key; prompt once so the profile actually works.
      Keys.prompt(profile)
    end
  end

  -- 2. persona (read by avante's system_prompt function)
  vim.g.agent_persona = profile.system_prompt or ""

  -- 3. provider + model (best-effort; avante may not be loaded yet)
  local ok_api, api = pcall(require, "avante.api")
  if ok_api then
    if profile.model then
      pcall(function()
        local providers = require("avante.providers")
        local p = providers[profile.provider]
        if p then
          p.model = profile.model
        end
      end)
    end
    pcall(function()
      api.switch_provider(profile.provider)
    end)
  end

  -- 4. persist active profile
  vim.g.agent_active_profile = profile.name
  Keys.save_active(profile.name)

  vim.notify("Agent profile: " .. profile.name, vim.log.levels.INFO)
end

--- Restore the last-used profile on startup (best-effort).
function M.restore()
  local name = M.get_active()
  if not name then
    return
  end
  local p = M.find(name)
  if p then
    M.switch(p)
  end
end

return M
