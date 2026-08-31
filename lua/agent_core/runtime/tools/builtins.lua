---@mod agent_core.runtime.tools.builtins Owned built-in tools (owned).
---@brief [[
--- The file/shell/search/todo built-ins the retired upstream runtime provided. Each tool
--- carries the AgentTool shape (name, description, param, returns,
--- func(input, opts)) so it dispatches through agent_core.runtime.tools unchanged
--- and is gated by the same modes.lua WRITE_TOOLS / auto_approve policy.
---
--- Mutating tools (bash, write_to_file, str_replace, write_todos) are listed in
--- modes.WRITE_TOOLS so read-only modes (ask/plan) strip them out.
---@brief ]]

local M = {}

--- Run an argv list via vim.system and deliver (stdout, stderr) through cb.
---@param argv string[]
---@param opts { cwd?:string, timeout?:number }
---@param cb fun(stdout:string|nil, stderr:string|nil, code:integer)
local function run_argv(argv, opts, cb)
  local sys_opts = { text = true }
  if opts.cwd and opts.cwd ~= "" then
    sys_opts.cwd = opts.cwd
  end
  if opts.timeout then
    sys_opts.timeout = opts.timeout
  end
  vim.system(argv, sys_opts, function(obj)
    cb(obj.stdout, obj.stderr, obj.code or 0)
  end)
end

--- Root path for tool output (scoped to the project cwd, falling back to "").
---@return string
local function root()
  return vim.fn.getcwd()
end

--- Join a possibly-relative path onto the project root when not absolute.
---@param path string
---@return string
local function abs(path)
  if path:match("^%a:[/\\]") or path:match("^[/\\]") then
    return path
  end
  return root() .. "/" .. path
end

----------------------------------------------------------------------------
-- read_file
----------------------------------------------------------------------------
local read_file = {
  name = "read_file",
  description = "Read a file's contents, optionally limited to a line range (offset + limit).",
  param = {
    type = "table",
    fields = {
      { name = "file_path", description = "Path to the file to read.", type = "string" },
      { name = "offset", description = "1-based starting line (default 1).", type = "integer", optional = true },
      {
        name = "limit",
        description = "Maximum number of lines to return (default all).",
        type = "integer",
        optional = true,
      },
    },
    required = { "file_path" },
  },
  returns = {
    { name = "content", description = "The file contents (with line numbers).", type = "string" },
    { name = "error", description = "Error message if the read failed.", type = "string", optional = true },
  },
}

---@type AgentToolFunc<{ file_path: string, offset?: integer, limit?: integer }>
function read_file.func(input, opts)
  local path = abs(input.file_path or "")
  if path == root() or path == "" then
    return nil, "file_path is required"
  end
  if vim.fn.filereadable(path) ~= 1 then
    return nil, "file not readable: " .. path
  end
  local lines = vim.fn.readfile(path)
  local start = math.max(1, tonumber(input.offset) or 1)
  local stop = #lines
  if input.limit then
    stop = math.min(#lines, start + tonumber(input.limit) - 1)
  end
  local out = {}
  for i = start, stop do
    out[#out + 1] = string.format("%6d\t%s", i, lines[i])
  end
  return table.concat(out, "\n")
end

----------------------------------------------------------------------------
-- write_to_file
----------------------------------------------------------------------------
local write_to_file = {
  name = "write_to_file",
  description = "Create or overwrite a file with the given content, creating parent directories as needed.",
  param = {
    type = "table",
    fields = {
      { name = "file_path", description = "Path to the file to write.", type = "string" },
      { name = "content", description = "The full content to write to the file.", type = "string" },
    },
    required = { "file_path", "content" },
  },
  returns = {
    { name = "result", description = "Confirmation message.", type = "string" },
    { name = "error", description = "Error message if the write failed.", type = "string", optional = true },
  },
}

---@type AgentToolFunc<{ file_path: string, content: string }>
function write_to_file.func(input, opts)
  local path = abs(input.file_path or "")
  if path == root() or path == "" then
    return nil, "file_path is required"
  end
  local dir = vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(dir) ~= 1 then
    local ok = vim.fn.mkdir(dir, "p")
    if ok ~= 1 then
      return nil, "could not create directory: " .. dir
    end
  end
  local ok, err = pcall(vim.fn.writefile, vim.split(input.content or "", "\n", { plain = true }), path)
  if not ok then
    return nil, tostring(err)
  end
  return "wrote " .. path
end

----------------------------------------------------------------------------
-- str_replace
----------------------------------------------------------------------------
local str_replace = {
  name = "str_replace",
  description = "Replace an exact old_string with new_string in a file (single occurrence; errors on ambiguity).",
  param = {
    type = "table",
    fields = {
      { name = "file_path", description = "Path to the file to edit.", type = "string" },
      { name = "old_string", description = "The exact text to replace (must be unique).", type = "string" },
      { name = "new_string", description = "The replacement text.", type = "string" },
    },
    required = { "file_path", "old_string", "new_string" },
  },
  returns = {
    { name = "result", description = "Confirmation message.", type = "string" },
    { name = "error", description = "Error message if the edit failed.", type = "string", optional = true },
  },
}

---@type AgentToolFunc<{ file_path: string, old_string: string, new_string: string }>
function str_replace.func(input, opts)
  local path = abs(input.file_path or "")
  if vim.fn.filereadable(path) ~= 1 then
    return nil, "file not readable: " .. path
  end
  local old_s = input.old_string or ""
  local new_s = input.new_string or ""
  local text = table.concat(vim.fn.readfile(path), "\n")
  local count = 0
  local start = 0
  while true do
    local s = text:find(old_s, start + 1, true)
    if not s then
      break
    end
    count = count + 1
    start = s
  end
  if count == 0 then
    return nil, "old_string not found in " .. path
  end
  if count > 1 then
    return nil, "old_string is ambiguous (" .. count .. " occurrences) in " .. path
  end
  local replaced = text:gsub(old_s, new_s:gsub("%%", "%%%%"), 1)
  local ok, err = pcall(vim.fn.writefile, vim.split(replaced, "\n", { plain = true }), path)
  if not ok then
    return nil, tostring(err)
  end
  return "edited " .. path
end

----------------------------------------------------------------------------
-- list_dir
----------------------------------------------------------------------------
local list_dir = {
  name = "list_dir",
  description = "List the entries of a directory.",
  param = {
    type = "table",
    fields = {
      { name = "directory", description = "Directory path (default: project root).", type = "string", optional = true },
    },
    required = {},
  },
  returns = {
    { name = "entries", description = "Newline-separated directory entries.", type = "string" },
    { name = "error", description = "Error message if listing failed.", type = "string", optional = true },
  },
}

---@type AgentToolFunc<{ directory?: string }>
function list_dir.func(input, opts)
  local dir = abs((input and input.directory) or root())
  if vim.fn.isdirectory(dir) ~= 1 then
    return nil, "not a directory: " .. dir
  end
  local out = vim.fn.readdir(dir)
  return table.concat(out, "\n")
end

----------------------------------------------------------------------------
-- glob
----------------------------------------------------------------------------
local glob = {
  name = "glob",
  description = "Find files matching a glob pattern (e.g. **/*.lua).",
  param = {
    type = "table",
    fields = {
      { name = "pattern", description = "Glob pattern to match.", type = "string" },
    },
    required = { "pattern" },
  },
  returns = {
    { name = "matches", description = "Newline-separated matching paths.", type = "string" },
    { name = "error", description = "Error message if globbing failed.", type = "string", optional = true },
  },
}

---@type AgentToolFunc<{ pattern: string }>
function glob.func(input, opts)
  local pattern = input and input.pattern
  if not pattern or pattern == "" then
    return nil, "pattern is required"
  end
  local ok, out = pcall(vim.fn.glob, pattern, true, true)
  if not ok then
    return nil, tostring(out)
  end
  return table.concat(out or {}, "\n")
end

----------------------------------------------------------------------------
-- grep
----------------------------------------------------------------------------
local grep = {
  name = "grep",
  description = "Search file contents for a literal or regex pattern using ripgrep (falls back to grep).",
  param = {
    type = "table",
    fields = {
      { name = "pattern", description = "The pattern to search for.", type = "string" },
      {
        name = "directory",
        description = "Directory to search (default: project root).",
        type = "string",
        optional = true,
      },
      {
        name = "file_types",
        description = "Optional comma-separated file extensions (e.g. lua,go).",
        type = "string",
        optional = true,
      },
    },
    required = { "pattern" },
  },
  returns = {
    { name = "matches", description = "Newline-separated matches (path:line:col:text).", type = "string" },
    { name = "error", description = "Error message if searching failed.", type = "string", optional = true },
  },
}

---@type AgentToolFunc<{ pattern: string, directory?: string, file_types?: string }>
function grep.func(input, opts)
  local pattern = input and input.pattern
  if not pattern or pattern == "" then
    return nil, "pattern is required"
  end
  local dir = abs(input.directory or root())
  local argv = { "rg", "--line-number", "--column", "--no-heading", "--color", "never", pattern, dir }
  if input.file_types and input.file_types ~= "" then
    for ft in (input.file_types .. ","):gmatch("([^,]+),") do
      argv[#argv + 1] = "-g"
      argv[#argv + 1] = "*." .. ft
    end
  end

  run_argv(argv, { timeout = 20000 }, function(stdout, stderr, code)
    if code == 0 then
      opts.on_complete(stdout or "", nil)
    elseif code == 1 then
      opts.on_complete("", nil) -- no matches
    else
      opts.on_complete(nil, (stderr and stderr ~= "") and stderr or ("rg exited " .. tostring(code)))
    end
  end)
end

----------------------------------------------------------------------------
-- bash
----------------------------------------------------------------------------
local bash = {
  name = "bash",
  description = "Run a shell command in the project root and return its combined output.",
  param = {
    type = "table",
    fields = {
      { name = "command", description = "The shell command to run.", type = "string" },
    },
    required = { "command" },
  },
  returns = {
    { name = "output", description = "Combined stdout/stderr of the command.", type = "string" },
    { name = "error", description = "Error message if the command failed.", type = "string", optional = true },
  },
}

---@type AgentToolFunc<{ command: string }>
function bash.func(input, opts)
  local command = input and input.command
  if not command or command == "" then
    return nil, "command is required"
  end
  local shell = vim.o.shell or "sh"
  local argv = { shell, "-c", command }
  run_argv(argv, { cwd = root(), timeout = 60000 }, function(stdout, stderr, code)
    local out = table.concat({ stdout or "", stderr or "" }, "\n")
    if code == 0 then
      opts.on_complete(out, nil)
    else
      opts.on_complete(nil, "command exited " .. tostring(code) .. "\n" .. out)
    end
  end)
end

----------------------------------------------------------------------------
-- read_todos / write_todos
----------------------------------------------------------------------------
local TODOS_PATH = vim.fn.stdpath("data") .. "/agent_core/todos.json"

local function read_todos_raw()
  if vim.fn.filereadable(TODOS_PATH) ~= 1 then
    return {}
  end
  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(TODOS_PATH), "\n"))
  if ok and type(data) == "table" then
    return data
  end
  return {}
end

local read_todos = {
  name = "read_todos",
  description = "Read the current todo list.",
  param = { type = "table", fields = {}, required = {} },
  returns = {
    { name = "todos", description = "JSON array of todo items.", type = "string" },
  },
}

---@type AgentToolFunc<{}>
function read_todos.func(input, opts)
  return vim.json.encode(read_todos_raw())
end

local write_todos = {
  name = "write_todos",
  description = "Replace the current todo list (a JSON array of items).",
  param = {
    type = "table",
    fields = {
      { name = "todos", description = "The full todo list to store.", type = "string[]" },
    },
    required = { "todos" },
  },
  returns = {
    { name = "result", description = "Confirmation message.", type = "string" },
    { name = "error", description = "Error message if writing failed.", type = "string", optional = true },
  },
}

---@type AgentToolFunc<{ todos: string[] }>
function write_todos.func(input, opts)
  local todos = input and input.todos
  if type(todos) ~= "table" then
    return nil, "todos must be an array"
  end
  vim.fn.mkdir(vim.fn.fnamemodify(TODOS_PATH, ":h"), "p")
  local ok, err = pcall(vim.fn.writefile, { vim.json.encode(todos) }, TODOS_PATH)
  if not ok then
    return nil, tostring(err)
  end
  return "wrote " .. #todos .. " todo(s)"
end

----------------------------------------------------------------------------
-- attempt_completion
----------------------------------------------------------------------------
local attempt_completion = {
  name = "attempt_completion",
  description = "Signal that the task is complete and return the final result to the user.",
  param = {
    type = "table",
    fields = {
      { name = "result", description = "The final summary/result of the completed task.", type = "string" },
    },
    required = { "result" },
  },
  returns = {
    { name = "result", description = "The final result.", type = "string" },
  },
}

---@type AgentToolFunc<{ result: string }>
function attempt_completion.func(input, opts)
  if opts and opts.on_complete then
    opts.on_complete(input and input.result or "", nil)
  end
end

--- All owned built-in tools in deterministic order.
---@return table[]
function M.all()
  return {
    read_file,
    write_to_file,
    str_replace,
    list_dir,
    glob,
    grep,
    bash,
    read_todos,
    write_todos,
    attempt_completion,
  }
end

return M
