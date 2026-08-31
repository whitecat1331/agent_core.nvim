---@mod tests.coordinator_spec Unit tests for agent_core.coordinator.

local h = require("tests.harness")
local Coordinator = require("agent_core.coordinator")

h.describe("coordinator.build_prompt", function()
  h.it("includes mode and profile recommendations", function()
    local prompt = Coordinator.build_prompt(
      { to = "agent", reason = "implement" },
      { to = "Claude", reason = "architecture" }
    )
    h.truthy(prompt:find("mode -> agent", 1, true), "mode recommendation present")
    h.truthy(prompt:find("profile -> Claude", 1, true), "profile recommendation present")
  end)

  h.it("omits absent recommendations", function()
    local prompt = Coordinator.build_prompt({ to = "agent", reason = "x" }, nil)
    h.truthy(prompt:find("mode -> agent", 1, true), "mode recommendation present")
    h.falsy(prompt:find("profile"))
  end)
end)

h.describe("coordinator.present", function()
  h.it("invokes apply for the chosen combined option", function()
    local applied = {}
    local saved_ui_select = vim.ui.select
    vim.ui.select = function(items, opts, cb)
      cb(items[1])
    end
    Coordinator.present({
      mode = {
        to = "agent",
        reason = "x",
        apply = function()
          applied.mode = true
        end,
      },
      profile = {
        to = "Claude",
        reason = "y",
        apply = function()
          applied.profile = true
        end,
      },
    })
    h.truthy(applied.mode, "mode apply should run")
    h.truthy(applied.profile, "profile apply should run")
    vim.ui.select = saved_ui_select
  end)

  h.it("presents a single mode decision", function()
    local chosen
    local saved_ui_select = vim.ui.select
    vim.ui.select = function(items, opts, cb)
      chosen = items
      cb(nil)
    end
    Coordinator.present({ mode = { to = "agent", reason = "x", apply = function() end } })
    h.truthy(chosen, "options should be presented")
    h.equals(2, #chosen)
    vim.ui.select = saved_ui_select
  end)
end)

h.describe("coordinator.evaluate", function()
  h.it("merges mode + profile recommendations into one present", function()
    local Recommend = require("agent_core.recommend")
    local AutoSwitch = require("agent_core.autoswitch")
    local saved_classify_r = Recommend.classify
    local saved_classify_a = AutoSwitch.classify
    local saved_schedule = vim.schedule
    local saved_ui_select = vim.ui.select

    Recommend.classify = function(request, cb)
      cb({ to = "agent", reason = "x", apply = function() end })
    end
    AutoSwitch.classify = function(request, cb)
      cb({ to = "Claude", reason = "y", apply = function() end })
    end
    vim.schedule = function(fn)
      fn()
    end
    local selected
    vim.ui.select = function(items, opts, cb)
      selected = { items = items, prompt = opts.prompt }
      cb(nil)
    end

    Coordinator.evaluate("implement x")

    h.truthy(selected, "present should be reached")
    h.truthy(selected.prompt:find("mode -> agent", 1, true), "mode recommendation present")
    h.truthy(selected.prompt:find("profile -> Claude", 1, true), "profile recommendation present")

    Recommend.classify = saved_classify_r
    AutoSwitch.classify = saved_classify_a
    vim.schedule = saved_schedule
    vim.ui.select = saved_ui_select
  end)
end)
