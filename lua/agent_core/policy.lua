---@mod agent_core.policy Model-selection policy: three orthogonal knobs + aliases
---@brief [[
--- Replaces the "design philosophy presets" idea with three independent settings
--- (the iron triangle + data sovereignty + mutation caution), plus optional named
--- aliases that expand to those knobs. Everything else (classifier gate, expanded
--- destructive tools, loop trimming, mode bias) is DERIVED from the knobs so the
--- three inputs can never drift out of sync.
---
---   model_policy  balanced | fast | good | cheap      (the iron triangle)
---   trust_scope   any | private | local               (data sovereignty)
---   caution       act_first | ask_first               (mutation behavior)
---
--- `M.apply()` returns a policy object consumed by autoswitch (filter + re-rank),
--- recommend (mode bias), completion (backend selection), and modes
--- (effective_destructive_tools). Knobs persist to <data>/agent_core/policy.json;
--- config.policy.* are the defaults.
---@brief ]]

local M = {}

--- Valid values per knob.
M.KNOBS = {
  model_policy = { "balanced", "fast", "good", "cheap" },
  trust_scope = { "any", "private", "local" },
  caution = { "act_first", "ask_first" },
}

--- Named compositions of the three knobs (name -> knob values).
M.ALIASES = {
  privacy = { model_policy = "balanced", trust_scope = "private", caution = "act_first" },
  cautious = { model_policy = "cheap", trust_scope = "local", caution = "ask_first" },
  question_first = { model_policy = "balanced", trust_scope = "any", caution = "ask_first" },
  quality = { model_policy = "good", trust_scope = "any", caution = "act_first" },
  speed = { model_policy = "fast", trust_scope = "any", caution = "act_first" },
  cost_first = { model_policy = "cheap", trust_scope = "any", caution = "act_first" },
}

--- Allowed trust tiers per trust_scope.
local TRUST_SCOPES = {
  any = { "local", "private-remote", "third-party-cloud" },
  private = { "local", "private-remote" },
  ["local"] = { "local" },
}

--- Numeric quality (0..1) from an entry: prefer catalog quality_score, else map
--- a coarse quality_tier to a representative value.
---@param e table
---@return number
local function quality_of(e)
  if e.quality_score ~= nil then
    return e.quality_score
  end
  return ({ high = 0.8, medium = 0.5, low = 0.2 })[e.quality_tier or "medium"]
end

--- Numeric per-1M cost (max of input/output) from an entry: prefer catalog
--- cost fields, else map a coarse cost tier to a representative value.
---@param e table
---@return number
local function cost_of(e)
  if e.cost_in_per_1m ~= nil or e.cost_out_per_1m ~= nil then
    return math.max(e.cost_in_per_1m or 0, e.cost_out_per_1m or 0)
  end
  return ({ free = 0, cheap = 0.25, metered = 4, expensive = 15 })[e.cost or "metered"]
end

--- Coarse latency hint: catalog latency_hint, else the legacy latency tag.
---@param e table
---@return string
local function latency_hint(e)
  return e.latency_hint or e.latency or "medium"
end

--- Numeric latency in ms: measured latency first, else a coarse hint.
---@param e table
---@return number
local function latency_of(e)
  if e.latency_ms and e.latency_ms > 0 then
    return e.latency_ms
  end
  return ({ low = 300, medium = 1200, high = 4000 })[latency_hint(e)]
end

--- Scoring definitions per model_policy: a hard filter plus a numeric weight.
--- Scores use numeric catalog fields when present and fall back to coarse
--- string tiers otherwise, so unknown user models never break ranking.
local POLICY_DEFS = {
  balanced = {
    hard = function()
      return true
    end,
    score = function(e)
      local s = quality_of(e) * 3
      local c = cost_of(e)
      if c <= 0 then
        s = s + 0.6
      elseif c < 0.5 then
        s = s + 0.3
      end
      if e.reasoning then
        s = s + 0.4
      end
      local l = latency_of(e)
      if l <= 500 then
        s = s + 0.2
      elseif l > 2000 then
        s = s - 0.2
      end
      return s
    end,
  },
  fast = {
    hard = function(e)
      return latency_hint(e) ~= "high"
    end,
    score = function(e)
      local l = latency_of(e)
      local s = 0
      if l <= 300 then
        s = s + 2
      elseif l <= 800 then
        s = s + 1
      elseif l > 3000 then
        s = s - 2
      end
      if cost_of(e) <= 0 then
        s = s + 0.5
      end
      s = s + (quality_of(e) - 0.5) * 0.4
      return s
    end,
  },
  good = {
    hard = function(e)
      return quality_of(e) >= 0.5
    end,
    score = function(e)
      local s = quality_of(e) * 3
      if e.reasoning then
        s = s + 1
      end
      local l = latency_of(e)
      if l > 2000 then
        s = s - 0.5
      end
      return s
    end,
  },
  cheap = {
    hard = function()
      return true
    end,
    score = function(e)
      local c = cost_of(e)
      local s = 0
      if c <= 0 then
        s = s + 3
      elseif c < 0.5 then
        s = s + 2
      elseif c < 2 then
        s = s + 1
      else
        s = s - 1
      end
      -- Smaller context windows imply cheaper local inference.
      if e.context_window and e.context_window > 0 then
        s = s - e.context_window / 1000000
      end
      s = s + quality_of(e) * 0.3
      return s
    end,
  },
}

--- Extra tools treated as destructive under ask_first (expands the base list).
local EXTRA_DESTRUCTIVE_ASK_FIRST = {
  "create",
  "edit_file",
  "insert",
  "replace_in_file",
  "str_replace",
  "write_to_file",
  "undo_edit",
  "write_todos",
  "run_agent",
  "create_plan",
  "update_plan",
  "add_debug_instrumentation",
}

--- Path to the persisted policy state.
---@return string
function M.path()
  local cfg = require("agent_core").config
  local pol = cfg.policy or {}
  if pol.path and pol.path ~= "" then
    return vim.fn.expand(pol.path)
  end
  return vim.fn.stdpath("data") .. "/agent_core/policy.json"
end

local function read_persisted()
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

local function write_persisted(data)
  vim.fn.mkdir(vim.fn.fnamemodify(M.path(), ":h"), "p")
  local f = io.open(M.path(), "w")
  if not f then
    return false
  end
  f:write(vim.fn.json_encode(data))
  f:close()
  return true
end

--- The active knob values (config defaults merged with persisted overrides).
---@return {model_policy:string, trust_scope:string, caution:string}
function M.get_active()
  local cfg = require("agent_core").config
  local pol = cfg.policy or {}
  local state = {
    model_policy = pol.model_policy or "balanced",
    trust_scope = pol.trust_scope or "any",
    caution = pol.caution or "act_first",
  }
  return vim.tbl_deep_extend("force", state, read_persisted())
end

--- Set a single knob to a valid value. Returns the updated state, or nil + err.
---@param knob string
---@param value string
---@return table|nil state
---@return string|nil err
function M.set_knob(knob, value)
  local valid = M.KNOBS[knob]
  if not valid then
    return nil, "unknown knob: " .. tostring(knob)
  end
  if not vim.tbl_contains(valid, value) then
    return nil, "invalid value '" .. tostring(value) .. "' for " .. knob
  end
  local data = read_persisted()
  data[knob] = value
  if not write_persisted(data) then
    return nil, "could not write policy store"
  end
  return M.get_active()
end

--- Set several knobs at once (used by aliases).
---@param knobs table<string, string>
---@return table state
function M.set(knobs)
  local data = read_persisted()
  for knob, value in pairs(knobs or {}) do
    if M.KNOBS[knob] and vim.tbl_contains(M.KNOBS[knob], value) then
      data[knob] = value
    end
  end
  write_persisted(data)
  return M.get_active()
end

--- Apply a named alias (composition of the three knobs).
---@param name string
---@return table|nil state
---@return string|nil err
function M.alias(name)
  local a = M.ALIASES[name]
  if not a then
    return nil, "unknown alias: " .. tostring(name)
  end
  return M.set(a)
end

--- Whether cloud LLM classification is allowed under the given knobs.
---@param knobs table
---@return boolean
local function classifier_allowed(knobs)
  if knobs.trust_scope ~= "any" then
    return false
  end
  if knobs.model_policy == "cheap" then
    return false
  end
  return true
end

--- Mode-preference bonus under the given knobs.
---@param knobs table
---@param mode_name string
---@return number
local function mode_bonus(knobs, mode_name)
  local bonus = 0
  if knobs.caution == "ask_first" then
    if mode_name == "plan" or mode_name == "ask" then
      bonus = bonus + 1
    end
  end
  if knobs.model_policy == "good" then
    if mode_name == "plan" then
      bonus = bonus + 0.5
    end
  end
  return bonus
end

--- Build a policy object from knob values.
---@param knobs table|nil
---@return table policy
function M.apply(knobs)
  knobs = knobs or M.get_active()
  local allowed = TRUST_SCOPES[knobs.trust_scope] or TRUST_SCOPES.any
  local def = POLICY_DEFS[knobs.model_policy] or POLICY_DEFS.balanced
  return {
    model_policy = knobs.model_policy,
    trust_scope = knobs.trust_scope,
    caution = knobs.caution,
    allowed_trusts = allowed,
    classifier_allowed = classifier_allowed(knobs),
    expand_destructive = knobs.caution == "ask_first",
    trim_loops = knobs.model_policy == "cheap",
    --- Score a registry entry. Returns -math.huge for filtered-out entries.
    score = function(entry)
      if not vim.tbl_contains(allowed, entry.trust) then
        return -math.huge
      end
      if not def.hard(entry) then
        return -math.huge
      end
      return def.score(entry)
    end,
    --- Mode-preference bonus for the recommend layer.
    mode_bonus = function(mode_name)
      return mode_bonus(knobs, mode_name)
    end,
  }
end

--- Rank registry entries for a role under the active policy (best first,
--- filtered entries omitted).
---@param role string
---@return table[]
function M.rank(role)
  local Registry = require("agent_core.registry")
  local pol = M.apply()
  local entries = {}
  for _, e in ipairs(Registry.for_role(role)) do
    if pol.score(e) > -1e15 then
      entries[#entries + 1] = e
    end
  end
  table.sort(entries, function(a, b)
    return pol.score(a) > pol.score(b)
  end)
  return entries
end

--- Effective destructive-tools list: the base config list, expanded by ask_first.
---@return string[]
function M.effective_destructive_tools()
  local cfg = require("agent_core").config
  local base = cfg.destructive_tools or {}
  if M.get_active().caution ~= "ask_first" then
    return base
  end
  local set = {}
  for _, t in ipairs(base) do
    set[t] = true
  end
  for _, t in ipairs(EXTRA_DESTRUCTIVE_ASK_FIRST) do
    set[t] = true
  end
  local out = {}
  for t in pairs(set) do
    out[#out + 1] = t
  end
  table.sort(out)
  return out
end

--- Human-readable one-line summary of the active policy.
---@return string
function M.describe()
  local s = M.get_active()
  return string.format("%s / %s / %s", s.model_policy, s.trust_scope, s.caution)
end

function M.setup()
  vim.fn.mkdir(vim.fn.fnamemodify(M.path(), ":h"), "p")
end

--- Backing for :AgentPolicy (with no arg, pick an alias; with an arg, apply it).
---@param arg string
function M.policy_cmd(arg)
  local text = arg or ""
  if text ~= "" then
    if M.ALIASES[text] then
      local ok, err = M.alias(text)
      if ok then
        vim.notify("Agent policy: " .. M.describe(), vim.log.levels.INFO)
      else
        vim.notify("Agent policy: " .. tostring(err), vim.log.levels.ERROR)
      end
    elseif text:find("=", 1, true) then
      local knob, value = text:match("^%s*([%w_]+)%s*=%s*([%w_]+)%s*$")
      local ok, err = M.set_knob(knob, value)
      if ok then
        vim.notify("Agent policy: " .. M.describe(), vim.log.levels.INFO)
      else
        vim.notify("Agent policy: " .. tostring(err), vim.log.levels.ERROR)
      end
    else
      vim.notify("Agent policy: " .. M.describe() .. " (unknown arg, showing current)", vim.log.levels.INFO)
    end
    return
  end

  local aliases = vim.tbl_keys(M.ALIASES)
  table.sort(aliases)
  local options = {}
  for _, a in ipairs(aliases) do
    options[#options + 1] = a
  end
  table.insert(options, "(show current)")
  vim.ui.select(options, { prompt = "Agent policy (alias): " }, function(choice)
    if not choice or choice == "(show current)" then
      vim.notify("Agent policy: " .. M.describe(), vim.log.levels.INFO)
      return
    end
    local ok, err = M.alias(choice)
    if ok then
      vim.notify("Agent policy: " .. M.describe(), vim.log.levels.INFO)
    else
      vim.notify("Agent policy: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

return M
