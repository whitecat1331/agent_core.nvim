---@mod agent_core.runtime.slash Slash commands + context variables (owned).
---@brief [[
--- Owned slash-command and context-variable expansion for submitted prompts.
--- Context variables (`#buffer`, `@lsp`, `@file`, `@git`, `@selection`, `@web`)
--- are expanded inline; slash commands (`/plan`, `/mode`, `/profile`, `/workflow`,
--- `/agent`) dispatch to the corresponding agent_core module.
---
--- Variable resolution is injectable so the pure tokenizer/substituter is
--- headless-testable; default resolvers guard against missing vim state.
---@brief ]]

local M = {}

--- Built-in context-variable registry: name -> resolver(text) -> string|nil.
--- Resolvers return nil (leave token verbatim) on any failure.
M.resolvers = {}

--- Find all context-variable tokens in a prompt: `#word`, `@word`, `@word:arg`.
---@param text string
---@return { token:string, name:string, arg:string|nil }[]
function M.find_variables(text)
  local out = {}
  text = text or ""
  local pos = 1
  while true do
    local s, e, name = text:find("[#@]([%w_]+)", pos)
    if not s then
      break
    end
    local token = text:sub(s, e)
    local arg = nil
    local suffix = text:sub(e + 1):match("^:%S+")
    if suffix then
      token = token .. suffix
      arg = suffix:sub(2)
      e = e + #suffix
    end
    out[#out + 1] = { token = token, name = name, arg = arg }
    pos = e + 1
  end
  return out
end

--- Expand context variables in a prompt using the supplied (or default) resolver
--- registry. Returns the expanded text and a list of resolved tokens.
---@param text string
---@param resolvers table|nil name -> fun(arg:string|nil) -> string|nil
---@return string expanded
---@return { name:string, value:string }[] resolved
function M.expand(text, resolvers)
  local reg = resolvers or M.resolvers
  local resolved = {}
  -- Replace longest-first so `@file:path` is not clobbered by `@file`.
  local vars = M.find_variables(text)
  table.sort(vars, function(a, b)
    return #a.token > #b.token
  end)
  local out = text or ""
  for _, v in ipairs(vars) do
    local r = reg[v.name]
    if type(r) == "function" then
      local ok, value = pcall(r, v.arg)
      if ok and type(value) == "string" and value ~= "" then
        resolved[#resolved + 1] = { name = v.name, value = value }
        local escaped = v.token:gsub("([^%w])", "%%%1")
        out = out:gsub(escaped, value, 1)
      end
    end
  end
  return out, resolved
end

--- Parse a leading slash command: `/command arg1 arg2` -> { command, args }.
--- Returns nil when the prompt does not start with a slash command.
---@param text string
---@return { command:string, args:string, rest:string }|nil
function M.parse(text)
  local command, rest = (text or ""):match("^%s*/([%w_-]+)%s*(.*)$")
  if not command then
    return nil
  end
  rest = (rest or ""):gsub("^%s+", "")
  return { command = command, args = rest, rest = rest }
end

--- Built-in slash commands: name -> { description, run(arg, opts) }.
M.commands = {
  plan = {
    description = "Switch to plan mode and submit the rest as the prompt",
    run = function(arg, opts)
      local Plan = require("agent_core.plan")
      if arg and arg ~= "" then
        return { action = "submit", text = arg, mode = "plan" }
      end
      return { action = "mode", mode = "plan" }
    end,
  },
  mode = {
    description = "Switch to a behavior mode (/mode agent|plan|debug|ask)",
    run = function(arg, opts)
      return { action = "mode", mode = arg }
    end,
  },
  profile = {
    description = "Switch to a named profile (/profile <name>)",
    run = function(arg, opts)
      return { action = "profile", profile = arg }
    end,
  },
  workflow = {
    description = "Run a named workflow (/workflow <name>)",
    run = function(arg, opts)
      return { action = "workflow", workflow = arg }
    end,
  },
  agent = {
    description = "Submit the rest to a fresh agent session",
    run = function(arg, opts)
      return { action = "submit", text = arg, new = true }
    end,
  },
}

--- List registered slash commands (name + description).
---@return { name:string, description:string }[]
function M.list()
  local out = {}
  for name, cmd in pairs(M.commands) do
    out[#out + 1] = { name = name, description = cmd.description or "" }
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

--- Resolve a prompt's slash command (if any) into an action descriptor, or expand
--- context variables when it is a plain prompt. Returns { expanded, action }.
---@param text string
---@param opts { resolvers?: table }|nil
---@return string expanded
---@return table|nil action
function M.resolve(text, opts)
  opts = opts or {}
  local cmd = M.parse(text)
  if cmd and M.commands[cmd.command] then
    local action = M.commands[cmd.command].run(cmd.args, opts)
    return text, action
  end
  return M.expand(text, opts.resolvers), nil
end

-- Default resolvers (guarded; headless-safe).
M.resolvers.buffer = function(arg)
  local ok, bufnr = pcall(vim.fn.bufnr, "%")
  if not ok or bufnr == -1 then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local txt = table.concat(lines, "\n")
  local max = arg and tonumber(arg) or 4000
  return txt:sub(1, max)
end

M.resolvers.selection = function(arg)
  local ok, _ = pcall(vim.fn.getpos, ".")
  if not ok then
    return nil
  end
  local s = vim.fn.getreg("v")
  return s ~= "" and s or nil
end

M.resolvers.file = function(arg)
  if not arg or arg == "" then
    return nil
  end
  local path = vim.fn.expand(arg)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  return table.concat(vim.fn.readfile(path), "\n")
end

M.resolvers.lsp = function(arg)
  local ok, diagnostics = pcall(vim.diagnostic.get, 0)
  if not ok or not diagnostics or #diagnostics == 0 then
    return nil
  end
  local lines = {}
  for _, d in ipairs(diagnostics) do
    lines[#lines + 1] = string.format(
      "%d:%d %s [%s] %s",
      d.lnum + 1,
      (d.col or 0) + 1,
      vim.diagnostic.severity and vim.diagnostic.severity[d.severity or 1] or "info",
      d.source or "diagnostic",
      d.message or ""
    )
  end
  return table.concat(lines, "\n")
end

M.resolvers.git = function(arg)
  local ok, job = pcall(vim.fn.systemlist, { "git", "diff", "--", arg or "" })
  if not ok then
    return nil
  end
  return #job > 0 and table.concat(job, "\n") or nil
end

return M
