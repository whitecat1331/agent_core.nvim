---@mod tests.commands_spec Unit tests for agent_core.commands.

local h = require("tests.harness")
local Commands = require("agent_core.commands")
local core = require("agent_core")

--- Write a .cmd.md file at path and return it.
---@param dir string
---@param name string
---@param lines string[]
---@return string
local function write_command(dir, name, lines)
  local p = dir .. "/" .. name .. ".cmd.md"
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile(lines, p)
  return p
end

--- Temporarily point the commands config at temp project/user dirs.
---@param fn fun(proj: string, user: string)
local function with_command_dirs(fn)
  local prev = core.config.commands
  local proj = vim.fn.tempname()
  local user = vim.fn.tempname()
  core.config.commands = { enabled = true, project_dir = proj, user_dir = user, prompt_max_chars = 3000 }
  local ok, err = pcall(fn, proj, user)
  core.config.commands = prev
  vim.fn.delete(proj, "rf")
  vim.fn.delete(user, "rf")
  if not ok then
    error(err, 0)
  end
end

h.describe("commands", function()
  h.it("parse_command extracts frontmatter, argv list, and trust default", function()
    local dir = vim.fn.tempname()
    local path = write_command(dir, "run-tests", {
      "---",
      "name: run-tests",
      "description: Run the test suite",
      "argv:",
      "  - pytest",
      "  - -q",
      '  - "{{pattern}}"',
      "args:",
      "  - pattern",
      "required:",
      "  - pattern",
      "---",
      "",
      "longer usage notes",
    })
    local c = Commands.parse_command(path, "project")
    h.equals("run-tests", c.name)
    h.equals("Run the test suite", c.description)
    h.equals("safe", c.trust)
    h.equals("project", c.scope)
    h.same({ "pytest", "-q", "{{pattern}}" }, c.argv)
    h.same({ "pattern" }, c.args)
    h.same({ "pattern" }, c.required)
    h.truthy(c.body:find("longer usage notes", 1, true), "body should follow the fence")
    vim.fn.delete(dir, "rf")
  end)

  h.it("parse_command honors trust: dangerous", function()
    local dir = vim.fn.tempname()
    local path = write_command(dir, "reset-db", {
      "---",
      "name: reset-db",
      "trust: dangerous",
      "argv:",
      "  - dropdb",
      "---",
      "",
      "body",
    })
    local c = Commands.parse_command(path, "project")
    h.equals("dangerous", c.trust)
    h.equals(false, Commands.is_safe(c))
    vim.fn.delete(dir, "rf")
  end)

  h.it("parse_command falls back to the file basename when name is absent", function()
    local dir = vim.fn.tempname()
    local path = write_command(dir, "lint", { "---", "argv:", "  - ruff", "---", "body" })
    local c = Commands.parse_command(path, "user")
    h.equals("lint", c.name)
    h.equals("user", c.scope)
    vim.fn.delete(dir, "rf")
  end)

  h.it("parse_command returns nil for an unreadable or argv-less file", function()
    h.equals(nil, Commands.parse_command(vim.fn.tempname() .. "/missing.cmd.md", "project"))
    local dir = vim.fn.tempname()
    local path = write_command(dir, "empty", { "---", "name: empty", "---", "no argv" })
    h.equals(nil, Commands.parse_command(path, "project"))
    vim.fn.delete(dir, "rf")
  end)

  h.it("discover finds project + user commands and sorts by name", function()
    with_command_dirs(function(proj, user)
      write_command(proj, "b-deploy", { "---", "name: b-deploy", "argv:", "  - deploy", "---", "body" })
      write_command(user, "a-lint", { "---", "name: a-lint", "argv:", "  - lint", "---", "body" })
      local cmds = Commands.discover()
      h.equals(2, #cmds)
      h.equals("a-lint", cmds[1].name)
      h.equals("user", cmds[1].scope)
      h.equals("b-deploy", cmds[2].name)
      h.equals("project", cmds[2].scope)
    end)
  end)

  h.it("find returns the matching command or nil", function()
    with_command_dirs(function(proj)
      write_command(proj, "deploy", { "---", "name: deploy", "argv:", "  - deploy", "---", "body" })
      h.truthy(Commands.find("deploy") ~= nil, "deploy should be found")
      h.equals(nil, Commands.find("nope"))
    end)
  end)

  h.it("interpolate substitutes placeholders", function()
    local argv, err = Commands.interpolate({ "pytest", "-q", "{{pattern}}" }, { pattern = "test_x.py" })
    h.equals(nil, err)
    h.same({ "pytest", "-q", "test_x.py" }, argv)
  end)

  h.it("interpolate errors on a missing placeholder value", function()
    local argv, err = Commands.interpolate({ "pytest", "{{pattern}}" }, {})
    h.equals(nil, argv)
    h.truthy(err ~= nil, "missing placeholder should error")
  end)

  h.it("validate enforces required args", function()
    local cmd = { name = "x", required = { "pattern" } }
    h.equals(false, (Commands.validate(cmd, {})))
    local ok, err = Commands.validate(cmd, { pattern = "a" })
    h.equals(true, ok)
    h.equals(nil, err)
  end)

  h.it("get_commands_prompt includes metadata but not the body", function()
    with_command_dirs(function(proj)
      write_command(proj, "deploy", {
        "---",
        "name: deploy",
        "description: Ship it",
        "argv:",
        "  - deploy",
        "---",
        "",
        "SECRET BODY",
      })
      local prompt = Commands.get_commands_prompt()
      h.truthy(prompt:find("deploy", 1, true), "name present")
      h.truthy(prompt:find("Ship it", 1, true), "description present")
      h.falsy(prompt:find("SECRET BODY", 1, true), "body must not be injected")
    end)
  end)

  h.it("get_commands_prompt is empty when no commands exist", function()
    with_command_dirs(function()
      h.equals("", Commands.get_commands_prompt())
    end)
  end)

  h.it("run_command_tool exposes the run_command tool", function()
    local tool = Commands.run_command_tool()
    h.equals("run_command", tool.name)
    h.equals("function", type(tool.func))
  end)
end)
