---@mod tests.edits_spec Unit tests for agent_core.edits (pure helpers).

local h = require("tests.harness")
local Edits = require("agent_core.edits")

h.describe("edits", function()
  h.it("parse_edits parses a JSON edit array", function()
    local edits = Edits.parse_edits('[{"path":"a.lua","find":"foo","replace":"bar"}]')
    h.equals(1, #edits)
    h.equals("a.lua", edits[1].path)
    h.equals("foo", edits[1].find)
    h.equals("bar", edits[1].replace)
  end)

  h.it("parse_edits strips code fences", function()
    local edits = Edits.parse_edits('```json\n[{"path":"a","find":"x","replace":"y"}]\n```')
    h.equals(1, #edits)
  end)

  h.it("parse_edits returns nil for non-JSON", function()
    h.equals(nil, Edits.parse_edits("not json"))
    h.equals(nil, Edits.parse_edits(""))
  end)

  h.it("validate_path accepts relative paths", function()
    local ok, err = Edits.validate_path("src/main.lua")
    h.truthy(ok, err)
  end)

  h.it("validate_path rejects absolute paths and traversal", function()
    local ok, err = Edits.validate_path("/etc/passwd")
    h.falsy(ok)
    h.matches("absolute", err)
    ok, err = Edits.validate_path("../secret.lua")
    h.falsy(ok)
    h.matches("traversal", err)
  end)

  h.it("replace_first replaces only the first occurrence", function()
    h.equals("bob cat foo dog", Edits.replace_first("foo cat foo dog", "foo", "bob"))
  end)

  h.it("replace_first returns nil when not found", function()
    h.equals(nil, Edits.replace_first("hello", "zzz", "x"))
  end)

  h.it("unified_diff emits a path header and hunk markers", function()
    local text = Edits.unified_diff({ "a", "b", "c" }, { "a", "x", "c" }, "src/main.lua")
    h.matches("src/main.lua", text)
    h.matches("@@", text)
    h.matches("%-b", text)
    h.matches("%+x", text)
  end)
end)
