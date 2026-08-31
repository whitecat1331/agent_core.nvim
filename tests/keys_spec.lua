---@mod tests.keys_spec Unit tests for agent_core.keys backend + JSON fallback.

local h = require("tests.harness")
local Keys = require("agent_core.keys")

local function restore_backend(saved)
  Keys.set_backend_for_test(saved == "json" and nil or saved)
end

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

  h.it("cmd with bang removes a stored key for a named profile", function()
    local saved_backend = Keys.backend()
    Keys.set_backend_for_test(nil) -- force json
    local original_path = Keys.path()
    local tmp = vim.fn.tempname()
    Keys.set_path(tmp)

    Keys.set("Claude", "sk-secret")
    h.equals("sk-secret", Keys.get("Claude"))

    Keys.cmd(true, "Claude")
    h.equals(nil, Keys.get("Claude"), "bang removes the stored key")

    Keys.set_path(original_path)
    Keys.set_backend_for_test(saved_backend)
  end)
end)

h.describe("keys keychain command builders", function()
  h.it("builds the macOS security delete argv", function()
    local saved = Keys.backend()
    Keys.set_backend_for_test("keychain")
    h.same(
      { "security", "delete-generic-password", "-a", "deepseek", "-s", "agent_core.nvim" },
      Keys.keychain_delete_command("deepseek")
    )
    restore_backend(saved)
  end)

  h.it("builds the Linux secret-tool delete argv", function()
    local saved = Keys.backend()
    Keys.set_backend_for_test("libsecret")
    h.same(
      { "secret-tool", "clear", "service", "agent_core.nvim", "account", "deepseek" },
      Keys.keychain_delete_command("deepseek")
    )
    restore_backend(saved)
  end)

  h.it("builds macOS security get/set argv", function()
    local saved = Keys.backend()
    Keys.set_backend_for_test("keychain")
    h.same(
      { "security", "find-generic-password", "-a", "p", "-s", "agent_core.nvim", "-w" },
      Keys.keychain_get_command("p")
    )
    h.same(
      { "security", "add-generic-password", "-a", "p", "-s", "agent_core.nvim", "-w", "k", "-U" },
      Keys.keychain_set_command("p", "k")
    )
    restore_backend(saved)
  end)

  h.it("builds Linux secret-tool get/set argv", function()
    local saved = Keys.backend()
    Keys.set_backend_for_test("libsecret")
    h.same({ "secret-tool", "lookup", "service", "agent_core.nvim", "account", "p" }, Keys.keychain_get_command("p"))
    h.same(
      { "secret-tool", "store", "--label=agent_core.nvim/p", "service", "agent_core.nvim", "account", "p" },
      Keys.keychain_set_command("p", "k")
    )
    restore_backend(saved)
  end)
end)
