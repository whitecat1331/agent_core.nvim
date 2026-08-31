---@mod agent_core.runtime.ui.highlights Highlight groups for the Agents Window.
---@brief [[
--- Owned highlight groups used by the Agents Window grid. Defines them lazily
--- (only when the window renders) so requiring this module is side-effect-free
--- in headless tests. Replaces the upstream highlights once the runtime is retired.
---@brief ]]

local M = {}

--- Highlight group name -> default spec.
local GROUPS = {
  AgentPaneHeader = { fg = "#89b4fa", bold = true },
  AgentPaneHeaderFocused = { fg = "#f9e2af", bold = true },
  AgentRoleUser = { fg = "#a6e3a1", bold = true },
  AgentRoleAssistant = { fg = "#89b4fa", bold = true },
  AgentRoleTool = { fg = "#cba6f7", bold = true },
  AgentRoleSystem = { fg = "#f38ba8", bold = true },
  AgentIndicator = { fg = "#7f849c", italic = true },
  AgentComposerFooter = { fg = "#6c7086", bg = "#181825" },
  AgentComposerPill = { fg = "#cdd6f4", bg = "#313244", bold = true },
  AgentComposerPillHint = { fg = "#a6adc8", bg = "#313244" },
}

--- Apply all owned highlight groups (defaults; user can override in their theme).
function M.setup()
  for name, spec in pairs(GROUPS) do
    vim.api.nvim_set_hl(0, name, spec)
  end
end

--- The canonical highlight group name for a given role/kind (for use in
--- nvim_buf_add_highlight / extmark hl_group). Returns nil for unknown kinds.
---@param kind string "user"|"assistant"|"tool"|"system"|"header"|"header_focused"|"indicator"
---@return string|nil
function M.group(kind)
  if kind == "user" then
    return "AgentRoleUser"
  elseif kind == "assistant" then
    return "AgentRoleAssistant"
  elseif kind == "tool" then
    return "AgentRoleTool"
  elseif kind == "system" then
    return "AgentRoleSystem"
  elseif kind == "header" then
    return "AgentPaneHeader"
  elseif kind == "header_focused" then
    return "AgentPaneHeaderFocused"
  elseif kind == "indicator" then
    return "AgentIndicator"
  elseif kind == "composer_footer" then
    return "AgentComposerFooter"
  elseif kind == "composer_pill" then
    return "AgentComposerPill"
  elseif kind == "composer_pill_hint" then
    return "AgentComposerPillHint"
  end
  return nil
end

return M
