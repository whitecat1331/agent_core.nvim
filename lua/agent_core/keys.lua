---@mod agent_core.keys Local API-key store (keychain-first, 0600 JSON fallback).
---@brief [[
--- Stores API keys for profiles. Resolution order: the environment (os.getenv,
--- done by profiles.switch / runner) takes precedence; this store is the fallback.
--- When an OS keychain is available the secret is stored there — macOS Keychain
--- (`security`), Linux libsecret (`secret-tool`), or Windows Credential Manager
--- (`cmdkey`). Windows `cmdkey` cannot read secrets back, so Windows stores in the
--- 0600 JSON file. Non-secret metadata (`_active` profile / `_active_mode`) always
--- lives in the JSON file. `M.backend()` reports which backend is active.
---@brief ]]

local M = {}

local SERVICE = "agent_core.nvim"

local path = vim.fn.stdpath("config") .. "/agent_keys.json"

--- Resolve the best available keychain backend at load time.
---@return string|nil "keychain" | "libsecret" | "credential-manager"
local function detect_backend()
  if vim.fn.has("mac") == 1 and vim.fn.exepath("security") ~= "" then
    return "keychain"
  end
  if vim.fn.has("win32") == 1 and vim.fn.exepath("cmdkey") ~= "" then
    -- cmdkey stores but cannot read secrets back; see M.get.
    return "credential-manager"
  end
  if vim.fn.exepath("secret-tool") ~= "" then
    return "libsecret"
  end
  return nil
end

local backend = detect_backend()

--- Override the JSON store path (used by tests).
---@param p string
function M.set_path(p)
  path = p
end

--- The current JSON store path.
---@return string
function M.path()
  return path
end

--- The active secret backend: "keychain", "libsecret", "credential-manager",
--- or "json" when no OS keychain is available.
---@return string
function M.backend()
  return backend or "json"
end

--- Run a command synchronously; return (stdout, ok).
---@param cmd string[]|string
---@param input string|nil
---@return string, boolean
local function run(cmd, input)
  local out
  if input ~= nil then
    out = vim.fn.system(cmd, input)
  else
    out = vim.fn.system(cmd)
  end
  return out, (vim.v.shell_error == 0)
end

--- Fetch a secret from the OS keychain, or nil when unavailable/missing.
---@param name string
---@return string|nil
local function keychain_get(name)
  if backend == "keychain" then
    local out, ok = run({ "security", "find-generic-password", "-a", name, "-s", SERVICE, "-w" })
    if ok and out ~= "" then
      return out:gsub("[\r\n]+$", "")
    end
  elseif backend == "libsecret" then
    local out, ok = run({ "secret-tool", "lookup", "service", SERVICE, "account", name })
    if ok and out ~= "" then
      return out:gsub("[\r\n]+$", "")
    end
  end
  return nil
end

--- Store a secret in the OS keychain. Returns true on success.
---@param name string
---@param key string
---@return boolean
local function keychain_set(name, key)
  if backend == "keychain" then
    run({ "security", "delete-generic-password", "-a", name, "-s", SERVICE })
    local _, ok = run({ "security", "add-generic-password", "-a", name, "-s", SERVICE, "-w", key, "-U" })
    return ok
  elseif backend == "libsecret" then
    local _, ok = run({
      "secret-tool",
      "store",
      "--label=" .. SERVICE .. "/" .. name,
      "service",
      SERVICE,
      "account",
      name,
    }, key)
    return ok
  end
  return false
end

--- Delete a secret from the OS keychain.
---@param name string
---@return boolean
local function keychain_delete(name)
  if backend == "keychain" then
    local _, ok = run({ "security", "delete-generic-password", "-a", name, "-s", SERVICE })
    return ok
  elseif backend == "libsecret" then
    local _, ok = run({ "secret-tool", "clear", "service", SERVICE, "account", name })
    return ok
  end
  return false
end

local function read()
  local f = io.open(path, "r")
  if not f then
    return {}
  end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then
    return {}
  end
  return data
end

local function write(data)
  local f = io.open(path, "w")
  if not f then
    return
  end
  f:write(vim.json.encode(data))
  f:close()
  pcall(vim.fn.setfperm, path, "rw-------")
end

--- Get a secret: keychain first, then the JSON file.
---@param name string
---@return string|nil
function M.get(name)
  if backend == "keychain" or backend == "libsecret" then
    local v = keychain_get(name)
    if v ~= nil and v ~= "" then
      return v
    end
  end
  return read()[name]
end

--- Store a secret: keychain first (when readable back), else the JSON file.
---@param name string
---@param key string
function M.set(name, key)
  if backend == "keychain" or backend == "libsecret" then
    if keychain_set(name, key) then
      return
    end
  end
  local data = read()
  data[name] = key
  write(data)
end

--- Remove a stored secret from both backends.
---@param name string
function M.delete(name)
  if backend == "keychain" or backend == "libsecret" then
    keychain_delete(name)
  end
  local data = read()
  data[name] = nil
  write(data)
end

function M.get_active()
  return read()["_active"]
end

function M.save_active(name)
  local data = read()
  data["_active"] = name
  write(data)
end

function M.get_active_mode()
  return read()["_active_mode"]
end

function M.save_active_mode(name)
  local data = read()
  data["_active_mode"] = name
  write(data)
end

--- Prompt the user to store a key for a profile (used when a profile requires
--- a key but none is stored yet).
function M.prompt(profile)
  if not profile.api_key_name or profile.api_key_name == "" then
    return
  end
  local current = M.get(profile.name)
  vim.ui.input({
    prompt = profile.api_key_name .. " for " .. profile.name .. ": ",
    default = current or "",
  }, function(input)
    if input and input ~= "" then
      M.set(profile.name, input)
      vim.notify("Stored API key for " .. profile.name, vim.log.levels.INFO)
      require("agent_core.profiles").switch(profile)
    end
  end)
end

return M
