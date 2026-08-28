---@mod tests.memory_spec Unit tests for agent_core.memory (isolated temp store).

local h = require("tests.harness")

local Memory = require("agent_core.memory")
local Config = require("agent_core").config

--- Point the memory store at a temporary file and clean it up afterwards.
---@param fn fun(tmp_path: string)
local function with_temp_memory(fn)
  local tmp = vim.fn.tempname()
  local orig = Config.memory and Config.memory.path
  Config.memory = Config.memory or {}
  Config.memory.path = tmp
  local ok, err = pcall(fn, tmp)
  vim.fn.delete(tmp)
  if orig then
    Config.memory.path = orig
  else
    Config.memory.path = nil
  end
  if not ok then
    error(err, 0)
  end
end

h.describe("memory", function()
  h.it("remember/recall/forget roundtrip", function()
    with_temp_memory(function()
      h.equals(nil, Memory.remember("topic", "value one"))
      h.equals("value one", Memory.recall("topic"))
      h.equals(nil, Memory.forget("topic"))
      h.equals(nil, Memory.recall("topic"))
    end)
  end)

  h.it("remember rejects empty keys", function()
    with_temp_memory(function()
      local err = Memory.remember("   ", "value")
      h.truthy(err ~= nil, "should return an error string")
    end)
  end)

  h.it("forget of a missing key returns nil without error", function()
    with_temp_memory(function()
      h.equals(nil, Memory.forget("missing-key"))
    end)
  end)

  h.it("get_memory_prompt indexes keys but not values", function()
    with_temp_memory(function()
      Memory.remember("favorite color", "blue")
      local prompt = Memory.get_memory_prompt()
      h.truthy(prompt:find("favorite color", 1, true), "key should be listed")
      h.falsy(prompt:find("blue", 1, true), "value should NOT be in the index")
    end)
  end)
end)
