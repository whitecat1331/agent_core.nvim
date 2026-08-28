---@mod tests.keys_spec Unit tests for agent_core.keys backend + JSON fallback.

local h = require("tests.harness")
local Keys = require("agent_core.keys")

h.describe("keys", function()
  h.it("backend returns a known backend name", function()
    local b = Keys.backend()
    h.truthy(vim.tbl_contains({ "json", "keychain", "libsecret", "credential-manager" }, b), b)
  end)

  h.it("path reports the JSON store path", function()
    h.truthy(Keys.path() ~= nil and Keys.path() ~= "", "path should not be empty")
  end)

  h.it("JSON fallback round-trips set/get/delete", function()
    if Keys.backend() ~= "json" then
      return -- keychain active; JSON path is covered in json-only environments
    end
    local tmp = vim.fn.tempname()
    Keys.set_path(tmp)
    Keys.set("test_profile", "secret-value")
    h.equals("secret-value", Keys.get("test_profile"))
    Keys.delete("test_profile")
    h.equals(nil, Keys.get("test_profile"))
    vim.fn.delete(tmp)
  end)
end)
