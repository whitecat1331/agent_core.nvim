---@mod tests.session_edits_spec Unit tests for agent_core.session_edits.

local h = require("tests.harness")
local SE = require("agent_core.session_edits")

--- Point the journal at a fresh temp dir so tests never touch the real data dir.
---@return string dir
local function isolate()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  SE.config = { enabled = true, dir = dir }
  return dir
end

h.describe("session_edits", function()
  h.it("capture/discard deletes a file that did not previously exist", function()
    local dir = isolate()
    local path = dir .. "/new.txt"
    SE.capture("s1", 1, "write_to_file", path)
    vim.fn.writefile({ "hello" }, path, "b")

    h.equals(1, SE.discard("s1"))
    h.equals(0, vim.fn.filereadable(path), "created file removed on discard")
  end)

  h.it("capture/discard restores an overwritten file to its before-bytes", function()
    local dir = isolate()
    local path = dir .. "/existing.txt"
    vim.fn.writefile({ "original" }, path, "b")

    SE.capture("s1", 1, "write_to_file", path)
    vim.fn.writefile({ "changed" }, path, "b")

    h.equals(1, SE.discard("s1"))
    h.same({ "original" }, vim.fn.readfile(path, "b"))
  end)

  h.it("keep advances the baseline so discard only reverts later turns", function()
    local dir = isolate()
    local a = dir .. "/a.txt"
    local b = dir .. "/b.txt"

    SE.capture("s1", 1, "write_to_file", a)
    vim.fn.writefile({ "a" }, a, "b")
    SE.keep("s1")

    SE.capture("s1", 2, "write_to_file", b)
    vim.fn.writefile({ "b" }, b, "b")

    h.equals(1, SE.discard("s1"))
    h.equals(1, vim.fn.filereadable(a), "kept turn survives discard")
    h.equals(0, vim.fn.filereadable(b), "un-kept turn reverted")
  end)

  h.it("reverses multiple edits to the same file in LIFO order", function()
    local dir = isolate()
    local path = dir .. "/f.txt"
    vim.fn.writefile({ "v0" }, path, "b")

    SE.capture("s1", 1, "str_replace", path)
    vim.fn.writefile({ "v1" }, path, "b")
    SE.capture("s1", 2, "str_replace", path)
    vim.fn.writefile({ "v2" }, path, "b")

    h.equals(2, SE.discard("s1"))
    h.same({ "v0" }, vim.fn.readfile(path, "b"))
  end)

  h.it("discard on an empty journal is a no-op", function()
    isolate()
    h.equals(0, SE.discard("nonexistent"))
    h.equals(0, SE.pending_count("nonexistent"))
    h.equals(true, SE.keep("nonexistent"))
  end)

  h.it("pending_count reflects un-kept turns", function()
    local dir = isolate()
    SE.capture("s1", 1, "write_to_file", dir .. "/a.txt")
    vim.fn.writefile({ "a" }, dir .. "/a.txt", "b")
    SE.capture("s1", 2, "write_to_file", dir .. "/b.txt")
    vim.fn.writefile({ "b" }, dir .. "/b.txt", "b")
    h.equals(2, SE.pending_count("s1"))

    SE.keep("s1")
    h.equals(0, SE.pending_count("s1"))

    SE.capture("s1", 3, "write_to_file", dir .. "/c.txt")
    vim.fn.writefile({ "c" }, dir .. "/c.txt", "b")
    h.equals(1, SE.pending_count("s1"))
  end)

  h.it("capture is a no-op when disabled", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    SE.config = { enabled = false, dir = dir }
    h.equals(false, SE.capture("s1", 1, "write_to_file", dir .. "/a.txt"))
    h.equals(0, SE.pending_count("s1"))
  end)
end)
