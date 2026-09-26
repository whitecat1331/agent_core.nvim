---@mod agent_core.runtime.ui.composer Multi-line chat composer (owned).
---@brief [[
--- Cursor-style input box: a floating multi-line scratch buffer. Enter inserts a
--- newline; send keys submit the message (see SEND_KEYS in set_keymaps). Sends through the owned runtime's submit
--- path so slash commands, @-context variables, and the mode permission policy
--- all apply unchanged.
---
--- A statusline footer shows clickable mode and model pills (bottom-left).
--- Normal-mode keys on the composer buffer:
---   send keys   <C-n> new chat   <C-m> model picker   <C-d> mode picker
---   (<C-CR>, <S-CR>, <M-CR>, <C-S-CR>, or <C-g><CR>)
---   <C-s> stop    <C-x><C-o> attach menu   q close
--- Insert-mode: send keys above plus <C-j> (terminal), <C-d> mode picker (click pills).
--- Pure helpers (normalize, menu_items, footer_labels) are headless-testable;
--- the float/buffer glue is thin and no-ops when no UI is attached.
---@brief ]]

local M = {}

local state = { buf = nil, win = nil, footer_win = nil, footer_buf = nil, footer_ns = nil, footer_mode_end = 0, inline_pills = false, pill_ns = nil, new_on_send = false, prev_laststatus = nil, prev_mouse = nil, chrome_autocmd = false }

local chrome_augroup = vim.api.nvim_create_augroup("AgentCoreComposerChrome", { clear = true })

-- #region agent log
local function _dbg_log_paths()
  return {
    vim.fn.stdpath("cache") .. "/agent_core-debug-52d16c.log",
    "/mnt/c/Users/ployd/Desktop/IMS/debug-52d16c.log",
    "C:/Users/ployd/Desktop/IMS/debug-52d16c.log",
    vim.fn.getcwd() .. "/debug-52d16c.log",
  }
end

local function _dbg(hypothesisId, location, message, data)
  local payload = vim.json.encode({
    sessionId = "52d16c",
    hypothesisId = hypothesisId,
    location = location,
    message = message,
    data = data or {},
    timestamp = os.time() * 1000,
  })
  for _, path in ipairs(_dbg_log_paths()) do
    local f = io.open(path, "a")
    if f then
      f:write(payload .. "\n")
      f:close()
    end
  end
end
-- #endregion

--- Trim trailing newlines and surrounding whitespace so an empty prompt is not
--- submitted. Pure.
---@param text string
---@return string
function M.normalize(text)
  text = text or ""
  text = text:gsub("\r\n", "\n")
  text = text:gsub("%s*\n%s*$", "")
  if text:match("^%s*$") then
    return ""
  end
  return text
end

--- The active session's model/mode indicator for the composer title bar.
---@return string
function M.indicator()
  local parts = {}
  local model = M.model_label()
  if model and model ~= "" and model ~= "Model" then
    parts[#parts + 1] = model
  end
  local mode = M.mode_label()
  if mode and mode ~= "" then
    parts[#parts + 1] = mode
  end
  return #parts > 0 and table.concat(parts, " · ") or ""
end

--- Display label for the active behavior mode. Pure when `active` is passed.
---@param active string|nil mode name override (for tests)
---@return string
function M.mode_label(active)
  local ok, Modes = pcall(require, "agent_core.modes")
  if not ok then
    return "Agent"
  end
  local name = active or Modes.get_active() or vim.g.agent_mode
  local m = name and Modes.find(name)
  if m and m.label and m.label ~= "" then
    return m.label
  end
  if m and m.name and m.name ~= "" then
    return m.name:sub(1, 1):upper() .. m.name:sub(2)
  end
  if name and name ~= "" then
    return name:sub(1, 1):upper() .. name:sub(2)
  end
  return "Agent"
end

--- Display label for the active session model. Omit args to read the active
--- session; pass provider/model explicitly for tests.
---@param provider string|nil
---@param model string|nil
---@return string
function M.model_label(provider, model)
  local from_session = select("#", provider, model) == 0
    or (provider == nil and model == nil)
  if from_session then
    local rt = require("agent_core.runtime")
    local s = rt.active_session()
    model = s and s.model
    if not model or model == "" then
      model = vim.g.agent_active_model
    end
    if not model or model == "" then
      local ok, Profiles = pcall(require, "agent_core.profiles")
      if ok then
        local p = Profiles.find(Profiles.get_active())
        if p then
          model = Profiles.effective_model(p)
        end
      end
    end
  elseif model and model ~= "" then
    -- explicit args: model id only
  elseif provider and provider ~= "" then
    model = provider
  end
  if model and model ~= "" then
    return model
  end
  return "Model"
end

--- Footer pill text for mode and model selectors. Pure.
---@param mode_label string|nil
---@param model_label string|nil
---@return { mode:string, model:string }
function M.footer_labels(mode_label, model_label)
  local mode = (mode_label or "Agent") .. " ▾"
  local model = (model_label or "Model") .. " ▾"
  return { mode = mode, model = model }
end

--- Build a single footer line and the column where the model pill starts. Pure.
---@param mode_label string|nil
---@param model_label string|nil
---@return string line, integer mode_end_col
function M.footer_line(mode_label, model_label)
  local labels = M.footer_labels(mode_label, model_label)
  local gap = "   "
  local line = " " .. labels.mode .. gap .. labels.model
  local mode_end = 1 + #labels.mode
  return line, mode_end
end

--- Which pill was hit? `col` and `mode_end_col` are 1-based byte columns. Pure.
---@param col integer
---@param mode_end_col integer
---@return "mode"|"model"
function M.pill_target(col, mode_end_col)
  if col <= mode_end_col then
    return "mode"
  end
  return "model"
end

--- Whether a line is the composer pill row (mode + model selectors). Pure.
---@param text string
---@return boolean
function M.is_pill_line(text)
  text = text or ""
  return text:match("^ .+▾   .+▾$") ~= nil
end

--- Line index of the bottom pill row, or nil.
---@param buf integer|nil
---@return integer|nil
function M.pill_line_index(buf)
  buf = buf or state.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local n = vim.api.nvim_buf_line_count(buf)
  if n < 1 then
    return nil
  end
  local last = vim.api.nvim_buf_get_lines(buf, n - 1, n, false)[1] or ""
  if M.is_pill_line(last) then
    return n
  end
  return nil
end

--- Update the bottom pill row inside the composer buffer (Cursor-style single pane).
function M.sync_pill_line()
  if not state.inline_pills or not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  pcall(require("agent_core.runtime.ui.highlights").setup)
  local mode_l = M.mode_label()
  local model_l = M.model_label()
  local line, mode_end = M.footer_line(mode_l, model_l)
  state.footer_mode_end = mode_end
  local buf = state.buf
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  local idx = M.pill_line_index(buf)
  if idx then
    vim.api.nvim_buf_set_lines(buf, idx - 1, idx, false, { line })
  elseif vim.api.nvim_buf_line_count(buf) == 1 and (vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "") == "" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", line })
  else
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { line })
  end
  if not state.pill_ns then
    state.pill_ns = vim.api.nvim_create_namespace("agent_core_composer_pills")
  end
  local pill_idx = M.pill_line_index(buf)
  if not pill_idx then
    return
  end
  local row = pill_idx - 1
  vim.api.nvim_buf_clear_namespace(buf, state.pill_ns, row, row + 1)
  local model_start = mode_end + 4
  vim.api.nvim_buf_set_extmark(buf, state.pill_ns, row, 1, {
    end_col = mode_end,
    hl_group = "AgentComposerPill",
  })
  vim.api.nvim_buf_set_extmark(buf, state.pill_ns, row, model_start, {
    end_col = #line,
    hl_group = "AgentComposerPill",
  })
  vim.api.nvim_buf_set_extmark(buf, state.pill_ns, row, 0, {
    end_col = #line,
    hl_group = "AgentComposerFooter",
  })
end

local function on_pill_click(col)
  local target = M.pill_target(col, state.footer_mode_end)
  if target == "mode" then
    M.pick_mode()
  else
    M.pick_model()
  end
end

local function attach_pill_autocmds(buf)
  vim.api.nvim_create_autocmd({ "CursorMovedI", "InsertEnter" }, {
    group = chrome_augroup,
    buffer = buf,
    callback = function()
      if not state.inline_pills then
        return
      end
      local pill = M.pill_line_index(buf)
      if pill and vim.fn.line(".") >= pill then
        vim.api.nvim_win_set_cursor(0, { math.max(1, pill - 1), 0 })
      end
    end,
  })
end

--- Build the composer window statusline (clickable mode/model pills). Pure when
--- labels are supplied.
---@param opts { mode_label?:string, model_label?:string }|nil
---@return string
function M.footer_statusline(opts)
  opts = opts or {}
  local labels = M.footer_labels(opts.mode_label, opts.model_label)
  return table.concat({
    "%#AgentComposerFooter# ",
    "%@agent_core_composer_click_mode@",
    "%#AgentComposerPill# ",
    labels.mode,
    " %#AgentComposerFooter#  ",
    "%@agent_core_composer_click_model@",
    "%#AgentComposerPill# ",
    labels.model,
    " %#AgentComposerFooter#",
  })
end

local function ensure_click_handlers()
  if _G.agent_core_composer_click_mode then
    return
  end
  _G.agent_core_composer_click_mode = function()
    vim.schedule(function()
      M.pick_mode()
    end)
  end
  _G.agent_core_composer_click_model = function()
    vim.schedule(function()
      M.pick_model()
    end)
  end
end

local chrome_pending = false
local COMPOSER_STATUSLINE = "%!v:lua.require('agent_core.runtime.ui.composer').statusline()"

local apply_chrome

local function schedule_apply_chrome(win)
  if chrome_pending then
    return
  end
  chrome_pending = true
  vim.defer_fn(function()
    chrome_pending = false
    local target = win
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
      local by_buf = vim.fn.bufwinid(state.buf)
      if by_buf > 0 then
        target = by_buf
        state.win = by_buf
      end
    end
    if target and vim.api.nvim_win_is_valid(target) and apply_chrome then
      apply_chrome(target)
    end
  end, 100)
end

local function attach_chrome_autocmds(buf)
  if state.chrome_autocmd then
    return
  end
  state.chrome_autocmd = true
  vim.api.nvim_create_autocmd("WinEnter", {
    group = chrome_augroup,
    buffer = buf,
    callback = function()
      schedule_apply_chrome(state.win)
    end,
  })
end

--- Statusline expr for the composer window (mode/model pills).
---@return string
function M.statusline()
  return M.footer_statusline({
    mode_label = M.mode_label(),
    model_label = M.model_label(),
  })
end

--- Apply the composer chrome (statusline footer) to a window.
---@param win integer
--- Neovim hides all statuslines when laststatus < 2; bump temporarily so pills show.
local function ensure_statusline_visible()
  local ls = vim.o.laststatus
  if ls < 2 then
    if state.prev_laststatus == nil then
      state.prev_laststatus = ls
    end
    vim.o.laststatus = 2
  end
end

--- Restore laststatus after the composer chrome is torn down.
local function restore_statusline()
  if state.prev_laststatus ~= nil then
    local restored = state.prev_laststatus
    vim.o.laststatus = restored
    state.prev_laststatus = nil
  end
  if state.prev_mouse ~= nil then
    vim.o.mouse = state.prev_mouse
    state.prev_mouse = nil
  end
end

local function ensure_mouse_enabled()
  if vim.fn.has("mouse") ~= 1 then
    return
  end
  local mouse = vim.o.mouse or ""
  if mouse:find("a", 1, true) then
    return
  end
  if state.prev_mouse == nil then
    state.prev_mouse = mouse
  end
  vim.o.mouse = mouse == "" and "a" or (mouse .. ",a")
end

apply_chrome = function(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  ensure_statusline_visible()
  ensure_mouse_enabled()
  ensure_click_handlers()
  pcall(require("agent_core.runtime.ui.highlights").setup)
  local rb_ok, rb_val = pcall(vim.api.nvim_get_option_value, "statusline", { win = win })
  -- Global statusline (laststatus=3 / lualine) hides per-window statuslines — use inline pills instead.
  if vim.o.laststatus >= 3 or state.footer_win then
    return
  end
  if rb_ok and rb_val == COMPOSER_STATUSLINE then
    return
  end
  pcall(vim.api.nvim_set_option_value, "statusline", COMPOSER_STATUSLINE, { win = win })
end

--- Menu entries for @-mentions and /slash commands. Pure.
---@return { token:string, desc:string, kind:string }[]
function M.menu_items()
  local items = {}
  local ok, Slash = pcall(require, "agent_core.runtime.slash")
  if ok and type(Slash.list) == "function" then
    for _, c in ipairs(Slash.list()) do
      items[#items + 1] = { token = "/" .. c.name, desc = c.description or "", kind = "command" }
    end
  end
  for _, v in ipairs({ "file", "git", "selection", "buffer", "lsp" }) do
    items[#items + 1] = { token = "@" .. v, desc = "attach " .. v .. " context", kind = "mention" }
  end
  for _, v in ipairs({ "web", "docs", "folder", "symbol", "codebase" }) do
    items[#items + 1] = { token = "@" .. v, desc = "attach " .. v .. " (via agent_core.mentions)", kind = "mention" }
  end
  return items
end

local function create_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "hide")
  vim.api.nvim_buf_set_option(buf, "swapfile", false)
  vim.api.nvim_buf_set_option(buf, "filetype", "agent_core_composer")
  return buf
end

local function create_footer_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "hide")
  vim.api.nvim_buf_set_option(buf, "swapfile", false)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_set_option(buf, "filetype", "agent_core_composer_footer")
  return buf
end

local function footer_click_at(col)
  if col <= state.footer_mode_end then
    M.pick_mode()
  else
    M.pick_model()
  end
end

local function set_footer_keymaps(buf)
  local opts = { noremap = true, silent = true, buffer = buf }
  vim.keymap.set("n", "<CR>", function()
    footer_click_at(1)
  end, opts)
  vim.keymap.set("n", "<LeftMouse>", function()
    local pos = vim.fn.getmousepos()
    footer_click_at(pos.wincol or pos.column or 1)
  end, opts)
  vim.keymap.set("n", "<C-d>", M.pick_mode, opts)
  vim.keymap.set("n", "<C-m>", M.pick_model, opts)
end

--- Paint mode/model pills into the footer strip buffer (IDE layout).
function M.render_footer_bar()
  if not state.footer_buf or not vim.api.nvim_buf_is_valid(state.footer_buf) then
    return
  end
  pcall(require("agent_core.runtime.ui.highlights").setup)
  local line, mode_end = M.footer_line(M.mode_label(), M.model_label())
  state.footer_mode_end = mode_end
  local buf = state.footer_buf
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  if not state.footer_ns then
    state.footer_ns = vim.api.nvim_create_namespace("agent_core_composer_footer")
  end
  vim.api.nvim_buf_clear_namespace(buf, state.footer_ns, 0, -1)
  local gap_start = mode_end + 1
  local model_start = gap_start + 3
  vim.api.nvim_buf_set_extmark(buf, state.footer_ns, 0, 1, {
    end_col = mode_end,
    hl_group = "AgentComposerPill",
  })
  vim.api.nvim_buf_set_extmark(buf, state.footer_ns, 0, model_start, {
    end_col = #line,
    hl_group = "AgentComposerPill",
  })
  vim.api.nvim_buf_set_extmark(buf, state.footer_ns, 0, 0, {
    end_col = #line,
    hl_group = "AgentComposerFooter",
  })
end

--- Attach the 1-line footer strip below the composer (IDE layout).
---@param win integer
function M.setup_footer_win(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  if not state.footer_buf or not vim.api.nvim_buf_is_valid(state.footer_buf) then
    state.footer_buf = create_footer_buffer()
    set_footer_keymaps(state.footer_buf)
  end
  state.footer_win = win
  vim.api.nvim_win_set_buf(win, state.footer_buf)
  vim.api.nvim_win_set_height(win, 1)
  pcall(vim.api.nvim_set_option_value, "winbar", "", { win = win })
  pcall(vim.api.nvim_set_option_value, "statusline", "", { win = win })
  pcall(vim.api.nvim_set_option_value, "number", false, { win = win })
  pcall(vim.api.nvim_set_option_value, "relativenumber", false, { win = win })
  pcall(vim.api.nvim_set_option_value, "signcolumn", "no", { win = win })
  M.render_footer_bar()
end

--- Clear footer strip state when the IDE layout closes.
function M.teardown_footer()
  state.footer_win = nil
  state.footer_buf = nil
  state.footer_ns = nil
  state.footer_mode_end = 0
end

local function submit(text)
  -- #region agent log
  _dbg("H5", "composer.lua:submit", "submit called", {
    text_len = text and #text or 0,
    preview = text and text:sub(1, 40) or "",
  })
  -- #endregion
  local rt = require("agent_core.runtime")
  local opts = { open = false }
  if state.new_on_send then
    opts.new = true
    state.new_on_send = false
  end
  rt.submit(text, opts)
  require("agent_core.runtime.ui").workspace()
  M.refresh_chrome()
end

--- Send the composer buffer contents, clearing the buffer first.
local function resolve_composer_buf()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    local ft = vim.api.nvim_buf_get_option(state.buf, "filetype")
    if ft == "agent_core_composer" then
      return state.buf
    end
  end
  local cur = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_is_valid(cur) then
    local ft = vim.api.nvim_buf_get_option(cur, "filetype")
    if ft == "agent_core_composer" then
      state.buf = cur
      return cur
    end
  end
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    local win_buf = vim.api.nvim_win_get_buf(state.win)
    if vim.api.nvim_buf_is_valid(win_buf) then
      local ft = vim.api.nvim_buf_get_option(win_buf, "filetype")
      if ft == "agent_core_composer" then
        state.buf = win_buf
        return win_buf
      end
    end
  end
  return state.buf
end

function M.send_buffer()
  local buf = resolve_composer_buf()
  -- #region agent log
  _dbg("H2", "composer.lua:send_buffer", "enter", {
    buf = buf,
    state_buf = state.buf,
    buf_valid = buf and vim.api.nvim_buf_is_valid(buf),
    cur_buf = vim.api.nvim_get_current_buf(),
    cur_ft = vim.api.nvim_buf_get_option(vim.api.nvim_get_current_buf(), "filetype"),
    cur_win = vim.api.nvim_get_current_win(),
  })
  -- #endregion
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    -- #region agent log
    _dbg("H2", "composer.lua:send_buffer", "abort no buf", {})
    -- #endregion
    return
  end
  state.buf = buf
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local pill = M.pill_line_index(buf)
  if pill and pill <= #lines then
    table.remove(lines, pill)
  end
  local text = M.normalize(table.concat(lines, "\n"))
  -- #region agent log
  _dbg("H2", "composer.lua:send_buffer", "parsed text", {
    pill = pill,
    line_count = #lines,
    text = text,
    text_empty = text == "",
  })
  -- #endregion
  if text == "" then
    return
  end
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  if pill then
    vim.api.nvim_buf_set_lines(buf, 0, pill - 1, false, {})
  else
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
  end
  submit(text)
end

--- Start a fresh chat (the next send opens a new session).
function M.new_chat()
  state.new_on_send = true
  M.open()
end

--- Insert a token at the caret (used by the mention/slash menu).
---@param text string
function M.insert_at_cursor(text)
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
  else
    vim.api.nvim_set_current_buf(state.buf)
  end
  local line, col = unpack(vim.api.nvim_win_get_cursor(0))
  local current = vim.api.nvim_buf_get_lines(state.buf, line - 1, line, false)[1] or ""
  local newline = current:sub(1, col) .. text .. current:sub(col + 1)
  vim.api.nvim_buf_set_lines(state.buf, line - 1, line, false, { newline })
  vim.api.nvim_win_set_cursor(0, { line, col + #text })
  vim.cmd("startinsert")
end

--- Open the @-mention / slash-command menu and insert the chosen token.
function M.menu()
  local items = M.menu_items()
  local function insert(item)
    if item and item.token then
      M.insert_at_cursor(item.token .. " ")
    end
  end

  local ok, Snacks = pcall(require, "snacks.picker")
  if ok and type(Snacks) == "table" and type(Snacks.pick) == "function" then
    Snacks.pick({
      title = "Attach",
      items = items,
      layout = { preview = false },
      format = function(item)
        return { { item.token }, { "  " .. (item.desc or ""), "Comment" } }
      end,
      confirm = function(picker, item)
        picker:close()
        insert(item)
      end,
    })
    return
  end

  local labels = {}
  for _, it in ipairs(items) do
    labels[#labels + 1] = it.token .. "  " .. (it.desc or "")
  end
  vim.ui.select(labels, { prompt = "Attach" }, function(choice)
    for _, it in ipairs(items) do
      if choice == (it.token .. "  " .. (it.desc or "")) then
        insert(it)
        return
      end
    end
  end)
end

--- Switch the active session's model (persisted per-session).
function M.pick_model()
  local ok, err = pcall(function()
    require("agent_core.pickers").pick_model(function(entry)
      if not entry then
        return
      end
      require("agent_core.profiles").switch_model(entry)
      local rt = require("agent_core.runtime")
      local s = rt.active_session()
      if s then
        require("agent_core.history").persist_model(s.id, s.provider, s.model)
      end
      M.refresh_chrome()
    end)
  end)
  if not ok then
    vim.notify("[agent_core] model picker failed: " .. tostring(err), vim.log.levels.ERROR)
  end
end

--- Switch the active mode.
function M.pick_mode()
  local ok, err = pcall(function()
    require("agent_core.pickers").pick_mode(function(mode)
      if mode then
        require("agent_core.modes").switch(mode)
        M.refresh_chrome()
      end
    end)
  end)
  if not ok then
    vim.notify("[agent_core] mode picker failed: " .. tostring(err), vim.log.levels.ERROR)
  end
end

local SEND_KEYS = {
  "<C-CR>", -- GUI / terminals with CSI-u Ctrl+Enter binding
  "<S-CR>", -- Shift+Enter (when the terminal sends a distinct code)
  "<M-CR>", -- Alt+Enter
  "<C-S-CR>",
  "<C-g><CR>", -- chord fallback in all terminals
}

-- Insert-only: normal-mode <C-s> stops the agent run.
local INSERT_SEND_KEYS = {
  "<C-j>", -- terminal-safe submit (Ctrl+S is XON flow-control in many terminals)
}

-- #region agent log
local key_probe_attached = false

local function attach_key_probe()
  if key_probe_attached then
    return
  end
  key_probe_attached = true
  vim.on_key(function(key)
    local cur = vim.api.nvim_get_current_buf()
    if vim.api.nvim_buf_get_option(cur, "filetype") ~= "agent_core_composer" then
      return
    end
    local mode = vim.api.nvim_get_mode().mode
    if mode:sub(1, 1) ~= "i" then
      return
    end
    _dbg("H12", "composer.lua:on_key", "raw key", {
      key = key:sub(1, 48),
      mode = mode,
      buf = cur,
    })
  end, "agent_core_composer_dbg")

  vim.api.nvim_create_autocmd("InsertEnter", {
    group = chrome_augroup,
    callback = function(ev)
      if vim.api.nvim_buf_get_option(ev.buf, "filetype") ~= "agent_core_composer" then
        return
      end
      _dbg("H14", "composer.lua:InsertEnter", "composer focus", {
        buf = ev.buf,
        win = vim.fn.bufwinid(ev.buf),
      })
    end,
  })
end
-- #endregion

local function set_keymaps(buf)
  local opts = { noremap = true, silent = true, buffer = buf }
  local function send(trigger)
    -- #region agent log
    _dbg("H1", "composer.lua:send_keymap", "fired", {
      trigger = trigger,
      mode = vim.api.nvim_get_mode().mode,
      buf = buf,
      cur_buf = vim.api.nvim_get_current_buf(),
    })
    -- #endregion
    M.send_buffer()
  end
  -- #region agent log
  _dbg("H6", "composer.lua:set_keymaps", "applied", { buf = buf })
  attach_key_probe()
  -- #endregion
  -- Enter inserts a newline (default). Send keys submit (Cursor-style).
  -- Terminals send Ctrl+Enter as plain <CR>; use <C-j>, <C-g><CR>, or :AgentSend.
  -- Do not map <C-M> in insert mode: it is the same key as <CR> in most terminals.
  for _, key in ipairs(SEND_KEYS) do
    vim.keymap.set("i", key, function()
      send(key)
    end, opts)
    vim.keymap.set("n", key, function()
      send(key)
    end, opts)
  end
  for _, key in ipairs(INSERT_SEND_KEYS) do
    vim.keymap.set("i", key, function()
      send(key)
    end, opts)
  end
  vim.keymap.set("i", "<C-x><C-o>", function()
    vim.schedule(M.menu)
  end, opts)

  vim.keymap.set("n", "q", function()
    M.close()
  end, opts)
  vim.keymap.set("n", "<Esc>", function()
    M.close()
  end, opts)
  vim.keymap.set("n", "<C-s>", function()
    require("agent_core.runtime.ui").stop()
  end, opts)
  vim.keymap.set("n", "<C-n>", function()
    M.new_chat()
  end, opts)
  vim.keymap.set("n", "<C-m>", function()
    M.pick_model()
  end, opts)
  vim.keymap.set("n", "<C-d>", function()
    M.pick_mode()
  end, opts)
  vim.keymap.set("i", "<C-d>", function()
    vim.schedule(M.pick_mode)
  end, opts)

  local function pill_click()
    local pill = M.pill_line_index(buf)
    if not pill or vim.fn.line(".") ~= pill then
      return
    end
    on_pill_click(vim.fn.col("."))
  end
  vim.keymap.set("n", "<LeftMouse>", pill_click, opts)
  vim.keymap.set("i", "<LeftMouse>", function()
    vim.schedule(function()
      local pill = M.pill_line_index(buf)
      local pos = vim.fn.getmousepos()
      if pill and pos.line == pill then
        local byte_col = pos.col or 1
        vim.cmd("stopinsert")
        vim.api.nvim_win_set_cursor(0, { pill, math.max(0, byte_col - 1) })
        on_pill_click(byte_col)
      end
    end)
  end, opts)
  vim.keymap.set("n", "<CR>", function()
    if M.pill_line_index(buf) and vim.fn.line(".") == M.pill_line_index(buf) then
      on_pill_click(1)
      return
    end
  end, opts)
end

--- Refresh the composer title bar with the current provider · model · mode.
function M.refresh_title()
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then
    return
  end
  local bar = " Composer · " .. M.indicator()
  local ok, cfg = pcall(vim.api.nvim_win_get_config, state.win)
  if ok and cfg.relative and cfg.relative ~= "" then
    cfg.title = bar
    pcall(vim.api.nvim_win_set_config, state.win, cfg)
  else
    pcall(vim.api.nvim_set_option_value, "winbar", bar, { win = state.win })
  end
end

--- Refresh winbar/title and pill row together.
function M.refresh_chrome()
  if state.inline_pills then
    M.sync_pill_line()
    return
  end
  M.refresh_title()
  M.render_footer_bar()
  if not state.footer_win and state.win and vim.api.nvim_win_is_valid(state.win) then
    apply_chrome(state.win)
  end
end

--- Open the composer (floating at the bottom). `width`/`height` may be supplied
--- by the workspace layout; otherwise a default bottom band is used.
---@param width integer|nil
---@param height integer|nil
function M.open(width, height)
  if #vim.api.nvim_list_uis() == 0 then
    return
  end
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    state.buf = create_buffer()
    attach_chrome_autocmds(state.buf)
  end
  set_keymaps(state.buf)

  local cols = width or vim.o.columns
  local h = height or 6
  local row = math.max(0, vim.o.lines - h - 1)

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    M.refresh_chrome()
    return
  end

  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    row = row,
    col = 0,
    width = cols,
    height = h,
    style = "minimal",
    border = "rounded",
    title = " Composer · " .. M.indicator(),
    title_pos = "center",
  })
  apply_chrome(state.win)
  vim.cmd("startinsert")
end

--- Attach the composer buffer to an existing split window (IDE layout).
---@param win integer
function M.open_in_win(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    state.buf = create_buffer()
    attach_chrome_autocmds(state.buf)
    attach_pill_autocmds(state.buf)
  end
  set_keymaps(state.buf)
  vim.api.nvim_win_set_buf(win, state.buf)
  state.win = win
  state.inline_pills = true
  state.footer_win = nil
  ensure_mouse_enabled()
  pcall(vim.api.nvim_set_option_value, "winbar", "", { win = win })
  M.sync_pill_line()
  vim.api.nvim_set_current_win(win)
  vim.cmd("startinsert")
end

--- Close the composer window (the buffer is kept for the next open).
function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
  -- Only close float composers; IDE splits are closed by ide.close().
    local ok, cfg = pcall(vim.api.nvim_win_get_config, state.win)
    if ok and cfg.relative == "" then
      pcall(vim.api.nvim_win_close, state.win, true)
    end
  end
  state.win = nil
  state.inline_pills = false
  restore_statusline()
  M.teardown_footer()
end

--- Toggle the composer.
function M.toggle(width, height)
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    M.close()
  else
    M.open(width, height)
  end
end

return M
