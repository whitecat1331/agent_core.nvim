---@mod agent_core.manager Unified agent registry manager (:AgentManager)
---@brief [[
--- One floating panel that views and edits every :AgentSetup-managed concern:
--- profiles (enable/disable, set key, switch default), modes (switch default),
--- policy (guided selector), and Ollama endpoints (add/remove). It delegates to
--- the same underlying functions the granular :Agent* commands use, so the
--- behavior has one source of truth and the commands stay as thin wrappers.
---
--- Mirrors the interactive-buffer idiom from agent_core.diff: a pure rows()
--- builder (lines + row->action map) that is headless-testable, plus a redraw()
--- that renders it into a scratch buffer with buffer-local keymaps. Headless-safe:
--- open() is a no-op when no UI is attached.
---@brief ]]

local M = {}

--- Current interactive panel state (nil when no manager is open).
local state = nil

--- Build a registry-like entry from a profile so Registry.entry_enabled() can
--- apply the persisted setup.json override and env/key presence rules.
---@param p table profile
---@return table
local function profile_entry(p)
  return {
    name = p.name,
    provider = p.provider,
    model = p.model,
    api_key_name = p.api_key_name,
  }
end

--- Whether a profile has a resolvable key (env or stored).
---@param p table profile
---@return boolean
local function key_present(p)
  if p.api_key_name and p.api_key_name ~= "" then
    local env = os.getenv(p.api_key_name)
    if env and env ~= "" then
      return true
    end
  end
  local ok, Keys = pcall(require, "agent_core.keys")
  if ok then
    local k = Keys.get(p.name)
    return k ~= nil and k ~= ""
  end
  return false
end

--- Pure builder: render the full panel and the caret-row -> action map.
---@return table { lines:string[], map:table<integer, table> }
function M.rows()
  local Profiles = require("agent_core.profiles")
  local Modes = require("agent_core.modes")
  local Policy = require("agent_core.policy")
  local Registry = require("agent_core.registry")

  local lines = {}
  local map = {}

  local active_profile = Profiles.get_active()
  local active_mode = Modes.get_active()

  -- Profiles
  lines[#lines + 1] = "# Profiles"
  lines[#lines + 1] = ""
  for _, p in ipairs(Profiles.all()) do
    local enabled = Registry.entry_enabled(profile_entry(p))
    local mark = enabled and "[x]" or "[ ]"
    local active = (p.name == active_profile) and " [active]" or ""
    local key = key_present(p) and "[key]" or "[no key]"
    lines[#lines + 1] = string.format(
      "%s %-22s provider=%-9s model=%s %s%s",
      mark,
      p.name,
      p.provider or "?",
      Profiles.effective_model(p) or p.model or "?",
      key,
      active
    )
    map[#lines] = { type = "profile", name = p.name }
  end
  lines[#lines + 1] = ""

  -- Modes
  lines[#lines + 1] = "# Modes"
  lines[#lines + 1] = ""
  for _, m in ipairs(Modes.all()) do
    local active = (m.name == active_mode) and " [active]" or ""
    local scope = m.read_only and "read-only" or "full"
    lines[#lines + 1] = string.format(
      "  %-12s %-10s %s%s",
      m.name,
      m.label or "",
      scope,
      active
    )
    map[#lines] = { type = "mode", name = m.name }
  end
  lines[#lines + 1] = ""

  -- Policy
  lines[#lines + 1] = "# Policy"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  " .. Policy.describe()
  map[#lines] = { type = "policy" }
  lines[#lines + 1] = ""

  -- Endpoints
  lines[#lines + 1] = "# Ollama endpoints"
  lines[#lines + 1] = ""
  local eps = Registry.ollama_endpoints()
  if #eps == 0 then
    lines[#lines + 1] = "  (none)"
  else
    for _, url in ipairs(eps) do
      lines[#lines + 1] = "  " .. url
      map[#lines] = { type = "endpoint", url = url }
    end
  end
  lines[#lines + 1] = ""

  return { lines = lines, map = map }
end

--- The keymap legend rendered at the bottom of the panel.
---@return string[]
function M.header()
  return {
    "<CR> toggle/switch/remove",
    "e/d enable/disable profile",
    "k   set profile key",
    "s   switch default profile",
    "m   pick model",
    "c   clear model override",
    "p   guided policy",
    "a   add endpoint",
    "q   close",
  }
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

--- Toggle a profile's persisted enabled override.
---@param name string
function M.toggle_profile(name)
  local Registry = require("agent_core.registry")
  local Profiles = require("agent_core.profiles")
  local p = Profiles.find(name)
  if not p then
    return
  end
  local enabled = Registry.entry_enabled(profile_entry(p))
  Registry.set_enabled(name, not enabled)
end

--- Toggle the profile under the caret.
function M.toggle_under_caret()
  local a = M.action_at()
  if not a then
    return
  end
  if a.type == "profile" then
    M.toggle_profile(a.name)
    M.redraw()
  elseif a.type == "mode" then
    local Modes = require("agent_core.modes")
    local m = Modes.find(a.name)
    if m then
      Modes.switch(m)
      M.redraw()
    end
  elseif a.type == "policy" then
    require("agent_core.policy").guided(function()
      M.redraw()
    end)
  elseif a.type == "endpoint" then
    local Registry = require("agent_core.registry")
    Registry.remove_ollama_endpoint(a.url)
    Registry.refresh_ollama()
    M.redraw()
  end
end

--- Rebuild the panel buffer in place (mirrors agent_core.diff.redraw).
function M.redraw()
  if not state then
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
      { "<CR>", function() M.toggle_under_caret() end },
      { "e", function() M.set_enabled_under_caret(true) end },
      { "d", function() M.set_enabled_under_caret(false) end },
      { "k", function() M.set_key_under_caret() end },
      { "s", function() M.switch_profile_under_caret() end },
      { "m", function() M.pick_model_under_caret() end },
      { "c", function() M.clear_model_override() end },
      { "p", function() M.guided_policy() end },
      { "a", function() M.add_endpoint() end },
      { "q", function() M.close() end },
      { "<Esc>", function() M.close() end },
    }
    for _, k in ipairs(keys) do
      vim.keymap.set("n", k[1], k[2], { buffer = buf, desc = "AgentManager" })
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
      title = " AgentManager ",
      title_pos = "center",
    })
  end
end

--- Enable/disable the profile under the caret.
---@param enabled boolean
function M.set_enabled_under_caret(enabled)
  local a = M.action_at()
  if not a or a.type ~= "profile" then
    vim.notify("AgentManager: caret is not on a profile", vim.log.levels.WARN)
    return
  end
  require("agent_core.registry").set_enabled(a.name, enabled)
  M.redraw()
end

--- Prompt for a key for the profile under the caret.
function M.set_key_under_caret()
  local a = M.action_at()
  if not a or a.type ~= "profile" then
    vim.notify("AgentManager: caret is not on a profile", vim.log.levels.WARN)
    return
  end
  require("agent_core.keys").cmd(false, a.name, function()
    M.redraw()
  end)
end

--- Switch the default profile to the profile under the caret.
function M.switch_profile_under_caret()
  local a = M.action_at()
  if not a or a.type ~= "profile" then
    vim.notify("AgentManager: caret is not on a profile", vim.log.levels.WARN)
    return
  end
  local Profiles = require("agent_core.profiles")
  local p = Profiles.find(a.name)
  if p then
    Profiles.switch(p)
    M.redraw()
  end
end

--- Open the pooled model picker for the profile under the caret, then redraw.
function M.pick_model_under_caret()
  local a = M.action_at()
  if not a or a.type ~= "profile" then
    vim.notify("AgentManager: caret is not on a profile", vim.log.levels.WARN)
    return
  end
  require("agent_core.pickers").pick_model(function(entry)
    if entry then
      require("agent_core.profiles").switch_model(entry)
      M.redraw()
    end
  end)
end

--- Clear the active-model override (revert to the profile default), then redraw.
function M.clear_model_override()
  require("agent_core.profiles").clear_model_override()
  M.redraw()
end

--- Launch the guided policy selector, then redraw.
function M.guided_policy()
  require("agent_core.policy").guided(function()
    M.redraw()
  end)
end

--- Prompt for and add a remote Ollama endpoint.
function M.add_endpoint()
  vim.ui.input({ prompt = "Ollama endpoint URL: " }, function(input)
    if input and input ~= "" then
      local Registry = require("agent_core.registry")
      local ok, err = Registry.add_ollama_endpoint(input)
      if ok then
        Registry.refresh_ollama()
      else
        vim.notify("AgentManager: " .. tostring(err), vim.log.levels.ERROR)
      end
      M.redraw()
    end
  end)
end

--- Close the panel and clear state.
function M.close()
  if state and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state = nil
end

--- Open the manager panel. No-op when no UI is attached (headless-safe).
function M.open()
  if #vim.api.nvim_list_uis() == 0 then
    return
  end
  state = { buf = nil, win = nil, map = {} }
  M.redraw()
end

return M
