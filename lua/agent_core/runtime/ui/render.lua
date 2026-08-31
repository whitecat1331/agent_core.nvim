---@mod agent_core.runtime.ui.render Pure chat text rendering.
---@brief [[
--- Turns session messages, status, and per-pane metadata into buffer lines
--- (markdown-lite) and builds the per-pane header/model indicator. No window
--- API here — pure string transforms so it can be unit-tested headlessly.
---@brief ]]

local M = {}

--- Strip ANSI escape sequences and terminal control codes from a string.
---@param s string
---@return string
local function strip_ansi(s)
  return (s:gsub("\27%[[%d;]*[%a]", ""))
end

--- The display label for a chat role.
---@param role string|nil
---@return string
function M.role_prefix(role)
  if role == "user" then
    return "You"
  elseif role == "assistant" then
    return "Agent"
  elseif role == "tool" then
    return "Tool"
  elseif role == "system" then
    return "System"
  end
  return tostring(role or "?")
end

--- Extract plain text from a normalized content value (string or parts array).
---@param content any
---@return string
function M.content_text(content)
  if type(content) == "string" then
    return content
  end
  if type(content) == "table" then
    local parts = {}
    for _, b in ipairs(content) do
      if type(b) == "string" then
        parts[#parts + 1] = b
      elseif type(b) == "table" and b.text ~= nil then
        parts[#parts + 1] = tostring(b.text)
      end
    end
    return table.concat(parts, "")
  end
  return tostring(content or "")
end

--- Split text into display lines (handles \n and \r\n, strips ANSI).
---@param text string
---@return string[]
function M.lines(text)
  text = strip_ansi(tostring(text or ""))
  text = text:gsub("\r\n", "\n")
  local out = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    out[#out + 1] = line
  end
  -- Drop the trailing empty segment produced by the sentinel newline.
  if #out > 0 and out[#out] == "" then
    out[#out] = nil
  end
  return out
end

--- Render a chat message (role + content) into display lines. The message is
--- prefixed with a markdown heading carrying the role label and a blank
--- separator line. Tool output is wrapped in `{{{` / `}}}` fold markers (with
--- the tool name in the heading) so results collapse under marker folding.
---@param role string
---@param content any
---@param name string|nil
---@return string[]
function M.message_lines(role, content, name)
  if role == "tool" then
    local out = { "## Tool · " .. tostring(name or "tool") }
    out[#out + 1] = "{{{"
    for _, line in ipairs(M.lines(M.content_text(content))) do
      out[#out + 1] = line
    end
    out[#out + 1] = "}}}"
    out[#out + 1] = ""
    return out
  end
  local out = { "## " .. M.role_prefix(role) }
  for _, line in ipairs(M.lines(M.content_text(content))) do
    out[#out + 1] = line
  end
  out[#out + 1] = ""
  return out
end

--- Build the per-pane model/status indicator string.
---@param provider string|nil
---@param model string|nil
---@param status string|nil
---@return string
function M.model_indicator(provider, model, status)
  local parts = {}
  if provider and provider ~= "" then
    parts[#parts + 1] = provider
  end
  if model and model ~= "" then
    parts[#parts + 1] = model
  end
  local label = #parts > 0 and table.concat(parts, " · ") or "?"
  if status and status ~= "" and status ~= "idle" then
    label = label .. " [" .. status .. "]"
  end
  return label
end

--- Build a pane header line with the title and model indicator.
---@param title string|nil
---@param indicator string
---@param focused boolean
---@return string
function M.pane_header(title, indicator, focused)
  local t = title and title ~= "" and title or "untitled"
  local prefix = focused and "▣" or "▢"
  return string.format("%s %s  ·  %s", prefix, t, indicator)
end

return M
