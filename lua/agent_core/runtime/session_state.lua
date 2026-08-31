---@mod agent_core.runtime.session_state Open-session persistence across reloads.
---@brief [[
--- Saves which chat sessions were open when Neovim exits and restores them on
--- the next startup (when `ui.restore_sessions` is enabled). Session message
--- bodies live in the owned history store; this file only tracks open ids.
---@brief ]]

local M = {}

--- Path to the open-sessions state file.
---@return string
function M.path()
  return vim.fn.stdpath("data") .. "/agent_core/open_sessions.json"
end

---@return table
local function read()
  local path = M.path()
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(data) ~= "table" then
    return {}
  end
  return data
end

---@param data table
local function write(data)
  vim.fn.mkdir(vim.fn.fnamemodify(M.path(), ":h"), "p")
  local f = io.open(M.path(), "w")
  if not f then
    return false
  end
  f:write(vim.json.encode(data))
  f:close()
  return true
end

--- Persist the current open session list.
---@param rt table agent_core.runtime
function M.save(rt)
  if not rt or not rt.sessions then
    return
  end
  local dir = vim.fn.stdpath("data") .. "/agent_core/history"
  local ids = {}
  for _, s in ipairs(rt.sessions()) do
    if s.id then
      ids[#ids + 1] = s.id
      if s.persist then
        s:persist(dir)
      end
    end
  end
  local active = rt.active_session()
  write({
    active_id = active and active.id,
    open_ids = ids,
  })
end

--- Replay history messages into a pane buffer (shared with history.load_into_sidebar).
---@param ui table
---@param pane table
---@param messages table[]
local function replay_messages(ui, pane, messages)
  for _, m in ipairs(messages or {}) do
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
end

--- Restore open sessions from disk into the runtime + UI panes.
---@param rt table agent_core.runtime
---@return integer count restored
function M.restore(rt)
  local data = read()
  local open_ids = data.open_ids
  if not open_ids or #open_ids == 0 then
    return 0
  end

  local History = require("agent_core.history")
  local ui = require("agent_core.runtime.ui")
  local dir = History.history_dir()
  local count = 0

  for _, id in ipairs(open_ids) do
    if rt.get_session(id) then
      count = count + 1
    else
      local record, err = History.load(dir, id)
      if record then
        local session = rt.create_session({
          id = record.id or id,
          title = record.title,
          provider = record.provider,
          model = record.model,
        })
        session.messages = vim.deepcopy(record.messages or {})
        local pane = ui.add(session)
        replay_messages(ui, pane, record.messages)
        count = count + 1
      end
    end
  end

  if data.active_id then
    rt.focus_session(data.active_id)
  end
  return count
end

return M
