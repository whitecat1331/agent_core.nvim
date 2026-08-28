---@mod tests.slugify_spec Unit tests for slugify helpers across modules.

local h = require("tests.harness")
local Checkpoint = require("agent_core.checkpoint")
local Plan = require("agent_core.plan")
local Debug = require("agent_core.debug")
local McpIndex = require("agent_core.mcp_index")

h.describe("slugify", function()
  h.it("checkpoint/debug/plan slugify agree and normalize", function()
    local input = "  Hello, World!  "
    local a = Checkpoint.slugify(input)
    local b = Plan.slugify(input)
    local c = Debug.slugify(input)
    h.equals(a, b)
    h.equals(b, c)
    h.equals("hello-world", a)
  end)

  h.it("slugify collapses runs and strips leading/trailing dashes", function()
    h.equals("a-b", Checkpoint.slugify("a---b"))
    h.equals("a-b", Checkpoint.slugify("---a-b---"))
  end)

  h.it("slugify falls back for empty input", function()
    h.equals("checkpoint", Checkpoint.slugify(""))
    h.equals("plan", Plan.slugify("   "))
    h.equals("session", Debug.slugify("!!!"))
  end)

  h.it("mcp_index.slug_for returns a semnav-prefixed slug", function()
    local slug = McpIndex.slug_for("/home/user/My Project")
    h.matches("^semnav%-", slug)
    h.truthy(slug:find("my-project", 1, true), "slug should include a normalized name")
  end)

  h.it("mcp_index.slug_for is deterministic", function()
    h.equals(McpIndex.slug_for("/a/b"), McpIndex.slug_for("/a/b"))
  end)
end)
