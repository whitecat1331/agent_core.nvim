---@mod tests.runtime_ui_spec Unit tests for the Agents Window grid + render layers.

local h = require("tests.harness")
local Grid = require("agent_core.runtime.ui.grid")
local Render = require("agent_core.runtime.ui.render")
local Highlights = require("agent_core.runtime.ui.highlights")

h.describe("runtime.ui.grid dimensions", function()
  h.it("a single pane fills a 1x1 grid", function()
    local cols, rows = Grid.dimensions(1, 80, 24)
    h.equals(1, cols)
    h.equals(1, rows)
  end)

  h.it("two panes in a wide container go side by side", function()
    local cols, rows = Grid.dimensions(2, 160, 40)
    h.equals(2, cols)
    h.equals(1, rows)
  end)

  h.it("four panes form a 2x2 grid", function()
    local cols, rows = Grid.dimensions(4, 80, 40)
    h.equals(2, cols)
    h.equals(2, rows)
  end)

  h.it("never returns more columns than panes", function()
    local cols = Grid.dimensions(3, 200, 24)
    h.truthy(cols <= 3, "cols should not exceed pane count")
  end)
end)

h.describe("runtime.ui.grid layout", function()
  h.it("produces one geometry entry per pane with positive cells", function()
    local layout = Grid.layout(5, 100, 30)
    h.equals(5, #layout)
    for _, g in ipairs(layout) do
      h.truthy(g.width > 0, "width should be positive")
      h.truthy(g.height > 0, "height should be positive")
    end
  end)

  h.it("assigns each pane a distinct cell", function()
    local layout = Grid.layout(6, 120, 30)
    local seen = {}
    for _, g in ipairs(layout) do
      local key = g.row .. "," .. g.col
      h.falsy(seen[key], "cell " .. key .. " should be unique")
      seen[key] = true
    end
  end)

  h.it("cells never overflow the container", function()
    local width, height = 80, 24
    local cols, rows = Grid.dimensions(6, width, height)
    local layout = Grid.layout(6, width, height)
    for _, g in ipairs(layout) do
      h.truthy((g.col + 1) * g.width <= width + 1, "col span should fit")
      h.truthy((g.row + 1) * g.height <= height + 1, "row span should fit")
    end
    h.truthy(cols >= 1 and rows >= 1)
  end)
end)

h.describe("runtime.ui.grid focus", function()
  h.it("next_index wraps at the end", function()
    h.equals(2, Grid.next_index(1, 3))
    h.equals(3, Grid.next_index(2, 3))
    h.equals(1, Grid.next_index(3, 3))
    h.equals(1, Grid.next_index(nil, 3))
  end)

  h.it("prev_index wraps at the start", function()
    h.equals(1, Grid.prev_index(2, 3))
    h.equals(3, Grid.prev_index(1, 3))
    h.equals(3, Grid.prev_index(nil, 3))
  end)

  h.it("cell maps a linear index to row/col", function()
    local row, col = Grid.cell(5, 3)
    h.equals(1, row)
    h.equals(1, col)
  end)
end)

h.describe("runtime.ui.render", function()
  h.it("role_prefix maps roles to friendly labels", function()
    h.equals("You", Render.role_prefix("user"))
    h.equals("Agent", Render.role_prefix("assistant"))
    h.equals("Tool", Render.role_prefix("tool"))
    h.equals("System", Render.role_prefix("system"))
  end)

  h.it("lines normalizes newlines and strips ANSI", function()
    local out = Render.lines("a\r\nb\27[31mC\27[0m")
    h.equals("a", out[1])
    h.equals("bC", out[2])
  end)

  h.it("content_text extracts text from string and parts array", function()
    h.equals("hi", Render.content_text("hi"))
    h.equals("ab", Render.content_text({ { type = "text", text = "a" }, { type = "text", text = "b" } }))
    h.equals("", Render.content_text({ { type = "image", source = {} } }))
  end)

  h.it("message_lines prefixes a role heading", function()
    local lines = Render.message_lines("assistant", "hello")
    h.equals("## Agent", lines[1])
    h.equals("hello", lines[2])
  end)

  h.it("model_indicator includes provider, model, and status", function()
    h.equals("deepseek · deepseek-chat", Render.model_indicator("deepseek", "deepseek-chat", nil))
    h.equals("claude · sonnet [running]", Render.model_indicator("claude", "sonnet", "running"))
    h.equals("?", Render.model_indicator(nil, nil, nil))
  end)

  h.it("pane_header marks focus", function()
    local focused = Render.pane_header("Task", "deepseek · deepseek-chat", true)
    local idle = Render.pane_header("Task", "deepseek · deepseek-chat", false)
    h.truthy(focused:find("▣", 1, true) ~= nil, "focused header should use the filled marker")
    h.truthy(idle:find("▢", 1, true) ~= nil, "idle header should use the hollow marker")
  end)
end)

h.describe("runtime.ui.highlights", function()
  h.it("maps roles and chrome to group names", function()
    h.equals("AgentRoleUser", Highlights.group("user"))
    h.equals("AgentRoleAssistant", Highlights.group("assistant"))
    h.equals("AgentPaneHeader", Highlights.group("header"))
    h.equals("AgentComposerPill", Highlights.group("composer_pill"))
    h.equals(nil, Highlights.group("nope"))
  end)
end)

h.describe("runtime.ui manager streaming", function()
  h.it("streams chunks into a pane buffer and flushes the partial line", function()
    local UI = require("agent_core.runtime.ui")
    local session = {
      id = "s1",
      title = "T",
      provider = "deepseek",
      model = "deepseek-chat",
      status = "idle",
      on_text = nil,
    }
    local pane = UI.new_pane(session)
    h.truthy(pane.bufnr > 0, "pane should own a buffer")
    h.truthy(type(session.on_text) == "function", "on_text should be wired")

    UI.stream_chunk(pane, "hello")
    UI.stream_chunk(pane, " worl")
    UI.stream_chunk(pane, "d\nsecond line")
    UI.end_turn(pane)

    local lines = vim.api.nvim_buf_get_lines(pane.bufnr, 0, -1, false)
    h.equals("## Agent", lines[1])
    h.equals("hello world", lines[2])
    h.equals("second line", lines[3])

    -- Cleanup the scratch buffer so it does not leak across tests.
    vim.api.nvim_buf_delete(pane.bufnr, { force = true })
  end)

  h.it("begin_stream marks a turn and end_stream resets it", function()
    local UI = require("agent_core.runtime.ui")
    local session = { provider = "deepseek", model = "deepseek-chat", status = "idle", on_text = nil }
    local pane = UI.new_pane(session)
    UI.begin_stream(pane)
    h.truthy(pane.stream_started, "stream should be started")
    UI.end_stream(pane)
    h.falsy(pane.stream_started, "stream should be reset")
    vim.api.nvim_buf_delete(pane.bufnr, { force = true })
  end)
end)

h.describe("runtime.ui.render tool blocks", function()
  h.it("message_lines wraps tool output in fold markers", function()
    local lines = Render.message_lines("tool", "some result", "bash")
    h.equals("## Tool · bash", lines[1])
    h.equals("{{{", lines[2])
    h.equals("some result", lines[3])
    h.equals("}}}", lines[4])
  end)

  h.it("message_lines falls back to a generic tool name", function()
    local lines = Render.message_lines("tool", "x")
    h.equals("## Tool · tool", lines[1])
  end)
end)

h.describe("runtime.ui.composer", function()
  h.it("normalize strips trailing newlines and whitespace", function()
    local C = require("agent_core.runtime.ui.composer")
    h.equals("hello", C.normalize("hello\r\n\r\n"))
    h.equals("a\nb", C.normalize("a\nb\n  "))
    h.equals("", C.normalize("   "))
  end)

  h.it("menu_items includes slash commands and mentions", function()
    local C = require("agent_core.runtime.ui.composer")
    local items = C.menu_items()
    local tokens = {}
    for _, it in ipairs(items) do
      tokens[it.token] = true
    end
    h.truthy(tokens["/plan"] ~= nil, "slash commands should be listed")
    h.truthy(tokens["@file"] ~= nil, "@file mention should be listed")
    h.truthy(tokens["@codebase"] ~= nil, "@codebase mention should be listed")
  end)

  h.it("mode_label resolves labels from mode names", function()
    local C = require("agent_core.runtime.ui.composer")
    h.equals("Plan", C.mode_label("plan"))
    h.equals("Debug", C.mode_label("debug"))
    h.equals("Multi-task", C.mode_label("multitask"))
  end)

  h.it("model_label formats provider and model", function()
    local C = require("agent_core.runtime.ui.composer")
    h.equals("deepseek · deepseek-chat", C.model_label("deepseek", "deepseek-chat"))
    h.equals("Model", C.model_label("", ""))
  end)

  h.it("footer_labels appends dropdown markers", function()
    local C = require("agent_core.runtime.ui.composer")
    local labels = C.footer_labels("Agent", "claude · sonnet")
    h.equals("Agent ▾", labels.mode)
    h.equals("claude · sonnet ▾", labels.model)
  end)

  h.it("footer_statusline embeds click handlers and pill highlights", function()
    local C = require("agent_core.runtime.ui.composer")
    local sl = C.footer_statusline({ mode_label = "Plan", model_label = "ollama · llama3" })
    h.truthy(sl:find("agent_core_composer_click_mode", 1, true) ~= nil, "mode click handler")
    h.truthy(sl:find("agent_core_composer_click_model", 1, true) ~= nil, "model click handler")
    h.truthy(sl:find("Plan ▾", 1, true) ~= nil, "mode pill text")
    h.truthy(sl:find("ollama · llama3 ▾", 1, true) ~= nil, "model pill text")
    h.truthy(sl:find("AgentComposerPill", 1, true) ~= nil, "pill highlight group")
  end)
end)

h.describe("runtime.ui.chatlist", function()
  h.it("rows returns a header and empty map when no chats exist", function()
    local CL = require("agent_core.runtime.ui.chatlist")
    local empty_dir = vim.fn.tempname() .. "/no_chats"
    vim.fn.mkdir(empty_dir, "p")
    local data = CL.rows("", { history_dir = empty_dir })
    h.truthy(type(data.lines) == "table", "lines should be a table")
    h.equals(0, #data.map)
    h.equals("# Agents", data.lines[1])
    vim.fn.delete(empty_dir, "rf")
  end)

  h.it("time_group buckets calendar days", function()
    local CL = require("agent_core.runtime.ui.chatlist")
    local now = os.time({ year = 2026, month = 8, day = 31, hour = 12 })
    local today = os.time({ year = 2026, month = 8, day = 31, hour = 8 })
    local yesterday = os.time({ year = 2026, month = 8, day = 30, hour = 8 })
    h.equals("Today", CL.time_group(today, now))
    h.equals("Yesterday", CL.time_group(yesterday, now))
    h.equals("Older", CL.time_group(0, now))
  end)

  h.it("status_icon marks running vs idle", function()
    local CL = require("agent_core.runtime.ui.chatlist")
    h.equals("●", CL.status_icon("running"))
    h.equals("✓", CL.status_icon("idle"))
  end)
end)
