---@mod agent_core.runtime.providers Owned provider registry (owned).
---@brief [[
--- Owned registry of LLM providers with a common interface. Replaces the retired
--- upstream runtime's global provider table + provider selection. Each
--- provider implements:
---   build_request(opts) -> { url, headers, body }
---   parse_delta(json_str, acc) -> nil   (feeds acc.text / acc.tool_calls / acc.done)
---   stream(opts)                        (full streaming call, no network deps)
---
--- `M.get(name)` resolves a provider module by name; `M.stream(opts)` dispatches
--- to the resolved provider. Provider/model are per-call (passed in opts), never
--- a process-global — this is what enables concurrent multi-model sessions.
---@brief ]]

local M = {}

--- Provider name -> module (lazy-loaded). Keys mirror agent_core.profiles.
local MODULES = {
  deepseek = "agent_core.runtime.providers.openai_compat",
  openai = "agent_core.runtime.providers.openai_compat",
  claude = "agent_core.runtime.providers.anthropic",
  anthropic = "agent_core.runtime.providers.anthropic",
  gemini = "agent_core.runtime.providers.gemini",
  google = "agent_core.runtime.providers.gemini",
  ollama = "agent_core.runtime.providers.ollama",
}

--- Default endpoints/keys per provider name (used when the profile omits them).
--- Never put real keys here; API keys resolve at runtime from env / agent_core.keys.
M.defaults = {
  deepseek = {
    endpoint = "https://api.deepseek.com/v1/chat/completions",
    api_key_name = "DEEPSEEK_API_KEY",
  },
  openai = {
    endpoint = "https://api.openai.com/v1/chat/completions",
    api_key_name = "OPENAI_API_KEY",
  },
  claude = {
    endpoint = "https://api.anthropic.com/v1/messages",
    api_key_name = "ANTHROPIC_API_KEY",
  },
  anthropic = {
    endpoint = "https://api.anthropic.com/v1/messages",
    api_key_name = "ANTHROPIC_API_KEY",
  },
  gemini = {
    endpoint = "https://generativelanguage.googleapis.com/v1beta",
    api_key_name = "GEMINI_API_KEY",
  },
  google = {
    endpoint = "https://generativelanguage.googleapis.com/v1beta",
    api_key_name = "GEMINI_API_KEY",
  },
  ollama = {
    endpoint = "http://127.0.0.1:11434",
    api_key_name = nil,
  },
}

--- Resolve a provider module by name.
---@param name string
---@return table|nil module
---@return string|nil module_name
function M.get(name)
  local mod = MODULES[name or ""]
  if not mod then
    return nil, nil
  end
  local ok, loaded = pcall(require, mod)
  if not ok then
    return nil, mod
  end
  return loaded, mod
end

--- Merge provider defaults into a profile-shaped opts table.
---@param opts { provider:string, endpoint?:string, api_key_name?:string }
---@return table
function M.with_defaults(opts)
  local d = M.defaults[opts.provider] or {}
  return vim.tbl_deep_extend("force", {
    endpoint = d.endpoint,
    api_key_name = d.api_key_name,
  }, opts or {})
end

--- Stream a completion through the resolved provider. `opts` is the normalized
--- completion request (model, api_key, system, messages, tools, max_tokens,
--- temperature) plus on_chunk / on_stop callbacks.
---@param opts table
---@return boolean ok
---@return string|nil err
function M.stream(opts)
  local provider, mod = M.get(opts.provider)
  if not provider then
    return false,
      "provider not found: " .. tostring(opts.provider) .. (mod and (" (module " .. mod .. " failed to load)") or "")
  end
  return provider.stream(M.with_defaults(opts))
end

return M
