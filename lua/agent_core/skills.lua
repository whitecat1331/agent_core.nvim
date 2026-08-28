---@mod agent_core.skills Discover and inject reusable skill procedures
---@brief [[
--- Discovers agent skills (self-contained procedures stored as SKILL.md files)
--- from the project (.agent_core/skills/<name>/SKILL.md) and the user
--- (<data>/agent_core/skills/<name>/SKILL.md), parses their YAML frontmatter
--- (name, description, argument-hint, user-invocable), and injects a compact
--- index (name + description + argument hint) into the system prompt via
--- get_skills_prompt(). The model reads a skill's full body on demand with the
--- `read_skill` tool, so only metadata is ever auto-injected.
---@brief ]]

local M = {}

M.config = {
  enabled = true,
  project_dir = ".agent_core/skills", -- project skills (committed alongside the repo)
  user_dir = nil, -- nil = <data>/agent_core/skills (user-global skills)
  prompt_max_chars = 4000,
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

--- Project skills directory (relative to the active root).
---@return string
function M.project_dir()
  local cfg = require("agent_core").config
  local sk = cfg.skills or {}
  if sk.project_dir and sk.project_dir ~= "" then
    return vim.fn.expand(sk.project_dir)
  end
  return require("agent_core.indexer").root() .. "/" .. (M.config.project_dir or ".agent_core/skills")
end

--- User skills directory.
---@return string
function M.user_dir()
  local cfg = require("agent_core").config
  local sk = cfg.skills or {}
  if sk.user_dir and sk.user_dir ~= "" then
    return vim.fn.expand(sk.user_dir)
  end
  return vim.fn.stdpath("data") .. "/agent_core/skills"
end

--- Normalize a frontmatter value to a string list (scalar, comma-separated, or
--- YAML list).
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

---@class AgentSkill
---@field name string
---@field description string|nil
---@field argument_hint string|nil
---@field user_invocable boolean|nil
---@field path string
---@field body string full SKILL.md body (frontmatter stripped)
---@field scope "project"|"user"

--- Parse a SKILL.md file into a skill entry, or nil when unreadable/empty.
---@param path string
---@param scope "project"|"user"
---@return AgentSkill|nil
function M.parse_skill(path, scope)
  local content = read_file(path)
  if not content or content == "" then
    return nil
  end
  local fm, body = require("agent_core.rules").parse_frontmatter(content)
  local name = fm.name
  if not name or name == "" then
    name = path:match("([^/\\]+)[/\\]SKILL%.md$") or path:match("([^/\\]+)%.md$") or path
  end
  return {
    name = name,
    description = fm.description or fm.desc,
    argument_hint = fm["argument-hint"] or fm.argument_hint,
    user_invocable = fm["user-invocable"] ~= nil and tostring(fm["user-invocable"]):lower() ~= "false",
    path = path,
    body = body,
    scope = scope,
  }
end

--- Discover every skill under the project + user skill directories.
---@return AgentSkill[]
function M.discover()
  local out = {}

  local function collect(dir, scope)
    if dir == "" or vim.fn.isdirectory(dir) ~= 1 then
      return
    end
    local files = vim.fn.glob(dir .. "/*/SKILL.md", false, true)
    table.sort(files)
    for _, p in ipairs(files) do
      local skill = M.parse_skill(p, scope)
      if skill then
        out[#out + 1] = skill
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

--- List discovered skills as { name, description, argument_hint, path, scope }.
---@return {name:string,description:string|nil,argument_hint:string|nil,path:string,scope:string}[]
function M.list()
  local out = {}
  for _, s in ipairs(M.discover()) do
    out[#out + 1] = {
      name = s.name,
      description = s.description,
      argument_hint = s.argument_hint,
      path = s.path,
      scope = s.scope,
    }
  end
  return out
end

--- Find a skill by name, or nil.
---@param name string
---@return AgentSkill|nil
function M.find(name)
  for _, s in ipairs(M.discover()) do
    if s.name == name then
      return s
    end
  end
  return nil
end

--- Build the compact skill index for the system prompt (metadata only). Empty
--- string when no skills exist or skills are disabled. Bounded by
--- config.skills.prompt_max_chars.
---@return string
function M.get_skills_prompt()
  local cfg = require("agent_core").config
  local sk = cfg.skills or {}
  if sk.enabled == false or (M.config.enabled == false and sk.enabled == nil) then
    return ""
  end

  local skills = M.discover()
  if #skills == 0 then
    return ""
  end

  local lines = {
    "## Skills",
    "",
    "Reusable procedures the user has saved. Reference one by name and read its",
    "full body with the `read_skill` tool when the task matches. Metadata only:",
    "",
  }
  for _, s in ipairs(skills) do
    local line = "- " .. s.name
    if s.description and s.description ~= "" then
      line = line .. " — " .. s.description
    end
    if s.argument_hint and s.argument_hint ~= "" then
      line = line .. " (args: " .. s.argument_hint .. ")"
    end
    lines[#lines + 1] = line
  end

  local content = table.concat(lines, "\n")
  local max = sk.prompt_max_chars or M.config.prompt_max_chars or 4000
  if #content > max then
    content = content:sub(1, max) .. "\n\n[... skills index truncated ...]"
  end
  return content
end

--- Read a skill's full body by name (used by the read_skill tool).
---@param name string
---@return string|nil, string|nil
function M.read(name)
  local skill = M.find(name)
  if not skill then
    return nil, "no skill named '" .. tostring(name) .. "'"
  end
  return skill.body, nil
end

--- Skills the user has explicitly marked `user-invocable: true`.
---@return AgentSkill[]
function M.invocable()
  local out = {}
  for _, s in ipairs(M.discover()) do
    if s.user_invocable == true then
      out[#out + 1] = s
    end
  end
  return out
end

--- Invoke a skill by name: return its body with the argument substituted into
--- `{{args}}` / `{arg}` placeholders.
---@param name string
---@param arg string|nil
---@return string|nil, string|nil
function M.invoke(name, arg)
  local skill = M.find(name)
  if not skill then
    return nil, "no skill named '" .. tostring(name) .. "'"
  end
  local body = skill.body or ""
  if arg and arg ~= "" then
    body = body:gsub("{{%s*args%s*}}", arg)
    body = body:gsub("{%s*arg%s*}", arg)
  end
  return body, nil
end

---@type AvanteLLMTool
local read_skill = {
  name = "read_skill",
  description = "Read a saved skill's full procedure by name. Use when a task matches a skill listed in the Skills index.",
  param = {
    type = "table",
    fields = {
      { name = "name", description = "Skill name from the Skills index.", type = "string" },
    },
    required = { "name" },
    usage = {
      name = "Skill name",
    },
  },
  returns = {
    { name = "result", description = "The full skill body.", type = "string" },
    { name = "error", description = "Error message if the skill was not found.", type = "string", optional = true },
  },
}
---@type AvanteLLMToolFunc<{ name: string }>
function read_skill.func(input, opts)
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

--- Present discovered skills in a scratch buffer (:AgentSkills).
function M.list_cmd()
  local skills = M.discover()
  local lines = { "# Agent skills", "" }
  if #skills == 0 then
    lines[#lines + 1] = "(none — add a SKILL.md under .agent_core/skills/<name>/ or <data>/agent_core/skills/<name>/)"
  else
    for _, s in ipairs(skills) do
      lines[#lines + 1] = string.format("## %s  (%s)", s.name, s.scope)
      if s.description and s.description ~= "" then
        lines[#lines + 1] = s.description
      end
      if s.argument_hint and s.argument_hint ~= "" then
        lines[#lines + 1] = "args: " .. s.argument_hint
      end
      lines[#lines + 1] = "path: " .. s.path
      lines[#lines + 1] = ""
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.api.nvim_open_win(buf, true, { split = "right" })
end

function M.read_skill_tool()
  return read_skill
end

---@type AvanteLLMTool
local run_skill = {
  name = "run_skill",
  description = "Run a user-invocable skill by name and return its procedure with the argument substituted. "
    .. "Use for skills the user has marked user-invocable.",
  param = {
    type = "table",
    fields = {
      { name = "name", description = "Skill name (must be user-invocable).", type = "string" },
      { name = "argument", description = "Optional argument to substitute into the skill's {{args}} placeholder.", type = "string", optional = true },
    },
    required = { "name" },
    usage = {
      name = "Skill name",
      argument = "Argument (optional)",
    },
  },
  returns = {
    { name = "result", description = "The skill body with the argument substituted.", type = "string" },
    { name = "error", description = "Error message if the skill was not found.", type = "string", optional = true },
  },
}
---@type AvanteLLMToolFunc<{ name: string, argument?: string }>
function run_skill.func(input, opts)
  if not opts.on_complete then
    return nil, "on_complete not provided"
  end
  local body, err = M.invoke(input.name, input.argument)
  if err then
    opts.on_complete(nil, err)
    return
  end
  opts.on_complete(body, nil)
end

function M.run_skill_tool()
  return run_skill
end

--- Backing for :AgentSkill: pick a user-invocable skill, collect its argument,
--- and show the invoked body in a scratch buffer for review/sending.
function M.invoke_cmd()
  local skills = M.invocable()
  if #skills == 0 then
    vim.notify("No user-invocable skills (add `user-invocable: true` to a SKILL.md frontmatter)", vim.log.levels.WARN)
    return
  end

  local function run(skill, arg)
    local body, err = M.invoke(skill.name, arg)
    if err then
      vim.notify("AgentSkill: " .. err, vim.log.levels.ERROR)
      return
    end
    local lines = { "# " .. skill.name, "" }
    for _, l in ipairs(vim.split(body, "\n")) do
      lines[#lines + 1] = l
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].modifiable = false
    vim.api.nvim_open_win(buf, true, { split = "right" })
  end

  local function pick_arg(skill)
    if skill.argument_hint and skill.argument_hint ~= "" then
      vim.ui.input({ prompt = "AgentSkill " .. skill.name .. " (" .. skill.argument_hint .. "): " }, function(input)
        if input == nil then
          return
        end
        run(skill, input)
      end)
    else
      run(skill, "")
    end
  end

  local ok, Snacks = pcall(require, "snacks.picker")
  if ok and type(Snacks) == "table" and type(Snacks.pick) == "function" then
    Snacks.pick({
      title = "Agent Skill",
      items = skills,
      layout = { preview = false },
      format = function(item)
        return { { item.name .. "  |  " .. (item.description or "") } }
      end,
      confirm = function(picker, item)
        picker:close()
        if item then
          pick_arg(item)
        end
      end,
    })
    return
  end

  local choices = vim.tbl_map(function(s)
    return s.name
  end, skills)
  vim.ui.select(choices, { prompt = "Agent skill" }, function(choice)
    for _, s in ipairs(skills) do
      if s.name == choice then
        pick_arg(s)
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
