---@mod tests.context_spec Unit tests for agent_core.context.

local h = require("tests.harness")
local Context = require("agent_core.context")

h.describe("context", function()
  h.it("format_diagnostics renders one-based line:col and message", function()
    local out = Context.format_diagnostics({ { lnum = 2, col = 4, message = "boom" } })
    h.truthy(out:find("L3:5 boom", 1, true), "formats one-based positions")
  end)

  h.it("format_diagnostics is empty for no diagnostics", function()
    h.equals("", Context.format_diagnostics({}))
  end)

  h.it("get_context_prompt is empty when disabled", function()
    local saved = Context.config.enabled
    Context.config.enabled = false
    h.equals("", Context.get_context_prompt())
    Context.config.enabled = saved
  end)

  h.it("get_context_prompt includes the buffer window", function()
    -- Use a scratch buffer + window so the shared current buffer is never
    -- mutated (and never left modified, which would make `+qa` exit E37).
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line one", "line two", "line three" })
    local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = 30,
      height = 3,
      row = 0,
      col = 0,
    })
    local saved = vim.deepcopy(Context.config)
    Context.config = vim.tbl_deep_extend("force", Context.config, {
      enabled = true,
      include_selection = false,
      include_diagnostics = false,
      include_buffer = true,
      max_lines = 200,
      max_chars = 6000,
    })
    local out = Context.get_context_prompt()
    h.truthy(out:find("Current context", 1, true), "has the header")
    h.truthy(out:find("line two", 1, true), "includes buffer lines")
    Context.config = saved
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
