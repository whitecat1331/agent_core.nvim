---@mod tests.platform_spec Unit tests for agent_core.platform.

local h = require("tests.harness")
local P = require("agent_core.platform")

h.describe("platform", function()
  h.it("is_windows returns a boolean", function()
    local v = P.is_windows()
    h.equals("boolean", type(v))
  end)

  h.it("is_abs detects POSIX absolute paths", function()
    h.truthy(P.is_abs("/foo/bar"), "leading slash is absolute")
  end)

  h.it("is_abs detects home-relative paths", function()
    h.truthy(P.is_abs("~/foo"), "tilde is absolute")
  end)

  h.it("is_abs detects Windows drive paths", function()
    h.truthy(P.is_abs("C:/foo/bar"), "forward-slash drive")
    h.truthy(P.is_abs("C:\\foo\\bar"), "backslash drive")
  end)

  h.it("is_abs detects UNC paths", function()
    h.truthy(P.is_abs("\\\\server\\share"), "UNC path is absolute")
  end)

  h.it("is_abs rejects relative, empty, and nil", function()
    h.falsy(P.is_abs("foo/bar"), "relative path")
    h.falsy(P.is_abs(""), "empty string")
    h.falsy(P.is_abs(nil), "nil")
  end)

  h.it("resolve_bin passes through absolute paths", function()
    h.equals("/usr/bin/curl", P.resolve_bin("/usr/bin/curl"))
    h.equals("C:\\tools\\curl.exe", P.resolve_bin("C:\\tools\\curl.exe"))
  end)

  h.it("resolve_bin returns empty for empty input", function()
    h.equals("", P.resolve_bin(""))
    h.equals("", P.resolve_bin(nil))
  end)

  h.it("resolve_bin returns the name when not found on PATH", function()
    local r = P.resolve_bin("definitely-not-a-real-binary-xyz")
    h.equals("definitely-not-a-real-binary-xyz", r)
  end)

  h.it("join concatenates with forward slashes", function()
    h.equals("a/b", P.join("a", "b"))
    h.equals("a/b/c", P.join("a", "b", "c"))
  end)

  h.it("join normalizes backslashes", function()
    h.equals("a/b", P.join("a\\b"))
  end)

  h.it("join drops empty parts", function()
    h.equals("a/b", P.join("", "a", "", "b", nil))
  end)

  h.it("shell_and matches the platform", function()
    local expected = P.is_windows() and ";" or "&&"
    h.equals(expected, P.shell_and())
  end)

  h.it("os_hint returns a non-empty string", function()
    local hint = P.os_hint()
    h.equals("string", type(hint))
    h.truthy(#hint > 0, "os_hint should not be empty")
  end)

  h.it("events exposes caret-related autocmd names", function()
    h.equals("CursorMoved", P.events.caret_moved)
    h.equals("CursorMovedI", P.events.caret_moved_i)
    h.equals("InsertLeave", P.events.insert_leave)
    h.equals("ModeChanged", P.events.mode_changed)
  end)

  h.it("get_caret returns a zero-based row and byte column", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello", "world" })
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      width = 20,
      height = 3,
      row = 0,
      col = 0,
    })
    vim.api.nvim_win_set_cursor(win, { 1, 1 })
    local row, col = P.get_caret(win)
    h.equals(0, row)
    h.equals(1, col)
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  h.it("set_caret moves the caret to a one-based position", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello", "world" })
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      width = 20,
      height = 3,
      row = 0,
      col = 0,
    })
    P.set_caret(win, 2, 1)
    local pos = vim.api.nvim_win_get_cursor(win)
    h.equals(2, pos[1])
    h.equals(1, pos[2])
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
