---@mod tests.runtime_slash_spec Unit tests for owned slash commands + context variables.

local h = require("tests.harness")
local Slash = require("agent_core.runtime.slash")

h.describe("runtime.slash find_variables", function()
  h.it("finds hash and at variables with optional args", function()
    local vars = Slash.find_variables("explain #buffer and @file:src/main.lua and @lsp")
    h.equals(3, #vars)
    h.equals("buffer", vars[1].name)
    h.equals(nil, vars[1].arg)
    h.equals("file", vars[2].name)
    h.equals("src/main.lua", vars[2].arg)
    h.equals("lsp", vars[3].name)
  end)
end)

h.describe("runtime.slash expand", function()
  h.it("replaces variables via injected resolvers", function()
    local out, resolved = Slash.expand("fix #buffer", {
      buffer = function()
        return "local x = 1"
      end,
    })
    h.equals("fix local x = 1", out)
    h.equals(1, #resolved)
    h.equals("buffer", resolved[1].name)
  end)

  h.it("leaves unresolvable variables verbatim", function()
    local out = Slash.expand("fix #nope", {})
    h.equals("fix #nope", out)
  end)

  h.it("resolves longest-first so @file:arg is not clobbered by @file", function()
    local out = Slash.expand("read @file:a and @file:b", {
      file = function(arg)
        return "[" .. (arg or "") .. "]"
      end,
    })
    h.equals("read [a] and [b]", out)
  end)
end)

h.describe("runtime.slash parse + resolve", function()
  h.it("parses a leading slash command", function()
    local cmd = Slash.parse("/mode agent")
    h.equals("mode", cmd.command)
    h.equals("agent", cmd.args)
  end)

  h.it("returns nil for a plain prompt", function()
    h.equals(nil, Slash.parse("hello world"))
  end)

  h.it("resolves /mode to a mode action", function()
    local _, action = Slash.resolve("/mode debug", {})
    h.equals("mode", action.action)
    h.equals("debug", action.mode)
  end)

  h.it("resolves /plan with a prompt to a submit action", function()
    local _, action = Slash.resolve("/plan build the thing", {})
    h.equals("submit", action.action)
    h.equals("build the thing", action.text)
    h.equals("plan", action.mode)
  end)

  h.it("resolves /plan with no prompt to a mode action", function()
    local _, action = Slash.resolve("/plan", {})
    h.equals("mode", action.action)
    h.equals("plan", action.mode)
  end)

  h.it("resolves /profile to a profile action", function()
    local _, action = Slash.resolve("/profile Gemini", {})
    h.equals("profile", action.action)
    h.equals("Gemini", action.profile)
  end)

  h.it("resolves /workflow to a workflow action", function()
    local _, action = Slash.resolve("/workflow triage", {})
    h.equals("workflow", action.action)
    h.equals("triage", action.workflow)
  end)

  h.it("resolves /agent to a fresh-session submit action", function()
    local _, action = Slash.resolve("/agent do the thing", {})
    h.equals("submit", action.action)
    h.equals("do the thing", action.text)
    h.equals(true, action.new)
  end)

  h.it("lists registered commands", function()
    local cmds = Slash.list()
    h.truthy(#cmds >= 4)
  end)
end)
