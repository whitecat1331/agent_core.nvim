---@mod agent_core.runtime.ui Agents Window grid manager (owned).
---@brief [[
--- Owned Agents Window: renders N simultaneous chat panes — one scratch buffer
--- per Session — with live streaming, focus switching, and a per-pane model
--- indicator. Replaces the upstream single sidebar + UI line + highlights.
---
--- The window/tiling layer is intentionally thin; all layout math and text
--- rendering live in grid.lua / render.lua / highlights.lua so the pure parts are
--- unit-testable headlessly. This module wires a Session's `on_text` stream to a
--- buffer and coordinates focus + the per-pane title/indicator.
---@brief ]]

local Grid = require("agent_core.runtime.ui.grid")
local Render = require("agent_core.runtime.ui.render")
local Highlights = require("agent_core.runtime.ui.highlights")

local M = {}

---@class AgentPane
---@field session table
---@field bufnr integer
---@field winid integer|nil
---@field model_label string
---@field pending string
---@field stream_started boolean|nil

M.panes = {} ---@type AgentPane[]
M.active_index = 0
M.winids = {} ---@type integer[]
M.workspace_mode = false ---@type boolean
M.msg_win = nil ---@type integer|nil

--- Create a scratch (nofile) buffer for a pane.
---@return integer bufnr
local function new_buffer()
  local bufnr = vim.api.nvim_create_buf(false, true)
  -- Drop the initial blank line so appends start at line 0.
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
  vim.api.nvim_buf_set_option(bufnr, "buftype", "nofile")
  vim.api.nvim_buf_set_option(bufnr, "bufhidden", "hide")
  vim.api.nvim_buf_set_option(bufnr, "swapfile", false)
  vim.api.nvim_buf_set_option(bufnr, "filetype", "markdown")
  vim.api.nvim_buf_set_option(bufnr, "foldmethod", "marker")
  vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
  return bufnr
end

--- Split a raw text into complete lines (terminated by \n) and a trailing partial.
---@param text string
---@return string[] complete
---@return string partial
local function split_stream(text)
  text = text:gsub("\r\n", "\n")
  local lines = {}
  local pos = 1
  while true do
    local s, e = text:find("\n", pos, true)
    if not s then
      break
    end
    lines[#lines + 1] = text:sub(pos, s - 1)
    pos = e + 1
  end
  return lines, text:sub(pos)
end

--- Append lines to the end of a pane buffer (no-op if the buffer is gone).
--- Handles the "empty buffer" case: Neovim buffers always hold at least one
--- line, so a fresh buffer is a single blank line that must be replaced rather
--- than appended after (otherwise every pane would start with a blank line).
---@param pane AgentPane
---@param lines string[]
local function append_lines(pane, lines)
  if not vim.api.nvim_buf_is_valid(pane.bufnr) then
    return
  end
  vim.api.nvim_buf_set_option(pane.bufnr, "modifiable", true)
  if vim.api.nvim_buf_line_count(pane.bufnr) == 1 and vim.api.nvim_buf_get_lines(pane.bufnr, 0, 1, false)[1] == "" then
    vim.api.nvim_buf_set_lines(pane.bufnr, 0, 1, false, lines)
  else
    vim.api.nvim_buf_set_lines(pane.bufnr, -1, -1, false, lines)
  end
  vim.api.nvim_buf_set_option(pane.bufnr, "modifiable", false)
end

--- Create a pane for a Session, wiring its `on_text` stream to the pane buffer.
---@param session table
---@return AgentPane
function M.new_pane(session)
  local pane = {
    session = session,
    bufnr = new_buffer(),
    winid = nil,
    model_label = Render.model_indicator(session.provider, session.model, session.status),
    pending = "",
    stream_started = nil,
  }
  session.on_text = function(chunk)
    M.stream_chunk(pane, chunk)
  end
  return pane
end

--- Find a pane by its Session (identity) or by buffer number.
---@param session table|nil
---@param bufnr integer|nil
---@return AgentPane|nil
function M.find(session, bufnr)
  for _, pane in ipairs(M.panes) do
    if (session and pane.session == session) or (bufnr and pane.bufnr == bufnr) then
      return pane
    end
  end
  return nil
end

--- Add a Session as a new pane. Returns the pane.
---@param session table
---@return AgentPane
function M.add(session)
  local pane = M.new_pane(session)
  M.panes[#M.panes + 1] = pane
  if M.active_index == 0 then
    M.active_index = #M.panes
  end
  if M.winids and #M.winids > 0 and not M.workspace_mode then
    -- Window already open: re-layout to include the new pane.
    M.relayout()
  end
  return pane
end

--- Remove a pane by index (and its buffer). Returns true on success.
---@param index integer
---@return boolean
function M.remove(index)
  local pane = M.panes[index]
  if not pane then
    return false
  end
  if pane.winid and vim.api.nvim_win_is_valid(pane.winid) then
    pcall(vim.api.nvim_win_close, pane.winid, true)
  end
  if vim.api.nvim_buf_is_valid(pane.bufnr) then
    vim.api.nvim_buf_delete(pane.bufnr, { force = true })
  end
  table.remove(M.panes, index)
  if #M.panes == 0 then
    M.active_index = 0
  elseif M.active_index > #M.panes then
    M.active_index = #M.panes
  end
  if M.winids and #M.winids > 0 and not M.workspace_mode then
    M.relayout()
  end
  return true
end

--- Point the UI's active pane at the runtime's active session (keeps the two
--- index books in sync when the runtime focuses/removes sessions directly).
function M.sync_active()
  local ok, rt = pcall(require, "agent_core.runtime")
  if not ok or not rt.active_session then
    return
  end
  local s = rt.active_session()
  if not s then
    M.active_index = 0
    return
  end
  local pane = M.find(s)
  if pane then
    for i, p in ipairs(M.panes) do
      if p == pane then
        M.active_index = i
        return
      end
    end
  end
end

--- The currently active pane, or nil.
---@return AgentPane|nil
function M.active()
  M.sync_active()
  return M.panes[M.active_index]
end

--- Append a fully-formed chat message to a pane.
---@param pane AgentPane
---@param role string
---@param content any
---@param name string|nil
function M.append_message(pane, role, content, name)
  append_lines(pane, Render.message_lines(role, content, name))
end

--- Begin a streaming assistant turn (adds the "## Agent" header).
---@param pane AgentPane
function M.begin_stream(pane)
  append_lines(pane, { "## Agent" })
  pane.stream_started = true
  pane.pending = ""
end

--- Append a streamed text chunk, splitting on newlines and buffering the trailing
--- partial line so words are never broken mid-line.
---@param pane AgentPane
---@param chunk string|nil
function M.stream_chunk(pane, chunk)
  if not pane or not vim.api.nvim_buf_is_valid(pane.bufnr) then
    return
  end
  if not pane.stream_started then
    M.begin_stream(pane)
  end
  pane.pending = pane.pending .. (chunk or "")
  local complete, partial = split_stream(pane.pending)
  if #complete > 0 then
    append_lines(pane, complete)
  end
  pane.pending = partial
end

--- Flush the trailing partial line of a stream and reset the turn marker so the
--- next assistant turn opens a fresh header.
---@param pane AgentPane
function M.end_turn(pane)
  if not pane or not vim.api.nvim_buf_is_valid(pane.bufnr) then
    return
  end
  if pane.pending and pane.pending ~= "" then
    append_lines(pane, Render.lines(pane.pending))
  end
  pane.pending = ""
  pane.stream_started = nil
end

--- Finalize a streaming turn: flush partials, add a separator, reset the status.
---@param pane AgentPane
function M.end_stream(pane)
  M.end_turn(pane)
  append_lines(pane, { "" })
  M.refresh_indicator(pane, pane.session and pane.session.status or "idle")
end

--- Refresh a pane's model/status indicator (and its window title if open).
---@param pane AgentPane
---@param status string|nil
function M.refresh_indicator(pane, status)
  if not pane then
    return
  end
  pane.model_label = Render.model_indicator(pane.session.provider, pane.session.model, status or pane.session.status)
  M.apply_title(pane)
end

--- Apply the pane's title (title + model indicator + focus marker) to its window.
---@param pane AgentPane
function M.apply_title(pane)
  if not pane.winid or not vim.api.nvim_win_is_valid(pane.winid) then
    return
  end
  local focused = M.active_index > 0 and M.panes[M.active_index] == pane
  local title = Render.pane_header(pane.session.title, pane.model_label, focused)
  local ok, cfg = pcall(vim.api.nvim_win_get_config, pane.winid)
  if ok then
    cfg.title = title
    pcall(vim.api.nvim_win_set_config, pane.winid, cfg)
  end
end

--- Set the active pane to `index` and move focus to its window.
---@param index integer
function M.focus(index)
  if index < 1 or index > #M.panes then
    return
  end
  M.active_index = index
  local pane = M.panes[index]
  local ok, rt = pcall(require, "agent_core.runtime")
  if ok and rt.focus_session then
    rt.focus_session(pane.session.id)
  end
  for _, p in ipairs(M.panes) do
    M.apply_title(p)
  end
  if M.workspace_mode and M.msg_win and vim.api.nvim_win_is_valid(M.msg_win) then
    -- Workspace: the message view shows the active pane's buffer.
    vim.api.nvim_win_set_buf(M.msg_win, pane.bufnr)
    pane.winid = M.msg_win
    M.apply_title(pane)
    pcall(function()
      require("agent_core.runtime.ui.chatlist").render()
    end)
    vim.api.nvim_set_current_win(M.msg_win)
    return
  end
  if pane.winid and vim.api.nvim_win_is_valid(pane.winid) then
    vim.api.nvim_set_current_win(pane.winid)
  end
end

--- Focus the next pane (round-robin).
function M.next()
  if #M.panes == 0 then
    return
  end
  M.focus(Grid.next_index(M.active_index, #M.panes))
end

--- Focus the previous pane (round-robin).
function M.prev()
  if #M.panes == 0 then
    return
  end
  M.focus(Grid.prev_index(M.active_index, #M.panes))
end

--- Set per-pane buffer keymaps (cycle focus, close window).
---@param pane AgentPane
local function set_pane_keymaps(pane)
  local opts = { noremap = true, silent = true, buffer = pane.bufnr }
  vim.keymap.set("n", "<Tab>", M.next, opts)
  vim.keymap.set("n", "<S-Tab>", M.prev, opts)
  vim.keymap.set("n", "q", function()
    M.close()
  end, opts)
end

--- (Re)open the Agents Window as a grid of floating panes over the editor.
function M.open()
  if #M.panes == 0 then
    return
  end
  if #M.winids > 0 then
    M.focus(M.active_index)
    return
  end
  Highlights.setup()

  local cols = vim.o.columns
  local lines = vim.o.lines
  local layout = Grid.layout(#M.panes, cols, math.max(3, lines - 2))

  for i, pane in ipairs(M.panes) do
    local g = layout[i]
    local winid = vim.api.nvim_open_win(pane.bufnr, false, {
      relative = "editor",
      row = g.row * g.height,
      col = g.col * g.width,
      width = g.width,
      height = g.height,
      style = "minimal",
      border = "rounded",
      title_pos = "center",
    })
    pane.winid = winid
    M.winids[i] = winid
    set_pane_keymaps(pane)
    M.apply_title(pane)
  end

  if M.active_index == 0 then
    M.active_index = 1
  end
  M.focus(M.active_index)
end

--- Close all Agents Window panes (buffers persist; windows are torn down).
function M.close()
  for _, winid in ipairs(M.winids) do
    if vim.api.nvim_win_is_valid(winid) then
      pcall(vim.api.nvim_win_close, winid, true)
    end
  end
  M.winids = {}
  for _, pane in ipairs(M.panes) do
    pane.winid = nil
  end
  M.workspace_mode = false
  M.msg_win = nil
end

--- Re-layout the window grid after a pane is added/removed.
function M.relayout()
  M.close()
  M.open()
end

--- Toggle the Agents Window.
function M.toggle()
  if #M.winids > 0 then
    M.close()
  else
    M.open()
  end
end

--- Run a user prompt through a pane's Session, streaming the result into the
--- pane and rendering tool results. This is the submit primitive the Phase 4
--- `submit` API reuses.
---@param pane AgentPane
---@param input string
---@param opts { system_prompt?:string, tools?:table[], session_ctx?:table, max_iterations?:integer, approve?:fun(name:string, cb:fun(allow:boolean)), context?:table, compact_fn?:fun(older:table[], cfg:table, cb:fun(summary:string|nil)), on_complete?:fun(err:string|nil) }
function M.run(pane, input, opts)
  opts = opts or {}
  M.append_message(pane, "user", input)
  local session = pane.session

  session:run({
    system_prompt = opts.system_prompt,
    user_input = input,
    tools = opts.tools,
    approve = opts.approve,
    context = opts.context,
    compact_fn = opts.compact_fn,
    on_start = function()
      M.refresh_indicator(pane, "running")
    end,
    on_messages_add = function(msgs)
      for _, m in ipairs(msgs) do
        if m.role == "assistant" then
          M.end_turn(pane)
        elseif m.role == "tool" then
          M.append_message(pane, "tool", m.content, m.name)
        end
      end
    end,
    on_complete = function(err)
      M.end_turn(pane)
      if err == "cancelled" then
        M.append_message(pane, "system", "cancelled")
      elseif err then
        M.append_message(pane, "system", "error: " .. tostring(err))
      end
      M.end_stream(pane)
      if opts.on_complete then
        opts.on_complete(err)
      end
    end,
    session_ctx = opts.session_ctx,
    max_iterations = opts.max_iterations,
  })
end

--- Stop the active pane's in-flight run (cancels the provider stream).
---@return boolean cancelled
function M.stop()
  local pane = M.active()
  if not pane or not pane.session or not pane.session.cancel then
    return false
  end
  return pane.session:cancel()
end

--- Remove a pane by its session id. Returns true when a pane was removed.
---@param id string
---@return boolean
function M.remove_by_session(id)
  for i, pane in ipairs(M.panes) do
    if pane.session and pane.session.id == id then
      return M.remove(i)
    end
  end
  return false
end

--- Open the Cursor-style chat workspace: chat messages (center-right), composer
--- (bottom), and Agents history sidebar (far right). Uses split-based IDE layout
--- when `config.ui.ide_layout` is true; otherwise the legacy float layout.
function M.workspace()
  local rt = require("agent_core.runtime")
  local session = rt.active_session()
  if not session then
    return
  end
  if not M.find(session) then
    M.add(session)
  end

  local cfg = rt.config.ui or {}
  if cfg.ide_layout then
    require("agent_core.runtime.ui.ide").open(M)
    pcall(function()
      require("agent_core.runtime.ui.chatlist").render()
    end)
    return
  end

  local chatlist = require("agent_core.runtime.ui.chatlist")
  local composer = require("agent_core.runtime.ui.composer")

  -- Idempotent: refresh in place when the layout is already up.
  if M.workspace_mode and M.msg_win and vim.api.nvim_win_is_valid(M.msg_win) then
    local pane = M.active()
    vim.api.nvim_win_set_buf(M.msg_win, pane.bufnr)
    pane.winid = M.msg_win
    M.apply_title(pane)
    chatlist.render()
    return
  end

  M.close()

  local cols = math.max(24, vim.o.columns)
  local lines = math.max(12, vim.o.lines)
  local agents_w = math.min(32, math.max(16, math.floor(cols * 0.22)))
  local chat_w = math.min(48, math.max(20, math.floor(cols * 0.35)))
  local comp_h = math.min(10, math.max(3, math.floor(lines * 0.22)))

  -- Center-right: message view (chat list is on the far right in IDE mode; floats
  -- place agents list on the right of the chat column).
  local pane = M.active()
  local mwin = vim.api.nvim_open_win(pane.bufnr, false, {
    relative = "editor",
    row = 0,
    col = cols - agents_w - chat_w,
    width = chat_w,
    height = lines - comp_h - 1,
    style = "minimal",
    border = "rounded",
    title = " Chat ",
    title_pos = "center",
  })
  pane.winid = mwin
  M.workspace_mode = true
  M.msg_win = mwin

  -- Far right: agents sidebar.
  local cbuf = chatlist.ensure_buffer()
  local cwin = vim.api.nvim_open_win(cbuf, false, {
    relative = "editor",
    row = 0,
    col = cols - agents_w,
    width = agents_w,
    height = lines - 2,
    style = "minimal",
    border = "rounded",
    title = " Agents ",
    title_pos = "center",
  })
  chatlist.attach(cwin)
  chatlist.render()

  M.winids = { cwin, mwin }
  set_pane_keymaps(pane)
  vim.keymap.set("n", "q", function()
    M.close_workspace()
  end, { noremap = true, silent = true, buffer = pane.bufnr })
  M.apply_title(pane)

  -- Bottom: composer (full width of chat + agents band).
  composer.open(cols - agents_w - chat_w, comp_h)
end

--- Tear down the workspace (chat list + message view + composer).
function M.close_workspace()
  local cfg = require("agent_core.runtime").config.ui or {}
  if cfg.ide_layout then
    require("agent_core.runtime.ui.ide").close()
  end
  M.close()
  pcall(function()
    require("agent_core.runtime.ui.chatlist").close()
  end)
  pcall(function()
    require("agent_core.runtime.ui.composer").close()
  end)
end

return M
