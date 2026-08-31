---@mod agent_core.reset Full first-install reset.
---@brief [[
--- Wipes all global agent_core state: API keys (OS keychain + agent_keys.json),
--- the active profile/mode, and the entire <data>/agent_core tree (policy,
--- registry, setup, catalog, modes, workspace, automations, memory, todos,
--- history, debug, checkpoints, screenshots, workflows, skills, commands,
--- notepads, rules). Project-scoped files (.agent_core/, AVANTE.md, .semnav/,
--- .mcphub/) are intentionally NOT touched.
---@brief ]]

local M = {}

--- The data tree the reset removes. Kept module-local so tests can redirect it
--- to a temp dir; defaults to <data>/agent_core.
local data_dir = vim.fn.stdpath("data") .. "/agent_core"

--- Override the data-tree path (used by tests). Pass nil to restore the default.
---@param p string|nil
function M.set_data_dir(p)
  data_dir = p or (vim.fn.stdpath("data") .. "/agent_core")
end

--- Ordered list of concrete paths the reset removes. Kept as data so the wipe
--- is enumerable and headless-testable.
---@return string[]
function M.targets()
  local Keys = require("agent_core.keys")
  return {
    Keys.path(), -- ~/.config/nvim/agent_keys.json
    data_dir,
  }
end

--- Remove a path (file or directory tree), never erroring.
local function remove(path)
  if path == nil or path == "" then
    return
  end
  pcall(vim.fn.delete, path, "rf")
end

--- Perform the wipe: purge keychain secrets, delete the JSON key store, and
--- delete the data tree. Returns true on success.
---@return boolean
function M.clear()
  local ok, Keys = pcall(require, "agent_core.keys")
  if not ok then
    return false
  end

  -- Keychain purge must happen before the JSON store is deleted (the JSON
  -- names drive which keychain entries to clear).
  pcall(Keys.reset)

  for _, p in ipairs(M.targets()) do
    remove(p)
  end

  -- Reset in-memory state so a running session does not linger with stale
  -- profile/mode/sessions after the wipe.
  vim.g.agent_active_profile = nil
  vim.g.agent_active_model = nil
  vim.g.agent_persona = ""
  vim.g.agent_mode = nil
  vim.g.agent_mode_prompt = ""
  local ok_rt, rt = pcall(require, "agent_core.runtime")
  if ok_rt and type(rt) == "table" then
    rt._sessions = {}
    rt._active = 0
  end

  return true
end

--- Interactive :AgentSettingsClear[!] entry point. `bang` skips the
--- confirmation prompt (scripted/CI).
---@param bang boolean
function M.clear_cmd(bang)
  if not bang then
    local choice = vim.fn.confirm("Wipe ALL agent_core state and API keys?", "&Yes\n&No", 2, "Warning")
    if choice ~= 1 then
      vim.notify("AgentSettingsClear cancelled", vim.log.levels.INFO)
      return
    end
  end
  if M.clear() then
    vim.notify("agent_core state cleared (first-install reset)", vim.log.levels.INFO)
  else
    vim.notify("agent_core reset failed", vim.log.levels.ERROR)
  end
end

return M
