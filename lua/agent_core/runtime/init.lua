---@mod agent_core.runtime Owned agent runtime (owned).
---@brief [[
--- The owned core that replaces the retired upstream runtime: provider transport,
--- per-session agent loop, tool dispatch, history persistence, the Agents Window
--- grid, and clipboard. Exposes the public API agent_core's existing modules
--- consume once the upstream runtime is retired (Phase 5):
---
---   submit(text, opts)  — run a prompt through a per-session agent
---   sessions()           — the live Session list
---   open()               — open the Agents Window grid
---   model(provider, m)   — switch the active session's model (mid-flight ok)
---   providers()/tools()/history()/clipboard()/ui() — subsystem accessors
---
--- Provider/model are per-Session fields, so N sessions on N models stream
--- concurrently. This file is the stable entry point; each subsystem lives in a
--- submodule so it can be required and unit-tested independently.
---@brief ]]

local Config = require("agent_core.runtime.config")

local M = {}

M.config = Config.merge()

--- Merge user options into the runtime config.
---@param opts table|nil
function M.setup(opts)
  M.config = Config.merge(opts)
end

--- Resolve a provider module by name (delegates to the registry).
---@param name string
---@return table|nil
function M.provider(name)
  return (require("agent_core.runtime.providers").get(name))
end

--- The provider registry module (get / with_defaults / stream).
---@return table
function M.providers()
  return require("agent_core.runtime.providers")
end

--- Stream a completion through a provider (thin wrapper over the registry).
---@param opts table
---@return boolean ok
---@return string|nil err
function M.stream(opts)
  return require("agent_core.runtime.providers").stream(opts)
end

--- Normalize legacy-shaped custom tools into provider descriptors.
---@param tools table[]
---@return table[]
function M.normalize_tools(tools)
  return require("agent_core.runtime.schema").normalize_tools(tools)
end

--- The owned tool registry (register / get / all / descriptors / execute).
---@return table
function M.tools()
  return require("agent_core.runtime.tools")
end

--- Create a per-session agent (provider/model are per-instance fields).
---@param opts table
---@return table session
function M.new_session(opts)
  return require("agent_core.runtime.session").new(opts)
end

--- The owned built-in tools.
---@return table[]
function M.builtin_tools()
  return require("agent_core.runtime.session").builtin_tools()
end

--- The owned session-history store (list/load/save/rename/fork/rewind/set_model).
---@return table
function M.history()
  return require("agent_core.runtime.history")
end

--- The owned clipboard → vision-message bridge.
---@return table
function M.clipboard()
  return require("agent_core.runtime.clipboard")
end

--- The Agents Window grid manager.
---@return table
function M.ui()
  return require("agent_core.runtime.ui")
end

--- Context editing + compaction (token estimation, thresholds, summary request).
---@return table
function M.context()
  return require("agent_core.runtime.context")
end

--- The successive-prompt workflows engine.
---@return table
function M.workflows()
  return require("agent_core.runtime.workflows")
end

--- Slash commands + context variables.
---@return table
function M.slash()
  return require("agent_core.runtime.slash")
end

--- The owned MCP client bridge.
---@return table
function M.mcp()
  return require("agent_core.runtime.mcp")
end

-- ---------------------------------------------------------------------------
-- Session manager + submit API
-- ---------------------------------------------------------------------------

M._sessions = {} ---@type table[]
M._active = 0 ---@type integer

--- Resolve an API key from a profile (explicit key > environment > keys store).
---@param p table profile
---@return string|nil
local function resolve_key(p)
  if not p then
    return nil
  end
  local api_key = p.api_key
  if (not api_key or api_key == "") and p.api_key_name then
    api_key = os.getenv(p.api_key_name)
  end
  if (not api_key or api_key == "") and p.name then
    local ok2, Keys = pcall(require, "agent_core.keys")
    if ok2 then
      local k = Keys.get(p.name)
      if k and k ~= "" then
        api_key = k
      end
    end
  end
  return api_key
end

--- Resolve default provider/model/api-key from the active agent_core profile.
--- Returns nil when no profile is resolvable.
---@return table|nil
local function resolve_defaults()
  local ok, Profiles = pcall(require, "agent_core.profiles")
  if not ok then
    return nil
  end
  local p = Profiles.find(Profiles.get_active())
  if not p then
    for _, cand in ipairs(Profiles.all()) do
      if cand.autoswitch ~= false and cand.provider and cand.model then
        p = cand
        break
      end
    end
  end
  if not p then
    return nil
  end

  return {
    provider = p.provider,
    model = Profiles.effective_model(p),
    api_key = resolve_key(p),
    endpoint = p.endpoint,
    api_key_name = p.api_key_name,
  }
end

--- The live Session list.
---@return table[]
function M.sessions()
  return M._sessions
end

--- The active Session (or nil).
---@return table|nil
function M.active_session()
  return M._sessions[M._active]
end

--- Look up a Session by id.
---@param id string
---@return table|nil
function M.get_session(id)
  for _, s in ipairs(M._sessions) do
    if s.id == id then
      return s
    end
  end
  return nil
end

--- Create and track a Session, defaulting provider/model from the active profile
--- when not supplied.
---@param opts table
---@return table session
function M.create_session(opts)
  opts = opts or {}
  local d = resolve_defaults() or {}
  local session = require("agent_core.runtime.session").new({
    id = opts.id,
    title = opts.title,
    provider = opts.provider or d.provider,
    model = opts.model or d.model,
    api_key = opts.api_key or d.api_key,
    endpoint = opts.endpoint or d.endpoint,
    api_key_name = opts.api_key_name or d.api_key_name,
  })
  M._sessions[#M._sessions + 1] = session
  if M._active == 0 then
    M._active = #M._sessions
  end
  return session
end

--- Set the active session by id (or index). Returns the session or nil.
---@param id string|integer
---@return table|nil
function M.focus_session(id)
  if type(id) == "number" then
    local s = M._sessions[id]
    if s then
      M._active = id
    end
    return s
  end
  for i, s in ipairs(M._sessions) do
    if s.id == id then
      M._active = i
      return s
    end
  end
  return nil
end

--- Remove a session by id (and its active-index bookkeeping). Returns true when
--- a session was removed.
---@param id string
---@return boolean
function M.remove_session(id)
  local idx = nil
  for i, s in ipairs(M._sessions) do
    if s.id == id then
      idx = i
      break
    end
  end
  if not idx then
    return false
  end
  table.remove(M._sessions, idx)
  if M._active > #M._sessions then
    M._active = #M._sessions
  end
  return true
end

--- Switch the active session's provider/model (mid-flight switch supported —
--- the next turn picks up the new model). Returns (ok, err).
---@param provider string|nil
---@param model string|nil
---@return boolean ok
---@return string|nil err
function M.model(provider, model)
  local s = M.active_session()
  if not s then
    return false, "no active session"
  end
  if provider and provider ~= "" then
    s.provider = provider
  end
  if model and model ~= "" then
    s.model = model
  end
  return true, nil
end

--- Apply a full profile to the active session (provider/model/API key/endpoint).
--- Mid-flight switch supported: the next turn picks up the new fields. No-op when
--- no active session exists.
---@param profile table
---@return boolean applied
function M.apply_profile(profile)
  local s = M.active_session()
  if not s or not profile then
    return false
  end
  if profile.provider then
    s.provider = profile.provider
  end
  if profile.model then
    s.model = profile.model
  end
  if profile.api_key_name then
    s.api_key_name = profile.api_key_name
    s.api_key = resolve_key(profile)
  end
  if profile.endpoint then
    s.endpoint = profile.endpoint
  end
  return true
end

--- Restore open sessions from the last Neovim run (when enabled in ui config).
---@return integer count
function M.restore_sessions()
  local cfg = M.config.ui or {}
  if not cfg.restore_sessions then
    return 0
  end
  return require("agent_core.runtime.session_state").restore(M)
end

--- Persist the current open session list (for reload).
function M.persist_open_sessions()
  require("agent_core.runtime.session_state").save(M)
end

--- Open the Agents Window grid.
function M.open()
  return require("agent_core.runtime.ui").open()
end

--- Build an approval gate for the active mode: destructive tools (per the
--- modes.lua auto_approve policy) prompt the user; everything else auto-approves.
--- Returns nil when no gate is needed (read-only mode has no writes to approve).
---@param mode_name string|nil
---@return fun(name:string, cb:fun(allow:boolean))|nil
local function make_approver(mode_name)
  local ok, Modes = pcall(require, "agent_core.modes")
  if not ok then
    return nil
  end
  local mode = Modes.find(mode_name)
  if not mode or mode.read_only then
    return nil
  end

  local Tools = require("agent_core.runtime.tools")
  local full = Tools.full_set(require("agent_core").get_custom_tools())
  local names = {}
  for _, t in ipairs(full) do
    names[#names + 1] = t.name
  end

  local ok_pol, Policy = pcall(require, "agent_core.policy")
  local destructive = (ok_pol and Policy.effective_destructive_tools and Policy.effective_destructive_tools()) or {}
  local approval = Modes.auto_approve(mode, names)

  return function(name, cb)
    local needs
    if approval == true then
      needs = false
    elseif approval == false then
      needs = vim.tbl_contains(destructive, name)
    else
      needs = vim.tbl_contains(destructive, name) and not vim.tbl_contains(approval, name)
    end
    if not needs then
      cb(true)
      return
    end
    local choice = vim.fn.confirm('Allow tool "' .. name .. '"?', "&Yes\n&No", 1, "Question")
    cb(choice == 1)
  end
end

--- Submit a prompt through a per-session agent, streaming into the Agents
--- Window. Creates a new session when `opts.new` is set or none is active.
--- Returns the session.
---@param text string
---@param opts { new?:boolean, provider?:string, model?:string, api_key?:string, endpoint?:string, api_key_name?:string, title?:string, system_prompt?:string, tools?:table[], max_iterations?:integer, open?:boolean }
---@return table session
function M.submit(text, opts)
  opts = opts or {}
  local ui = require("agent_core.runtime.ui")

  -- Resolve slash commands (/plan /mode /profile /workflow /agent) and
  -- @-context variables first. Dispatch mutating control actions before a
  -- session/turn exists; plain prompts fall through with the expanded text.
  local Slash = require("agent_core.runtime.slash")
  local expanded, action = Slash.resolve(text)

  if action then
    if action.action == "mode" then
      local Modes = require("agent_core.modes")
      local m = action.mode and Modes.find(action.mode) or nil
      if m then
        Modes.switch(m)
      else
        vim.notify("Mode not found: " .. tostring(action.mode), vim.log.levels.WARN)
      end
      return nil
    elseif action.action == "profile" then
      local Profiles = require("agent_core.profiles")
      local p = action.profile and Profiles.find(action.profile) or nil
      if p then
        Profiles.switch(p)
      else
        vim.notify("Profile not found: " .. tostring(action.profile), vim.log.levels.WARN)
      end
      return nil
    elseif action.action == "workflow" then
      local W = require("agent_core.runtime.workflows")
      local found
      for _, w in ipairs(W.list()) do
        if w.name == action.workflow then
          found = w
          break
        end
      end
      if not found then
        vim.notify("Workflow not found: " .. tostring(action.workflow), vim.log.levels.WARN)
        return nil
      end
      local def = table.concat(vim.fn.readfile(found.path), "\n")
      W.run(def, nil, function(err)
        if err then
          vim.notify("Workflow error: " .. tostring(err), vim.log.levels.ERROR)
        else
          vim.notify("Workflow complete: " .. found.name, vim.log.levels.INFO)
        end
      end)
      return nil
    elseif action.action == "submit" then
      if action.mode and action.mode ~= "" then
        local Modes = require("agent_core.modes")
        local m = Modes.find(action.mode)
        if m then
          Modes.switch(m)
        end
      end
      local sub = vim.deepcopy(opts)
      if action.new then
        sub.new = true
      end
      return M.submit(action.text, sub)
    end
  end

  text = expanded

  -- Fire the input-submitted event so coordinator/recommend/hooks observe the
  -- prompt (the owned analog of the upstream input-submitted event).
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "AgentInputSubmitted",
    modeline = false,
    data = { input = text, request = text },
  })

  local session = (not opts.new) and M.active_session() or nil
  if not session then
    session = M.create_session({
      provider = opts.provider,
      model = opts.model,
      api_key = opts.api_key,
      endpoint = opts.endpoint,
      api_key_name = opts.api_key_name,
      title = opts.title,
    })
    M.focus_session(session.id)
  end

  -- Title an untitled session from the first prompt (Cursor-like).
  if (session.title == nil or session.title == "untitled") and text ~= "" then
    session.title = text:gsub("%s+", " "):sub(1, 60)
  end

  -- Resolve the full tool set and filter it by the active mode (read_only
  -- allowlist), preserving the modes.lua permission policy 1:1.
  local ok_modes, Modes = pcall(require, "agent_core.modes")
  local mode_name = ok_modes and Modes.get_active() or nil
  local Tools = require("agent_core.runtime.tools")
  local tools = opts.tools
  if not tools or #tools == 0 then
    local full = Tools.full_set(require("agent_core").get_custom_tools())
    tools = Tools.filter_for_mode(full, Modes.find(mode_name))
  end

  -- System prompt: explicit override, else the interactive assembly (mode
  -- persona + brief + rules + notepad + memory + commands).
  local system_prompt = opts.system_prompt or require("agent_core.runner").build_system_prompt(nil)

  local pane = ui.find(session)
  if not pane then
    pane = ui.add(session)
  end

  -- Compaction: summarize old turns with a cheaper model once the soft
  -- threshold is crossed, then force-drop on the hard threshold.
  local Context = require("agent_core.runtime.context")
  local compact_fn = function(older, cfg, cb)
    local req = Context.build_compaction_request(older, cfg)
    local Providers = require("agent_core.runtime.providers")
    local provider = req.provider or session.provider
    local model = req.model or session.model
    local api_key = session.api_key
    local api_key_name = session.api_key_name
    if req.provider and req.provider ~= session.provider then
      api_key_name = Providers.defaults[req.provider] and Providers.defaults[req.provider].api_key_name
      api_key = resolve_key({ api_key_name = api_key_name })
    end
    local ok, err = Providers.stream({
      provider = provider,
      model = model,
      api_key = api_key,
      endpoint = session.endpoint,
      api_key_name = api_key_name,
      system = req.system,
      messages = { { role = "user", content = req.prompt } },
      on_chunk = function() end,
      on_stop = function(res)
        cb(res.error and nil or res.text, res.error)
      end,
    })
    if not ok then
      cb(nil, err)
    end
  end

  -- Start the agent turn. MCP discovery is async, so the turn is gated on it
  -- completing (merging discovered MCP tools into the descriptor set).
  local function start_turn(final_tools)
    ui.run(pane, text, {
      system_prompt = system_prompt,
      tools = final_tools,
      approve = make_approver(mode_name),
      max_iterations = opts.max_iterations,
      context = M.config.context,
      compact_fn = compact_fn,
      on_complete = function(err)
        -- Persist the session into the owned history store so list/resume/
        -- rename/fork/rewind see it. A cancelled turn is not persisted (no
        -- half-written messages).
        if err ~= "cancelled" then
          session:persist(vim.fn.stdpath("data") .. "/agent_core/history")
          M.persist_open_sessions()
        end
        pcall(function()
          require("agent_core.runtime.ui.chatlist").render()
        end)
      end,
    })
    if opts.open ~= false then
      ui.open()
    end
  end

  local Mcp = require("agent_core.runtime.mcp")
  if Mcp.config.enabled then
    Mcp.discover_all(function(mcp_tools)
      if not mcp_tools or #mcp_tools == 0 then
        start_turn(tools)
        return
      end
      local merged = {}
      for _, t in ipairs(tools) do
        merged[#merged + 1] = t
      end
      for _, t in ipairs(mcp_tools) do
        merged[#merged + 1] = t
      end
      start_turn(merged)
    end)
  else
    start_turn(tools)
  end

  return session
end

return M
