---@mod agent_core.context Auto context attachment (open buffer + selection + LSP)
---@brief [[
--- Builds a bounded "## Current context" system-prompt block from the editor's
--- live state: the active buffer lines around the caret, the current visual
--- selection, and the LSP diagnostics for the active buffer. This is the local
--- analog of an editor that auto-attaches the open file, selection, and linter
--- errors to every prompt, so the model has immediate context without the user
--- manually @-mentioning anything.
---@brief ]]

local M = {}

M.config = {
  enabled = true,
  max_lines = 200, -- max buffer lines included around the caret
  max_chars = 6000, -- hard cap on the whole block
  include_diagnostics = true,
  include_selection = true,
  include_buffer = true,
}

--- Read the caret (zero-based row) via the platform helper.
---@return integer row
local function caret_row()
  local row = require("agent_core.platform").get_caret(0)
  return row
end

--- Format a list of diagnostics into a compact multi-line string.
---@param diags table[] vim.diagnostic entries (lnum, col, message)
---@return string
function M.format_diagnostics(diags)
  diags = diags or {}
  if #diags == 0 then
    return ""
  end
  local lines = {}
  for _, d in ipairs(diags) do
    lines[#lines + 1] = string.format("L%d:%d %s", (d.lnum or 0) + 1, (d.col or 0) + 1, d.message or "")
  end
  return table.concat(lines, "\n")
end

--- Return the LSP diagnostics for the active buffer as a string ("" if none).
---@return string
function M.diagnostics()
  if M.config.include_diagnostics == false then
    return ""
  end
  return M.format_diagnostics(vim.diagnostic.get(0))
end

--- Return the current visual selection as a string, or "" when there is none.
---@return string
function M.selection()
  if M.config.include_selection == false then
    return ""
  end
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    return ""
  end
  local ok1, sl = pcall(vim.fn.getpos, "'<")
  local ok2, el = pcall(vim.fn.getpos, "'>")
  if not ok1 or not ok2 then
    return ""
  end
  local lines = vim.fn.getline(sl[2], el[2])
  if #lines == 0 then
    return ""
  end
  lines[1] = lines[1]:sub(sl[3])
  lines[#lines] = lines[#lines]:sub(1, el[3])
  return table.concat(lines, "\n")
end

--- Return a window of buffer lines around the caret, or "" when disabled/empty.
---@return string
function M.buffer_window()
  if M.config.include_buffer == false then
    return ""
  end
  local total = vim.api.nvim_buf_line_count(0)
  if total == 0 then
    return ""
  end
  local max_lines = M.config.max_lines or 200
  local row = caret_row()
  local half = math.floor(max_lines / 2)
  local start_line = math.max(0, row - half)
  local end_line = math.min(total - 1, start_line + max_lines - 1)
  start_line = math.max(0, end_line - max_lines + 1)
  local lines = vim.api.nvim_buf_get_lines(0, start_line, end_line + 1, false)
  return table.concat(lines, "\n")
end

--- Build the full "## Current context" block, or "" when disabled/empty.
---@return string
function M.get_context_prompt()
  if M.config.enabled == false then
    return ""
  end
  local parts = {}
  local buf = M.buffer_window()
  if buf ~= "" then
    parts[#parts + 1] = "### Active file (window around caret)\n```\n" .. buf .. "\n```"
  end
  local sel = M.selection()
  if sel ~= "" then
    parts[#parts + 1] = "### Current selection\n```\n" .. sel .. "\n```"
  end
  local diags = M.diagnostics()
  if diags ~= "" then
    parts[#parts + 1] = "### LSP diagnostics\n" .. diags
  end
  if #parts == 0 then
    return ""
  end
  local content = "## Current context\n\n" .. table.concat(parts, "\n\n")
  local max = M.config.max_chars or 6000
  if #content > max then
    content = content:sub(1, max) .. "\n\n[... context truncated ...]"
  end
  return content
end

function M.setup()
  local cfg = require("agent_core").config
  M.config = vim.tbl_deep_extend("force", M.config, cfg.context or {})
end

return M
