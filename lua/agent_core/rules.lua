---@mod agent_core.rules Auto-inject project + user rules into the system prompt
---@brief [[
--- Aggregates the instruction files agent-style editors honor (AGENTS.md and
--- CLAUDE.md at the project root, plus .agent_core/rules/*.mdc|md for the project
--- and <data>/agent_core/rules/*.mdc|md for the user) into one bounded
--- system-prompt block. Project rules are injected first, then user rules. It
--- honors .mdc frontmatter: `description` and `globs` are surfaced in the
--- heading, and `alwaysApply: false` (or a non-`always` `type`) injects only the
--- rule's metadata as an on-demand note instead of its full body. The block is
--- bounded by config.rules.prompt_max_chars and only includes committed rule
--- files the user already authored; it never embeds arbitrary file contents.
---@brief ]]

local M = {}

--- Read a file as a string, or nil when unreadable.
---@param path string
---@return string|nil
local function read_file(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  return table.concat(vim.fn.readfile(path), "\n")
end

--- List markdown rule files under a directory (glob *.mdc + *.md, sorted).
---@param dir string
---@return string[]
local function rule_files(dir)
  local seen = {}
  local list = {}
  local function collect(pattern)
    for _, p in ipairs(vim.fn.glob(dir .. "/" .. pattern, false, true)) do
      if vim.fn.filereadable(p) == 1 and not seen[p] then
        seen[p] = true
        list[#list + 1] = p
      end
    end
  end
  collect("*.mdc")
  collect("*.md")
  table.sort(list)
  return list
end

--- Parse a simple YAML frontmatter block (a leading `---` … `---` fence).
--- Returns (frontmatter, body). Scalars become string values; list items under
--- a key become a string[] table; body is the content after the closing fence.
--- Returns ({}, content) when there is no frontmatter.
---@param content string
---@return table, string
function M.parse_frontmatter(content)
  content = content or ""
  local fm = {}
  local body = content

  local lines = vim.split(content, "\n")
  if #lines > 0 and lines[1]:match("^%s*%-%-%-%s*$") then
    local i = 2
    local block = {}
    local closed = false
    while i <= #lines do
      if lines[i]:match("^%s*%-%-%-%s*$") then
        if i + 1 <= #lines then
          body = table.concat(vim.list_slice(lines, i + 1, #lines), "\n")
        else
          body = ""
        end
        closed = true
        break
      end
      block[#block + 1] = lines[i]
      i = i + 1
    end

    if closed then
      local list_key = nil
      local function unquote(s)
        s = s:gsub('^"(.*)"$', "%1")
        s = s:gsub("^'(.*)'$", "%1")
        return s
      end
      for _, line in ipairs(block) do
        local key, val = line:match("^%s*([%w_%-]+)%s*:%s*(.-)%s*$")
        if key and val ~= "" then
          fm[key] = unquote(val)
          list_key = nil
        elseif key then
          fm[key] = {}
          list_key = key
        elseif list_key then
          local item = line:match("^%s*%-%s*(.-)%s*$")
          if item then
            local list = fm[list_key]
            if type(list) ~= "table" then
              list = {}
              fm[list_key] = list
            end
            list[#list + 1] = unquote(item)
          end
        end
      end
    end
  end

  return fm, body
end

---@param v any
---@return boolean
local function is_truthy(v)
  if type(v) == "boolean" then
    return v
  end
  if type(v) == "string" then
    local s = v:lower()
    return s == "true" or s == "yes" or s == "1" or s == "on"
  end
  return v ~= nil and v ~= false
end

--- Normalize a frontmatter value to a string list (handles scalar strings,
--- comma-separated strings, and YAML lists).
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
  if type(v) == "string" then
    local out = {}
    for item in v:gmatch("[^,]+") do
      item = item:match("^%s*(.-)%s*$")
      if item ~= "" then
        out[#out + 1] = item
      end
    end
    return out
  end
  return {}
end

--- Convert a glob to a Lua pattern anchored to the whole path. `**` matches
--- across `/` segments, `*` matches within a segment, `?` matches one char.
---@param glob string
---@return string
local function glob_to_pattern(glob)
  glob = glob or ""
  local out = {}
  local i = 1
  local n = #glob
  while i <= n do
    local c = glob:sub(i, i)
    if c == "*" then
      if glob:sub(i, i + 1) == "**" then
        out[#out + 1] = ".*"
        i = i + 2
      else
        out[#out + 1] = "[^/]*"
        i = i + 1
      end
    elseif c == "?" then
      out[#out + 1] = "[^/]"
      i = i + 1
    else
      out[#out + 1] = c:gsub("([%^%$%(%)%%%.%[%]%+%-])", "%%%1")
      i = i + 1
    end
  end
  return "^" .. table.concat(out) .. "$"
end

--- True when any glob in `globs` matches `path` (full path or its basename).
---@param globs string[]
---@param path string
---@return boolean
function M.matches_globs(globs, path)
  if not globs or #globs == 0 then
    return false
  end
  path = tostring(path):gsub("\\", "/")
  local base = path:match("([^/]+)$") or path
  for _, g in ipairs(globs) do
    local pat = glob_to_pattern(g)
    if path:match(pat) or base:match(pat) then
      return true
    end
  end
  return false
end

--- Full path of the active buffer, normalized to forward slashes ("" when none).
---@return string
function M.active_file()
  return vim.fn.expand("%:p"):gsub("\\", "/")
end

---@class AgentRuleEntry
---@field path string
---@field label string
---@field content string rule body (frontmatter stripped)
---@field description string|nil
---@field globs string[]
---@field always boolean whether to inject the full body

--- Aggregate every rule source into a list of entries, in injection order
--- (project root files, then project rules dir, then user rules dir).
---@param root string
---@param rules table
---@return AgentRuleEntry[]
function M.aggregate(root, rules)
  rules = rules or {}
  local out = {}

  local function add_file(path, label)
    local content = read_file(path)
    if not content or content == "" then
      return
    end
    local fm, body = M.parse_frontmatter(content)
    if body == "" then
      return
    end
    local always = true
    if fm.alwaysApply ~= nil then
      always = is_truthy(fm.alwaysApply)
    elseif fm.type ~= nil and fm.type ~= "" then
      always = tostring(fm.type):lower() == "always"
    end
    out[#out + 1] = {
      path = path,
      label = label,
      content = body,
      description = fm.description or fm.desc,
      globs = normalize_list(fm.globs or fm.glob),
      always = always,
    }
  end

  -- 1. Project-root instruction files (most specific, injected first).
  local filenames = rules.filenames or { "AGENTS.md", "CLAUDE.md" }
  for _, f in ipairs(filenames) do
    add_file(root .. "/" .. f, f)
  end

  -- 2. Project .agent_core/rules/*.mdc|md.
  local project_dir = root .. "/" .. (rules.project_rules_dir or ".agent_core/rules")
  if vim.fn.isdirectory(project_dir) == 1 then
    for _, p in ipairs(rule_files(project_dir)) do
      local rel = p:gsub("^" .. vim.pesc(root) .. "/", "")
      add_file(p, rel)
    end
  end

  -- 3. User-level <data>/agent_core/rules/*.mdc|md.
  local user_dir = vim.fn.expand(rules.user_rules_dir or (vim.fn.stdpath("data") .. "/agent_core/rules"))
  if user_dir ~= "" and vim.fn.isdirectory(user_dir) == 1 then
    for _, p in ipairs(rule_files(user_dir)) do
      add_file(p, p:gsub("^" .. vim.pesc(user_dir) .. "/", "user/"))
    end
  end

  return out
end

--- Build the aggregated rules block. Empty string when no rule files exist or
--- rules are disabled.
---@return string
function M.get_rules_prompt()
  local cfg = require("agent_core").config
  local rules = cfg.rules or {}
  if rules.enabled == false then
    return ""
  end

  local root = require("agent_core.indexer").root()
  local entries = M.aggregate(root, rules)
  if #entries == 0 then
    return ""
  end

  local auto_globs = rules.auto_attach_globs ~= false
  local active = M.active_file()

  local chunks = {}
  for _, e in ipairs(entries) do
    local heading = "### " .. e.label
    if e.description and e.description ~= "" then
      heading = heading .. " — " .. e.description
    end
    if #e.globs > 0 then
      heading = heading .. "\nApplies to: " .. table.concat(e.globs, ", ")
    end

    local attach
    if not e.always then
      attach = "on-demand"
    elseif #e.globs > 0 and auto_globs then
      attach = M.matches_globs(e.globs, active) and "full" or "on-demand"
    else
      attach = "full"
    end

    if attach == "full" then
      chunks[#chunks + 1] = heading .. "\n\n" .. e.content
    else
      chunks[#chunks + 1] = heading
        .. "\n\n(On-demand rule: request its full content with the `read_rule` tool if it applies to the current task.)"
    end
  end

  local content = "## Project & user rules\n\n" .. table.concat(chunks, "\n\n")
  local max = rules.prompt_max_chars or 8000
  if #content > max then
    content = content:sub(1, max) .. "\n\n[... rules truncated ...]"
  end
  return content
end

--- Read a rule's full body by name (label or file basename).
---@param name string
---@return string|nil, string|nil
function M.read(name)
  if not name or name == "" then
    return nil, "rule name required"
  end
  local cfg = require("agent_core").config
  local rules = cfg.rules or {}
  local root = require("agent_core.indexer").root()
  for _, e in ipairs(M.aggregate(root, rules)) do
    local base = e.path:match("([^/\\]+)$") or e.path
    if e.label == name or base == name then
      return e.content, nil
    end
  end
  return nil, "no rule named '" .. tostring(name) .. "'"
end

---@type AgentTool
local read_rule = {
  name = "read_rule",
  description = "Read a rule's full body by name. Use when an on-demand rule listed in the rules block applies to the current task.",
  param = {
    type = "table",
    fields = {
      { name = "name", description = "Rule label or file basename (e.g. 'security.mdc').", type = "string" },
    },
    required = { "name" },
    usage = {
      name = "Rule name",
    },
  },
  returns = {
    { name = "result", description = "The full rule body.", type = "string" },
    { name = "error", description = "Error message if the rule was not found.", type = "string", optional = true },
  },
}
---@type AgentToolFunc<{ name: string }>
function read_rule.func(input, opts)
  if not opts.on_complete then
    return nil, "on_complete not provided"
  end
  local body, err = M.read(input.name)
  if err then
    opts.on_complete(nil, err)
    return
  end
  opts.on_complete(body, nil)
end

function M.read_rule_tool()
  return read_rule
end

return M
