---@mod agent_core.runtime.ui.ide Split-based Cursor IDE layout (owned).
---@brief [[
--- Persistent split panes instead of floating windows: editor (left) | chat
--- messages + composer (center-right) | agents history sidebar (far right).
--- The file explorer and bottom terminal are left to the user's Neovim config.
---@brief ]]

local M = {}

local state = {
  editor_win = nil,
  chat_win = nil,
  agents_win = nil,
  composer_win = nil,
  active = false,
}

--- Whether the IDE layout splits are currently open.
---@return boolean
function M.is_open()
  return state.active and state.chat_win and vim.api.nvim_win_is_valid(state.chat_win)
end

--- Tear down IDE splits (buffers persist).
function M.close()
  if state.composer_win and vim.api.nvim_win_is_valid(state.composer_win) then
    pcall(vim.api.nvim_win_close, state.composer_win, true)
  end
  if state.chat_win and vim.api.nvim_win_is_valid(state.chat_win) then
    pcall(vim.api.nvim_win_close, state.chat_win, true)
  end
  if state.agents_win and vim.api.nvim_win_is_valid(state.agents_win) then
    pcall(vim.api.nvim_win_close, state.agents_win, true)
  end
  state.editor_win = nil
  state.chat_win = nil
  state.agents_win = nil
  state.composer_win = nil
  state.active = false
  pcall(function()
    require("agent_core.runtime.ui.composer").close()
  end)
  pcall(function()
    require("agent_core.runtime.ui.chatlist").close()
  end)
end

--- Open or refresh the IDE layout for the owned UI manager.
---@param ui table agent_core.runtime.ui
function M.open(ui)
  if #vim.api.nvim_list_uis() == 0 then
    return
  end

  local rt = require("agent_core.runtime")
  local cfg = rt.config.ui or {}
  local chat_w = cfg.chat_width or 38
  local agents_w = cfg.agents_width or 28
  local comp_h = cfg.composer_height or 6

  local chatlist = require("agent_core.runtime.ui.chatlist")
  local composer = require("agent_core.runtime.ui.composer")

  local pane = ui.active()
  if not pane then
    return
  end

  -- Idempotent refresh when splits are already up.
  if M.is_open() then
    vim.api.nvim_win_set_buf(state.chat_win, pane.bufnr)
    pane.winid = state.chat_win
    ui.apply_title(pane)
    chatlist.render()
    if state.composer_win and vim.api.nvim_win_is_valid(state.composer_win) then
      composer.open_in_win(state.composer_win)
    else
      composer.refresh_chrome()
    end
    return
  end

  state.editor_win = vim.api.nvim_get_current_win()

  -- Chat column (right of editor).
  vim.cmd("vsplit")
  local chat_col = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(chat_col, chat_w)

  -- Agents sidebar (far right).
  vim.cmd("vsplit")
  state.agents_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(state.agents_win, agents_w)

  -- Message view (top) + unified composer input with bottom pills (bottom).
  vim.api.nvim_set_current_win(chat_col)
  vim.cmd("belowright split")
  state.composer_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(state.composer_win, comp_h)
  vim.cmd("wincmd k")
  state.chat_win = vim.api.nvim_get_current_win()

  -- Attach buffers.
  vim.api.nvim_win_set_buf(state.chat_win, pane.bufnr)
  pane.winid = state.chat_win

  local cbuf = chatlist.ensure_buffer()
  vim.api.nvim_win_set_buf(state.agents_win, cbuf)
  chatlist.attach(state.agents_win)
  chatlist.render()

  composer.open_in_win(state.composer_win)
  pcall(vim.api.nvim_set_option_value, "winbar", "", { win = state.composer_win })

  -- Winbar labels (splits have no float title).
  local ok_wl, wl = pcall(vim.api.nvim_get_option_value, "winbar", { win = state.chat_win })
  if ok_wl and wl == "" then
    pcall(vim.api.nvim_set_option_value, "winbar", " Chat ", { win = state.chat_win })
    pcall(vim.api.nvim_set_option_value, "winbar", " Agents ", { win = state.agents_win })
  end

  ui.workspace_mode = true
  ui.msg_win = state.chat_win
  ui.winids = { state.agents_win, state.chat_win }
  state.active = true

  -- Buffer-local keymaps on the message view.
  local opts = { noremap = true, silent = true, buffer = pane.bufnr }
  vim.keymap.set("n", "<Tab>", ui.next, opts)
  vim.keymap.set("n", "<S-Tab>", ui.prev, opts)
  vim.keymap.set("n", "q", function()
    ui.close_workspace()
  end, opts)

  ui.apply_title(pane)
  vim.api.nvim_set_current_win(state.composer_win)
end

return M
