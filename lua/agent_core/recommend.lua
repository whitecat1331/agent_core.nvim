---@mod agent_core.recommend Mode-realm recommendation.
---@brief [[
--- Listens for avante's `AvanteInputSubmitted` User autocmd and classifies each
--- prompt against the active mode's "realm" (its keywords). When a prompt is a
--- poor fit for the active mode, recommends switching to the best-fit mode with
--- an interactive Switch/Ignore prompt.
---
--- Classification is hybrid:
---   1. A fast, offline keyword heuristic scores every mode (sum of weighted
---      keyword hits). High-confidence results short-circuit.
---   2. Low-confidence results optionally trigger a one-shot LLM classification
---      via avante's own client, falling back to the heuristic on any failure.
---@brief ]]

local M = {}

---@class AgentRecommendConfig
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

local Modes ---@type agent_core.modes

--- Resolve the modes module lazily so heuristic_classify works even when called
--- directly (e.g. in tests) before recommend.setup() has run.
local function get_modes()
  if not Modes then
    Modes = require("agent_core.modes")
  end
  return Modes
end

--- Imperative edit verbs. When the active mode is read-only and one of these
--- appears, we boost full-write modes (agent/debug) so a mismatch is more
--- likely to be surfaced.
local IMPERATIVE_VERBS = {
  "implement",
  "build",
  "add",
  "create",
  "rename",
  "delete",
  "change",
  "write",
  "refactor",
  "update",
  "modify",
  "fix",
  "wire up",
  "scaffold",
  "generate",
}

local MODE_NAMES = { "ask", "plan", "debug", "agent", "multitask" }

--- Normalize a keyword entry (string or { phrase, weight }) to (phrase, weight).
local function norm_keyword(k)
  if type(k) == "table" then
    return k[1], k[2] or 1
  end
  return k, 1
end

--- Score a lowercased prompt against every mode's keywords.
--- @param ltext string lowercased prompt
--- @return {mode: string, score: number}[] sorted descending by score
local function score_modes(ltext)
  local modes = get_modes()
  local active = modes.get_active()

  -- Policy mode-preference bonus (0 when policy is unavailable).
  local ok_pol, Policy = pcall(require, "agent_core.policy")
  local pol = ok_pol and Policy.apply() or nil

  local scored = {}
  for _, mode in ipairs(modes.all()) do
    local score = 0
    for _, k in ipairs(mode.keywords or {}) do
      local phrase, weight = norm_keyword(k)
      if phrase and phrase ~= "" and ltext:find(phrase, 1, true) then
        score = score + weight
      end
    end

    -- Bonus when a read-only mode is active but the prompt reads like an edit
    -- request: boost the full-write modes (agent for build verbs, debug for
    -- "fix"-family verbs) so the mismatch surfaces.
    if modes.find(active) and modes.find(active).read_only then
      for _, verb in ipairs(IMPERATIVE_VERBS) do
        if ltext:find(verb, 1, true) then
          if mode.name == "debug" and verb == "fix" then
            score = score + 1
          elseif mode.name == "agent" then
            score = score + 0.5
          end
          break
        end
      end
    end

    -- Policy bias (ask_first -> plan/ask; good -> plan).
    if pol then
      score = score + pol.mode_bonus(mode.name)
    end

    scored[#scored + 1] = { mode = mode.name, score = score }
  end

  table.sort(scored, function(a, b)
    return a.score > b.score
  end)
  return scored
end

--- Classify a prompt using the fast keyword heuristic.
--- @param text string
--- @return {mode: string, score: number, confidence: number}|nil
function M.heuristic_classify(text)
  local ltext = text:lower()
  local scored = score_modes(ltext)
  local top = scored[1]
  if not top or top.score <= 0 then
    return nil
  end
  local runner_up = scored[2] or { score = 0 }
  local confidence = top.score / (top.score + runner_up.score)
  return { mode = top.mode, score = top.score, confidence = confidence }
end

--- One-shot LLM classification. Calls avante's own curl client; falls back to
--- the heuristic result (via cb with a nil mode) if the model is unavailable,
--- fails, or times out.
--- @param text string
--- @param cb fun(mode: string|nil)
function M.llm_classify(text, cb)
  -- Short-circuit when the active policy forbids cloud classification.
  local ok_pol, Policy = pcall(require, "agent_core.policy")
  if ok_pol and not Policy.apply().classifier_allowed then
    cb(nil)
    return
  end
  local ok_llm, Llm = pcall(require, "avante.llm")
  if not ok_llm or not Llm.curl then
    cb(nil)
    return
  end
  local ok_prov, Providers = pcall(require, "avante.providers")
  local ok_cfg, Config = pcall(require, "avante.config")
  if not ok_prov or not ok_cfg or not Config.provider then
    cb(nil)
    return
  end
  local provider = Providers[Config.provider]
  if not provider then
    cb(nil)
    return
  end

  local names = table.concat(MODE_NAMES, "/")
  local system_prompt = "You classify software-engineering requests. Reply with exactly one word from: " .. names .. "."
  local labels = {}
  for _, m in ipairs(get_modes().all()) do
    labels[#labels + 1] = m.name .. ": " .. (m.when_to_use or "")
  end
  local messages = {
    {
      role = "user",
      content = table.concat({
        "Classify this request as the single best-fit mode.",
        "Modes:\n" .. table.concat(labels, "\n"),
        "Request: " .. text,
      }, "\n\n"),
    },
  }

  local response = ""
  local done = false

  local function finish(mode)
    if done then
      return
    end
    done = true
    cb(mode)
  end

  -- Hard timeout so a stuck request can never leave the callback dangling.
  vim.defer_fn(function()
    finish(nil)
  end, 15000)

  local ok = pcall(Llm.curl, {
    provider = provider,
    prompt_opts = {
      system_prompt = system_prompt,
      messages = messages,
    },
    handler_opts = {
      on_start = function() end,
      on_chunk = function(chunk)
        if not chunk then
          return
        end
        response = response .. chunk
      end,
      on_stop = function(stop_opts)
        if stop_opts and stop_opts.error ~= nil then
          finish(nil)
          return
        end
        response = response:gsub("```", ""):lower()
        local word = response:match("(%a+)")
        for _, name in ipairs(MODE_NAMES) do
          if word == name then
            finish(name)
            return
          end
        end
        finish(nil)
      end,
    },
  })
  if not ok then
    finish(nil)
  end
end

--- Build a switch descriptor for a target mode, or nil if already active.
--- @param target table mode definition
--- @return {to:string, reason:string, apply:fun()}|nil
function M.make_decision(target)
  local modes = get_modes()
  local active = modes.get_active()
  if not target or target.name == active then
    return nil
  end
  local label = target.label or target.name
  local reason = target.when_to_use or ("best fit for " .. target.name)
  return {
    to = label,
    reason = reason,
    apply = function()
      modes.switch(target)
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
  -- Skip avante's internally generated "handover document" prompt.
  if text:find("handover document to be stored in the AGENTS.md", 1, true) then
    cb(nil)
    return
  end

  local best = M.heuristic_classify(text)
  if not best then
    cb(nil)
    return
  end

  local modes = get_modes()
  if best.mode == modes.get_active() then
    cb(nil)
    return
  end

  if best.confidence >= M.config.confidence_threshold or not M.config.use_llm_fallback then
    cb(M.make_decision(modes.find(best.mode)))
    return
  end

  -- Low confidence: ask the model, fall back to the heuristic on failure.
  M.llm_classify(text, function(mode)
    if mode then
      cb(M.make_decision(modes.find(mode)))
    else
      cb(M.make_decision(modes.find(best.mode)))
    end
  end)
end

--- Public helper backing the :AgentRecommend command.
--- @param text string
function M.recommend_manual(text)
  if not text or text == "" then
    return
  end
  M.classify(text, function(decision)
    if decision then
      require("agent_core.coordinator").present({ mode = decision })
    else
      vim.notify("Agent mode: no mode switch needed for that prompt", vim.log.levels.INFO)
    end
  end)
end

function M.setup(opts)
  Modes = require("agent_core.modes")
  local cfg = require("agent_core").config
  M.config = vim.tbl_deep_extend("force", M.config, cfg.recommend or {})
  if opts then
    M.config = vim.tbl_deep_extend("force", M.config, opts)
  end
end

return M
