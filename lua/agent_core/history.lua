---@mod agent_core.history Session history resume (owned persistence).
---@brief [[
--- Lists, resumes, renames, forks, and rewinds prior agent chat sessions so the
--- user can navigate them like Cursor's chat list. The store is the OWNED
--- runtime history directory (`agent_core.runtime.history`); each session record
--- carries its own `title`, `profile`, `provider`, and `model`, so there are no
--- sticky side-stores (the old session_titles.json / session_profiles.json
--- workarounds are gone).
---
--- `list(dir)`, `load(dir, id)`, `rename_session`, `fork_session`, and
--- `rewind_session` are pure and delegate to the owned store so they remain
--- trivially testable without any external runtime installed. `load_into_sidebar`
--- and `current_session_id` are re-pointed to the owned Agents Window.
---@brief ]]

local M = {}

M.config = {
  enabled = true,
  dir = nil, -- nil = <data>/agent_core/history (owned store)
}

--- The owned history store module.
---@return table
local function store()
  return require("agent_core.runtime.history")
end

--- The active history directory (owned store).
---@return string
function M.history_dir()
  if M.config.dir and M.config.dir ~= "" then
    return vim.fn.expand(M.config.dir)
  end
  return vim.fn.stdpath("data") .. "/agent_core/history"
end

--- List session files in `dir` as {id, title, provider, model, path} entries.
---@param dir string|nil
---@return {id:string,title:string,provider:string|nil,model:string|nil,path:string}[]
function M.list(dir)
  return store().list(dir or M.history_dir())
end

--- Load a session by id and return its decoded JSON, or nil,error.
---@param dir string|nil
---@param id string
---@return table|nil, string|nil
function M.load(dir, id)
  return store().load(dir or M.history_dir(), id)
end

--- The title of a session id (record title, else id).
---@param dir string|nil
---@param id string
---@return string
function M.title_for(dir, id)
  return store().title_for(dir or M.history_dir(), id)
end

--- Resolve a profile name to its provider + model (best-effort, nil on failure).
---@param name string
---@return string|nil provider
---@return string|nil model
local function resolve_profile_model(name)
  local ok, Profiles = pcall(require, "agent_core.profiles")
  if not ok then
    return nil, nil
  end
  local p = Profiles.find(name)
  if not p then
    return nil, nil
  end
  return p.provider, p.model
end

--- Bind a session id to a profile (name) and its resolved provider/model, all
--- stored on the session record itself.
---@param id string
---@param profile string
---@return boolean
function M.bind_profile(id, profile)
  if not id or id == "" or not profile or profile == "" then
    return false
  end
  local dir = M.history_dir()
  local data = store().load(dir, id) or {}
  data.profile = profile
  local provider, model = resolve_profile_model(profile)
  data.provider = provider or data.provider
  data.model = model or data.model
  return store().save(dir, id, data)
end

--- Return the profile name bound to a session id, or nil.
---@param id string
---@return string|nil
function M.get_bound_profile(id)
  if not id or id == "" then
    return nil
  end
  local data = store().load(M.history_dir(), id)
  if not data then
    return nil
  end
  return data.profile
end

--- Rename a session by setting the record title (no sticky side-store).
---@param id string
---@param title string
---@return boolean
function M.rename_session(id, title)
  if not id or id == "" or not title or title == "" then
    return false
  end
  return store().rename(M.history_dir(), id, title)
end

--- Delete a session record by id.
---@param id string
---@return boolean
function M.delete_session(id)
  if not id or id == "" then
    return false
  end
  return store().delete(M.history_dir(), id)
end

--- Persist a provider/model pair onto a session record (per-session model memory).
---@param id string
---@param provider string|nil
---@param model string|nil
---@return boolean
function M.persist_model(id, provider, model)
  if not id or id == "" then
    return false
  end
  return store().set_model(M.history_dir(), id, provider, model)
end

--- Fork a session: deep-copy its record to a new id with a new title. The fork
--- carries the same provider/model/profile, so it reopens on the same model.
---@param id string
---@param title string|nil
---@return string|nil, string|nil
function M.fork_session(id, title)
  if not id or id == "" then
    return nil, "no session to fork"
  end
  return store().fork(M.history_dir(), id, title)
end

--- Rewind a session to a message index (keep 1..index), backing up first.
---@param id string
---@param index integer
---@return boolean, string|nil
function M.rewind_session(id, index)
  if not id or id == "" then
    return false, "no session to rewind"
  end
  return store().rewind(M.history_dir(), id, index)
end

--- Extract readable text from a message content (string or content blocks).
---@param content any
---@return string
local function content_text(content)
  if type(content) == "string" then
    return content
  end
  if type(content) == "table" then
    local parts = {}
    for _, block in ipairs(content) do
      if type(block) == "table" and block.text ~= nil then
        parts[#parts + 1] = tostring(block.text)
      elseif block ~= nil then
        parts[#parts + 1] = tostring(block)
      end
    end
    return table.concat(parts, " ")
  end
  return tostring(content or "")
end

--- A one-line preview of a history message (role + first text).
---@param msg table
---@return string
local function message_preview(msg)
  local m = type(msg) == "table" and (msg.message or msg) or {}
  local role = m.role or msg and msg.role or "?"
  local text = content_text(m.content):gsub("%s+", " ")
  if #text > 90 then
    text = text:sub(1, 90) .. "…"
  end
  return string.format("%s: %s", tostring(role), text ~= "" and text or "(empty)")
end

--- The current session id (the active owned-runtime session, or "" when none).
---@return string
function M.current_session_id()
  local ok, rt = pcall(require, "agent_core.runtime")
  if not ok or not rt.active_session then
    return ""
  end
  local s = rt.active_session()
  if not s then
    return ""
  end
  return s.id or ""
end

--- Resume a session straight into the owned Agents Window, seeding a new session
--- from the record (title/provider/model/messages) and replaying prior turns.
--- Restores a bound profile when present.
---@param id string
---@return boolean
function M.load_into_sidebar(id)
  if not id or id == "" then
    return false
  end

  local data, err = M.load(M.history_dir(), id)
  if not data then
    vim.notify("History: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end

  local rt = require("agent_core.runtime")
  local ui = require("agent_core.runtime.ui")

  local session = rt.create_session({
    id = data.id or id,
    title = data.title,
    provider = data.provider,
    model = data.model,
  })
  session.messages = vim.deepcopy(data.messages or {})
  rt.focus_session(session.id)

  local pane = ui.add(session)
  for _, m in ipairs(data.messages or {}) do
    local msg = type(m) == "table" and (m.message or m) or m
    local role = type(msg) == "table" and msg.role or "user"
    local content = type(msg) == "table" and msg.content or msg
    if role == "assistant" then
      ui.append_message(pane, "assistant", content)
    elseif role == "tool" then
      ui.append_message(pane, "tool", content, msg.name)
    else
      ui.append_message(pane, "user", content)
    end
  end

  ui.workspace()
  return true
end

--- Present session history as a picker and resume the selected session.
function M.list_cmd()
  local entries = M.list()
  if #entries == 0 then
    vim.notify("History: no prior sessions found", vim.log.levels.INFO)
    return
  end

  local items = {}
  for _, e in ipairs(entries) do
    items[#items + 1] = { text = e.title, entry = e }
  end

  local ok, Snacks = pcall(require, "snacks.picker")
  if ok and type(Snacks) == "table" and type(Snacks.pick) == "function" then
    Snacks.pick({
      title = "Agent history",
      items = items,
      layout = { preview = false },
      format = function(item)
        return { { item.text }, { "  (" .. item.entry.id .. ")", "Comment" } }
      end,
      confirm = function(picker, item)
        picker:close()
        if item and item.entry then
          M.load_into_sidebar(item.entry.id)
        end
      end,
    })
    return
  end

  local labels = {}
  for _, e in ipairs(entries) do
    labels[#labels + 1] = string.format("%s (%s)", e.title, e.id)
  end
  vim.ui.select(labels, { prompt = "Agent history (resume)" }, function(choice)
    for _, e in ipairs(entries) do
      if choice == string.format("%s (%s)", e.title, e.id) then
        M.load_into_sidebar(e.id)
        return
      end
    end
  end)
end

--- Backing for :AgentRename.
---@param arg string|nil
function M.rename_cmd(arg)
  local id = M.current_session_id()
  if id == "" then
    vim.notify("Rename: no active session (open a chat first)", vim.log.levels.WARN)
    return
  end
  local function do_rename(title)
    if not title or title == "" then
      return
    end
    if M.rename_session(id, title) then
      vim.notify("Renamed session -> " .. title, vim.log.levels.INFO)
    else
      vim.notify("Rename: could not write title", vim.log.levels.ERROR)
    end
  end
  if arg and arg ~= "" then
    do_rename(arg)
  else
    local current = M.title_for(M.history_dir(), id)
    vim.ui.input({ prompt = "Rename session: ", default = current }, do_rename)
  end
end

--- Backing for :AgentFork.
---@param arg string|nil
function M.fork_cmd(arg)
  local id = M.current_session_id()
  if id == "" then
    vim.notify("Fork: no active session (open a chat first)", vim.log.levels.WARN)
    return
  end
  local new_id, err = M.fork_session(id, (arg ~= "" and arg) or nil)
  if not new_id then
    vim.notify("Fork: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  M.load_into_sidebar(new_id)
  vim.notify("Forked session -> " .. new_id, vim.log.levels.INFO)
end

--- Backing for :AgentRewind.
---@param arg string|nil
function M.rewind_cmd(arg)
  local id = M.current_session_id()
  if id == "" then
    vim.notify("Rewind: no active session (open a chat first)", vim.log.levels.WARN)
    return
  end

  local function do_rewind(index)
    local ok, err = M.rewind_session(id, index)
    if not ok then
      vim.notify("Rewind: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    M.load_into_sidebar(id)
    vim.notify("Rewound to message " .. index .. " (backup: " .. id .. ".json.rewind-bak)", vim.log.levels.INFO)
  end

  if arg and arg ~= "" and tonumber(arg) then
    do_rewind(tonumber(arg))
    return
  end

  local data = M.load(M.history_dir(), id)
  local msgs = data and data.messages or {}
  if #msgs == 0 then
    vim.notify("Rewind: session has no messages", vim.log.levels.WARN)
    return
  end

  local items = {}
  for i, m in ipairs(msgs) do
    items[#items + 1] = { index = i, text = message_preview(m) }
  end

  local ok, Snacks = pcall(require, "snacks.picker")
  if ok and type(Snacks) == "table" and type(Snacks.pick) == "function" then
    Snacks.pick({
      title = "Rewind to message",
      items = items,
      layout = { preview = false },
      format = function(item)
        return { { string.format("%d  ", item.index) }, { item.text } }
      end,
      confirm = function(picker, item)
        picker:close()
        if item then
          do_rewind(item.index)
        end
      end,
    })
    return
  end

  local labels = {}
  for _, item in ipairs(items) do
    labels[#labels + 1] = string.format("%d. %s", item.index, item.text)
  end
  vim.ui.select(labels, { prompt = "Rewind to message (keep up to and including)" }, function(choice)
    for _, item in ipairs(items) do
      if choice == string.format("%d. %s", item.index, item.text) then
        do_rewind(item.index)
        return
      end
    end
  end)
end

--- Backing for :AgentSessionBind.
---@param arg string|nil
function M.session_bind_cmd(arg)
  local id = M.current_session_id()
  if id == "" then
    vim.notify("Session bind: no active session (open a chat first)", vim.log.levels.WARN)
    return
  end
  local Profiles = require("agent_core.profiles")
  local profile_name = (arg and arg ~= "") and arg or Profiles.get_active()
  if not profile_name or profile_name == "" then
    vim.notify("Session bind: no active profile", vim.log.levels.WARN)
    return
  end
  local p = Profiles.find(profile_name)
  if not p then
    vim.notify("Session bind: unknown profile " .. tostring(profile_name), vim.log.levels.ERROR)
    return
  end
  if M.bind_profile(id, p.name) then
    vim.notify("Session bind: " .. p.name .. " -> " .. id, vim.log.levels.INFO)
  else
    vim.notify("Session bind: could not write session record", vim.log.levels.ERROR)
  end
end

function M.setup()
  local cfg = require("agent_core").config
  M.config = vim.tbl_deep_extend("force", M.config, cfg.history or {})
  vim.fn.mkdir(vim.fn.fnamemodify(M.history_dir(), ":h"), "p")
end

return M
