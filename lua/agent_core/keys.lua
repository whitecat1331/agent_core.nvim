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

--- Override the active backend for tests (keychain/libsecret/credential-manager,
--- or nil to force the JSON fallback). Callers must save/restore the prior value.
---@param b string|nil
function M.set_backend_for_test(b)
  backend = b
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

--- Build the argv for a keychain secret lookup (pure; testable).
---@param name string
---@return string[]
function M.keychain_get_command(name)
  if backend == "keychain" then
    return { "security", "find-generic-password", "-a", name, "-s", SERVICE, "-w" }
  elseif backend == "libsecret" then
    return { "secret-tool", "lookup", "service", SERVICE, "account", name }
  end
  return {}
end

--- Build the argv for a keychain secret store (pure; testable). For libsecret
--- the secret value is supplied on stdin, not argv.
---@param name string
---@param key string
---@return string[]
function M.keychain_set_command(name, key)
  if backend == "keychain" then
    return { "security", "add-generic-password", "-a", name, "-s", SERVICE, "-w", key, "-U" }
  elseif backend == "libsecret" then
    return { "secret-tool", "store", "--label=" .. SERVICE .. "/" .. name, "service", SERVICE, "account", name }
  end
  return {}
end

--- Build the argv for a keychain secret deletion (pure; testable).
---@param name string
---@return string[]
function M.keychain_delete_command(name)
  if backend == "keychain" then
    return { "security", "delete-generic-password", "-a", name, "-s", SERVICE }
  elseif backend == "libsecret" then
    return { "secret-tool", "clear", "service", SERVICE, "account", name }
  end
  return {}
end

--- Fetch a secret from the OS keychain, or nil when unavailable/missing.
---@param name string
---@return string|nil
local function keychain_get(name)
  if backend == "keychain" or backend == "libsecret" then
    local out, ok = run(M.keychain_get_command(name))
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
    run(M.keychain_delete_command(name))
    local _, ok = run(M.keychain_set_command(name, key))
    return ok
  elseif backend == "libsecret" then
    local _, ok = run(M.keychain_set_command(name, key), key)
    return ok
  end
  return false
end

--- Delete a secret from the OS keychain.
---@param name string
---@return boolean
local function keychain_delete(name)
  if backend == "keychain" or backend == "libsecret" then
    local _, ok = run(M.keychain_delete_command(name))
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

--- Set (or, with bang, remove) a profile's stored API key without switching the
--- active profile. Backing for :AgentKey[!]. `on_done` fires after the key is
--- actually stored/removed (the set path is async via vim.ui.input).
---@param profile table
---@param bang boolean
---@param on_done fun()|nil
local function apply_key(profile, bang, on_done)
  on_done = on_done or function() end
  if not profile.api_key_name or profile.api_key_name == "" then
    vim.notify("AgentKey: " .. profile.name .. " needs no API key", vim.log.levels.INFO)
    on_done()
    return
  end
  if bang then
    M.delete(profile.name)
    vim.notify("Removed API key for " .. profile.name, vim.log.levels.INFO)
    on_done()
    return
  end
  local current = M.get(profile.name) or ""
  vim.ui.input({
    prompt = profile.api_key_name .. " for " .. profile.name .. ": ",
    default = current,
  }, function(input)
    if input and input ~= "" then
      M.set(profile.name, input)
      vim.notify("Stored API key for " .. profile.name, vim.log.levels.INFO)
    end
    on_done()
  end)
end

--- Standalone :AgentKey[!] [profile] command: set a profile's API key, or with
--- a bang, remove it. Resolves the profile from `arg` or a picker.
---@param bang boolean
---@param arg string|nil
---@param on_done fun()|nil
function M.cmd(bang, arg, on_done)
  local Profiles = require("agent_core.profiles")
  if arg and arg ~= "" then
    local p = Profiles.find(arg)
    if not p then
      vim.notify("AgentKey: profile not found: " .. arg, vim.log.levels.WARN)
      if on_done then on_done() end
      return
    end
    apply_key(p, bang, on_done)
    return
  end
  require("agent_core.pickers").pick_profile(function(p)
    if p then
      apply_key(p, bang, on_done)
    elseif on_done then
      on_done()
    end
  end)
end

--- Wipe all stored secrets (OS keychain + JSON file) and reset the active
--- profile/mode. Used by :AgentSettingsClear (full first-install reset).
--- The JSON keys drive which keychain entries to clear, so this must run before
--- the JSON file is deleted.
---@return boolean ok
function M.reset()
  for _, name in ipairs(M.reset_names()) do
    keychain_delete(name)
  end
  pcall(vim.fn.delete, path)
  return true
end

--- Compute the secret names to purge: every non-"_" key in the JSON store plus
--- every default profile name (covers a missing/corrupt JSON file). Pure and
--- deterministic so the reset iteration is headless-testable.
---@return string[]
function M.reset_names()
  local names = {}
  local seen = {}
  local function add(n)
    if n and n ~= "" and not seen[n] then
      seen[n] = true
      names[#names + 1] = n
    end
  end
  for name in pairs(read()) do
    if name:sub(1, 1) ~= "_" then
      add(name)
    end
  end
  local ok, Profiles = pcall(require, "agent_core.profiles")
  if ok then
    for _, p in ipairs(Profiles.defaults or {}) do
      if p.name then
        add(p.name)
      end
    end
  end
  return names
end

return M
