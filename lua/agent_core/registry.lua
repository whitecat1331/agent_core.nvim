---@mod agent_core.registry Unified model registry (trust tiers + role/value tags)
---@brief [[
--- Single source of truth for every model backend nvim can reach. Each entry is
--- tagged with the role(s) it can serve (primary/completion/edit/classifier),
--- a trust tier (local / private-remote / third-party-cloud), and value tags
--- (cost, latency, fim, reasoning, quality_tier). The policy layer filters and
--- weights these entries; the completion router picks a FIM-capable backend from
--- them.
---
--- Entries come from several sources, merged by name:
---   1. Auto-discovered Ollama models (/api/tags) across every configured
---      endpoint (local loopback plus declared remote boxes), cached per-endpoint
---      and stamped with endpoint + trust tier.
---   2. Catalog-only chat models (agent_core.catalog) with a primary/classifier
---      role — the "other LLMs" a fresh install might have a key for.
---   3. Declared chat profiles (agent_core.profiles) — the `primary` role,
---      augmented with authoritative numeric fields from the catalog.
---   4. Declared completion backends (config.completion.backends) — `completion`
---      / `edit` roles.
---   5. User-added entries persisted in <data>/agent_core/registry.json (highest
---      priority override).
--- Each entry carries an `enabled` flag (persisted setup override > key/env
--- presence > provider defaults).
---@brief ]]

local M = {}

---@class AgentRegistryConfig
---@field path string|nil
---@field ollama_endpoint string|nil
---@field ollama_endpoints string[]|nil
---@field setup_path string|nil
---@field auto_discover boolean
M.config = {
  path = nil, -- nil = <data>/agent_core/registry.json
  ollama_endpoint = nil, -- nil = $OLLAMA_HOST or http://127.0.0.1:11434
  ollama_endpoints = nil, -- extra (remote) Ollama endpoints; loopback is always included
  setup_path = nil, -- nil = <data>/agent_core/setup.json
  auto_discover = true, -- include `ollama list` results in M.list()
}

M.TRUST_TIERS = { "local", "private-remote", "third-party-cloud" }
M.ROLES = { "primary", "completion", "edit", "classifier" }

--- Cached auto-discovered Ollama entries, keyed by endpoint URL.
local ollama_cache = {}

--- Resolve the Ollama endpoint (mirrors completion.ollama_endpoint).
---@return string
function M.ollama_endpoint()
  local cfg = require("agent_core").config
  local reg = cfg.registry or {}
  if reg.ollama_endpoint and reg.ollama_endpoint ~= "" then
    return reg.ollama_endpoint
  end
  return os.getenv("OLLAMA_HOST") or "http://127.0.0.1:11434"
end

--- Extra (remote) Ollama endpoints persisted in setup.json — the exact state the
--- wizard and :AgentEndpointAdd/:AgentEndpointRemove manage.
---@return string[]
function M.extra_ollama_endpoints()
  local state = M.load_setup_state()
  return state.ollama_endpoints or {}
end

--- Full set of Ollama endpoints: the default/local endpoint, config-declared
--- remotes, plus persisted setup.json endpoints. Deduplicated, loopback first.
---@return string[]
function M.ollama_endpoints()
  local cfg = require("agent_core").config
  local reg = cfg.registry or {}
  local list = {}
  local seen = {}
  local function push(url)
    if url and url ~= "" and not seen[url] then
      seen[url] = true
      list[#list + 1] = url
    end
  end
  push(M.ollama_endpoint())
  if type(reg.ollama_endpoints) == "table" then
    for _, url in ipairs(reg.ollama_endpoints) do
      push(url)
    end
  end
  for _, url in ipairs(M.extra_ollama_endpoints()) do
    push(url)
  end
  return list
end

--- Persist a remote Ollama endpoint into setup.json (deduped). Pure (no probing);
--- the endpoint is picked up by ollama_endpoints() on the next refresh.
---@param url string
---@return boolean ok
---@return string|nil err
function M.add_ollama_endpoint(url)
  if not url or url == "" then
    return false, "endpoint URL required"
  end
  local state = M.load_setup_state()
  state.ollama_endpoints = state.ollama_endpoints or {}
  for _, u in ipairs(state.ollama_endpoints) do
    if u == url then
      return false, "endpoint already present"
    end
  end
  state.ollama_endpoints[#state.ollama_endpoints + 1] = url
  if not M.save_setup_state(state) then
    return false, "could not write setup state"
  end
  return true, nil
end

--- Remove a persisted remote Ollama endpoint from setup.json.
---@param url string
---@return boolean ok
---@return string|nil err
function M.remove_ollama_endpoint(url)
  local state = M.load_setup_state()
  local list = state.ollama_endpoints or {}
  local out = {}
  for _, u in ipairs(list) do
    if u ~= url then
      out[#out + 1] = u
    end
  end
  state.ollama_endpoints = out
  if not M.save_setup_state(state) then
    return false, "could not write setup state"
  end
  return true, nil
end

--- True when an Ollama endpoint host is loopback (local Ollama).
---@param endpoint string|nil
---@return boolean
function M.is_loopback(endpoint)
  if not endpoint or endpoint == "" then
    return true
  end
  return endpoint:find("127.0.0.1", 1, true) ~= nil
    or endpoint:find("localhost", 1, true) ~= nil
    or endpoint:find("[::1]", 1, true) ~= nil
end

--- Default trust tier for an Ollama endpoint: local for loopback, private-remote
--- otherwise (a non-loopback host is assumed to be the user's own box over VPN).
---@param endpoint string|nil
---@return string
function M.default_ollama_trust(endpoint)
  if M.is_loopback(endpoint) then
    return "local"
  end
  return "private-remote"
end

--- Path to the persisted user-added entry store.
---@return string
function M.path()
  local cfg = require("agent_core").config
  local reg = cfg.registry or {}
  if reg.path and reg.path ~= "" then
    return vim.fn.expand(reg.path)
  end
  return vim.fn.stdpath("data") .. "/agent_core/registry.json"
end

--- Load user-added entries, or {} when missing/corrupt.
---@return table<string, table>
local function load_user_entries()
  local path = M.path()
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local ok, data = pcall(function()
    return vim.fn.json_decode(table.concat(vim.fn.readfile(path), "\n"))
  end)
  if not ok or type(data) ~= "table" then
    return {}
  end
  return data
end

--- Persist user-added entries.
---@param data table
---@return boolean
local function save_user_entries(data)
  vim.fn.mkdir(vim.fn.fnamemodify(M.path(), ":h"), "p")
  local f = io.open(M.path(), "w")
  if not f then
    return false
  end
  f:write(vim.fn.json_encode(data))
  f:close()
  return true
end

--- Path to the persisted setup state (enabled-provider overrides, wizard output).
---@return string
function M.setup_path()
  local cfg = require("agent_core").config
  local reg = cfg.registry or {}
  if reg.setup_path and reg.setup_path ~= "" then
    return vim.fn.expand(reg.setup_path)
  end
  return vim.fn.stdpath("data") .. "/agent_core/setup.json"
end

--- Load the persisted setup state (or {} when missing/corrupt).
---@return table
function M.load_setup_state()
  local path = M.setup_path()
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local ok, data = pcall(function()
    return vim.fn.json_decode(table.concat(vim.fn.readfile(path), "\n"))
  end)
  if not ok or type(data) ~= "table" then
    return {}
  end
  return data
end

--- Persist the setup state.
---@param data table
---@return boolean
function M.save_setup_state(data)
  vim.fn.mkdir(vim.fn.fnamemodify(M.setup_path(), ":h"), "p")
  local f = io.open(M.setup_path(), "w")
  if not f then
    return false
  end
  f:write(vim.fn.json_encode(data or {}))
  f:close()
  return true
end

--- Compute whether an entry is enabled, with clear precedence: a persisted
--- setup.json `enabled` override wins, else an Ollama endpoint counts as
--- enabled, else a cloud entry is enabled only when its API key is present in
--- the environment or the key store.
---@param entry table
---@param state table|nil persisted setup state (loaded once by M.list())
---@return boolean
function M.entry_enabled(entry, state)
  state = state or M.load_setup_state()
  local overrides = state.enabled
  if type(overrides) == "table" and overrides[entry.name] ~= nil then
    return overrides[entry.name] == true
  end
  if entry.provider == "ollama" then
    return true
  end
  if entry.api_key_name and entry.api_key_name ~= "" then
    local env = os.getenv(entry.api_key_name)
    if env and env ~= "" then
      return true
    end
    local Keys = require("agent_core.keys")
    local stored = Keys.get(entry.name)
    if stored and stored ~= "" then
      return true
    end
    return false
  end
  return true
end

--- Persist an enabled/disabled override for a named entry into setup.json.
---@param name string
---@param enabled boolean
---@return boolean ok
---@return string|nil err
function M.set_enabled(name, enabled)
  if not name or name == "" then
    return false, "entry name required"
  end
  local state = M.load_setup_state()
  state.enabled = state.enabled or {}
  state.enabled[name] = enabled == true
  if not M.save_setup_state(state) then
    return false, "could not write setup state"
  end
  return true, nil
end

--- Every eligible chat model: primary/classifier role AND enabled (key present
--- for cloud providers, always for Ollama). This is the :AgentModel dropdown
--- pool, sourced from the same merge M.list() already computes.
---@return table[]
function M.eligible_models()
  local out = {}
  for _, e in ipairs(M.list()) do
    local roles = e.roles or {}
    if (vim.tbl_contains(roles, "primary") or vim.tbl_contains(roles, "classifier")) and e.enabled then
      out[#out + 1] = e
    end
  end
  return out
end

--- The persisted active-model override: { provider, model } or nil.
---@return table|nil
function M.active_model()
  local state = M.load_setup_state()
  local am = state.active_model
  if type(am) == "table" and am.provider and am.model and am.model ~= "" then
    return am
  end
  return nil
end

--- Set (or clear, when model is nil) the active-model override in setup.json.
---@param provider string
---@param model string|nil
---@return boolean ok
function M.set_active_model(provider, model)
  local state = M.load_setup_state()
  if not model then
    state.active_model = nil
  else
    state.active_model = { provider = provider, model = model }
  end
  return M.save_setup_state(state)
end

--- Infer whether a model name is FIM-trained.
---@param name string
---@return boolean
function M.infer_fim(name)
  name = name:lower()
  return name:find("coder", 1, true) ~= nil
    or name:find("fim", 1, true) ~= nil
    or name:find("starcoder", 1, true) ~= nil
    or name:find("codellama", 1, true) ~= nil
    or name:find("codegemma", 1, true) ~= nil
end

--- Infer whether a model name is a reasoning model.
---@param name string
---@return boolean
function M.infer_reasoning(name)
  name = name:lower()
  return name:find("r1", 1, true) ~= nil
    or name:find("reasoner", 1, true) ~= nil
    or name:find("-o1", 1, true) ~= nil
    or name:find("-o3", 1, true) ~= nil
    or name:find("thinking", 1, true) ~= nil
end

--- Infer whether a model name supports vision (image input).
---@param name string
---@return boolean
function M.infer_vision(name)
  name = name:lower()
  return name:find("llava", 1, true) ~= nil
    or name:find("vision", 1, true) ~= nil
    or name:find("moondream", 1, true) ~= nil
    or name:find("bakllava", 1, true) ~= nil
    or name:find("qwen2.5vl", 1, true) ~= nil
    or name:find("minicpm", 1, true) ~= nil
    or name:find("gemma3", 1, true) ~= nil
end

--- Whether a model name is vision-capable (image input): the name-based
--- heuristic first, then any registry/catalog entry tagged `vision`.
---@param model string
---@return boolean
function M.is_vision(model)
  if not model or model == "" then
    return false
  end
  if M.infer_vision(model) then
    return true
  end
  for _, e in ipairs(M.list()) do
    if e.model == model and e.vision == true then
      return true
    end
  end
  return false
end

--- Infer a quality tier from a model size in bytes.
---@param size_bytes number|nil
---@return string "low"|"medium"|"high"
function M.infer_quality_tier(size_bytes)
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

--- Parse the JSON body of Ollama /api/tags into registry entries, stamping the
--- endpoint and trust tier (defaulting to private-remote for non-loopback hosts).
--- Pure function (no I/O) so it is unit-testable.
---@param body string
---@param endpoint string|nil
---@param trust string|nil
---@return table[]
function M.parse_ollama_tags(body, endpoint, trust)
  local ok, decoded = pcall(vim.json.decode, body)
  if not ok or type(decoded) ~= "table" or type(decoded.models) ~= "table" then
    return {}
  end
  endpoint = endpoint or M.ollama_endpoint()
  trust = trust or M.default_ollama_trust(endpoint)
  local out = {}
  for _, m in ipairs(decoded.models) do
    local name = m.name or m.model
    if name and name ~= "" then
      out[#out + 1] = {
        name = name,
        roles = { "completion", "edit" },
        trust = trust,
        cost = "free",
        latency = "medium",
        fim = M.infer_fim(name),
        reasoning = M.infer_reasoning(name),
        vision = M.infer_vision(name),
        quality_tier = M.infer_quality_tier(m.size),
        provider = "ollama",
        model = name,
        endpoint = endpoint,
      }
    end
  end
  return out
end

--- Discover Ollama models across every configured endpoint (/api/tags) and cache
--- them per-endpoint. Stamps each entry with its endpoint and trust tier.
---@param cb fun(entries: table[])|nil
function M.refresh_ollama(cb)
  cb = cb or function() end
  local bin = require("agent_core.platform").resolve_bin("curl")
  if bin == "curl" or bin == "" then
    ollama_cache = {}
    cb({})
    return
  end
  local endpoints = M.ollama_endpoints()
  if #endpoints == 0 then
    ollama_cache = {}
    cb({})
    return
  end
  ollama_cache = {}
  local pending = #endpoints
  local flattened = {}
  for _, url in ipairs(endpoints) do
    local endpoint = url
    local trust = M.default_ollama_trust(endpoint)
    vim.system({ bin, "-sS", "-m", "5", endpoint .. "/api/tags" }, { text = true }, function(obj)
      pending = pending - 1
      if obj.code == 0 and obj.stdout then
        local entries = M.parse_ollama_tags(obj.stdout, endpoint, trust)
        ollama_cache[endpoint] = entries
        for _, e in ipairs(entries) do
          flattened[#flattened + 1] = e
        end
      else
        ollama_cache[endpoint] = {}
      end
      if pending == 0 then
        cb(flattened)
      end
    end)
  end
end

--- Alias: probe every configured Ollama endpoint (used by the setup wizard).
---@param cb fun(entries: table[])|nil
function M.detect(cb)
  M.refresh_ollama(cb)
end

--- Flatten the per-endpoint cache into a single entry list.
---@return table[]
function M.ollama_entries()
  local out = {}
  for _, entries in pairs(ollama_cache) do
    for _, e in ipairs(entries) do
      out[#out + 1] = e
    end
  end
  return out
end

--- Declared chat profiles as registry entries, with value tags from profiles.lua
--- (falling back to provider-based inference when tags are absent), then
--- augmented with authoritative numeric fields from the catalog.
---@return table[]
local function chat_entries()
  local Profiles = require("agent_core.profiles")
  local Catalog = require("agent_core.catalog")
  local out = {}
  for _, p in ipairs(Profiles.all()) do
    local is_local = p.provider == "ollama"
    local entry = {
      name = p.name,
      roles = p.roles or { "primary" },
      trust = p.trust or (is_local and "local" or "third-party-cloud"),
      cost = p.cost or (is_local and "free" or "metered"),
      latency = p.latency or "low",
      fim = p.fim or false,
      reasoning = p.reasoning or false,
      vision = p.vision or false,
      quality_tier = p.quality_tier or (is_local and "medium" or "high"),
      provider = p.provider,
      model = p.model,
      endpoint = p.endpoint,
      api_key_name = p.api_key_name,
      description = p.description,
      autoswitch = p.autoswitch,
    }
    out[#out + 1] = Catalog.augment(entry)
  end
  return out
end

--- Catalog-only chat models (primary/classifier role) that are not already
--- declared as chat profiles. Surfaces "other LLMs" (e.g. GPT-4o, Claude Haiku)
--- whose key is present in the environment, deterministically.
---@return table[]
local function catalog_entries()
  local Catalog = require("agent_core.catalog")
  local Profiles = require("agent_core.profiles")
  local declared = {}
  for _, p in ipairs(Profiles.all()) do
    if p.provider and p.model then
      declared[p.provider .. "\0" .. p.model] = true
    end
  end
  local out = {}
  for _, c in ipairs(Catalog.models()) do
    local roles = c.roles or {}
    local is_chat = vim.tbl_contains(roles, "primary") or vim.tbl_contains(roles, "classifier")
    if is_chat and not declared[c.provider .. "\0" .. c.model] then
      out[#out + 1] = {
        name = c.name or (c.provider .. ":" .. c.model),
        roles = roles,
        trust = c.trust or "third-party-cloud",
        cost = Catalog.cost_tier(c.cost_in_per_1m, c.cost_out_per_1m),
        latency = c.latency_hint or "low",
        fim = c.fim == true,
        reasoning = c.reasoning == true,
        vision = c.vision == true,
        quality_tier = c.quality_score ~= nil and Catalog.quality_tier(c.quality_score) or "medium",
        provider = c.provider,
        model = c.model,
        api_key_name = c.api_key_name,
        cost_in_per_1m = c.cost_in_per_1m,
        cost_out_per_1m = c.cost_out_per_1m,
        context_window = c.context_window,
        quality_score = c.quality_score,
        latency_hint = c.latency_hint,
        insert_template = c.insert_template,
      }
    end
  end
  return out
end

--- Declared completion backends from config.completion.backends.
---@return table[]
local function completion_backends()
  local cfg = require("agent_core").config
  local backends = cfg.completion and cfg.completion.backends
  if not backends or type(backends) ~= "table" then
    return {}
  end
  local out = {}
  for _, b in ipairs(backends) do
    out[#out + 1] = M.normalize(b)
  end
  return out
end

--- Normalize a backend/profile into a full registry entry (fills defaults).
---@param entry table
---@return table
function M.normalize(entry)
  entry = entry or {}
  local is_local = entry.provider == "ollama" or entry.trust == "local"
  return {
    name = entry.name or (entry.model or "unnamed"),
    roles = entry.roles or { "completion", "edit" },
    trust = entry.trust or (is_local and "local" or "third-party-cloud"),
    cost = entry.cost or (is_local and "free" or "metered"),
    latency = entry.latency or "medium",
    fim = entry.fim == true,
    reasoning = entry.reasoning == true,
    vision = entry.vision == true,
    quality_tier = entry.quality_tier or "medium",
    provider = entry.provider,
    model = entry.model or entry.name,
    endpoint = entry.endpoint,
    api_key_name = entry.api_key_name,
    description = entry.description,
  }
end

--- Merge entries from all sources, deduplicated by name. Priority (lowest to
--- highest): auto-discovered Ollama -> catalog-only chat models -> declared chat
--- profiles -> declared completion backends -> user-added overrides. Each entry
--- gets an `enabled` flag computed with persisted-setup precedence. Synchronous:
--- uses the cached ollama discovery.
---@return table[]
function M.list()
  local merged = {}
  local function add(entry)
    if entry and entry.name then
      merged[entry.name] = entry
    end
  end

  for _, e in ipairs(M.ollama_entries()) do
    add(e)
  end
  for _, e in ipairs(catalog_entries()) do
    add(e)
  end
  for _, e in ipairs(chat_entries()) do
    add(e)
  end
  for _, e in ipairs(completion_backends()) do
    add(e)
  end
  for _, e in pairs(load_user_entries()) do
    add(M.normalize(e))
  end

  local state = M.load_setup_state()
  local out = {}
  for _, e in pairs(merged) do
    e.enabled = M.entry_enabled(e, state)
    out[#out + 1] = e
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

--- Entries that can serve a given role.
---@param role string
---@return table[]
function M.for_role(role)
  local out = {}
  for _, e in ipairs(M.list()) do
    if vim.tbl_contains(e.roles or {}, role) then
      out[#out + 1] = e
    end
  end
  return out
end

--- Entries carrying a given boolean capability flag (e.g. "vision", "fim",
--- "reasoning").
---@param cap string
---@return table[]
function M.for_capability(cap)
  local out = {}
  for _, e in ipairs(M.list()) do
    if e[cap] == true then
      out[#out + 1] = e
    end
  end
  return out
end

--- Entries whose trust tier is one of the given tiers.
---@param ... string
---@return table[]
function M.by_trust(...)
  local allowed = {}
  for i = 1, select("#", ...) do
    allowed[select(i, ...)] = true
  end
  local out = {}
  for _, e in ipairs(M.list()) do
    if allowed[e.trust] then
      out[#out + 1] = e
    end
  end
  return out
end

--- Find an entry by name.
---@param name string
---@return table|nil
function M.find(name)
  for _, e in ipairs(M.list()) do
    if e.name == name then
      return e
    end
  end
  return nil
end

--- Add a user-declared entry (persisted). Remote third-party-cloud endpoints
--- require explicit confirmation so the trust boundary is never silently crossed.
---@param entry table
---@param opts {confirm:boolean}|nil
---@return table|nil entry
---@return string|nil err
function M.add(entry, opts)
  opts = opts or {}
  local e = M.normalize(entry)
  if not e.provider or e.provider == "" then
    return nil, "entry requires a provider"
  end
  if not vim.tbl_contains(M.TRUST_TIERS, e.trust) then
    return nil, "invalid trust tier: " .. tostring(e.trust)
  end
  if e.trust == "third-party-cloud" and not opts.confirm then
    return nil, "third-party-cloud endpoints send code to an external host; re-call with confirm=true once acknowledged"
  end
  local data = load_user_entries()
  data[e.name] = e
  if not save_user_entries(data) then
    return nil, "could not write registry store"
  end
  return e
end

--- Remove a user-declared entry (declared/auto entries cannot be removed this way).
---@param name string
---@return boolean removed
function M.remove(name)
  local data = load_user_entries()
  if data[name] == nil then
    return false
  end
  data[name] = nil
  return save_user_entries(data)
end

--- One-time, honest warning when adding a third-party-cloud endpoint. Returns a
--- confirm=true-wrapped callback the caller invokes after the user acknowledges.
---@param entry table
---@param on_ack fun(entry: table)
function M.warn_third_party(entry, on_ack)
  local e = M.normalize(entry)
  vim.ui.select({
    "Continue (code will leave this machine)",
    "Cancel",
  }, {
    prompt = "Third-party cloud endpoint: "
      .. e.name
      .. " — code snippets are sent to an external host. Only add endpoints you trust.",
  }, function(choice)
    if choice and choice:find("Continue", 1, true) then
      on_ack(e)
    end
  end)
end

function M.setup()
  local cfg = require("agent_core").config
  M.config = vim.tbl_deep_extend("force", M.config, cfg.registry or {})
  vim.fn.mkdir(vim.fn.fnamemodify(M.path(), ":h"), "p")
  if M.config.auto_discover then
    M.refresh_ollama()
  end
end

--- Present the registry in a scratch buffer (:AgentRegistryList).
function M.list_cmd()
  local entries = M.list()
  local lines = { "# Model registry", "", string.format("%d backend(s)", #entries), "" }
  for _, e in ipairs(entries) do
    local roles = table.concat(e.roles or {}, ",")
    local flags = {}
    if e.fim then
      flags[#flags + 1] = "fim"
    end
    if e.reasoning then
      flags[#flags + 1] = "reasoning"
    end
    local tags = table.concat(flags, ",")
    if tags == "" then
      tags = "-"
    end
    lines[#lines + 1] = string.format("## %s  [%s | %s | %s | %s]", e.name, roles, e.trust, e.cost, e.quality_tier)
    lines[#lines + 1] = string.format("  %s  model=%s  tags=%s", e.provider or "?", e.model or "?", tags)
    if e.endpoint then
      lines[#lines + 1] = "  endpoint=" .. e.endpoint
    end
    lines[#lines + 1] = ""
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.api.nvim_open_win(buf, true, { split = "right" })
end

--- Add a remote backend (:AgentRegistryAdd). `arg` is a positional string
--- "name provider model endpoint [trust]" (trust defaults to private-remote).
---@param arg string
function M.add_cmd(arg)
  local text = arg or ""
  local name, provider, model, endpoint, trust = text:match("^%s*(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s*(%S*)%s*$")
  if not name then
    vim.notify(
      "AgentRegistryAdd usage: :AgentRegistryAdd <name> <provider> <model> <endpoint> [local|private-remote|third-party-cloud]",
      vim.log.levels.WARN
    )
    return
  end
  trust = trust ~= "" and trust or "private-remote"
  local entry = {
    name = name,
    provider = provider,
    model = model,
    endpoint = endpoint,
    trust = trust,
    roles = { "completion", "edit" },
  }

  if trust == "third-party-cloud" then
    M.warn_third_party(entry, function(e)
      local added, err = M.add(e, { confirm = true })
      if added then
        vim.notify("Added registry backend: " .. e.name, vim.log.levels.INFO)
      else
        vim.notify("AgentRegistryAdd: " .. tostring(err), vim.log.levels.ERROR)
      end
    end)
    return
  end

  local added, err = M.add(entry)
  if added then
    vim.notify("Added registry backend: " .. entry.name, vim.log.levels.INFO)
  else
    vim.notify("AgentRegistryAdd: " .. tostring(err), vim.log.levels.ERROR)
  end
end

--- Resolve a profile name (arg or picker) and mutate its persisted enabled flag.
---@param arg string|nil
---@param enabled boolean
local function set_enabled_cmd(arg, enabled)
  local Profiles = require("agent_core.profiles")
  local Pickers = require("agent_core.pickers")
  local function apply(p)
    local ok, err = M.set_enabled(p.name, enabled)
    if ok then
      vim.notify(
        string.format("Agent profile %s: %s", p.name, enabled and "enabled" or "disabled"),
        vim.log.levels.INFO
      )
    else
      vim.notify("Agent profile: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
  if arg and arg ~= "" then
    local p = Profiles.find(arg)
    if not p then
      vim.notify("Profile not found: " .. arg, vim.log.levels.WARN)
      return
    end
    apply(p)
    return
  end
  Pickers.pick_profile(function(p)
    if p then
      apply(p)
    end
  end)
end

--- Enable a chat profile via a persisted setup.json override (:AgentProfileEnable).
---@param arg string|nil
function M.enable_cmd(arg)
  set_enabled_cmd(arg, true)
end

--- Disable a chat profile via a persisted setup.json override (:AgentProfileDisable).
---@param arg string|nil
function M.disable_cmd(arg)
  set_enabled_cmd(arg, false)
end

--- List every configured Ollama endpoint in a scratch buffer (:AgentEndpointList).
function M.endpoint_list_cmd()
  local eps = M.ollama_endpoints()
  local lines = { "# Ollama endpoints", "", string.format("%d endpoint(s)", #eps), "" }
  for i, url in ipairs(eps) do
    lines[#lines + 1] = string.format("%d. %s", i, url)
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.api.nvim_open_win(buf, true, { split = "right" })
end

--- Add a remote Ollama endpoint (:AgentEndpointAdd [url]). Prompts when no url.
---@param arg string|nil
function M.endpoint_add_cmd(arg)
  local function add(url)
    local ok, err = M.add_ollama_endpoint(url)
    if ok then
      vim.notify("Added Ollama endpoint: " .. url, vim.log.levels.INFO)
      M.refresh_ollama()
    else
      vim.notify("AgentEndpointAdd: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
  if arg and arg ~= "" then
    add(arg)
    return
  end
  vim.ui.input({ prompt = "Ollama endpoint URL: " }, function(input)
    if input and input ~= "" then
      add(input)
    end
  end)
end

--- Remove a remote Ollama endpoint (:AgentEndpointRemove [url]). Picks when no url.
---@param arg string|nil
function M.endpoint_remove_cmd(arg)
  local function remove(url)
    local ok, err = M.remove_ollama_endpoint(url)
    if ok then
      vim.notify("Removed Ollama endpoint: " .. url, vim.log.levels.INFO)
      M.refresh_ollama()
    else
      vim.notify("AgentEndpointRemove: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
  if arg and arg ~= "" then
    remove(arg)
    return
  end
  local eps = M.extra_ollama_endpoints()
  if #eps == 0 then
    vim.notify("No extra Ollama endpoints to remove", vim.log.levels.INFO)
    return
  end
  vim.ui.select(eps, { prompt = "Remove Ollama endpoint: " }, function(choice)
    if choice then
      remove(choice)
    end
  end)
end

return M
