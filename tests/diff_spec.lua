---@mod tests.diff_spec Unit tests for agent_core.diff (pure helpers).

local h = require("tests.harness")
local Diff = require("agent_core.diff")

h.describe("diff", function()
  h.it("compute_hunks returns a list of hunks", function()
    local hunks = Diff.compute_hunks({ "a", "b", "c" }, { "a", "x", "c" })
    h.equals("table", type(hunks))
    h.truthy(#hunks >= 1, "at least one hunk")
    h.truthy(hunks[1].start_a ~= nil, "hunk has start_a")
    h.truthy(hunks[1].count_a ~= nil, "hunk has count_a")
  end)

  h.it("compute_hunks handles identical inputs", function()
    h.equals(0, #Diff.compute_hunks({ "a", "b" }, { "a", "b" }))
  end)

  h.it("merge accepts all hunks to equal the new lines", function()
    local old = { "a", "b", "c" }
    local new = { "a", "x", "c" }
    local hunks = Diff.compute_hunks(old, new)
    local accepted = {}
    for i = 1, #hunks do
      accepted[#accepted + 1] = i
    end
    h.same(new, Diff.merge(old, new, hunks, accepted))
  end)

  h.it("merge rejects all hunks to equal the old lines", function()
    local old = { "a", "b", "c" }
    local new = { "a", "x", "c" }
    local hunks = Diff.compute_hunks(old, new)
    h.same(old, Diff.merge(old, new, hunks, {}))
  end)

  h.it("merge handles pure insertion and deletion", function()
    local old = { "a", "c" }
    local new = { "a", "b", "c" }
    local hunks = Diff.compute_hunks(old, new)
    local all = {}
    for i = 1, #hunks do
      all[#all + 1] = i
    end
    h.same(new, Diff.merge(old, new, hunks, all))
    h.same(old, Diff.merge(old, new, hunks, {}))
  end)

  h.it("toggle adds then removes an index", function()
    h.same({ 1 }, Diff.toggle({}, 1))
    h.same({}, Diff.toggle({ 1 }, 1))
  end)

  h.it("render marks hunk headers and maps a line to a hunk", function()
    local old = { "a", "b", "c" }
    local new = { "a", "x", "c" }
    local hunks = Diff.compute_hunks(old, new)
    local lines, map = Diff.render(old, new, hunks, { 1 })
    h.truthy(#lines > 0, "renders lines")
    local has_header = false
    for _, l in ipairs(lines) do
      if l:find("hunk 1", 1, true) then
        has_header = true
      end
    end
    h.truthy(has_header, "has a hunk 1 header")
    local mapped = false
    for _, idx in pairs(map) do
      if idx == 1 then
        mapped = true
      end
    end
    h.truthy(mapped, "a display line maps to hunk 1")
  end)

  h.it("render shows ACCEPT when a hunk is accepted", function()
    local old = { "a", "b" }
    local new = { "a", "x" }
    local hunks = Diff.compute_hunks(old, new)
    local lines = Diff.render(old, new, hunks, { 1 })
    h.matches("%[ACCEPT%]", table.concat(lines, "\n"))
  end)
end)
