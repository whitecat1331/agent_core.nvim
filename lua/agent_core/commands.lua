---@mod agent_core.commands Declarative command palette for the agent
---@brief [[
--- Discovers curated shell commands stored as one file per command
--- (.agent_core/commands/<name>.cmd.md for the project and
--- <data>/agent_core/commands/<name>.cmd.md for the user), parses their YAML
--- frontmatter (name, description, trust, argv, args, required), and exposes them
--- to the model through a single constrained `run_command` tool whose `name`
--- field enumerates the discovered commands. The model emits a short command ID
--- plus typed args instead of a full free-form command string; the harness builds
--- the argv array deterministically (never shell-interpolated), so commands are
--- cheap, unambiguous, and injection-safe.
---
--- Only `safe` commands are exposed via the tool; `dangerous` commands are
--- excluded and left to the approval-gated `bash` breakout. The palette mirrors
--- the skills pattern: discover files, parse frontmatter, inject a compact
--- metadata index via get_commands_prompt(), and expose a tool + :AgentCommand
--- picker.
---@brief ]]

local M = {}

M.config = {
  enabled = true,
  project_dir = ".agent_core/commands", -- project commands (committed alongside the repo)
  user_dir = nil, -- nil = <data>/agent_core/commands (user-global)
  prompt_max_chars = 3000,
}

--- Read a file as a string, or nil when unreadable.
---@param path string
---@return string|nil
local function read_file(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  return table.concat(vim.fn.readfile(path), "\n")
end

--- Project commands directory (relative to the active root).
---@return string
function M.project_dir()
  local cfg = require("agent_core").config
  local c = cfg.commands or {}
  if c.project_dir and c.project_dir ~= "" then
    return vim.fn.expand(c.project_dir)
  end
  return require("agent_core.indexer").root() .. "/" .. (M.config.project_dir or ".agent_core/commands")
end

--- User commands directory.
---@return string
function M.user_dir()
  local cfg = require("agent_core").config
  local c = cfg.commands or {}
  if c.user_dir and c.user_dir ~= "" then
    return vim.fn.expand(c.user_dir)
  end
  return vim.fn.stdpath("data") .. "/agent_core/commands"
end

--- Normalize a frontmatter value to a string list (scalar or YAML list).
---@param v any
---@return string[]
local function normalize_list(v)
  if v == nil then
    return {}
  end
  if type(v) == "table" then
    local out = {}
    for _, item in ipairs(v) do
      out[#out + 1] = tostring(item)
    end
    return out
  end
  return { tostring(v) }
end

---@class AgentCommand
---@field name string
---@field description string|nil
---@field trust string "safe" | "dangerous"
---@field argv string[] program + argument tokens, with optional {{name}} placeholders
---@field args string[] argument names accepted by the command
---@field required string[] argument names that must be provided
---@field body string full body (frontmatter stripped)
---@field scope "project"|"user"
---@field path string

--- Parse a command file into a command entry, or nil when unreadable/empty.
---@param path string
---@param scope "project"|"user"
---@return AgentCommand|nil
function M.parse_command(path, scope)
  local content = read_file(path)
  if not content or content == "" then
    return nil
  end
  local fm, body = require("agent_core.rules").parse_frontmatter(content)
  local name = fm.name
  if not name or name == "" then
    name = path:match("([^/\\]+)%.cmd%.md$") or path:match("([^/\\]+)%.md$") or path:match("([^/\\]+)$")
  end
  local trust = fm.trust
  if not trust or trust == "" then
    trust = "safe"
  end
  local argv = normalize_list(fm.argv)
  if #argv == 0 then
    return nil
  end
  return {
    name = name,
    description = fm.description,
    trust = trust,
    argv = argv,
    args = normalize_list(fm.args),
    required = normalize_list(fm.required),
    body = body,
    scope = scope,
    path = path,
  }
end

--- Discover every command under the project + user command directories.
---@return AgentCommand[]
function M.discover()
  local out = {}

  local function collect(dir, scope)
    if dir == "" or vim.fn.isdirectory(dir) ~= 1 then
      return
    end
    local files = vim.fn.glob(dir .. "/*.cmd.md", false, true)
    table.sort(files)
    for _, p in ipairs(files) do
      local cmd = M.parse_command(p, scope)
      if cmd then
        out[#out + 1] = cmd
      end
    end
  end

  collect(M.project_dir(), "project")
  collect(M.user_dir(), "user")

  table.sort(out, function(a, b)
    return a.name:lower() < b.name:lower()
  end)
  return out
end

--- Find a command by name, or nil.
---@param name string
---@return AgentCommand|nil
function M.find(name)
  if not name or name == "" then
    return nil
  end
  for _, c in ipairs(M.discover()) do
    if c.name == name then
      return c
    end
  end
  return nil
end

--- True when a command is safe to auto-approve (not `dangerous`).
---@param cmd AgentCommand
---@return boolean
function M.is_safe(cmd)
  return not cmd or cmd.trust ~= "dangerous"
end

--- List discovered commands as metadata-only entries.
---@return {name:string,description:string|nil,trust:string,args:string[],required:string[],path:string,scope:string}[]
function M.list()
  local out = {}
  for _, c in ipairs(M.discover()) do
    out[#out + 1] = {
      name = c.name,
      description = c.description,
      trust = c.trust,
      args = c.args,
      required = c.required,
      path = c.path,
      scope = c.scope,
    }
  end
  return out
end

--- Validate that every required argument is present. Returns (true, nil) or
--- (false, err).
---@param cmd AgentCommand
---@param values table<string,string>
---@return boolean ok
---@return string|nil err
function M.validate(cmd, values)
  values = values or {}
  for _, name in ipairs(cmd.required or {}) do
    local v = values[name]
    if v == nil or v == "" then
      return false, "missing required argument: " .. tostring(name)
    end
  end
  return true, nil
end

--- Substitute `{{name}}` placeholders in argv tokens from `values`. Returns
--- (argv, nil) on success or (nil, err) when a placeholder cannot be resolved.
---@param argv string[]
---@param values table<string,string>
---@return string[]|nil argv
---@return string|nil err
function M.interpolate(argv, values)
  values = values or {}
  local out = {}
  for _, token in ipairs(argv or {}) do
    local ok = true
    local replaced = token:gsub("{{%s*([%w_%-]+)%s*}}", function(name)
      local v = values[name]
      if v == nil or v == "" then
        ok = false
        return "{{" .. name .. "}}"
      end
      return tostring(v)
    end)
    if not ok then
      return nil, "missing argument: " .. tostring(token)
    end
    out[#out + 1] = replaced
  end
  return out, nil
end

--- Run an argv list via vim.system with cwd = project root. Delivers
--- (stdout, nil) on success or (nil, err) on failure.
---@param argv string[]
---@param cb fun(stdout:string|nil, err:string|nil)
function M.execute(argv, cb)
  cb = cb or function() end
  if not argv or #argv == 0 then
    cb(nil, "empty command")
    return
  end
  local root = require("agent_core.indexer").root()
  vim.system(argv, { cwd = root, text = true }, function(obj)
    if obj.code ~= 0 then
      cb(nil, "command failed (exit " .. tostring(obj.code) .. "): " .. tostring(obj.stderr or ""))
      return
    end
    cb(obj.stdout or "", nil)
  end)
end

--- Build the compact command index for the system prompt (metadata only). Empty
--- string when no commands exist or commands are disabled. Bounded by
--- config.commands.prompt_max_chars.
---@return string
function M.get_commands_prompt()
  local cfg = require("agent_core").config
  local c = cfg.commands or {}
  if c.enabled == false or (M.config.enabled == false and c.enabled == nil) then
    return ""
  end

  local commands = M.discover()
  if #commands == 0 then
    return ""
  end

  local lines = {
    "## Command palette",
    "",
    "Curated commands the agent can run with the `run_command` tool (safe) or",
    "via `bash` (dangerous). Prefer `run_command` for any supported command.",
    "",
  }
  for _, cmd in ipairs(commands) do
    local line = "- " .. cmd.name
    if cmd.description and cmd.description ~= "" then
      line = line .. " — " .. cmd.description
    end
    if #cmd.args > 0 then
      line = line .. " (args: " .. table.concat(cmd.args, ", ") .. ")"
    end
    if not M.is_safe(cmd) then
      line = line .. " [dangerous: use bash]"
    end
    lines[#lines + 1] = line
  end

  local content = table.concat(lines, "\n")
  local max = c.prompt_max_chars or M.config.prompt_max_chars or 3000
  if #content > max then
    content = content:sub(1, max) .. "\n\n[... command palette truncated ...]"
  end
  return content
end

--- Build the `run_command` tool description enumerating every safe command.
---@return string
function M.build_tool_description()
  local commands = M.discover()
  local parts = {
    "Run a known command from the command palette. Prefer this over bash for any supported command.",
  }
  local safe = {}
  for _, c in ipairs(commands) do
    if M.is_safe(c) then
      local line = "- " .. c.name
      if c.description and c.description ~= "" then
        line = line .. " — " .. c.description
      end
      if #c.args > 0 then
        line = line .. " (args: " .. table.concat(c.args, ", ") .. ")"
      end
      safe[#safe + 1] = line
    end
  end
  if #safe > 0 then
    parts[#parts + 1] = "Available commands:\n" .. table.concat(safe, "\n")
  else
    parts[#parts + 1] = "No commands are currently registered."
  end
  return table.concat(parts, "\n")
end

---@type AvanteLLMTool
local run_command = {
  name = "run_command",
  description = "", -- populated at registration time
  param = {
    type = "table",
    fields = {
      { name = "name", description = "Command name from the command palette.", type = "string" },
      { name = "args", description = "Optional arguments keyed by name.", type = "table", optional = true },
    },
    required = { "name" },
    usage = {
      name = "Command name",
      args = "Arguments (optional)",
    },
  },
  returns = {
    { name = "result", description = "The command's stdout output.", type = "string" },
    { name = "error", description = "Error message if the command failed.", type = "string", optional = true },
  },
}
---@type AvanteLLMToolFunc<{ name: string, args?: table }>
function run_command.func(input, opts)
  if not opts.on_complete then
    return nil, "on_complete not provided"
  end
  local name = input.name
  if not name or name == "" then
    opts.on_complete(nil, "command name required")
    return
  end
  local cmd = M.find(name)
  if not cmd then
    opts.on_complete(nil, "unknown command: " .. tostring(name))
    return
  end
  if not M.is_safe(cmd) then
    opts.on_complete(nil, "command '" .. name .. "' is marked dangerous; use bash for it")
    return
  end

  local values = input.args or {}
  local ok, err = M.validate(cmd, values)
  if not ok then
    opts.on_complete(nil, err)
    return
  end
  local argv, ierr = M.interpolate(cmd.argv, values)
  if not argv then
    opts.on_complete(nil, ierr)
    return
  end

  M.execute(argv, function(stdout, eerr)
    if eerr then
      opts.on_complete(nil, eerr)
      return
    end
    opts.on_complete(stdout, nil)
  end)
end

function M.run_command_tool()
  run_command.description = M.build_tool_description()
  return run_command
end

--- Present discovered commands in a scratch buffer (:AgentCommands).
function M.list_cmd()
  local commands = M.discover()
  local lines = { "# Agent command palette", "" }
  if #commands == 0 then
    lines[#lines + 1] = "(none — add a .cmd.md under .agent_core/commands/ or <data>/agent_core/commands/)"
  else
    for _, c in ipairs(commands) do
      lines[#lines + 1] = string.format("## %s  [%s | %s]", c.name, c.trust, c.scope)
      if c.description and c.description ~= "" then
        lines[#lines + 1] = c.description
      end
      if #c.args > 0 then
        lines[#lines + 1] = "args: " .. table.concat(c.args, ", ")
      end
      lines[#lines + 1] = "argv: " .. table.concat(c.argv, " ")
      lines[#lines + 1] = "path: " .. c.path
      lines[#lines + 1] = ""
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.api.nvim_open_win(buf, true, { split = "right" })
end

--- Backing for :AgentCommand: pick a command and run it, collecting required
--- arguments interactively and showing the output.
function M.invoke_cmd()
  local commands = M.discover()
  if #commands == 0 then
    vim.notify("No commands (add a .cmd.md under .agent_core/commands/)", vim.log.levels.WARN)
    return
  end

  local function run(cmd, values)
    local ok, err = M.validate(cmd, values)
    if not ok then
      vim.notify("AgentCommand: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    local argv, ierr = M.interpolate(cmd.argv, values)
    if not argv then
      vim.notify("AgentCommand: " .. tostring(ierr), vim.log.levels.ERROR)
      return
    end
    M.execute(argv, function(stdout, eerr)
      if eerr then
        vim.notify("AgentCommand: " .. tostring(eerr), vim.log.levels.ERROR)
        return
      end
      vim.notify("AgentCommand " .. cmd.name .. " complete", vim.log.levels.INFO)
      vim.print(stdout or "")
    end)
  end

  local function collect_args(cmd, idx, values)
    local required = cmd.required or {}
    if idx > #required then
      run(cmd, values)
      return
    end
    local name = required[idx]
    vim.ui.input({ prompt = "AgentCommand " .. cmd.name .. " (" .. name .. "): " }, function(input)
      if input == nil then
        return
      end
      values[name] = input
      collect_args(cmd, idx + 1, values)
    end)
  end

  local function pick_args(cmd)
    collect_args(cmd, 1, {})
  end

  local items = {}
  for _, c in ipairs(commands) do
    items[#items + 1] = {
      text = string.format("%s  |  %s  |  %s", c.name, c.trust, c.description or ""),
      command = c,
    }
  end

  local ok, Snacks = pcall(require, "snacks.picker")
  if ok and type(Snacks) == "table" and type(Snacks.pick) == "function" then
    Snacks.pick({
      title = "Agent Command",
      items = items,
      layout = { preview = false },
      format = function(item)
        return { { item.text } }
      end,
      confirm = function(picker, item)
        picker:close()
        if item and item.command then
          pick_args(item.command)
        end
      end,
    })
    return
  end

  local choices = vim.tbl_map(function(c)
    return c.name
  end, commands)
  vim.ui.select(choices, { prompt = "Agent command" }, function(choice)
    for _, c in ipairs(commands) do
      if c.name == choice then
        pick_args(c)
        return
      end
    end
  end)
end

function M.setup()
  vim.fn.mkdir(M.project_dir(), "p")
  vim.fn.mkdir(M.user_dir(), "p")
end

return M
