---@mod tests.github_spec Unit tests for agent_core.github.

local h = require("tests.harness")
local Github = require("agent_core.github")

h.describe("github.github_tool", function()
  h.it("exposes the expected tool shape", function()
    local tool = Github.github_tool()
    h.equals("github", tool.name)
    h.truthy(type(tool.description) == "string" and #tool.description > 0, "description present")
    h.truthy(type(tool.func) == "function", "func present")
    h.equals("action", tool.param.required[1])
  end)

  h.it("rejects a missing on_complete", function()
    local tool = Github.github_tool()
    local r, err = tool.func({}, {})
    h.equals(nil, r)
    h.truthy(err and err:find("on_complete", 1, true), "reports missing on_complete")
  end)

  h.it("requires an action", function()
    local tool = Github.github_tool()
    local r, err = tool.func({}, { on_complete = function() end })
    h.equals(nil, r)
    h.truthy(err and err:find("action is required", 1, true), "reports action required")
  end)
end)
