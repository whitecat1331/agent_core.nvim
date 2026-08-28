---@mod agent_core.catalog Curated model catalog (pricing/quality/authoritative flags).
---@brief [[
--- Single source of truth for the model metadata that cannot be derived at
--- runtime: per-token cost, benchmark-derived quality_score, authoritative
--- fim/insert_template and reasoning flags, context window, and a latency hint.
--- These change over time and no probe exposes them, so they ship as data
--- (bundled snapshot) and can be refreshed from a pinned URL.
---
--- SECURITY: a fetched catalog is untrusted remote input. Only a small
--- field allowlist is accepted from it (numeric/capability fields); it can
--- never set api_key_name / endpoint / trust / name / roles, so a malicious or
--- compromised catalog cannot make the wizard read an unexpected env var or
--- point at a hostile endpoint.
---@brief ]]

local M = {}

---@class AgentCatalogConfig
---@field url string|nil nil = no fetch (bundled snapshot only)
---@field path string|nil nil = <data>/agent_core/catalog.json
---@field auto_refresh boolean
M.config = {
  url = nil,
  path = nil,
  auto_refresh = false,
}

--- Fields a fetched catalog is permitted to set. Everything else is stripped
--- at parse time. Security-relevant fields (api_key_name, endpoint, trust,
--- name, roles, provider) come only from the bundled snapshot or declared
--- sources.
local FETCH_ALLOWLIST = {
  model = true,
  cost_in_per_1m = true,
  cost_out_per_1m = true,
  context_window = true,
  fim = true,
  insert_template = true,
  reasoning = true,
  vision = true,
  quality_score = true,
  latency_hint = true,
}

---@return string
function M.path()
  local cfg = require("agent_core").config
  local cat = cfg.catalog or {}
  if cat.path and cat.path ~= "" then
    return vim.fn.expand(cat.path)
  end
  return vim.fn.stdpath("data") .. "/agent_core/catalog.json"
end

--- The bundled (trusted) snapshot.
---@return table {version:integer, models:table[]}
function M.bundled()
  return require("agent_core.catalog_snapshot")
end

--- Load a fetched/cached catalog, applying the field allowlist so remote input
--- can only touch non-security fields. Returns {} when missing/corrupt.
---@return table[]
local function load_cached()
  local path = M.path()
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local ok, data = pcall(function()
    return vim.fn.json_decode(table.concat(vim.fn.readfile(path), "\n"))
  end)
  if not ok or type(data) ~= "table" or type(data.models) ~= "table" then
    return {}
  end
  local out = {}
  for _, m in ipairs(data.models) do
    if type(m) == "table" and type(m.provider) == "string" and type(m.model) == "string" then
      local e = { provider = m.provider, model = m.model }
      for field in pairs(FETCH_ALLOWLIST) do
        if m[field] ~= nil then
          e[field] = m[field]
        end
      end
      out[#out + 1] = e
    end
  end
  return out
end

--- Merge the bundled snapshot with the cached (fetched) catalog, cached entries
--- overriding by provider+model. The fetched overlay contributes only
--- allowlisted fields, so bundled security fields survive.
---@return table[]
function M.models()
  local merged = {}
  for _, m in ipairs(M.bundled().models) do
    merged[m.provider .. "\0" .. m.model] = vim.deepcopy(m)
  end
  for _, m in ipairs(load_cached()) do
    local key = m.provider .. "\0" .. m.model
    local base = merged[key]
    if base then
      merged[key] = vim.tbl_deep_extend("force", base, m)
    else
      merged[key] = m
    end
  end
  local out = {}
  for _, m in pairs(merged) do
    out[#out + 1] = m
  end
  table.sort(out, function(a, b)
    return (a.provider .. a.model) < (b.provider .. b.model)
  end)
  return out
end

--- All catalog entries for a provider.
---@param provider string
---@return table[]
function M.lookup(provider)
  local out = {}
  for _, m in ipairs(M.models()) do
    if m.provider == provider then
      out[#out + 1] = m
    end
  end
  return out
end

--- The single catalog entry for a provider + model, or nil.
---@param provider string
---@param model string
---@return table|nil
function M.lookup_model(provider, model)
  if not provider or not model then
    return nil
  end
  for _, m in ipairs(M.models()) do
    if m.provider == provider and m.model == model then
      return m
    end
  end
  return nil
end

--- Distinct provider names present in the catalog.
---@return string[]
function M.known_providers()
  local seen = {}
  local out = {}
  for _, m in ipairs(M.models()) do
    if not seen[m.provider] then
      seen[m.provider] = true
      out[#out + 1] = m.provider
    end
  end
  table.sort(out)
  return out
end

--- Coarse cost tier from per-1M input/output cost. free when unset or zero.
---@param cost_in number|nil
---@param cost_out number|nil
---@return string "free" | "cheap" | "metered" | "expensive"
function M.cost_tier(cost_in, cost_out)
  local c = math.max(cost_in or 0, cost_out or 0)
  if c <= 0 then
    return "free"
  end
  if c < 0.5 then
    return "cheap"
  end
  if c < 8.0 then
    return "metered"
  end
  return "expensive"
end

--- Coarse quality tier from a benchmark score, falling back to model size.
---@param score number|nil
---@param size_bytes number|nil
---@return string "high" | "medium" | "low"
function M.quality_tier(score, size_bytes)
  if score ~= nil then
    if score >= 0.8 then
      return "high"
    end
    if score >= 0.5 then
      return "medium"
    end
    return "low"
  end
  if not size_bytes or size_bytes <= 0 then
    return "medium"
  end
  if size_bytes < 2 * 1024 * 1024 * 1024 then
    return "low"
  end
  if size_bytes > 10 * 1024 * 1024 * 1024 then
    return "high"
  end
  return "medium"
end

--- Attach numeric + authoritative flags from the catalog to a registry entry.
--- Additive to metadata only: never clobbers roles, trust, endpoint, api_key_name,
--- or name (those come from the declared/auto source). Falls back to the entry's
--- existing values when the catalog lacks the model.
---@param entry table
---@return table entry (same reference, mutated)
function M.augment(entry)
  entry = entry or {}
  local c = M.lookup_model(entry.provider, entry.model)
  if not c then
    return entry
  end
  if c.cost_in_per_1m ~= nil or c.cost_out_per_1m ~= nil then
    entry.cost_in_per_1m = c.cost_in_per_1m
    entry.cost_out_per_1m = c.cost_out_per_1m
    entry.cost = M.cost_tier(c.cost_in_per_1m, c.cost_out_per_1m)
  end
  if c.context_window ~= nil then
    entry.context_window = c.context_window
  end
  if c.quality_score ~= nil then
    entry.quality_score = c.quality_score
    entry.quality_tier = M.quality_tier(c.quality_score)
  end
  if c.latency_hint ~= nil then
    entry.latency_hint = c.latency_hint
  end
  if c.fim ~= nil then
    entry.fim = c.fim
  end
  if c.insert_template ~= nil then
    entry.insert_template = c.insert_template
  end
  if c.reasoning ~= nil then
    entry.reasoning = c.reasoning
  end
  if c.vision ~= nil then
    entry.vision = c.vision
  end
  return entry
end

--- Fetch the catalog from config.url and cache it locally (allowlisted fields
--- only). On success `cb(true)`; offline/error keeps the bundled snapshot and
--- `cb(false)`.
---@param cb fun(ok:boolean)|nil
function M.refresh(cb)
  cb = cb or function() end
  local url = M.config.url
  if not url or url == "" then
    cb(false)
    return
  end
  local bin = require("agent_core.platform").resolve_bin("curl")
  if bin == "curl" or bin == "" then
    cb(false)
    return
  end
  vim.system({
    bin,
    "-sS",
    "-m",
    "15",
    url,
  }, { text = true }, function(obj)
    if obj.code ~= 0 or not obj.stdout or obj.stdout == "" then
      cb(false)
      return
    end
    -- Re-parse through the allowlist before persisting (defense in depth).
    local ok, decoded = pcall(vim.json.decode, obj.stdout)
    if not ok or type(decoded) ~= "table" or type(decoded.models) ~= "table" then
      cb(false)
      return
    end
    local clean = { version = decoded.version, models = {} }
    for _, m in ipairs(decoded.models) do
      if type(m) == "table" and type(m.provider) == "string" and type(m.model) == "string" then
        local e = { provider = m.provider, model = m.model }
        for field in pairs(FETCH_ALLOWLIST) do
          if m[field] ~= nil then
            e[field] = m[field]
          end
        end
        clean.models[#clean.models + 1] = e
      end
    end
    vim.fn.mkdir(vim.fn.fnamemodify(M.path(), ":h"), "p")
    local f = io.open(M.path(), "w")
    if f then
      f:write(vim.fn.json_encode(clean))
      f:close()
      cb(true)
    else
      cb(false)
    end
  end)
end

function M.setup()
  local cfg = require("agent_core").config
  M.config = vim.tbl_deep_extend("force", M.config, cfg.catalog or {})
  if M.config.auto_refresh then
    M.refresh()
  end
end

--- Backing for :AgentCatalogUpdate.
function M.update_cmd()
  if not M.config.url or M.config.url == "" then
    vim.notify("AgentCatalogUpdate: no catalog.url configured", vim.log.levels.WARN)
    return
  end
  vim.notify("AgentCatalogUpdate: fetching…", vim.log.levels.INFO)
  M.refresh(function(ok)
    if ok then
      vim.notify("AgentCatalogUpdate: catalog refreshed", vim.log.levels.INFO)
    else
      vim.notify("AgentCatalogUpdate: fetch failed, keeping bundled snapshot", vim.log.levels.WARN)
    end
  end)
end

return M
