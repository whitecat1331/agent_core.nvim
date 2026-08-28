---@mod tests.indexer_spec Unit tests for agent_core.indexer pure helpers.

local h = require("tests.harness")
local Indexer = require("agent_core.indexer")

h.describe("indexer", function()
  h.it("language_counts counts and sorts descending", function()
    local files = { "a.go", "b.go", "c.py", "d.go", "e.py", "f.py", "g.py" }
    local langs = Indexer.language_counts(files)
    h.equals(2, #langs)
    h.equals("Python", langs[1].lang)
    h.equals(4, langs[1].n)
    h.equals("Go", langs[2].lang)
    h.equals(3, langs[2].n)
  end)

  h.it("language_counts returns empty for no known extensions", function()
    h.equals(0, #Indexer.language_counts({ "file.unknown" }))
    h.equals(0, #Indexer.language_counts({}))
  end)

  h.it("root_for resolves the active project root", function()
    local root = Indexer.root_for(vim.fn.getcwd())
    h.truthy(root ~= nil and root ~= "", "root should not be empty")
  end)

  h.it("summary_for returns a non-empty summary on this repo", function()
    local summary = Indexer.summary_for(Indexer.root())
    h.truthy(summary ~= nil and summary ~= "", "summary should not be empty")
  end)
end)
