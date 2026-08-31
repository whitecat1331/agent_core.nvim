---@mod tests.pickers_spec Unit tests for agent_core.pickers.

local h = require("tests.harness")
local Pickers = require("agent_core.pickers")

h.describe("pickers.pick_profile", function()
  h.it("invokes the callback with the chosen profile", function()
    local Profiles = require("agent_core.profiles")
    local first = Profiles.all()[1]
    local chosen
    local saved_ui_select = vim.ui.select
    vim.ui.select = function(items, opts, cb)
      cb(first.name)
    end
    Pickers.pick_profile(function(p)
      chosen = p
    end)
    h.truthy(chosen, "profile should be chosen")
    h.equals(first.name, chosen.name)
    vim.ui.select = saved_ui_select
  end)
end)

h.describe("pickers.pick_mode", function()
  h.it("invokes the callback with the chosen mode", function()
    local Modes = require("agent_core.modes")
    local first = Modes.all()[1]
    local chosen
    local saved_ui_select = vim.ui.select
    vim.ui.select = function(items, opts, cb)
      cb(first.name)
    end
    Pickers.pick_mode(function(m)
      chosen = m
    end)
    h.truthy(chosen, "mode should be chosen")
    h.equals(first.name, chosen.name)
    vim.ui.select = saved_ui_select
  end)
end)
