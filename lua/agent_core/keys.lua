---@mod agent_core.keys Local API-key store (0600, never committed).
--- Stores keys in <config>/agent_keys.json. This is a fallback only: profiles
--- prefer the environment (os.getenv) first, so this file typically holds
--- nothing secret. TODO: optional encryption at rest if secrets are stored here.

local M = {}

local path = vim.fn.stdpath("config") .. "/agent_keys.json"

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

function M.get(name)
  return read()[name]
end

function M.set(name, key)
  local data = read()
  data[name] = key
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
