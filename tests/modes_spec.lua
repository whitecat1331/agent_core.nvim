---@mod tests.modes_spec Unit tests for agent_core.modes.

local h = require("tests.harness")
local Modes = require("agent_core.modes")
local core = require("agent_core")

h.describe("modes", function()
  h.it("exposes five modes", function()
    local modes = Modes.all()
    h.equals(5, #modes)
    local names = {}
    for _, m in ipairs(modes) do
      names[#names + 1] = m.name
    end
    h.contains(names, "ask")
    h.contains(names, "plan")
    h.contains(names, "debug")
    h.contains(names, "agent")
    h.contains(names, "multitask")
  end)

  h.it("find resolves a mode by name", function()
    local m = Modes.find("debug")
    h.truthy(m, "debug mode should exist")
    h.equals("debug", m.name)
    h.falsy(m.read_only, "debug is a write mode")
  end)

  h.it("find returns nil for unknown names", function()
    h.equals(nil, Modes.find("nonexistent"))
  end)

  h.it("WRITE_TOOLS includes mutating tools", function()
    h.contains(Modes.WRITE_TOOLS, "bash")
    h.contains(Modes.WRITE_TOOLS, "write_to_file")
    h.contains(Modes.WRITE_TOOLS, "run_agent")
  end)

  h.it("plan mode allow-lists its own plan tools", function()
    local plan = Modes.find("plan")
    h.truthy(plan.allow_tools, "plan mode has allow_tools")
    h.contains(plan.allow_tools, "create_plan")
    h.contains(plan.allow_tools, "update_plan")
  end)

  h.it("auto_approve is false for read-only modes", function()
    local ask = Modes.find("ask")
    h.equals(false, Modes.auto_approve(ask, { "bash", "grep" }))
  end)

  h.it("auto_approve filters destructive tools", function()
    local agent = Modes.find("agent")
    local allow = Modes.auto_approve(agent, { "grep", "bash", "read_file" })
    h.contains(allow, "grep")
    h.contains(allow, "read_file")
    h.falsy(vim.tbl_contains(allow, "bash"), "bash is destructive and should be excluded")
  end)

  h.it("auto_approve == all returns true", function()
    local m = vim.deepcopy(Modes.find("agent"))
    m.auto_approve = "all"
    h.equals(true, Modes.auto_approve(m, { "bash" }))
  end)

  h.it("get_mode_prompt is empty without an active mode", function()
    vim.g.agent_mode_prompt = nil
    h.equals("", Modes.get_mode_prompt())
  end)

  h.it("get_mode_prompt wraps a populated persona", function()
    vim.g.agent_mode = "debug"
    vim.g.agent_mode_prompt = "MODE: Debug"
    local out = Modes.get_mode_prompt()
    h.truthy(out:find("MODE: Debug", 1, true), "prompt should contain the persona")
    vim.g.agent_mode_prompt = nil
    vim.g.agent_mode = nil
  end)

  h.it("all merges config.modes.extra custom modes", function()
    local saved = core.config.modes
    core.config.modes = {
      extra = { { name = "reviewer", label = "Reviewer", read_only = true, system_prompt = "REVIEW" } },
    }
    local names = vim.tbl_map(function(m)
      return m.name
    end, Modes.all())
    h.contains(names, "ask")
    h.contains(names, "reviewer")
    core.config.modes = saved
  end)

  h.it("all returns a full replacement array when config.modes is an array", function()
    local saved = core.config.modes
    core.config.modes = { { name = "only", label = "Only", read_only = false } }
    h.equals(1, #Modes.all())
    h.equals("only", Modes.all()[1].name)
    core.config.modes = saved
  end)
end)
