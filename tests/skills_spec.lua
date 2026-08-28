---@mod tests.skills_spec Unit tests for agent_core.skills.

local h = require("tests.harness")
local Skills = require("agent_core.skills")
local core = require("agent_core")

--- Write a SKILL.md file at path and return it.
---@param dir string
---@param name string
---@param lines string[]
---@return string
local function write_skill(dir, name, lines)
  local p = dir .. "/" .. name .. "/SKILL.md"
  vim.fn.mkdir(dir .. "/" .. name, "p")
  vim.fn.writefile(lines, p)
  return p
end

--- Temporarily point the skills config at temp project/user dirs.
---@param fn fun(proj: string, user: string)
local function with_skill_dirs(fn)
  local prev = core.config.skills
  local proj = vim.fn.tempname()
  local user = vim.fn.tempname()
  core.config.skills = { enabled = true, project_dir = proj, user_dir = user, prompt_max_chars = 4000 }
  local ok, err = pcall(fn, proj, user)
  core.config.skills = prev
  vim.fn.delete(proj, "rf")
  vim.fn.delete(user, "rf")
  if not ok then
    error(err, 0)
  end
end

h.describe("skills", function()
  h.it("parse_skill extracts frontmatter metadata and strips the body", function()
    local dir = vim.fn.tempname()
    local path = write_skill(dir, "deploy", {
      "---",
      "name: deploy",
      "description: Deploy the service",
      "argument-hint: <env>",
      "user-invocable: true",
      "---",
      "",
      "# Steps",
      "1. run the deploy script",
    })
    local s = Skills.parse_skill(path, "project")
    h.equals("deploy", s.name)
    h.equals("Deploy the service", s.description)
    h.equals("<env>", s.argument_hint)
    h.equals(true, s.user_invocable)
    h.equals("project", s.scope)
    h.truthy(s.body:find("# Steps", 1, true), "body should follow the fence")
    h.falsy(s.body:find("description:", 1, true), "frontmatter should be stripped")
    vim.fn.delete(dir, "rf")
  end)

  h.it("parse_skill falls back to the directory name when name is absent", function()
    local dir = vim.fn.tempname()
    local path = write_skill(dir, "lint", { "# Just a body" })
    local s = Skills.parse_skill(path, "user")
    h.equals("lint", s.name)
    h.equals("user", s.scope)
    vim.fn.delete(dir, "rf")
  end)

  h.it("parse_skill returns nil for an unreadable path", function()
    h.equals(nil, Skills.parse_skill(vim.fn.tempname() .. "/missing/SKILL.md", "project"))
  end)

  h.it("discover finds project + user skills and sorts by name", function()
    with_skill_dirs(function(proj, user)
      write_skill(proj, "b-deploy", { "---", "name: b-deploy", "---", "", "body" })
      write_skill(user, "a-lint", { "---", "name: a-lint", "---", "", "body" })
      local skills = Skills.discover()
      h.equals(2, #skills)
      h.equals("a-lint", skills[1].name)
      h.equals("user", skills[1].scope)
      h.equals("b-deploy", skills[2].name)
      h.equals("project", skills[2].scope)
    end)
  end)

  h.it("find returns the matching skill or nil", function()
    with_skill_dirs(function(proj)
      write_skill(proj, "deploy", { "---", "name: deploy", "---", "run it" })
      local found = Skills.find("deploy")
      h.truthy(found ~= nil, "deploy should be found")
      h.equals("run it", found.body)
      h.equals(nil, Skills.find("nope"))
    end)
  end)

  h.it("read returns the full body or an error for a missing skill", function()
    with_skill_dirs(function(proj)
      write_skill(proj, "deploy", { "---", "name: deploy", "---", "run it" })
      local body, err = Skills.read("deploy")
      h.equals(nil, err)
      h.equals("run it", body)
      local _, err2 = Skills.read("nope")
      h.truthy(err2 ~= nil, "missing skill should error")
    end)
  end)

  h.it("get_skills_prompt includes metadata but not the body", function()
    with_skill_dirs(function(proj)
      write_skill(proj, "deploy", {
        "---",
        "name: deploy",
        "description: Ship it",
        "argument-hint: <env>",
        "---",
        "",
        "SECRET BODY",
      })
      local prompt = Skills.get_skills_prompt()
      h.truthy(prompt:find("deploy", 1, true), "name present")
      h.truthy(prompt:find("Ship it", 1, true), "description present")
      h.truthy(prompt:find("<env>", 1, true), "argument hint present")
      h.falsy(prompt:find("SECRET BODY", 1, true), "body must not be injected")
    end)
  end)

  h.it("get_skills_prompt is empty when no skills exist", function()
    with_skill_dirs(function()
      h.equals("", Skills.get_skills_prompt())
    end)
  end)

  h.it("list returns metadata-only entries", function()
    with_skill_dirs(function(proj)
      write_skill(proj, "deploy", { "---", "name: deploy", "description: D", "---", "", "body" })
      local items = Skills.list()
      h.equals(1, #items)
      h.equals("deploy", items[1].name)
      h.equals("D", items[1].description)
      h.equals("project", items[1].scope)
    end)
  end)

  h.it("read_skill_tool exposes the read_skill avante tool", function()
    local tool = Skills.read_skill_tool()
    h.equals("read_skill", tool.name)
    h.equals("function", type(tool.func))
  end)

  h.it("invocable filters to user-invocable skills", function()
    with_skill_dirs(function(proj)
      write_skill(proj, "deploy", { "---", "name: deploy", "user-invocable: true", "---", "body" })
      write_skill(proj, "internal", { "---", "name: internal", "---", "body" })
      local inv = Skills.invocable()
      h.equals(1, #inv)
      h.equals("deploy", inv[1].name)
    end)
  end)

  h.it("invoke substitutes the argument into placeholders", function()
    with_skill_dirs(function(proj)
      write_skill(proj, "deploy", { "---", "name: deploy", "user-invocable: true", "---", "deploy to {{args}}" })
      local body, err = Skills.invoke("deploy", "prod")
      h.equals(nil, err)
      h.equals("deploy to prod", body)
    end)
  end)

  h.it("invoke returns an error for a missing skill", function()
    local _, err = Skills.invoke("nope", nil)
    h.truthy(err ~= nil, "missing skill should error")
  end)

  h.it("run_skill_tool exposes the run_skill avante tool", function()
    h.equals("run_skill", Skills.run_skill_tool().name)
  end)
end)
