---@mod agent_core.autoswitch Provider/model router.
---@brief [[
--- Listens for the owned `AgentInputSubmitted` User autocmd and classifies each
--- prompt against the profiles' declared strengths (keywords). When the best-fit
--- profile differs from the active one, offers an interactive Switch/Ignore
--- prompt.
---
--- Classification is hybrid:
---   1. A fast, offline keyword heuristic scores every routable profile.
---      High-confidence results short-circuit.
---   2. Low-confidence results optionally trigger a one-shot LLM classification
---      via the owned provider transport, falling back to the heuristic on any
---      failure.
---@brief ]]

local M = {}

---@class AgentAutoSwitchConfig
---@field enabled boolean
---@field confidence_threshold number  0..1; below this the LLM fallback runs
---@field use_llm_fallback boolean
---@field min_prompt_length integer    prompts shorter than this are ignored
M.config = {
  enabled = true,
  confidence_threshold = 0.6,
  use_llm_fallback = true,
  min_prompt_length = 8,
}

local Profiles ---@type agent_core.profiles

--- Resolve the profiles module lazily so heuristic_classify works even when
--- called directly (e.g. in tests) before autoswitch.setup() has run.
local function get_profiles()
  if not Profiles then
    Profiles = require("agent_core.profiles")
  end
  return Profiles
end

--- Normalize a keyword entry (string or { phrase, weight }) to (phrase, weight).
local function norm_keyword(k)
  if type(k) == "table" then
    return k[1], k[2] or 1
  end
  return k, 1
end

--- Routable profile names (autoswitch ~= false), for the LLM fallback prompt.
local function routable_names()
  local names = {}
  for _, p in ipairs(get_profiles().all()) do
    if p.autoswitch ~= false then
      names[#names + 1] = p.name
    end
  end
  return names
end

--- Policy weight for a profile under the active policy. Returns -math.huge when
--- the profile is filtered out (trust scope or hard filter), 0 when the policy
--- or registry is unavailable (degrade to keyword-only scoring), otherwise the
--- numeric policy score.
---@param profile_name string
---@return number
local function policy_bonus(profile_name)
  local ok_pol, Policy = pcall(require, "agent_core.policy")
  if not ok_pol then
    return 0
  end
  local ok_reg, Registry = pcall(require, "agent_core.registry")
  if not ok_reg then
    return 0
  end
  local entry = Registry.find(profile_name)
  if not entry then
    return 0
  end
  return Policy.apply().score(entry)
end

--- Score a lowercased prompt against every routable profile's keywords.
--- A profile is only considered when at least one keyword matched; the policy
--- bonus then re-ranks among the matched profiles (and trust/hard filters drop
--- profiles entirely).
--- @param ltext string lowercased prompt
--- @return {profile: string, score: number}[] sorted descending by score
local function score_profiles(ltext)
  local scored = {}
  for _, p in ipairs(get_profiles().all()) do
    if p.autoswitch ~= false then
      local bonus = policy_bonus(p.name)
      if bonus > -1e15 then
        local kw = 0
        for _, k in ipairs(p.keywords or {}) do
          local phrase, weight = norm_keyword(k)
          if phrase and phrase ~= "" and ltext:find(phrase, 1, true) then
            kw = kw + weight
          end
        end
        if kw > 0 then
          scored[#scored + 1] = { profile = p.name, score = kw + bonus }
        end
      end
    end
  end

  table.sort(scored, function(a, b)
    return a.score > b.score
  end)
  return scored
end

--- Classify a prompt using the fast keyword heuristic.
--- @param text string
--- @return {profile: string, score: number, confidence: number}|nil
function M.heuristic_classify(text)
  local ltext = text:lower()
  local scored = score_profiles(ltext)
  local top = scored[1]
  if not top or top.score <= 0 then
    return nil
  end
  local runner_up = scored[2] or { score = 0 }
  local confidence = top.score / (top.score + runner_up.score)
  return { profile = top.profile, score = top.score, confidence = confidence }
end

--- One-shot LLM classification. Calls the owned provider transport; falls back
--- to the heuristic result (via cb with a nil profile) if the model is
--- unavailable, fails, or times out.
--- @param text string
--- @param cb fun(profile: string|nil)
function M.llm_classify(text, cb)
  -- Short-circuit when the active policy forbids cloud classification (it
  -- would send prompt content to an external host).
  local ok_pol, Policy = pcall(require, "agent_core.policy")
  if ok_pol and not Policy.apply().classifier_allowed then
    cb(nil)
    return
  end

  local profile = require("agent_core.runner").resolve_profile(nil)
  if not profile then
    cb(nil)
    return
  end

  local names = routable_names()
  if #names == 0 then
    cb(nil)
    return
  end

  local system_prompt =
    "You route software-engineering requests to the best-fit agent profile. Reply with exactly one profile name."
  local labels = {}
  for _, p in ipairs(get_profiles().all()) do
    if p.autoswitch ~= false then
      labels[#labels + 1] = p.name .. ": " .. (p.when_to_use or "")
    end
  end
  local user_prompt = table.concat({
    "Classify this request as the single best-fit agent profile.",
    "Profiles:\n" .. table.concat(labels, "\n"),
    "Request: " .. text,
  }, "\n\n")

  local done = false
  local function finish(profile_name)
    if done then
      return
    end
    done = true
    cb(profile_name)
  end

  -- Hard timeout so a stuck request can never leave the callback dangling.
  vim.defer_fn(function()
    finish(nil)
  end, 15000)

  require("agent_core.runner").llm_curl(profile, {
    system_prompt = system_prompt,
    user_prompt = user_prompt,
    timeout_ms = 15000,
  }, function(result)
    if result.error then
      finish(nil)
      return
    end
    local response = (result.text or ""):gsub("```", ""):lower()
    for _, p in ipairs(get_profiles().all()) do
      if p.autoswitch ~= false and response:find(p.name:lower(), 1, true) then
        finish(p.name)
        return
      end
    end
    finish(nil)
  end)
end

--- Build a switch descriptor for a target profile, or nil if already active.
--- @param target table profile definition
--- @return {to:string, reason:string, apply:fun()}|nil
function M.make_decision(target)
  local profiles = get_profiles()
  local active = profiles.get_active()
  if not target or target.name == active then
    return nil
  end
  local reason = target.when_to_use or ("best fit for " .. target.name)
  return {
    to = target.name,
    reason = reason,
    apply = function()
      profiles.switch(target)
    end,
  }
end

--- Full classification pipeline. Returns a switch descriptor via cb (nil when
--- disabled, too short, the handover prompt, no match, or already active).
--- @param text string
--- @param cb fun(decision: {to:string, reason:string, apply:fun()}|nil)
function M.classify(text, cb)
  if not M.config.enabled then
    cb(nil)
    return
  end
  if type(text) ~= "string" or text == "" then
    cb(nil)
    return
  end
  if #text < M.config.min_prompt_length then
    cb(nil)
    return
  end
  -- Skip the internally generated "handover document" prompt.
  if text:find("handover document to be stored in the AGENTS.md", 1, true) then
    cb(nil)
    return
  end

  local best = M.heuristic_classify(text)
  if not best then
    cb(nil)
    return
  end

  local profiles = get_profiles()
  if best.profile == profiles.get_active() then
    cb(nil)
    return
  end

  if best.confidence >= M.config.confidence_threshold or not M.config.use_llm_fallback then
    cb(M.make_decision(profiles.find(best.profile)))
    return
  end

  -- Low confidence: ask the model, fall back to the heuristic on failure.
  M.llm_classify(text, function(profile)
    if profile then
      cb(M.make_decision(profiles.find(profile)))
    else
      cb(M.make_decision(profiles.find(best.profile)))
    end
  end)
end

--- Public helper backing the :AgentAutoSwitch command.
--- @param text string
function M.autoswitch_manual(text)
  if not text or text == "" then
    return
  end
  M.classify(text, function(decision)
    if decision then
      require("agent_core.coordinator").present({ profile = decision })
    else
      vim.notify("Agent autoswitch: no profile switch needed for that prompt", vim.log.levels.INFO)
    end
  end)
end

function M.setup(opts)
  Profiles = require("agent_core.profiles")
  local cfg = require("agent_core").config
  M.config = vim.tbl_deep_extend("force", M.config, cfg.autoswitch or {})
  if opts then
    M.config = vim.tbl_deep_extend("force", M.config, opts)
  end
end

return M
