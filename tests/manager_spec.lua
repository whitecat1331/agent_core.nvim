---@mod tests.manager_spec Unit tests for agent_core.manager.

local h = require("tests.harness")
local Manager = require("agent_core.manager")
local Registry = require("agent_core.registry")
local core = require("agent_core")

h.describe("manager.rows", function()
  h.it("renders profile, mode, policy, and endpoint sections with an aligned map", function()
    local saved = vim.deepcopy(core.config.registry)
    core.config.registry = vim.tbl_deep_extend("force", {}, saved or {}, {
      setup_path = vim.fn.tempname(),
      ollama_endpoint = "http://127.0.0.1:11434",
    })

    local data = Manager.rows()
    h.truthy(#data.lines > 0, "lines present")

    -- Map keys are 1-based line indices within bounds.
    local types = {}
    for row, action in pairs(data.map) do
      h.truthy(row >= 1 and row <= #data.lines, "map row within bounds")
      h.truthy(type(data.lines[row]) == "string", "mapped line is a string")
      types[action.type] = true
    end

    h.truthy(types.profile, "profile rows present")
    h.truthy(types.mode, "mode rows present")
    h.truthy(types.policy, "policy row present")
    h.truthy(types.endpoint, "endpoint rows present (loopback always included)")

    core.config.registry = saved
  end)
end)

h.describe("manager actions", function()
  h.it("toggle_profile flips the persisted enabled override", function()
    local saved = vim.deepcopy(core.config.registry)
    core.config.registry = { setup_path = vim.fn.tempname() }

    local entry = { name = "Claude", provider = "claude", model = "x", api_key_name = "ANTHROPIC_API_KEY" }
    local before = Registry.entry_enabled(entry)

    Manager.toggle_profile("Claude")
    h.not_equals(before, Registry.entry_enabled(entry), "override toggled")

    Manager.toggle_profile("Claude")
    h.equals(before, Registry.entry_enabled(entry), "override toggled back")

    core.config.registry = saved
  end)

  h.it("toggle_profile is a no-op for an unknown profile", function()
    local saved = vim.deepcopy(core.config.registry)
    core.config.registry = { setup_path = vim.fn.tempname() }
    Manager.toggle_profile("does-not-exist")
    -- Reaching here without error is the assertion.
    h.equals(true, true)
    core.config.registry = saved
  end)

  h.it("header returns the keymap legend", function()
    local legend = table.concat(Manager.header(), "\n")
    h.truthy(#Manager.header() > 0, "header lines present")
    h.truthy(legend:find("pick model", 1, true) ~= nil, "model picker legend present")
    h.truthy(legend:find("clear model override", 1, true) ~= nil, "clear-model legend present")
  end)

  h.it("open is a headless no-op", function()
    -- No UI attached in headless mode; open() must not create a window or error.
    Manager.open()
    h.equals(true, true)
  end)
end)
