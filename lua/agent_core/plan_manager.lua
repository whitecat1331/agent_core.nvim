---@mod agent_core.plan_manager Plan + idea manager (:AgentPlans) + reminders
---@brief [[
--- Two surfaces over the same plan/idea data:
---   1. A floating panel (:AgentPlans) that lists drafted plans by status and the
---      ideas backlog, so unfinished work never gets lost across chats.
---   2. A persistent, collapsible reminder badge (plan.remind.indicator) showing
---      the unfinished-plan + idea counts, plus a once-per-session startup popup
---      (plan.remind.startup_popup). Both auto-refresh whenever a plan/idea
---      mutation emits User AgentPlanChanged.
--- It delegates to the same underlying agent_core.plan functions the
--- :AgentPlanBuild / :AgentPlanIdea commands use, so behavior has one source of
--- truth. Mirrors the interactive-buffer idiom from agent_core.manager; headless-
--- safe (open()/open_badge() are no-ops when no UI is attached).
---@brief ]]

local M = {}

--- Current interactive panel state (nil when no panel is open).
--- @type {mode:"badge"|"full", buf:integer|nil, win:integer|nil, map:table}|nil
local state = nil

--- Session-level dismissal flag for the reminder badge (reset on DirChanged or
--- when the outstanding count transitions 0 -> non-zero).
local dismissed = false

--- Snapshot of whether items were outstanding on the previous refresh (used to
--- detect the 0 -> non-zero transition that un-dismisses the badge).
local last_had_outstanding = nil

--- Pending debounce timer for refresh_indicator().
local refresh_timer = nil

local function plan()
  return require("agent_core.plan")
end

--- Read the plan.remind config block (defaults tolerant of missing keys).
---@return table
local function reminder_config()
  local cfg = require("agent_core").config
  local p = cfg.plan or {}
  return p.remind or {}
end

local function reminders_enabled()
  return reminder_config().enabled ~= false
end

local function indicator_enabled()
  return reminders_enabled() and reminder_config().indicator ~= false
end

local function has_outstanding()
  local s = M.summary()
  return (s.unfinished + s.ideas) > 0
end

--- Thin wrapper over plan.summary().
---@return { unfinished: number, archived: number, ideas: number }
function M.summary()
  return plan().summary()
end

--- Pure builder: render the full panel and the caret-row -> action map.
---@return table { lines:string[], map:table<integer, table> }
function M.rows()
  local lines = {}
  local map = {}

  local function emit(text, action)
    lines[#lines + 1] = text
    map[#lines] = action or {}
  end

  local UNFINISHED = plan().UNFINISHED

  -- Unfinished plans
  emit("# Unfinished plans")
  emit("")
  local any_unfinished = false
  for _, p in ipairs(plan().list()) do
    if UNFINISHED[p.status] then
      any_unfinished = true
      emit(string.format("  [%-11s] %s", p.status, p.title), { type = "plan", path = p.path })
    end
  end
  if not any_unfinished then
    emit("  (none)")
  end
  emit("")

  -- Completed / abandoned (archive group)
  emit("# Completed / abandoned")
  emit("")
  local any_archived = false
  for _, p in ipairs(plan().list()) do
    if not UNFINISHED[p.status] then
      any_archived = true
      emit(string.format("  [%-11s] %s", p.status, p.title), { type = "plan", path = p.path })
    end
  end
  if not any_archived then
    emit("  (none)")
  end
  emit("")

  -- Ideas backlog
  emit("# Ideas")
  emit("")
  local ideas = plan().ideas()
  if #ideas == 0 then
    emit("  (none)")
  else
    for _, e in ipairs(ideas) do
      emit("  • " .. e.title, { type = "idea", id = e.id })
    end
  end
  emit("")

  return { lines = lines, map = map }
end

--- The keymap legend rendered at the bottom of the full panel.
---@return string[]
function M.header()
  return {
    "<CR> open plan",
    "s    cycle status",
    "n    new idea",
    "p    promote idea → plan",
    "x    delete idea",
    "q    close",
  }
end

--- The badge text: "agent_core · N unfinished plan(s) · M idea(s)".
---@return string
function M.badge_text()
  local s = M.summary()
  local parts = {}
  if s.unfinished > 0 then
    parts[#parts + 1] = string.format("%d unfinished plan%s", s.unfinished, s.unfinished == 1 and "" or "s")
  end
  if s.ideas > 0 then
    parts[#parts + 1] = string.format("%d idea%s", s.ideas, s.ideas == 1 and "" or "s")
  end
  if #parts == 0 then
    parts[1] = "all clear"
  end
  return "agent_core · " .. table.concat(parts, " · ")
end

--- The action under the current caret row (or nil).
---@return table|nil
function M.action_at()
  if not state then
    return nil
  end
  local row = require("agent_core.platform").get_caret(0)
  return state.map and state.map[row + 1]
end

--- Open a plan file in the current window.
---@param path string
function M.open_plan(path)
  if path and vim.fn.filereadable(path) == 1 then
    vim.cmd("edit " .. vim.fn.fnameescape(path))
  end
end

--- Cycle the status of the plan under the caret, then redraw.
function M.cycle_under_caret()
  local a = M.action_at()
  if not a or a.type ~= "plan" then
    vim.notify("AgentPlans: caret is not on a plan", vim.log.levels.WARN)
    return
  end
  plan().cycle_status(a.path)
  M.redraw()
end

--- Prompt for a new idea (title + notes) and add it to the backlog.
function M.new_idea()
  vim.ui.input({ prompt = "Idea title: " }, function(title)
    if not title or title == "" then
      return
    end
    vim.ui.input({ prompt = "Notes (optional): " }, function(notes)
      local ok, _, err = plan().add_idea(title, notes)
      if not ok then
        vim.notify("AgentPlans: " .. tostring(err), vim.log.levels.ERROR)
      end
      M.redraw()
    end)
  end)
end

--- Promote the idea under the caret into a real plan, then redraw.
function M.promote_under_caret()
  local a = M.action_at()
  if not a or a.type ~= "idea" then
    vim.notify("AgentPlans: caret is not on an idea", vim.log.levels.WARN)
    return
  end
  local ok, path, err = plan().promote_idea(a.id)
  if not ok then
    vim.notify("AgentPlans: " .. tostring(err), vim.log.levels.ERROR)
  else
    vim.notify("Promoted idea to plan: " .. path, vim.log.levels.INFO)
  end
  M.redraw()
end

--- Delete the idea under the caret, then redraw.
function M.delete_under_caret()
  local a = M.action_at()
  if not a or a.type ~= "idea" then
    vim.notify("AgentPlans: caret is not on an idea", vim.log.levels.WARN)
    return
  end
  local ok, err = plan().remove_idea(a.id)
  if not ok then
    vim.notify("AgentPlans: " .. tostring(err), vim.log.levels.ERROR)
  end
  M.redraw()
end

--- Handle the default (<CR>) action for the row under the caret.
function M.open_under_caret()
  local a = M.action_at()
  if not a then
    return
  end
  if a.type == "plan" then
    M.open_plan(a.path)
  elseif a.type == "idea" then
    M.promote_under_caret()
  end
end

--- Rebuild the full panel buffer in place (mirrors agent_core.manager.redraw).
function M.redraw()
  if not state or state.mode ~= "full" then
    return
  end
  local data = M.rows()
  local lines = data.lines
  for _, h in ipairs(M.header()) do
    lines[#lines + 1] = h
  end
  state.map = data.map

  local buf = state.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    state.buf = buf
    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].bufhidden = "wipe"
    local keys = {
      { "<CR>", function() M.open_under_caret() end },
      { "s", function() M.cycle_under_caret() end },
      { "n", function() M.new_idea() end },
      { "p", function() M.promote_under_caret() end },
      { "x", function() M.delete_under_caret() end },
      { "q", function() M.close_full() end },
      { "<Esc>", function() M.close_full() end },
    }
    for _, k in ipairs(keys) do
      vim.keymap.set("n", k[1], k[2], { buffer = buf, desc = "AgentPlans" })
    end
  end

  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_set_buf(state.win, buf)
  else
    state.win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = math.min(110, vim.o.columns - 4),
      height = math.min(#lines + 2, vim.o.lines - 4),
      row = 2,
      col = 2,
      border = "rounded",
      title = " AgentPlans ",
      title_pos = "center",
    })
  end
end

--- Rebuild the one-line reminder badge in place.
function M.redraw_badge()
  if not state or state.mode ~= "badge" then
    return
  end
  local text = M.badge_text()
  state.map = {}

  local buf = state.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    state.buf = buf
    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].bufhidden = "wipe"
    local keys = {
      { "<CR>", function() M.open() end },
      { "e", function() M.open() end },
      { "q", function() M.dismiss() end },
      { "<Esc>", function() M.dismiss() end },
    }
    for _, k in ipairs(keys) do
      vim.keymap.set("n", k[1], k[2], { buffer = buf, desc = "AgentPlansBadge" })
    end
  end

  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  vim.api.nvim_buf_set_option(buf, "modifiable", false)

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_set_buf(state.win, buf)
  else
    local width = math.min(#text + 2, vim.o.columns - 2)
    state.win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = width,
      height = 1,
      row = 0,
      col = math.max(0, vim.o.columns - width - 2),
      border = "rounded",
      title = " agent_core ",
      title_pos = "center",
    })
  end
end

--- Close the active panel (full or badge) and clear state.
function M.close()
  if state and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state = nil
end

--- Close the full manager; return to the badge when the indicator is on and
--- items remain, otherwise clear state entirely.
function M.close_full()
  M.close()
  if indicator_enabled() and has_outstanding() then
    M.open_badge()
  end
end

--- Dismiss the reminder badge for the rest of the session.
function M.dismiss()
  M.close()
  dismissed = true
end

--- Open the full manager panel. No-op when no UI is attached (headless-safe).
function M.open()
  if #vim.api.nvim_list_uis() == 0 then
    return
  end
  if state then
    M.close()
  end
  state = { mode = "full", buf = nil, win = nil, map = {} }
  M.redraw()
end

--- Open the reminder badge. No-op when no UI is attached (headless-safe).
function M.open_badge()
  if #vim.api.nvim_list_uis() == 0 then
    return
  end
  if state then
    M.close()
  end
  state = { mode = "badge", buf = nil, win = nil, map = {} }
  M.redraw_badge()
end

--- Toggle between the badge and the full manager: full -> badge, badge -> full,
--- none -> badge.
function M.toggle()
  if state and state.mode == "full" then
    M.open_badge()
  elseif state and state.mode == "badge" then
    M.open()
  else
    M.open_badge()
  end
end

--- Recompute the outstanding summary and show/hide the badge accordingly.
--- Debounced; no-op in headless mode and when reminders are disabled.
function M.refresh_indicator()
  if #vim.api.nvim_list_uis() == 0 then
    return
  end
  if not reminders_enabled() then
    if state and state.mode == "badge" then
      M.close()
    end
    return
  end
  if refresh_timer then
    refresh_timer:stop()
    refresh_timer:close()
    refresh_timer = nil
  end
  refresh_timer = vim.defer_fn(function()
    refresh_timer = nil
    M.apply_indicator()
  end, 100)
end

--- Immediate indicator reconciliation (un-debounced). Used by refresh_indicator
--- after the debounce, and safe to call directly.
function M.apply_indicator()
  if #vim.api.nvim_list_uis() == 0 then
    return
  end
  if not indicator_enabled() then
    if state and state.mode == "badge" then
      M.close()
    end
    return
  end

  local outstanding = has_outstanding()
  if last_had_outstanding == false and outstanding then
    dismissed = false -- 0 -> non-zero: re-surface the badge
  end
  last_had_outstanding = outstanding

  if state and state.mode == "full" then
    return -- never disturb the open full manager
  end

  if outstanding and not dismissed then
    if not state or state.mode ~= "badge" then
      M.open_badge()
    else
      M.redraw_badge()
    end
  elseif not outstanding or dismissed then
    if state and state.mode == "badge" then
      M.close()
    end
  end
end

--- Register autocmds that keep the badge in sync: directory change (project
--- scope), buffer enter, and plan/idea mutations (User AgentPlanChanged).
function M.setup()
  local group = vim.api.nvim_create_augroup("AgentCorePlanRemind", { clear = true })
  -- Project-scope change resets session dismissal and refreshes the badge.
  vim.api.nvim_create_autocmd("DirChanged", {
    group = group,
    callback = function()
      dismissed = false
      M.refresh_indicator()
    end,
  })
  -- Buffer enter only refreshes (e.g. a hand-edited plan frontmatter), without
  -- undoing a session dismissal.
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function()
      M.refresh_indicator()
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "AgentPlanChanged",
    callback = function()
      M.refresh_indicator()
    end,
  })

  if not reminders_enabled() then
    return
  end
  vim.schedule(function()
    M.apply_indicator()
  end)
end

--- :AgentPlanIdea — add an idea from the command line. `[title]` is optional;
--- when omitted, prompt for title + notes (interactive only).
---@param title string|nil
function M.add_idea_cmd(title)
  if title and title ~= "" then
    local ok, _, err = plan().add_idea(title, "")
    if not ok then
      vim.notify("AgentPlanIdea: " .. tostring(err), vim.log.levels.ERROR)
    else
      vim.notify("Idea added: " .. title, vim.log.levels.INFO)
    end
  else
    M.new_idea()
  end
end

return M
