---@mod tests.reset_spec Unit tests for agent_core.reset + Keys.reset.

local h = require("tests.harness")
local Reset = require("agent_core.reset")
local Keys = require("agent_core.keys")
local runtime = require("agent_core.runtime")

local function force_json_backend()
  local saved = Keys.backend()
  Keys.set_backend_for_test(nil)
  return saved
end

local function restore_backend(saved)
  Keys.set_backend_for_test(saved == "json" and nil or saved)
end

h.describe("reset targets", function()
  h.it("enumerates the key store and the data tree", function()
    local targets = Reset.targets()
    h.equals(2, #targets)
    h.equals(Keys.path(), targets[1])
    h.equals(vim.fn.stdpath("data") .. "/agent_core", targets[2])
  end)
end)

h.describe("keys.reset", function()
  h.it("clears the JSON store and deletes the file (json backend)", function()
    if Keys.backend() ~= "json" then
      return -- keychain active; the JSON path is only meaningful on json backends
    end

    local tmp = vim.fn.tempname()
    local original = vim.fn.stdpath("config") .. "/agent_keys.json"
    Keys.set_path(tmp)
    Keys.set("reset_profile", "secret")
    h.equals("secret", Keys.get("reset_profile"))

    Keys.reset()

    h.equals(nil, Keys.get("reset_profile"))
    h.equals(0, vim.fn.filereadable(tmp))

    -- Restore the default path so other specs are unaffected.
    Keys.set_path(original)
  end)

  h.it("reset_names lists JSON keys (minus underscore) plus default profiles", function()
    local saved = force_json_backend()
    local original = Keys.path()
    local tmp = vim.fn.tempname()
    Keys.set_path(tmp)

    Keys.set("deepseek", "x")
    Keys.set("_active", "deepseek")
    Keys.set("_active_mode", "agent")

    local names = Keys.reset_names()
    h.truthy(vim.tbl_contains(names, "deepseek"), "json key should be purged")
    h.falsy(vim.tbl_contains(names, "_active"), "underscore key should be skipped")
    h.falsy(vim.tbl_contains(names, "_active_mode"), "underscore key should be skipped")
    h.truthy(vim.tbl_contains(names, "Claude"), "default profile should be purged")

    vim.fn.delete(tmp)
    Keys.set_path(original)
    restore_backend(saved)
  end)
end)

h.describe("reset.clear", function()
  h.it("removes the data tree, key file, and resets in-memory state", function()
    local saved = force_json_backend()
    local original_path = Keys.path()
    local keyfile = vim.fn.tempname()
    Keys.set_path(keyfile)

    local data_root = vim.fn.tempname()
    vim.fn.mkdir(data_root, "p")
    Reset.set_data_dir(data_root)
    vim.fn.writefile({ "marker" }, data_root .. "/marker.txt")

    vim.g.agent_active_profile = "Claude"
    vim.g.agent_persona = "persona"
    vim.g.agent_mode = "agent"
    vim.g.agent_mode_prompt = "persona"
    runtime._sessions = { { id = "s1" } }
    runtime._active = 1

    Reset.clear()

    h.equals(0, vim.fn.isdirectory(data_root), "data tree should be removed")
    h.equals(0, vim.fn.filereadable(keyfile), "key file should be removed")
    h.equals(nil, vim.g.agent_active_profile)
    h.equals("", vim.g.agent_persona)
    h.equals(nil, vim.g.agent_mode)
    h.equals("", vim.g.agent_mode_prompt)
    h.equals(0, #runtime._sessions, "runtime sessions should be empty")
    h.equals(0, runtime._active)

    vim.g.agent_active_profile = nil
    vim.g.agent_persona = nil
    vim.g.agent_mode = nil
    vim.g.agent_mode_prompt = nil
    Reset.set_data_dir(nil)
    Keys.set_path(original_path)
    restore_backend(saved)
  end)

  h.it("does not remove a sibling .agent_core/ directory", function()
    local saved = force_json_backend()
    local original_path = Keys.path()
    local keyfile = vim.fn.tempname()
    Keys.set_path(keyfile)

    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local data_root = root .. "/data"
    vim.fn.mkdir(data_root, "p")
    Reset.set_data_dir(data_root)

    local sibling = root .. "/.agent_core"
    vim.fn.mkdir(sibling, "p")

    Reset.clear()

    h.equals(1, vim.fn.isdirectory(sibling), "sibling .agent_core should be untouched")

    vim.fn.delete(root, "rf")
    Reset.set_data_dir(nil)
    Keys.set_path(original_path)
    restore_backend(saved)
  end)

  h.it("clear_cmd(true) clears without prompting", function()
    local saved = force_json_backend()
    local original_path = Keys.path()
    local keyfile = vim.fn.tempname()
    Keys.set_path(keyfile)

    local data_root = vim.fn.tempname()
    vim.fn.mkdir(data_root, "p")
    Reset.set_data_dir(data_root)
    vim.fn.writefile({ "x" }, data_root .. "/x.txt")

    Reset.clear_cmd(true)

    h.equals(0, vim.fn.isdirectory(data_root), "data tree removed by bang path")

    Reset.set_data_dir(nil)
    Keys.set_path(original_path)
    restore_backend(saved)
  end)

  h.it("clear_cmd(false) aborts when the user declines", function()
    local saved = force_json_backend()
    local original_path = Keys.path()
    local keyfile = vim.fn.tempname()
    Keys.set_path(keyfile)

    local data_root = vim.fn.tempname()
    vim.fn.mkdir(data_root, "p")
    Reset.set_data_dir(data_root)
    vim.fn.writefile({ "x" }, data_root .. "/x.txt")
    vim.g.agent_active_profile = "Claude"

    local saved_confirm = vim.fn.confirm
    vim.fn.confirm = function()
      return 2 -- "No"
    end
    Reset.clear_cmd(false)
    vim.fn.confirm = saved_confirm

    h.equals(1, vim.fn.isdirectory(data_root), "data tree untouched on decline")
    h.equals("Claude", vim.g.agent_active_profile, "state untouched on decline")

    vim.g.agent_active_profile = nil
    vim.fn.delete(data_root, "rf")
    Reset.set_data_dir(nil)
    Keys.set_path(original_path)
    restore_backend(saved)
  end)
end)
