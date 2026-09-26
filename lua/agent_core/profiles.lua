local M = {}

local Catalog = require("agent_core.catalog")

--- Default profiles, projected from agent_core.catalog. An entry with a
--- system_prompt persona is a routable agent; its capability tags (cost,
--- quality_tier, latency, fim, reasoning, vision) are derived from the
--- catalog's numeric fields via Catalog.cost_tier / Catalog.quality_tier.
--- Catalog-only models (no system_prompt) do not become profiles.
---
--- `api_key_name` is the env var the owned runtime reads; never put real keys
--- here (they live in agent_keys.json, managed by agent_core.keys).
---
--- Realm hints used by agent_core.autoswitch to route a prompt to the best
--- profile: `keywords` (weighted phrases; `{ "phrase", 2 }` for stronger
--- signals), `when_to_use` (one-line reason for the switch prompt), and
--- `autoswitch` (false = excluded from automatic routing).
local function build_defaults()
  local out = {}
  for _, e in ipairs(Catalog.models()) do
    if e.system_prompt and e.system_prompt ~= "" then
      out[#out + 1] = {
        name = e.name,
        provider = e.provider,
        model = e.model,
        api_key_name = e.api_key_name,
        description = e.description,
        system_prompt = e.system_prompt,
        autoswitch = e.autoswitch,
        roles = e.roles or { "primary" },
        trust = e.trust or (e.provider == "ollama" and "local" or "third-party-cloud"),
        cost = Catalog.cost_tier(e.cost_in_per_1m, e.cost_out_per_1m),
        latency = e.latency_hint or "low",
        fim = e.fim == true,
        reasoning = e.reasoning == true,
        vision = e.vision == true,
        quality_tier = Catalog.quality_tier(e.quality_score, nil),
        keywords = e.keywords,
        when_to_use = e.when_to_use,
      }
    end
  end
  return out
end

M.defaults = build_defaults()

--- Normalize a user-declared custom profile: fill provider-based defaults for
--- the capability tags the catalog would otherwise supply. The user supplies
--- identity + persona + routing (`name`, `provider`, `model`, `system_prompt`,
--- `autoswitch`, `keywords`, `when_to_use`, plus optional `endpoint`/`trust`/
--- `roles`/`api_key_name`/`fim`/`reasoning`/`vision`); the rest is defaulted so
--- policy and the registry see a well-formed entry.
---@param p table
---@return table
local function normalize_custom(p)
  local is_local = p.provider == "ollama"
  return {
    name = p.name,
    provider = p.provider,
    model = p.model,
    endpoint = p.endpoint,
    api_key_name = p.api_key_name,
    description = p.description,
    system_prompt = p.system_prompt,
    autoswitch = p.autoswitch,
    roles = p.roles or { "primary" },
    trust = p.trust or (is_local and "local" or "third-party-cloud"),
    cost = p.cost or (is_local and "free" or "metered"),
    latency = p.latency or (is_local and "medium" or "low"),
    fim = p.fim == true,
    reasoning = p.reasoning == true,
    vision = p.vision == true,
    quality_tier = p.quality_tier or (is_local and "medium" or "high"),
    keywords = p.keywords,
    when_to_use = p.when_to_use,
  }
end

--- User-defined custom profiles, from config `profiles.extra` (array) plus
--- `<data>/agent_core/profiles.json` (an array, or `{ profiles = [...] }`).
--- Mirrors agent_core.modes.custom_modes. Both sources are tolerant of
--- missing/corrupt data; entries are normalized with provider-based defaults.
---@return table[]
function M.custom_profiles()
  local out = {}
  local cfg = require("agent_core").config
  local extra = cfg.profiles and cfg.profiles.extra
  if type(extra) == "table" then
    for _, p in ipairs(extra) do
      if type(p) == "table" and p.name and p.provider and p.model then
        out[#out + 1] = normalize_custom(p)
      end
    end
  end
  local path = vim.fn.stdpath("data") .. "/agent_core/profiles.json"
  if vim.fn.filereadable(path) == 1 then
    local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
    if ok and type(data) == "table" then
      local list = data.profiles or data
      if type(list) == "table" then
        for _, p in ipairs(list) do
          if type(p) == "table" and p.name and p.provider and p.model then
            out[#out + 1] = normalize_custom(p)
          end
        end
      end
    end
  end
  return out
end

function M.all()
  local cfg = require("agent_core").config
  -- A plain array in `config.profiles` is a full replacement (back-compat);
  -- anything else (nil or `{ extra = { ... } }`) falls back to the defaults.
  local base
  if type(cfg.profiles) == "table" and cfg.profiles[1] ~= nil then
    base = cfg.profiles
  else
    base = M.defaults
  end
  -- Custom profiles are always appended (deduped by name, base wins) so a
  -- full-array `config.profiles` still surfaces JSON/`extra`-defined agents.
  local seen = {}
  local out = {}
  local function add(p)
    if type(p) == "table" and p.name and not seen[p.name] then
      seen[p.name] = true
      out[#out + 1] = p
    end
  end
  for _, p in ipairs(base) do
    add(p)
  end
  for _, p in ipairs(M.custom_profiles()) do
    add(p)
  end
  return out
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

--- The active profile's persona text, or "" (mirrors modes.get_mode_prompt).
--- Populated by M.switch, which writes vim.g.agent_persona from
--- profile.system_prompt.
---@return string
function M.get_persona()
  return vim.g.agent_persona or ""
end

--- First profile whose provider matches (defaults declare exactly one per
--- provider). Returns nil when no profile declares the provider.
---@param provider string
---@return table|nil
function M.find_by_provider(provider)
  for _, p in ipairs(M.all()) do
    if p.provider == provider then
      return p
    end
  end
end

--- The concrete model for a profile: the persisted active-model override when it
--- matches this profile's provider, else the profile's hardcoded model. Pure —
--- never mutates the shared defaults table.
---@param p table
---@return string|nil
function M.effective_model(p)
  local Registry = require("agent_core.registry")
  local am = Registry.active_model()
  if am and am.provider == p.provider and am.model and am.model ~= "" then
    return am.model
  end
  return p.model
end

--- Switch to a provider's profile and record the concrete model as the active-
--- model override. Backing for :AgentModel (pooled dropdown). Falls back to a
--- plain profile switch when the provider has no declared profile.
---@param entry table registry entry with .provider and .model
function M.switch_model(entry)
  local Registry = require("agent_core.registry")
  -- Persist the override first so M.switch() computes the correct effective
  -- model and applies it to the active session + vim.g.agent_active_model.
  Registry.set_active_model(entry.provider, entry.model)
  local p = M.find_by_provider(entry.provider)
  if p then
    M.switch(p)
  end
  vim.notify("Agent model: " .. entry.provider .. " / " .. entry.model, vim.log.levels.INFO)

  vim.schedule(function()
    pcall(function()
      require("agent_core.runtime.ui.composer").refresh_chrome()
    end)
  end)
end

--- Apply a profile: resolve API key, set persona, switch the active session's
--- provider/model (mid-flight switch supported).
function M.switch(profile)
  local Keys = require("agent_core.keys")

  -- 1. API key resolution (explicit profile key > environment > agent_keys.json).
  -- The owned runtime resolves the key at submit time; nothing is exported.
  if profile.api_key_name and profile.api_key_name ~= "" then
    local key = profile.api_key or os.getenv(profile.api_key_name) or Keys.get(profile.name)
    if not key or key == "" then
      -- No stored key; prompt once so the profile actually works.
      Keys.prompt(profile)
    end
  end

  -- 2. persona (read by the owned runtime's system-prompt assembly)
  vim.g.agent_persona = profile.system_prompt or ""

  -- 3. provider + model -> the active owned session (best-effort; no session yet
  --    is fine — the next create_session picks the active profile's defaults).
  local ok, rt = pcall(require, "agent_core.runtime")
  if ok and rt.apply_profile then
    local effective = vim.tbl_deep_extend("force", vim.deepcopy(profile), { model = M.effective_model(profile) })
    rt.apply_profile(effective)
  end

  -- 4. persist active profile
  vim.g.agent_active_profile = profile.name
  vim.g.agent_active_model = M.effective_model(profile)
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

--- Clear the active-model override: revert to the active profile's hardcoded
--- model. Mirrors the inverse of switch_model / :AgentModel.
function M.clear_model_override()
  local Registry = require("agent_core.registry")
  Registry.set_active_model(nil, nil)
  local name = M.get_active()
  local p = name and M.find(name)
  if p then
    vim.g.agent_active_model = M.effective_model(p)
    local ok, rt = pcall(require, "agent_core.runtime")
    if ok and rt.apply_profile then
      local effective = vim.tbl_deep_extend("force", vim.deepcopy(p), { model = M.effective_model(p) })
      rt.apply_profile(effective)
    end
    vim.notify("Agent model reset to default: " .. M.effective_model(p), vim.log.levels.INFO)
  else
    vim.g.agent_active_model = nil
    vim.notify("Agent model override cleared", vim.log.levels.INFO)
  end

  vim.schedule(function()
    pcall(function()
      require("agent_core.runtime.ui.composer").refresh_chrome()
    end)
  end)
end

--- Backing for :AgentSwitch [name]. Switch by name when given, else open the
--- profile picker. Nil-guarded so cancelling the picker is a no-op.
---@param name string|nil
function M.switch_cmd(name)
  if name and name ~= "" then
    local p = M.find(name)
    if not p then
      vim.notify("Profile not found: " .. name, vim.log.levels.WARN)
      return
    end
    M.switch(p)
    return
  end
  require("agent_core.pickers").pick_profile(function(p)
    if p then
      M.switch(p)
    end
  end)
end

return M
