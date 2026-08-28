---@mod tests.notepad_spec Unit tests for agent_core.notepad pure helpers.

local h = require("tests.harness")
local Notepad = require("agent_core.notepad")

h.describe("notepad", function()
  h.it("title_for returns the first markdown heading", function()
    h.equals("My Title", Notepad.title_for("note", "# My Title\n\nbody"))
  end)

  h.it("title_for falls back to the filename", function()
    h.equals("note", Notepad.title_for("note", "no heading here"))
  end)

  h.it("preview_for returns the first non-heading, non-empty line", function()
    h.equals("first line", Notepad.preview_for("# Title\n\nfirst line\nsecond"))
  end)

  h.it("preview_for returns empty when only a heading exists", function()
    h.equals("", Notepad.preview_for("# Only heading"))
  end)

  h.it("preview_for returns empty for blank content", function()
    h.equals("", Notepad.preview_for(""))
  end)
end)
