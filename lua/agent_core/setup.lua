---@mod agent_core.setup First-run setup wizard (:AgentSetup).
---@brief [[
--- Gets a fresh install from zero to working: detects what the user already has
--- (env keys, stored keys, local + remote Ollama), collects the missing keys in
--- a reviewable form, persists the enabled-provider set, and optionally uses one
--- AI call (catalog tags only — never key values) to suggest a policy + default
--- profile. The AI only picks the *subjective* part; tags and keys are always
--- deterministic.
---@brief ]]

local M = {}

---@class AgentSetupConfig
---@field auto_prompt boolean offer :AgentSetup on first load when unconfigured
---@field bootstrap boolean run the optional AI suggestion after save
---@field bootstrap_profile string|nil nil = first keyed cloud profile, else local Ollama
M.config = {
  auto_prompt = true,
  bootstrap = true,
  bootstrap_profile = nil,
}

---@return string
function M.setup_path()
  return require("agent_core.registry").setup_path()
end

---@return table
function M.load_state()
  return require("agent_core.registry").load_setup_state()
end

---@param data table
---@return boolean
function M.save_state(data)
  return require("agent_core.registry").save_setup_state(data)
end

--- True when a first-run setup is still needed: no setup.json and no active
--- profile has been chosen yet.
---@return boolean
function M.needs_setup()
  if vim.fn.filereadable(M.setup_path()) == 1 then
    return false
  end
  return require("agent_core.profiles").get_active() == nil
end

--- Detected environment state: which cloud providers have an env key or a stored
--- key, and the full Ollama endpoint set. Pure (no Ollama probing here; the
--- registry cache does that).
---@return table {providers: table<string, {api_key_name:string|nil, env_key:boolean, stored:boolean}>, ollama_endpoints:string[]}
function M.detect()
  local Catalog = require("agent_core.catalog")
  local Keys = require("agent_core.keys")
  local Registry = require("agent_core.registry")
  local providers = {}
  for _, provider in ipairs(Catalog.known_providers()) do
    if provider ~= "ollama" then
      local api_key_name
      for _, c in ipairs(Catalog.lookup(provider)) do
        if c.api_key_name and c.api_key_name ~= "" then
          api_key_name = c.api_key_name
          break
        end
      end
      local env_key = false
      if api_key_name then
        local v = os.getenv(api_key_name)
        env_key = v ~= nil and v ~= ""
      end
      local stored = false
      for _, c in ipairs(Catalog.lookup(provider)) do
        if c.api_key_name then
          local v = Keys.get(c.name)
          if v and v ~= "" then
            stored = true
            break
          end
        end
      end
      providers[provider] = {
        api_key_name = api_key_name,
        env_key = env_key,
        stored = stored,
      }
    end
  end
  return {
    providers = providers,
    ollama_endpoints = Registry.ollama_endpoints(),
  }
end

--- Build the form model: one row per chat-capable registry entry (primary or
--- classifier role), plus the remote Ollama endpoints from setup state. Pure
--- except for the registry/env reads; no keys are copied into the model.
---@return table {rows: table[], endpoints: string[]}
function M.form_model()
  local Registry = require("agent_core.registry")
  local state = M.load_state()
  local rows = {}
  for _, e in ipairs(Registry.list()) do
    local roles = e.roles or {}
    if vim.tbl_contains(roles, "primary") or vim.tbl_contains(roles, "classifier") then
      rows[#rows + 1] = {
        name = e.name,
        provider = e.provider,
        model = e.model,
        api_key_name = e.api_key_name,
        enabled = e.enabled,
        key_present = e.api_key_name ~= nil
          and (e.enabled == true or (os.getenv(e.api_key_name) ~= nil and os.getenv(e.api_key_name) ~= "")),
        cost = e.cost,
        quality_tier = e.quality_tier,
        trust = e.trust,
        fim = e.fim,
        reasoning = e.reasoning,
      }
    end
  end
  return {
    rows = rows,
    endpoints = state.ollama_endpoints or {},
  }
end

--- Deterministic fallback suggestion (zero AI): balanced/any/act_first and the
--- first keyed cloud profile, else the first local profile.
---@param entries table[]
---@return table {model_policy:string, trust_scope:string, caution:string, default_profile:string|nil}
function M.default_suggestion(entries)
  local cloud
  local localp
  for _, e in ipairs(entries or {}) do
    if not localp and e.provider == "ollama" then
      localp = e.name
    end
    if not cloud and e.provider ~= "ollama" and e.enabled ~= false then
      cloud = e.name
    end
  end
  return {
    model_policy = "balanced",
    trust_scope = "any",
    caution = "act_first",
    default_profile = cloud or localp or nil,
  }
end

--- Parse an LLM JSON response into a suggestion, tolerating prose/fences. On
--- failure returns nil + err.
---@param text string
---@return table|nil
---@return string|nil
function M.parse_suggestion(text)
  if not text or text == "" then
    return nil, "empty suggestion"
  end
  local start_pos = text:find("{", 1, true)
  if not start_pos then
    return nil, "no JSON object in suggestion"
  end
  local json = text:sub(start_pos)
  local depth = 0
  local end_pos = nil
  for i = 1, #json do
    local ch = json:sub(i, i)
    if ch == "{" then
      depth = depth + 1
    elseif ch == "}" then
      depth = depth - 1
      if depth == 0 then
        end_pos = i
        break
      end
    end
  end
  if not end_pos then
    return nil, "unterminated JSON in suggestion"
  end
  local ok, decoded = pcall(vim.json.decode, json:sub(1, end_pos))
  if not ok or type(decoded) ~= "table" then
    return nil, "invalid JSON in suggestion"
  end
  local Policy = require("agent_core.policy")
  local s = {}
  s.model_policy = vim.tbl_contains(Policy.KNOBS.model_policy, decoded.model_policy) and decoded.model_policy
    or "balanced"
  s.trust_scope = vim.tbl_contains(Policy.KNOBS.trust_scope, decoded.trust_scope) and decoded.trust_scope or "any"
  s.caution = vim.tbl_contains(Policy.KNOBS.caution, decoded.caution) and decoded.caution or "act_first"
  s.default_profile = decoded.default_profile
  return s
end

--- One LLM call whose input is catalog tags only (never key values), returning a
--- policy + default-profile suggestion.
---@param entries table[]
---@param cb fun(suggestion:table|nil, err:string|nil)
function M.bootstrap_suggest(entries, cb)
  cb = cb or function() end
  local Runner = require("agent_core.runner")
  local profile = Runner.resolve_profile(M.config.bootstrap_profile)
  if not profile then
    cb(M.default_suggestion(entries), nil)
    return
  end

  local lines = { "Available models (tags only):" }
  for _, e in ipairs(entries or {}) do
    lines[#lines + 1] = string.format(
      "- %s | provider=%s | model=%s | cost=%s | quality=%s | trust=%s | fim=%s | reasoning=%s",
      e.name,
      e.provider or "?",
      e.model or "?",
      e.cost or "?",
      e.quality_tier or "?",
      e.trust or "?",
      tostring(e.fim == true),
      tostring(e.reasoning == true)
    )
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = [[Choose a default policy for this user. Reply with ONLY a JSON object:
{"model_policy":"balanced|fast|good|cheap","trust_scope":"any|private|local","caution":"act_first|ask_first","default_profile":"<one of the names above>"}]]

  Runner.llm_curl(profile, {
    system_prompt = "You are a configuration assistant. Output only valid JSON, no commentary.",
    user_prompt = table.concat(lines, "\n"),
  }, function(result)
    if result.error or not result.text then
      cb(M.default_suggestion(entries), nil)
      return
    end
    local suggestion, err = M.parse_suggestion(result.text)
    if not suggestion then
      cb(M.default_suggestion(entries), nil)
      return
    end
    cb(suggestion, nil)
  end)
end

--- Live-apply a suggestion: set the policy knobs and switch the default profile.
---@param suggestion table
function M.live_apply(suggestion)
  local Policy = require("agent_core.policy")
  Policy.set({
    model_policy = suggestion.model_policy,
    trust_scope = suggestion.trust_scope,
    caution = suggestion.caution,
  })
  if suggestion.default_profile and suggestion.default_profile ~= "" then
    local Profiles = require("agent_core.profiles")
    local p = Profiles.find(suggestion.default_profile)
    if p then
      Profiles.switch(p)
    end
  end
end

--- Present a suggestion for review (Apply / Apply with edits / Skip).
---@param suggestion table
---@param cb fun(choice:string|nil)
function M.present(suggestion, cb)
  cb = cb or function() end
  local label = string.format(
    "%s / %s / %s -> %s",
    suggestion.model_policy,
    suggestion.trust_scope,
    suggestion.caution,
    suggestion.default_profile or "none"
  )
  vim.ui.select({
    "Apply",
    "Apply with edits",
    "Skip",
  }, {
    prompt = "Suggested policy: " .. label,
  }, function(choice)
    cb(choice)
  end)
end

--- Save the wizard output: store keys, persist enabled set + remote endpoints,
--- re-derive the default active profile, then optionally bootstrap.
---@param fields {enabled:table<string,boolean>|nil, keys:table<string,string>|nil, endpoints:string[]|nil, bootstrap:boolean|nil}
---@param cb fun()|nil
function M.save(fields, cb)
  cb = cb or function() end
  fields = fields or {}
  local Keys = require("agent_core.keys")
  local state = M.load_state()

  for name, key in pairs(fields.keys or {}) do
    if key and key ~= "" then
      Keys.set(name, key)
    end
  end

  if fields.enabled then
    state.enabled = state.enabled or {}
    for name, enabled in pairs(fields.enabled) do
      state.enabled[name] = enabled == true
    end
  end

  if fields.endpoints then
    state.ollama_endpoints = fields.endpoints
  end

  M.save_state(state)

  -- Re-derive the default active profile: first enabled cloud entry with a key,
  -- else the first local profile.
  local Profiles = require("agent_core.profiles")
  local target
  for _, p in ipairs(Profiles.all()) do
    local enabled = state.enabled and state.enabled[p.name]
    if enabled ~= false then
      if p.provider == "ollama" and not target then
        target = p
      elseif p.provider ~= "ollama" and p.api_key_name and Keys.get(p.name) then
        target = p
        break
      end
    end
  end
  if target and not Profiles.get_active() then
    Profiles.switch(target)
  end

  if fields.bootstrap ~= false and M.config.bootstrap then
    local Registry = require("agent_core.registry")
    local enabled_entries = {}
    for _, e in ipairs(Registry.list()) do
      if e.enabled then
        enabled_entries[#enabled_entries + 1] = e
      end
    end
    M.bootstrap_suggest(enabled_entries, function(suggestion, _)
      if not suggestion then
        cb()
        return
      end
      M.present(suggestion, function(choice)
        if choice == "Apply" then
          M.live_apply(suggestion)
          vim.notify("Applied policy: " .. require("agent_core.policy").describe(), vim.log.levels.INFO)
        elseif choice == "Apply with edits" then
          require("agent_core.policy").policy_cmd("")
        end
        cb()
      end)
    end)
    return
  end
  cb()
end

--- Render the form model into a reviewable scratch buffer (toggleable rows).
---@param model table
local function render_form(model)
  local lines = { "# Agent setup", "", "Toggle a line (edit `[x]`/`[ ]`) then :w to save, :q to cancel.", "" }
  for _, r in ipairs(model.rows) do
    local mark = r.enabled and "[x]" or "[ ]"
    lines[#lines + 1] = string.format(
      "%s %-22s provider=%-10s model=%-28s cost=%-8s quality=%-6s trust=%s",
      mark,
      r.name,
      r.provider,
      r.model or "?",
      r.cost or "?",
      r.quality_tier or "?",
      r.trust or "?"
    )
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "# Remote Ollama endpoints"
  if #model.endpoints == 0 then
    lines[#lines + 1] = "(none — local loopback only)"
  else
    for _, url in ipairs(model.endpoints) do
      lines[#lines + 1] = url
    end
  end
  lines[#lines + 1] = ""

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_keymap(buf, "n", "<CR>", "", { desc = "noop" })
  vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = math.min(120, vim.o.columns - 4),
    height = math.min(#lines + 2, vim.o.lines - 4),
    row = 2,
    col = 2,
    border = "rounded",
    title = " AgentSetup ",
    title_pos = "center",
  })
  return buf
end

--- Backing for :AgentSetup.
function M.setup_cmd()
  local model = M.form_model()
  local buf = render_form(model)

  local group = vim.api.nvim_create_augroup("AgentCoreSetup", { clear = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = buf,
    callback = function()
      local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      local enabled = {}
      for _, r in ipairs(model.rows) do
        local mark = content:match("%[([ x])%] " .. vim.pesc(r.name))
        if mark then
          enabled[r.name] = mark == "x"
        end
      end

      local keys = {}
      local function collect_keys(rows, done)
        local function next_row(i)
          if i > #rows then
            done()
            return
          end
          local r = rows[i]
          if not enabled[r.name] or r.provider == "ollama" or not r.api_key_name then
            next_row(i + 1)
            return
          end
          if r.key_present then
            next_row(i + 1)
            return
          end
          vim.ui.input({ prompt = r.api_key_name .. " for " .. r.name .. ": " }, function(input)
            if input and input ~= "" then
              keys[r.name] = input
            end
            next_row(i + 1)
          end)
        end
        next_row(1)
      end

      collect_keys(model.rows, function()
        local endpoints = model.endpoints
        vim.ui.input({
          prompt = "Extra Ollama endpoints (space-separated, blank to keep): ",
          default = table.concat(endpoints, " "),
        }, function(input)
          local ep = {}
          if input and input ~= "" then
            for url in input:gmatch("%S+") do
              ep[#ep + 1] = url
            end
          end
          vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
          M.save({ enabled = enabled, keys = keys, endpoints = ep }, function()
            vim.notify("Agent setup saved", vim.log.levels.INFO)
          end)
        end)
      end)
    end,
  })
end

function M.setup()
  local cfg = require("agent_core").config
  M.config = vim.tbl_deep_extend("force", M.config, cfg.setup or {})

  -- Never auto-prompt in headless/scripted mode (no attached UI); a blocking
  -- vim.ui.select there would hang CI/smoke runs.
  if #vim.api.nvim_list_uis() == 0 then
    return
  end
  if M.config.auto_prompt and M.needs_setup() then
    vim.schedule(function()
      vim.ui.select({
        "Run :AgentSetup now",
        "Later",
      }, {
        prompt = "agent_core first-run: configure your models?",
      }, function(choice)
        if choice and choice:find("now", 1, true) then
          M.setup_cmd()
        end
      end)
    end)
  end
end

return M
