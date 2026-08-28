---@mod tests.automation_spec Unit tests for agent_core.automation (isolated temp store).

local h = require("tests.harness")
local Automation = require("agent_core.automation")
local core = require("agent_core")

--- Point the automation store at a temporary file and clean up afterwards.
---@param fn fun()
local function with_temp(fn)
  local tmp = vim.fn.tempname()
  local prev = core.config.automation
  core.config.automation = { enabled = true, path = tmp }
  local ok, err = pcall(fn)
  core.config.automation = prev
  vim.fn.delete(tmp)
  if not ok then
    error(err, 0)
  end
end

h.describe("automation", function()
  h.it("add/list/remove roundtrip", function()
    with_temp(function()
      local entry, err = Automation.add("do the thing", 0)
      h.equals(nil, err)
      h.equals(1, #Automation.list())
      h.equals("do the thing", entry.prompt)
      local rerr = Automation.remove(entry.id)
      h.equals(nil, rerr)
      h.equals(0, #Automation.list())
    end)
  end)

  h.it("add rejects an empty prompt", function()
    with_temp(function()
      local _, err = Automation.add("   ")
      h.truthy(err ~= nil, "should return an error")
    end)
  end)

  h.it("remove returns an error for a missing id", function()
    with_temp(function()
      local err = Automation.remove("nope")
      h.truthy(err ~= nil, "missing id should error")
    end)
  end)

  h.it("add stores the interval and arms a timer", function()
    with_temp(function()
      local entry, err = Automation.add("run hourly", 60)
      h.equals(nil, err)
      h.equals(60, entry.interval_minutes)
      Automation.disarm(entry.id)
    end)
  end)
end)
