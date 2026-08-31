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

--- Selectable model_policy axes (the iron triangle). "balanced" is not an axis;
--- it is the collapsed form of selecting all three (or no strong preference).
M.AXES = { "good", "fast", "cheap" }

--- Normalize a model_policy value to its canonical form: the scalar "balanced",
--- a single axis scalar, or a sorted 2-axis list. Returns nil for an empty or
--- invalid selection (callers decide whether to fall back or reject).
---@param v string|string[]|nil
---@return string|string[]|nil
function M.normalize_model_policy(v)
  if v == "balanced" then
    return "balanced"
  end
  if type(v) == "string" then
    if vim.tbl_contains(M.AXES, v) then
      return v
    end
    return nil
  end
  if type(v) ~= "table" then
    return nil
  end
  local seen = {}
  for _, a in ipairs(v) do
    if type(a) == "string" and vim.tbl_contains(M.AXES, a) then
      seen[a] = true
    end
  end
  local axes = vim.tbl_keys(seen)
  table.sort(axes)
  if #axes == 0 then
    return nil
  elseif #axes == 3 then
    return "balanced"
  elseif #axes == 1 then
    return axes[1]
  end
  return axes
end

--- Whether a model_policy value (scalar or list) contains the named axis.
--- Returns false for the "balanced" scalar.
---@param mp string|string[]|nil
---@param name string
---@return boolean
function M.contains_axis(mp, name)
  if type(mp) == "table" then
    for _, a in ipairs(mp) do
      if a == name then
        return true
      end
    end
    return false
  end
  return mp == name
end

--- Human-readable model_policy: a list renders as "good+fast", otherwise the
--- scalar as-is.
---@param mp string|string[]|nil
---@return string
function M.format_model_policy(mp)
  if type(mp) == "table" then
    return table.concat(mp, "+")
  end
  return mp or "balanced"
end

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
    hard = function(e)
      -- Cost ceiling: reject the "expensive" tier (and any numeric per-1M cost
      -- above the metered tier) so a model can be "too expensive to use".
      return cost_of(e) <= 4
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

--- A combined policy def for a 2-axis selection: intersect the hard filters and
--- sum the scores. Reuses the individual POLICY_DEFS entries verbatim.
---@param axes string[]
---@return table
local function combined_def(axes)
  local defs = {}
  for _, a in ipairs(axes) do
    defs[#defs + 1] = POLICY_DEFS[a]
  end
  return {
    hard = function(e)
      for _, d in ipairs(defs) do
        if not d.hard(e) then
          return false
        end
      end
      return true
    end,
    score = function(e)
      local s = 0
      for _, d in ipairs(defs) do
        s = s + d.score(e)
      end
      return s
    end,
  }
end

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
  local stored = value
  if knob == "model_policy" then
    stored = M.normalize_model_policy(value)
    if not stored then
      return nil, "select at least one axis: good, fast, cheap"
    end
  elseif not vim.tbl_contains(valid, value) then
    return nil, "invalid value '" .. tostring(value) .. "' for " .. knob
  end
  local data = read_persisted()
  data[knob] = stored
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
    if M.KNOBS[knob] then
      if knob == "model_policy" then
        local normalized = M.normalize_model_policy(value)
        if normalized then
          data[knob] = normalized
        end
      elseif vim.tbl_contains(M.KNOBS[knob], value) then
        data[knob] = value
      end
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
  local mp = M.normalize_model_policy(knobs.model_policy) or "balanced"
  if M.contains_axis(mp, "cheap") then
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
  local mp = M.normalize_model_policy(knobs.model_policy) or "balanced"
  if M.contains_axis(mp, "good") then
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
  local mp = M.normalize_model_policy(knobs.model_policy)
  if not mp then
    mp = "balanced"
  end
  local def
  if type(mp) == "table" then
    def = combined_def(mp)
  else
    def = POLICY_DEFS[mp] or POLICY_DEFS.balanced
  end
  return {
    model_policy = mp,
    trust_scope = knobs.trust_scope,
    caution = knobs.caution,
    allowed_trusts = allowed,
    classifier_allowed = classifier_allowed(knobs),
    expand_destructive = knobs.caution == "ask_first",
    trim_loops = M.contains_axis(mp, "cheap"),
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

--- Best catalog model for a provider under the active policy (deterministic).
--- Returns a registry entry (with .model/.provider) or nil when none passes the
--- trust/hard filters.
---@param provider string
---@return table|nil
function M.best_model(provider)
  local Registry = require("agent_core.registry")
  local pol = M.apply()
  local best, best_score
  for _, e in ipairs(Registry.list()) do
    if e.provider == provider then
      local s = pol.score(e)
      if s > -1e15 and (not best or s > best_score) then
        best, best_score = e, s
      end
    end
  end
  return best
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
  return string.format("%s / %s / %s", M.format_model_policy(s.model_policy), s.trust_scope, s.caution)
end

--- Apply a full 3-knob selection (the guided wizard's write). Pure: no UI, so it
--- is headless-testable. Missing knobs keep their current value.
---@param model_policy string|string[]|nil
---@param trust_scope string|nil
---@param caution string|nil
---@return table state
function M.guided_apply(model_policy, trust_scope, caution)
  return M.set({
    model_policy = model_policy,
    trust_scope = trust_scope,
    caution = caution,
  })
end

--- Guided 3-knob selector: model_policy -> trust_scope -> caution, each via
--- vim.ui.select, defaulting to the current value on cancel, then guided_apply.
---@param cb fun()|nil
function M.guided(cb)
  cb = cb or function() end
  local current = M.get_active()

  local mp_labels = { "balanced", "good", "fast", "cheap", "good+fast", "good+cheap", "fast+cheap" }

  --- Map a picker label ("good+fast") back to the canonical scalar/list form.
  local function parse_mp(label)
    if label == "balanced" then
      return "balanced"
    end
    local axes = {}
    for axis in label:gmatch("[^+]+") do
      axes[#axes + 1] = axis
    end
    if #axes == 1 then
      return axes[1]
    end
    return axes
  end

  local function step_caution(mp_label, scope)
    vim.ui.select(M.KNOBS.caution, { prompt = "Model policy: caution" }, function(caution)
      M.guided_apply(parse_mp(mp_label), scope, caution or current.caution)
      cb()
    end)
  end

  local function step_trust_scope(mp_label)
    vim.ui.select(M.KNOBS.trust_scope, { prompt = "Model policy: trust scope" }, function(scope)
      step_caution(mp_label, scope or current.trust_scope)
    end)
  end

  vim.ui.select(mp_labels, { prompt = "Model policy: quality / cost / speed" }, function(mp)
    step_trust_scope(mp or M.format_model_policy(current.model_policy))
  end)
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
  table.insert(options, "(guided setup)")
  table.insert(options, "(show current)")
  vim.ui.select(options, { prompt = "Agent policy (alias): " }, function(choice)
    if not choice or choice == "(show current)" then
      vim.notify("Agent policy: " .. M.describe(), vim.log.levels.INFO)
      return
    end
    if choice == "(guided setup)" then
      M.guided(function()
        vim.notify("Agent policy: " .. M.describe(), vim.log.levels.INFO)
      end)
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
