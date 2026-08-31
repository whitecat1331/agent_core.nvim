---@mod agent_core.runtime.ui.chatlist Agents history sidebar (owned).
---@brief [[
--- Cursor-style far-right Agents Window: open chats plus persisted history
--- grouped by Today / Yesterday / Last 7 Days / Last 30 Days / Older, with
--- status icons. Pure rows() builder (headless-testable) + thin buffer glue.
--- <CR> focuses or resumes; r rename, d delete, / filter, q close.
---@brief ]]

local M = {}

local state = { buf = nil, win = nil, filter = "", map = {} }

--- Calendar day bucket for a Unix timestamp (pure).
---@param ts integer|nil file mtime from getftime
---@param now integer|nil override for tests
---@return string group label
function M.time_group(ts, now)
  if not ts or ts <= 0 then
    return "Older"
  end
  now = now or os.time()
  local today = os.date("*t", now)
  local then_d = os.date("*t", ts)
  local function day_num(t)
    return t.year * 10000 + t.month * 100 + t.day
  end
  local diff = day_num(today) - day_num(then_d)
  if diff == 0 then
    return "Today"
  end
  if diff == 1 then
    return "Yesterday"
  end
  if diff <= 7 then
    return "Last 7 Days"
  end
  if diff <= 30 then
    return "Last 30 Days"
  end
  return "Older"
end

--- Status glyph for an open session (pure).
---@param status string|nil
---@return string
function M.status_icon(status)
  if status == "running" then
    return "●"
  end
  return "✓"
end

--- Build chat-list rows: section headers plus one line per entry, and a
--- caret-line -> action map. Pure (runtime/history reads are injectable via env).
---@param filter string|nil
---@param opts { now?:integer, history_dir?:string }|nil
---@return { lines:string[], map:table<integer, table> }
function M.rows(filter, opts)
  filter = (filter or ""):lower()
  opts = opts or {}
  local rt = require("agent_core.runtime")
  local History = require("agent_core.history")
  local history_dir = opts.history_dir

  local lines = { "# Agents" }
  local map = {}

  local open_ids = {}
  local has_open = false
  for _, s in ipairs(rt.sessions()) do
    open_ids[s.id] = true
    local title = (s.title and s.title ~= "" and s.title) or s.id
    if filter == "" or title:lower():find(filter, 1, true) then
      if not has_open then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Open"
        has_open = true
      end
      local icon = M.status_icon(s.status)
      local active = rt.active_session() and rt.active_session().id == s.id
      local marker = active and "▣ " or "▢ "
      lines[#lines + 1] = marker .. icon .. " " .. title
      map[#lines] = { type = "open", id = s.id, title = title }
    end
  end

  local grouped = {}
  local group_order = { "Today", "Yesterday", "Last 7 Days", "Last 30 Days", "Older" }
  for _, e in ipairs(History.list(history_dir)) do
    if not open_ids[e.id] then
      local title = e.title or e.id
      if filter == "" or title:lower():find(filter, 1, true) then
        local ts = vim.fn.getftime(e.path) or 0
        local grp = M.time_group(ts, opts.now)
        grouped[grp] = grouped[grp] or {}
        grouped[grp][#grouped[grp] + 1] = e
      end
    end
  end

  for _, grp in ipairs(group_order) do
    local entries = grouped[grp]
    if entries and #entries > 0 then
      lines[#lines + 1] = ""
      lines[#lines + 1] = grp
      for _, e in ipairs(entries) do
        local title = e.title or e.id
        lines[#lines + 1] = "  ○ " .. title
        map[#lines] = { type = "history", id = e.id, title = title }
      end
    end
  end

  if #map == 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "(no chats)"
  end

  return { lines = lines, map = map }
end

local function create_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "hide")
  vim.api.nvim_buf_set_option(buf, "swapfile", false)
  vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
  return buf
end

--- Create (or return) the chat-list buffer.
---@return integer
function M.ensure_buffer()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    state.buf = create_buffer()
  end
  return state.buf
end

--- Render the current rows into the buffer (idempotent).
---@return integer buf
function M.render()
  local data = M.rows(state.filter)
  local buf = M.ensure_buffer()
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, data.lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  state.map = data.map
  return buf
end

--- The action entry under the cursor, or nil.
---@return table|nil
local function action_at()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  return state.map[line]
end

local function activate()
  local a = action_at()
  if not a then
    return
  end
  local rt = require("agent_core.runtime")
  if a.type == "open" then
    rt.focus_session(a.id)
  else
    require("agent_core.history").load_into_sidebar(a.id)
    rt.focus_session(a.id)
  end
  require("agent_core.runtime.ui").workspace()
  require("agent_core.runtime.ui.chatlist").render()
end

local function rename()
  local a = action_at()
  if not a then
    return
  end
  vim.ui.input({ prompt = "Rename chat: ", default = a.title }, function(input)
    if not input or input == "" then
      return
    end
    local rt = require("agent_core.runtime")
    local History = require("agent_core.history")
    local s = rt.get_session(a.id)
    if s then
      s.title = input
      if vim.fn.filereadable(History.history_dir() .. "/" .. a.id .. ".json") == 1 then
        History.rename_session(a.id, input)
      end
    else
      History.rename_session(a.id, input)
    end
    M.render()
  end)
end

local function remove()
  local a = action_at()
  if not a then
    return
  end
  local rt = require("agent_core.runtime")
  local ui = require("agent_core.runtime.ui")
  ui.remove_by_session(a.id)
  rt.remove_session(a.id)
  require("agent_core.history").delete_session(a.id)
  require("agent_core.runtime").persist_open_sessions()
  M.render()
  ui.workspace()
end

--- Attach buffer-local keymaps and record the window for this sidebar.
---@param win integer
function M.attach(win)
  state.win = win
  local opts = { noremap = true, silent = true, buffer = state.buf }
  vim.keymap.set("n", "<CR>", function()
    activate()
  end, opts)
  vim.keymap.set("n", "r", function()
    rename()
  end, opts)
  vim.keymap.set("n", "d", function()
    remove()
  end, opts)
  vim.keymap.set("n", "/", function()
    M.filter_prompt()
  end, opts)
  vim.keymap.set("n", "q", function()
    M.close()
  end, opts)
  vim.keymap.set("n", "<Esc>", function()
    M.close()
  end, opts)
end

--- Prompt for a filter and re-render.
function M.filter_prompt()
  vim.ui.input({ prompt = "Filter chats: ", default = state.filter }, function(input)
    state.filter = input or ""
    M.render()
  end)
end

--- Close the chat-list window (the buffer persists).
function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win = nil
end

return M
