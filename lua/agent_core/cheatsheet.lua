---@mod agent_core.cheatsheet Command + keymap cheat sheet (:AgentCheatsheet)
---@brief [[
--- A floating, read-only panel listing every agent_core command alongside its
--- currently-mapped key. The key column is introspected from live keymap state at
--- render time (vim.keymap.get), not a hardcoded table, so a user's
--- vim.keymap.set / vim.keymap.del changes are reflected on the next open or on
--- `r` refresh. Mirrors the interactive-buffer idiom from agent_core.manager;
--- the pure parts (matches_command / keymap_for / collect / section_for / render)
--- are headless-testable.
---@brief ]]

local M = {}

--- Current panel state (nil when the cheat sheet is closed).
--- @type {buf:integer|nil, win:integer|nil}|nil
local state = nil

----------------------------------------------------------------------------
-- Pure helpers (headless-testable)
----------------------------------------------------------------------------

--- True when a keymap's RHS invokes `name`, without false-matching a longer
--- command (AgentModel must not match AgentModelClear). Case-insensitive
--- substring match with an ASCII word-boundary check on the following char.
---@param rhs string
---@param name string
---@return boolean
function M.matches_command(rhs, name)
  if not rhs or name == "" then
    return false
  end
  local s, e = rhs:lower():find(name:lower(), 1, true)
  if not s then
    return false
  end
  local after = rhs:sub(e + 1, e + 1)
  if after ~= "" and after:match("[%a%d_]") then
    return false
  end
  return true
end

--- The lhs of the global normal-mode map whose RHS invokes `name`, or nil.
---@param name string
---@param maps table[] keymap list (vim.keymap.get / nvim_get_keymap)
---@return string|nil
function M.keymap_for(name, maps)
  for _, m in ipairs(maps or {}) do
    if (m.buffer or 0) == 0 and type(m.rhs) == "string" and M.matches_command(m.rhs, name) then
      return m.lhs
    end
  end
  return nil
end

--- Extract the command name from a `<cmd>X<cr>` / `:X<cr>` RHS, or nil.
---@param rhs string
---@return string|nil
function M.command_from_rhs(rhs)
  if type(rhs) ~= "string" then
    return nil
  end
  return rhs:match("^<[cC][mM][dD]>(%w+)") or rhs:match("^:(%w+)")
end

--- Build a command-name -> lhs table from global normal-mode keymaps.
---@param maps table[] keymap list
---@return table<string, string>
function M.collect(maps)
  local out = {}
  for _, m in ipairs(maps or {}) do
    if (m.buffer or 0) == 0 and type(m.rhs) == "string" then
      local name = M.command_from_rhs(m.rhs)
      if name and name:match("^Agent") then
        out[name] = m.lhs
      end
    end
  end
  return out
end

--- Ordered section definitions: title -> ordered command names. Any `Agent*`
--- command not listed here is bucketed under "Other" so nothing is dropped.
---@return {string, string[]}[]
function M.sections()
  return {
    { "Chat & sessions", {
      "AgentChat", "AgentNew", "AgentHistory", "AgentSessionBind",
      "AgentRename", "AgentFork", "AgentRewind",
    } },
    { "Profiles & models", {
      "AgentSwitch", "AgentModel", "AgentModelClear", "AgentProfile",
      "AgentProfileEnable", "AgentProfileDisable", "AgentKey", "AgentPolicy",
      "AgentSetup", "AgentSettingsClear", "AgentManager", "AgentCatalogUpdate",
    } },
    { "Modes & routing", {
      "AgentMode", "AgentRecommend", "AgentRecommendToggle",
      "AgentAutoSwitch", "AgentAutoSwitchToggle",
    } },
    { "Plans & ideas", {
      "AgentPlanBuild", "AgentPlanBuildNew", "AgentPlans",
      "AgentPlansToggle", "AgentPlanIdea",
    } },
    { "Checkpoints & undo", {
      "AgentCheckpoint", "AgentRollback", "AgentKeep", "AgentDiscard",
    } },
    { "Debug", {
      "AgentDebugCleanup", "AgentDebugStart", "AgentDebugContinue",
      "AgentDebugStepOver", "AgentDebugStepInto", "AgentDebugStepOut",
      "AgentDebugStop", "AgentDebugStatus",
    } },
    { "Completion & edits", {
      "AgentPredictEdit", "AgentInlineEdit", "AgentNextLocation",
      "AgentDiffApply", "AgentDiffAccept", "AgentDiffReject",
      "AgentCoordinatedEdit",
    } },
    { "Workspace & indexing", {
      "AgentIndex", "AgentWorkspaceAdd", "AgentWorkspaceRemove",
      "AgentWorkspaceScan", "AgentWorkspaceList", "AgentWorkspaceSwitch",
      "AgentImport",
    } },
    { "Registry & endpoints", {
      "AgentRegistryList", "AgentRegistryAdd", "AgentEndpointList",
      "AgentEndpointAdd", "AgentEndpointRemove",
    } },
    { "Notepad", {
      "AgentNotepad", "AgentNotepadNew", "AgentNotepadEdit", "AgentNotepadDelete",
    } },
    { "Automation", {
      "AgentAutomationList", "AgentAutomationAdd", "AgentAutomationRemove",
      "AgentAutomationRun",
    } },
    { "Skills & commands", {
      "AgentSkills", "AgentSkill", "AgentCommands", "AgentCommand",
    } },
    { "Tools", {
      "AgentBestOfN", "AgentBugbot", "AgentMemory", "AgentRun", "AgentMentions",
    } },
  }
end

--- The section title a command belongs to, or nil (un-grouped).
---@param name string
---@return string|nil
function M.section_for(name)
  for _, sec in ipairs(M.sections()) do
    for _, member in ipairs(sec[2]) do
      if member == name then
        return sec[1]
      end
    end
  end
  return nil
end

----------------------------------------------------------------------------
-- Live command / keymap introspection
----------------------------------------------------------------------------

--- Every `Agent*` user command: `{ name, desc }`, sorted by name.
---@return {name:string, desc:string|nil}[]
function M.commands()
  local all = vim.api.nvim_get_commands({ builtin = false })
  local out = {}
  for name, def in pairs(all) do
    if name:match("^Agent") then
      local desc = def.definition or def.desc
      out[#out + 1] = {
        name = name,
        desc = (type(desc) == "string" and desc ~= "" and desc) or nil,
      }
    end
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

--- The live global normal-mode keymaps (vim.keymap.get with nvim_get_keymap
--- fallback for older Neovim).
---@return table[]
function M.live_maps()
  local ok, maps = pcall(vim.keymap.get, { mode = "n" })
  if ok and type(maps) == "table" then
    return maps
  end
  local ok2, maps2 = pcall(vim.api.nvim_get_keymap, "n")
  if ok2 and type(maps2) == "table" then
    return maps2
  end
  return {}
end

----------------------------------------------------------------------------
-- Rendering (pure)
----------------------------------------------------------------------------

--- Render the cheat sheet body: grouped `# Title` headings plus per-command
--- rows of `  <lhs>  :AgentXxx  description`. `—` marks an unmapped command.
---@param commands {name:string, desc:string|nil}[]
---@param keymaps table<string, string> command-name -> lhs
---@return {lines:string[], map:table}
function M.render(commands, keymaps)
  keymaps = keymaps or {}
  local by_name = {}
  for _, c in ipairs(commands) do
    by_name[c.name] = c
  end

  local lines = {}
  local map = {}
  lines[#lines + 1] = "# agent_core command + keymap cheat sheet"
  lines[#lines + 1] = ""

  local used = {}
  local function emit_section(title, list)
    if #list == 0 then
      return
    end
    lines[#lines + 1] = "# " .. title
    lines[#lines + 1] = ""
    for _, c in ipairs(list) do
      used[c.name] = true
      local lhs = keymaps[c.name] or "—"
      lines[#lines + 1] = string.format("  %-12s :%s  %s", lhs, c.name, c.desc or "")
    end
    lines[#lines + 1] = ""
  end

  for _, sec in ipairs(M.sections()) do
    local list = {}
    for _, name in ipairs(sec[2]) do
      if by_name[name] then
        list[#list + 1] = by_name[name]
      end
    end
    emit_section(sec[1], list)
  end

  -- Catch-all for any Agent* command not explicitly grouped.
  local orphan = {}
  for _, c in ipairs(commands) do
    if not used[c.name] then
      orphan[#orphan + 1] = c
    end
  end
  emit_section("Other", orphan)

  return { lines = lines, map = map }
end

--- Adapter: render from the live command list and live keymaps.
---@return {lines:string[], map:table}
function M.rows()
  return M.render(M.commands(), M.collect(M.live_maps()))
end

--- The footer legend rendered at the bottom of the panel.
---@return string[]
function M.header()
  return {
    "r refresh (re-read current keymaps)",
    "q close",
  }
end

----------------------------------------------------------------------------
-- Interactive panel
----------------------------------------------------------------------------

--- Rebuild the panel buffer in place (mirrors agent_core.manager.redraw).
function M.redraw()
  if not state then
    return
  end
  local data = M.rows()
  local lines = data.lines
  for _, h in ipairs(M.header()) do
    lines[#lines + 1] = h
  end

  local buf = state.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    state.buf = buf
    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].bufhidden = "wipe"
    vim.keymap.set("n", "r", function()
      M.redraw()
    end, { buffer = buf, desc = "AgentCheatsheet: refresh" })
    vim.keymap.set("n", "q", function()
      M.close()
    end, { buffer = buf, desc = "AgentCheatsheet: close" })
    vim.keymap.set("n", "<Esc>", function()
      M.close()
    end, { buffer = buf, desc = "AgentCheatsheet: close" })
  end

  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_set_buf(state.win, buf)
  else
    state.win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = math.min(120, vim.o.columns - 4),
      height = math.min(#lines + 2, vim.o.lines - 4),
      row = 2,
      col = 2,
      border = "rounded",
      title = " AgentCheatsheet ",
      title_pos = "center",
    })
  end
end

--- Close the panel and clear state.
function M.close()
  if state and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state = nil
end

--- Open the cheat sheet. No-op when no UI is attached (headless-safe).
function M.open()
  if #vim.api.nvim_list_uis() == 0 then
    return
  end
  if state then
    M.close()
  end
  state = { buf = nil, win = nil }
  M.redraw()
end

return M
