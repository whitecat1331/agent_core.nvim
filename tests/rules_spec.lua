---@mod tests.rules_spec Unit tests for agent_core.rules frontmatter + aggregation.

local h = require("tests.harness")
local Rules = require("agent_core.rules")
local Indexer = require("agent_core.indexer")
local core = require("agent_core")

h.describe("rules", function()
  h.it("parse_frontmatter extracts description, globs, and alwaysApply", function()
    local content = '---\ndescription: Security rules\nglobs: "**/*.go"\nalwaysApply: true\n---\n\n# Body\n'
    local fm, body = Rules.parse_frontmatter(content)
    h.equals("Security rules", fm.description)
    h.equals("**/*.go", fm.globs)
    h.equals("true", fm.alwaysApply)
    h.truthy(body:find("# Body", 1, true), "body should follow the fence")
  end)

  h.it("parse_frontmatter returns empty fm and full body without frontmatter", function()
    local content = "# Just a heading\ncontent"
    local fm, body = Rules.parse_frontmatter(content)
    h.equals(0, #vim.tbl_keys(fm))
    h.equals(content, body)
  end)

  h.it("parse_frontmatter parses YAML list globs", function()
    local content = '---\nglobs:\n  - "**/*.go"\n  - "**/*.py"\n---\nbody\n'
    local fm, _ = Rules.parse_frontmatter(content)
    h.equals(2, #fm.globs)
    h.equals("**/*.go", fm.globs[1])
    h.equals("**/*.py", fm.globs[2])
  end)

  h.it("aggregate honors alwaysApply: false as on-demand", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/.agent_core/rules", "p")
    vim.fn.writefile(
      { "---", "description: On demand", "alwaysApply: false", "---", "", "secret body" },
      dir .. "/.agent_core/rules/on_demand.mdc"
    )
    local entries = Rules.aggregate(dir, {
      filenames = {},
      project_rules_dir = ".agent_core/rules",
      user_rules_dir = dir .. "/none",
    })
    h.equals(1, #entries)
    h.equals(false, entries[1].always)
    h.equals("On demand", entries[1].description)
    h.truthy(entries[1].content:find("secret body", 1, true), "body should be stripped of frontmatter")
    vim.fn.delete(dir, "rf")
  end)

  h.it("aggregate includes root instruction files from filenames", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "root rule" }, dir .. "/CLAUDE.md")
    local entries = Rules.aggregate(dir, {
      filenames = { "CLAUDE.md" },
      project_rules_dir = ".agent_core/rules",
      user_rules_dir = dir .. "/none",
    })
    h.equals(1, #entries)
    h.equals("CLAUDE.md", entries[1].label)
    h.equals(true, entries[1].always)
    vim.fn.delete(dir, "rf")
  end)

  h.it("matches_globs matches full path and basename", function()
    h.equals(true, Rules.matches_globs({ "**/*.go" }, "/home/u/proj/main.go"))
    h.equals(true, Rules.matches_globs({ "*.go" }, "/home/u/proj/main.go"))
    h.equals(false, Rules.matches_globs({ "*.py" }, "/home/u/proj/main.go"))
    h.equals(false, Rules.matches_globs({}, "/home/u/proj/main.go"))
  end)

  h.it("matches_globs handles ? single-char wildcard", function()
    h.equals(true, Rules.matches_globs({ "main.?" }, "main.c"))
    h.equals(false, Rules.matches_globs({ "main.?" }, "main.go"))
  end)

  h.it("read returns a rule body by label or basename", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/.agent_core/rules", "p")
    vim.fn.writefile({ "---", "description: Sec", "---", "rule body" }, dir .. "/.agent_core/rules/security.mdc")
    local saved_cfg = core.config.rules
    core.config.rules =
      { enabled = true, filenames = {}, project_rules_dir = ".agent_core/rules", user_rules_dir = dir .. "/none" }
    local saved_root = Indexer.root
    Indexer.root = function()
      return dir
    end
    local body, err = Rules.read("security.mdc")
    h.equals(nil, err)
    h.equals("rule body", body)
    local _, err2 = Rules.read("nope")
    h.truthy(err2 ~= nil, "missing rule should error")
    Indexer.root = saved_root
    core.config.rules = saved_cfg
    vim.fn.delete(dir, "rf")
  end)

  h.it("read_rule_tool exposes the read_rule avante tool", function()
    local tool = Rules.read_rule_tool()
    h.equals("read_rule", tool.name)
    h.equals("function", type(tool.func))
  end)
end)
