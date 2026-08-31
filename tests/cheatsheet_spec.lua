---@mod tests.cheatsheet_spec Unit tests for agent_core.cheatsheet.

local h = require("tests.harness")
local Cheatsheet = require("agent_core.cheatsheet")

h.describe("cheatsheet.matches_command", function()
  h.it("matches a plain command and is case-insensitive", function()
    h.truthy(Cheatsheet.matches_command("<cmd>AgentChat<cr>", "AgentChat"), "matches AgentChat")
    h.truthy(Cheatsheet.matches_command("<cmd>agentchat<cr>", "AgentChat"), "case-insensitive")
  end)

  h.it("does not false-match a longer command name", function()
    h.falsy(Cheatsheet.matches_command("<cmd>AgentModel<cr>", "AgentModelClear"), "AgentModel does not match AgentModelClear")
    h.falsy(Cheatsheet.matches_command("<cmd>AgentModelClear<cr>", "AgentModel"), "AgentModelClear does not match AgentModel")
  end)

  h.it("returns false for nil or non-matching rhs", function()
    h.falsy(Cheatsheet.matches_command(nil, "AgentChat"), "nil rhs")
    h.falsy(Cheatsheet.matches_command("<cmd>AgentNew<cr>", "AgentChat"), "different command")
  end)
end)

h.describe("cheatsheet.keymap_for", function()
  h.it("returns the lhs of a global normal-mode map whose rhs matches", function()
    local maps = {
      { lhs = "<leader>a ", rhs = "<cmd>AgentChat<cr>", buffer = 0 },
      { lhs = "<leader>aT", rhs = "<cmd>AgentNew<cr>", buffer = 0 },
    }
    h.equals("<leader>a ", Cheatsheet.keymap_for("AgentChat", maps), "lhs returned")
  end)

  h.it("returns nil for a buffer-local or function map", function()
    local maps = {
      { lhs = "q", rhs = "<cmd>AgentChat<cr>", buffer = 1 },
      { lhs = "<leader>a ", rhs = function() end, buffer = 0 },
    }
    h.falsy(Cheatsheet.keymap_for("AgentChat", maps), "buffer-local/function map skipped")
  end)

  h.it("returns nil when the command is unmapped", function()
    local maps = { { lhs = "<leader>aT", rhs = "<cmd>AgentNew<cr>", buffer = 0 } }
    h.falsy(Cheatsheet.keymap_for("AgentChat", maps), "no matching map")
  end)
end)

h.describe("cheatsheet.collect", function()
  h.it("builds a command-name -> lhs table from global maps", function()
    local maps = {
      { lhs = "<leader>a ", rhs = "<cmd>AgentChat<cr>", buffer = 0 },
      { lhs = "<leader>aT", rhs = "<cmd>AgentNew<cr>", buffer = 0 },
      { lhs = "q", rhs = "<cmd>AgentChat<cr>", buffer = 1 },
      { lhs = "<leader>x", rhs = "<cmd>NotAnAgent<cr>", buffer = 0 },
    }
    local out = Cheatsheet.collect(maps)
    h.equals("<leader>a ", out.AgentChat, "AgentChat lhs")
    h.equals("<leader>aT", out.AgentNew, "AgentNew lhs")
    h.falsy(out.AgentChat == "q", "buffer-local map ignored")
    h.falsy(out.NotAnAgent, "non-Agent command ignored")
  end)
end)

h.describe("cheatsheet.section_for", function()
  h.it("groups a known command", function()
    h.equals("Chat & sessions", Cheatsheet.section_for("AgentChat"), "AgentChat grouped")
  end)

  h.it("returns nil for an unknown name", function()
    h.falsy(Cheatsheet.section_for("AgentTotallyUnknown"), "unknown command ungrouped")
  end)
end)

h.describe("cheatsheet.render", function()
  h.it("renders a section heading and a command row with the key column", function()
    local commands = {
      { name = "AgentChat", desc = "Open the chat workspace" },
      { name = "AgentNew", desc = "Start a fresh chat session" },
    }
    local keymaps = { AgentChat = "<leader>a " }
    local data = Cheatsheet.render(commands, keymaps)
    h.truthy(#data.lines > 0, "lines present")

    local joined = table.concat(data.lines, "\n")
    h.matches("# Chat & sessions", joined, "section heading present")
    h.matches(":AgentChat", joined, "AgentChat row present")
    h.matches(":AgentNew", joined, "AgentNew row present")
  end)

  h.it("uses an em dash for an unmapped command", function()
    local commands = { { name = "AgentChat", desc = "Open the chat workspace" } }
    local data = Cheatsheet.render(commands, {})
    h.matches("—", table.concat(data.lines, "\n"), "unmapped placeholder present")
  end)

  h.it("buckets an ungrouped Agent* command under Other", function()
    local commands = { { name = "AgentTotallyUnknown", desc = nil } }
    local data = Cheatsheet.render(commands, {})
    h.matches("# Other", table.concat(data.lines, "\n"), "Other bucket present")
    h.matches(":AgentTotallyUnknown", table.concat(data.lines, "\n"), "orphan row present")
  end)
end)

h.describe("cheatsheet ui", function()
  h.it("open is a headless no-op", function()
    Cheatsheet.open()
    Cheatsheet.close()
    h.equals(true, true)
  end)

  h.it("header returns the legend", function()
    local lines = Cheatsheet.header()
    h.truthy(#lines > 0, "legend lines present")
    h.truthy(table.concat(lines, "\n"):find("refresh", 1, true) ~= nil, "refresh legend present")
  end)
end)
