---@mod agent_core.notepad Persistent user-authored context notes (Notepads)
---@brief [[
--- Stores user-authored markdown notes under <data>/agent_core/notepads/ and
--- injects a compact index (title + path per note) into the system prompt via
--- get_notepad_prompt(). The model reads a note's full content on demand with its
--- read tools (attach only when relevant).
--- Notes are plain markdown files: they are easy to edit in any buffer, portable,
--- and only their titles are ever auto-injected (never their full content).
---@brief ]]

local M = {}

--- Directory where notes live. Override with config.notepad.dir.
---@return string
function M.dir()
  local cfg = require("agent_core").config
  local np = cfg.notepad or {}
  if np.dir and np.dir ~= "" then
    return vim.fn.expand(np.dir)
  end
  return vim.fn.stdpath("data") .. "/agent_core/notepads"
end

--- Read a file's contents as a string, or nil when unreadable.
---@param path string
---@return string|nil
local function read_file(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  return table.concat(vim.fn.readfile(path), "\n")
end

--- Derive a note title from its content: first markdown heading, else filename.
---@param name string
---@param content string
---@return string
function M.title_for(name, content)
  local first = content:match("[^\r\n]+")
  if first then
    local heading = first:match("^%s*#+%s+(.-)%s*$")
    if heading and heading ~= "" then
      return heading
    end
  end
  return name
end

--- First non-empty, non-heading line of a note (a one-line preview).
---@param content string
---@return string
function M.preview_for(content)
  for line in content:gmatch("[^\r\n]+") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" and not trimmed:match("^#+%s") then
      return trimmed
    end
  end
  return ""
end

--- List all notes as { name, path, title, preview } sorted by name.
---@return {name:string,path:string,title:string,preview:string}[]
function M.list()
  local dir = M.dir()
  local notes = {}
  local files = vim.fn.glob(dir .. "/*.md", false, true)
  for _, path in ipairs(files) do
    local name = path:match("([^/\\]+)%.md$") or path
    local content = read_file(path) or ""
    notes[#notes + 1] = {
      name = name,
      path = path,
      title = M.title_for(name, content),
      preview = M.preview_for(content),
    }
  end
  table.sort(notes, function(a, b)
    return a.name:lower() < b.name:lower()
  end)
  return notes
end

--- Open a note in a buffer for editing.
---@param note {name:string,path:string,title:string,preview:string}
function M.open(note)
  if not note or not note.path then
    return
  end
  vim.fn.mkdir(M.dir(), "p")
  if vim.fn.filereadable(note.path) ~= 1 then
    local f = io.open(note.path, "w")
    if f then
      f:write("# " .. note.name .. "\n\n")
      f:close()
    end
  end
  vim.cmd("edit " .. vim.fn.fnameescape(note.path))
end

--- Open a picker over the notes (snacks.nvim if present, else vim.ui.select).
---@param cb fun(note: {name:string,path:string,title:string,preview:string}|nil)
function M.pick(cb)
  local notes = M.list()
  if #notes == 0 then
    vim.notify("Notepads: empty — run :AgentNotepadNew", vim.log.levels.WARN)
    cb(nil)
    return
  end

  local items = {}
  for _, n in ipairs(notes) do
    table.insert(items, {
      text = string.format("%s  |  %s", n.title, n.preview ~= "" and n.preview or n.path),
      note = n,
    })
  end

  local ok, Snacks = pcall(require, "snacks.picker")
  if ok and type(Snacks) == "table" and type(Snacks.pick) == "function" then
    Snacks.pick({
      title = "Notepads",
      items = items,
      layout = { preview = false },
      format = function(item)
        return { { item.text } }
      end,
      confirm = function(picker, item)
        picker:close()
        cb(item and item.note or nil)
      end,
    })
    return
  end

  local labels = {}
  for _, n in ipairs(notes) do
    table.insert(labels, string.format("%s (%s)", n.name, n.preview ~= "" and n.preview or n.path))
  end
  vim.ui.select(labels, { prompt = "Notepad" }, function(choice)
    for _, n in ipairs(notes) do
      if choice == string.format("%s (%s)", n.name, n.preview ~= "" and n.preview or n.path) then
        cb(n)
        return
      end
    end
    cb(nil)
  end)
end

--- Prompt for a name and create + open a new note.
function M.new()
  vim.ui.input({ prompt = "Notepad name: " }, function(input)
    if not input or input == "" then
      return
    end
    -- Sanitize to a filesystem-safe slug.
    local name =
      input:gsub("[\\/]+", "-"):gsub("[^%w%-_ ]", ""):gsub("%s+", "-"):gsub("-+", "-"):gsub("^-+", ""):gsub("-+$", "")
    if name == "" then
      vim.notify("Notepads: invalid name", vim.log.levels.ERROR)
      return
    end
    M.open({ name = name, path = M.dir() .. "/" .. name .. ".md", title = name, preview = "" })
  end)
end

--- Pick a note and open it.
function M.edit()
  M.pick(function(note)
    if note then
      M.open(note)
    end
  end)
end

--- Pick a note and delete it.
function M.remove()
  M.pick(function(note)
    if not note then
      return
    end
    if vim.fn.delete(note.path) ~= 0 then
      vim.notify("Notepads: could not delete " .. note.name, vim.log.levels.ERROR)
      return
    end
    vim.notify("Notepads: removed " .. note.name, vim.log.levels.INFO)
  end)
end

--- Build the compact notepad index for the system prompt (titles only). Empty
--- string when no notes exist. Bounded by config.notepad.prompt_max_chars.
---@return string
function M.get_notepad_prompt()
  local notes = M.list()
  if #notes == 0 then
    return ""
  end

  local cfg = require("agent_core").config
  local np = cfg.notepad or {}
  local dir = M.dir()

  local lines = {
    "## Notepads",
    "",
    "Persistent user-authored notes. Reference one by name and read its file",
    "(" .. dir .. "/<name>.md) when the task relates to it. Titles only:",
    "",
  }
  for _, n in ipairs(notes) do
    lines[#lines + 1] = "- " .. n.title .. "  (" .. n.name .. ".md)"
    if n.preview and n.preview ~= "" then
      lines[#lines + 1] = "  " .. n.preview
    end
  end

  local content = table.concat(lines, "\n")
  local max = np.prompt_max_chars or 3000
  if #content > max then
    content = content:sub(1, max) .. "\n\n[... notepad index truncated ...]"
  end
  return content
end

function M.setup()
  vim.fn.mkdir(M.dir(), "p")
end

return M
