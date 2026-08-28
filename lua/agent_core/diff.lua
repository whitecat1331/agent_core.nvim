---@mod agent_core.diff Composer-style diff presenter (per-hunk accept/reject)
---@brief [[
--- A shared diff UX for every agent_core edit path (predictive edit, inline
--- edit, multi-file coordinated edits, and bugbot autofix). Pure helpers
--- (compute_hunks / merge / render / toggle) are unit-testable and headless-
--- safe; `present` renders a per-hunk accept/reject view in a scratch buffer
--- with buffer-local keymaps, checkpoints before applying, and applies only
--- the accepted hunks. When no UI is attached (headless), `present` auto-accepts
--- every hunk so scripted/automation callers still get a deterministic apply.
---@brief ]]

local M = {}

M.config = {
  enabled = true,
  auto_checkpoint = true, -- checkpoint before applying an edit
}

--- Current interactive diff state (nil when no diff is open).
local state = nil

--- Compute hunks between two line lists using vim.diff in "indices" form.
--- vim.diff returns each hunk as a positional `{ start_a, count_a, start_b,
--- count_b }` list; we normalize to named keys for readability.
--- Each hunk is `{ start_a, count_a, start_b, count_b }` (1-indexed; count 0
--- means a pure insertion/deletion).
---@param old_lines string[]
---@param new_lines string[]
---@return table[]
function M.compute_hunks(old_lines, new_lines)
  old_lines = old_lines or {}
  new_lines = new_lines or {}
  local old_text = table.concat(old_lines, "\n")
  local new_text = table.concat(new_lines, "\n")
  local ok, raw = pcall(vim.diff, old_text, new_text, {
    result_type = "indices",
    algorithm = "histogram",
    ignore_whitespace = false,
    indent_heuristic = false,
  })
  if not ok or not raw then
    return {}
  end
  local out = {}
  for _, h in ipairs(raw) do
    if type(h) == "table" then
      out[#out + 1] = {
        start_a = h.start_a or h[1] or 1,
        count_a = h.count_a or h[2] or 0,
        start_b = h.start_b or h[3] or 1,
        count_b = h.count_b or h[4] or 0,
      }
    end
  end
  return out
end

--- Toggle a hunk's accepted state, returning a new accepted-index list (pure).
---@param accepted integer[]
---@param idx integer
---@return integer[]
function M.toggle(accepted, idx)
  local set = {}
  for _, i in ipairs(accepted or {}) do
    set[i] = true
  end
  if set[idx] then
    set[idx] = nil
  else
    set[idx] = true
  end
  local out = {}
  for i = 1, idx do
    if set[i] then
      out[#out + 1] = i
    end
  end
  -- Preserve any accepted indices beyond the toggled one (defensive).
  for _, i in ipairs(accepted or {}) do
    if set[i] and i > idx then
      out[#out + 1] = i
    end
  end
  table.sort(out)
  return out
end

--- Merge old/new lines by applying only the accepted hunks (pure).
--- vim.diff reports insertion hunks with `count_a == 0` and `start_a` as the
--- 0-based insertion position (lines to keep before the insertion); deletion /
--- replacement hunks use a 1-based `start_a`. This walks both files accordingly.
---@param old_lines string[]
---@param new_lines string[]
---@param hunks table[]
---@param accepted integer[]
---@return string[]
function M.merge(old_lines, new_lines, hunks, accepted)
  old_lines = old_lines or {}
  new_lines = new_lines or {}
  hunks = hunks or {}
  local accept_set = {}
  for _, i in ipairs(accepted or {}) do
    accept_set[i] = true
  end

  local out = {}
  local pos = 1
  for idx, h in ipairs(hunks) do
    local start_a = h.start_a or pos
    local count_a = h.count_a or 0
    local start_b = h.start_b or 1
    local count_b = h.count_b or 0
    -- Lines to keep before the change (0-based insertion position when
    -- count_a == 0, otherwise 1-based deletion start).
    local keep = (count_a == 0) and start_a or (start_a - 1)
    for i = pos, keep do
      out[#out + 1] = old_lines[i]
    end
    if accept_set[idx] then
      for i = start_b, start_b + count_b - 1 do
        out[#out + 1] = new_lines[i]
      end
    else
      for i = keep + 1, keep + count_a do
        out[#out + 1] = old_lines[i]
      end
    end
    pos = keep + count_a + 1
  end
  for i = pos, #old_lines do
    out[#out + 1] = old_lines[i]
  end
  return out
end

--- Render hunks into display lines with per-hunk accept/reject markers.
--- Returns the display lines plus a map from display line (1-indexed) to hunk
--- index so a keymap can toggle the hunk under the caret.
---@param old_lines string[]
---@param new_lines string[]
---@param hunks table[]
---@param accepted integer[]
---@return string[] lines
---@return table<integer, integer> hunk_line_map
function M.render(old_lines, new_lines, hunks, accepted)
  old_lines = old_lines or {}
  new_lines = new_lines or {}
  hunks = hunks or {}
  local accept_set = {}
  for _, i in ipairs(accepted or {}) do
    accept_set[i] = true
  end

  local lines = { "# agent_core diff", "", "  <a> toggle hunk    <aa> apply    <ar> cancel    q close", "" }
  local map = {}
  for idx, h in ipairs(hunks) do
    local start_a, count_a = h.start_a, h.count_a or 0
    local start_b, count_b = h.start_b, h.count_b or 0
    local status = accept_set[idx] and "ACCEPT" or "REJECT"
    map[#lines + 1] = idx
    lines[#lines + 1] = string.format("### hunk %d  [%s]", idx, status)
    for i = start_a, start_a + count_a - 1 do
      lines[#lines + 1] = "- " .. (old_lines[i] or "")
    end
    for i = start_b, start_b + count_b - 1 do
      lines[#lines + 1] = "+ " .. (new_lines[i] or "")
    end
    lines[#lines + 1] = ""
  end
  if #hunks == 0 then
    lines[#lines + 1] = "(no changes)"
  end
  return lines, map
end

--- Current diff state, or nil.
---@return table|nil
function M.state()
  return state
end

--- Redraw the interactive diff buffer from the current state.
function M.redraw()
  if not state then
    return
  end
  local lines, map = M.render(state.old_lines, state.new_lines, state.hunks, state.accepted)
  state.hunk_line_map = map
  local buf = state.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    state.buf = buf
    vim.bo[buf].filetype = "diff"
    vim.bo[buf].bufhidden = "wipe"
    vim.keymap.set("n", "a", function()
      M.toggle_caret()
    end, { buffer = buf, desc = "Toggle hunk accept/reject" })
    vim.keymap.set("n", "q", function()
      M.dismiss()
    end, { buffer = buf, desc = "Cancel diff" })
  end
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_set_buf(state.win, buf)
  else
    state.win = vim.api.nvim_open_win(buf, true, { split = "right", width = 80 })
  end
end

--- Toggle the hunk under the caret in the diff buffer.
function M.toggle_caret()
  if not state then
    return
  end
  local row = require("agent_core.platform").get_caret(0)
  local idx = state.hunk_line_map and state.hunk_line_map[row + 1]
  if not idx then
    vim.notify("Diff: caret is not on a hunk header", vim.log.levels.WARN)
    return
  end
  state.accepted = M.toggle(state.accepted, idx)
  M.redraw()
end

--- Apply the accepted hunks and close the diff view.
function M.apply()
  if not state then
    vim.notify("Diff: no diff open", vim.log.levels.WARN)
    return
  end
  local s = state
  M.close()
  local merged = M.merge(s.old_lines, s.new_lines, s.hunks, s.accepted)
  if s.on_apply then
    s.on_apply(merged)
  end
end

--- Dismiss the diff view without applying.
function M.dismiss()
  if not state then
    return
  end
  local s = state
  M.close()
  if s.on_dismiss then
    s.on_dismiss()
  end
end

--- Close the diff buffer/window and clear state.
function M.close()
  if state and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state = nil
end

--- Present an old/new line diff and apply only the accepted hunks on confirm.
--- Auto-accepts every hunk when headless (no UI attached).
---@param opts {
---   old_lines:string[],
---   new_lines:string[],
---   filetype:string|nil,
---   label:string|nil,
---   on_apply:fun(final_lines:string[])|nil,
---   on_dismiss:fun()|nil,
--- }
function M.present(opts)
  opts = opts or {}
  local old_lines = opts.old_lines or {}
  local new_lines = opts.new_lines or {}
  local hunks = M.compute_hunks(old_lines, new_lines)

  if M.config.auto_checkpoint and opts.label and opts.checkpoint ~= false then
    local ok_cp, Checkpoint = pcall(require, "agent_core.checkpoint")
    if ok_cp and Checkpoint.create then
      Checkpoint.create(opts.label)
    end
  end

  if #vim.api.nvim_list_uis() == 0 then
    local accepted = {}
    for i = 1, #hunks do
      accepted[#accepted + 1] = i
    end
    local merged = M.merge(old_lines, new_lines, hunks, accepted)
    if opts.on_apply then
      opts.on_apply(merged)
    end
    return
  end

  state = {
    old_lines = old_lines,
    new_lines = new_lines,
    hunks = hunks,
    accepted = {},
    filetype = opts.filetype or "",
    label = opts.label or "edit",
    on_apply = opts.on_apply,
    on_dismiss = opts.on_dismiss,
    buf = nil,
    win = nil,
    hunk_line_map = {},
  }
  M.redraw()
end

--- Present a raw unified diff text with accept/cancel (used for worktree/git
--- diffs where old/new line arrays are not available).
---@param opts { text:string, label:string|nil, on_apply:fun()|nil, on_dismiss:fun()|nil }
function M.present_text(opts)
  opts = opts or {}
  if #vim.api.nvim_list_uis() == 0 then
    if opts.on_apply then
      opts.on_apply()
    end
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "diff"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(opts.text or "", "\n", { plain = true }))
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  local win = vim.api.nvim_open_win(buf, true, { split = "right", width = 80 })

  local function finish(apply)
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    if apply and opts.on_apply then
      opts.on_apply()
    elseif not apply and opts.on_dismiss then
      opts.on_dismiss()
    end
  end
  vim.keymap.set("n", "y", function()
    finish(true)
  end, { buffer = buf, desc = "Accept diff" })
  vim.keymap.set("n", "n", function()
    finish(false)
  end, { buffer = buf, desc = "Reject diff" })
  vim.keymap.set("n", "q", function()
    finish(false)
  end, { buffer = buf, desc = "Reject diff" })
end

--- Backing for :AgentDiffApply.
function M.apply_cmd()
  M.apply()
end

--- Backing for :AgentDiffAccept (accept the hunk under the caret).
function M.accept_cmd()
  if not state then
    vim.notify("Diff: no diff open", vim.log.levels.WARN)
    return
  end
  local row = require("agent_core.platform").get_caret(0)
  local idx = state.hunk_line_map and state.hunk_line_map[row + 1]
  if not idx then
    vim.notify("Diff: caret is not on a hunk header", vim.log.levels.WARN)
    return
  end
  local set = {}
  for _, i in ipairs(state.accepted) do
    set[i] = true
  end
  set[idx] = true
  state.accepted = {}
  for i = 1, #state.hunks do
    if set[i] then
      state.accepted[#state.accepted + 1] = i
    end
  end
  M.redraw()
end

--- Backing for :AgentDiffReject (reject the hunk under the caret).
function M.reject_cmd()
  if not state then
    vim.notify("Diff: no diff open", vim.log.levels.WARN)
    return
  end
  local row = require("agent_core.platform").get_caret(0)
  local idx = state.hunk_line_map and state.hunk_line_map[row + 1]
  if not idx then
    vim.notify("Diff: caret is not on a hunk header", vim.log.levels.WARN)
    return
  end
  local out = {}
  for _, i in ipairs(state.accepted) do
    if i ~= idx then
      out[#out + 1] = i
    end
  end
  state.accepted = out
  M.redraw()
end

function M.setup()
  local cfg = require("agent_core").config
  M.config = vim.tbl_deep_extend("force", M.config, cfg.diff or {})
end

return M
