---@mod agent_core.automation Scheduled/recurring headless agents
---@brief [[
--- Persists recurring prompts (automations) to <data>/agent_core/automations.json
--- and schedules them with a vim.uv timer so a prompt can run on an interval
--- (e.g. "every hour"). This is the local analog of recurring Automations. Each
--- run goes through agent_core.runner; the schedule survives restarts by
--- re-arming from the persisted list on setup.
---@brief ]]

local M = {}

M.config = {
  enabled = true,
  path = nil, -- nil = <data>/agent_core/automations.json
}

--- Active timers keyed by automation id.
local timers = {}

--- Path to the automations store.
---@return string
function M.path()
  local cfg = require("agent_core").config
  local a = cfg.automation or {}
  if a.path and a.path ~= "" then
    return vim.fn.expand(a.path)
  end
  return vim.fn.stdpath("data") .. "/agent_core/automations.json"
end

--- Load the automations list, or {} when missing/corrupt.
---@return table[]
function M.load()
  local path = M.path()
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(data) ~= "table" then
    return {}
  end
  return data
end

--- Persist the automations list.
---@param data table[]
---@return boolean
local function save(data)
  vim.fn.mkdir(vim.fn.fnamemodify(M.path(), ":h"), "p")
  local f = io.open(M.path(), "w")
  if not f then
    return false
  end
  f:write(vim.fn.json_encode(data))
  f:close()
  return true
end

--- List all automations.
---@return table[]
function M.list()
  return M.load()
end

--- Add an automation. `interval_minutes` = repeat interval (0 = one-shot).
---@param prompt string
---@param interval_minutes number|nil
---@param profile string|nil
---@param mode string|nil
---@return table|nil, string|nil
function M.add(prompt, interval_minutes, profile, mode)
  prompt = (prompt or ""):gsub("%s+$", "")
  if prompt == "" then
    return nil, "automation requires a non-empty prompt"
  end
  local data = M.load()
  local entry = {
    id = tostring(os.time()) .. "-" .. tostring(#data + 1),
    prompt = prompt,
    interval_minutes = tonumber(interval_minutes) or 0,
    profile = profile or nil,
    mode = mode or nil,
    created_at = os.time(),
  }
  data[#data + 1] = entry
  if not save(data) then
    return nil, "could not write automations store"
  end
  M.arm(entry)
  return entry, nil
end

--- Remove an automation by id.
---@param id string
---@return string|nil err
function M.remove(id)
  local data = M.load()
  for i, e in ipairs(data) do
    if e.id == id then
      table.remove(data, i)
      save(data)
      M.disarm(id)
      return nil
    end
  end
  return "no automation with id '" .. tostring(id) .. "'"
end

--- Run an automation headlessly via the runner.
---@param entry table
---@param cb fun(result: table)|nil
function M.run(entry, cb)
  cb = cb or function() end
  local Runner = require("agent_core.runner")
  Runner.run(entry.prompt, { profile = entry.profile, mode = entry.mode }, function(result)
    if result.error then
      vim.notify("Automation " .. (entry.id or "?") .. ": " .. result.error, vim.log.levels.ERROR)
    else
      vim.notify("Automation " .. (entry.id or "?") .. " complete", vim.log.levels.INFO)
    end
    cb(result)
  end)
end

--- Stop and free a repeating timer, if any.
---@param id string
function M.disarm(id)
  local t = timers[id]
  if t then
    pcall(function()
      t:stop()
      t:close()
    end)
    timers[id] = nil
  end
end

--- (Re)arm a repeating automation timer.
---@param entry table
function M.arm(entry)
  M.disarm(entry.id)
  local mins = tonumber(entry.interval_minutes) or 0
  if mins <= 0 then
    return
  end
  local ok, uv = pcall(require, "vim.uv")
  if not ok or not uv.new_timer then
    return
  end
  local ms = mins * 60 * 1000
  local timer = uv.new_timer()
  timer:start(
    ms,
    ms,
    vim.schedule_wrap(function()
      M.run(entry)
    end)
  )
  timers[entry.id] = timer
end

--- Arm every persisted repeating automation.
function M.arm_all()
  for _, e in ipairs(M.list()) do
    M.arm(e)
  end
end

--- Backing for :AgentAutomationList.
function M.list_cmd()
  local entries = M.list()
  local lines = { "# Agent automations", "" }
  if #entries == 0 then
    lines[#lines + 1] = "(none — add with :AgentAutomationAdd)"
  else
    for _, e in ipairs(entries) do
      lines[#lines + 1] = string.format("## %s  (every %d min)", e.id, e.interval_minutes or 0)
      lines[#lines + 1] = e.prompt
      lines[#lines + 1] = ""
    end
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.api.nvim_open_win(buf, true, { split = "right" })
end

--- Backing for :AgentAutomationAdd.
---@param arg string
function M.add_cmd(arg)
  local prompt = arg
  if not prompt or prompt == "" then
    vim.ui.input({ prompt = "Automation prompt: " }, function(input)
      if input and input ~= "" then
        M.prompt_interval(function(interval)
          local entry, err = M.add(input, interval, nil, nil)
          if err then
            vim.notify("Automation: " .. err, vim.log.levels.ERROR)
          else
            vim.notify("Automation added: " .. entry.id, vim.log.levels.INFO)
          end
        end)
      end
    end)
    return
  end
  local entry, err = M.add(prompt, 0, nil, nil)
  if err then
    vim.notify("Automation: " .. err, vim.log.levels.ERROR)
  else
    vim.notify("Automation added: " .. entry.id, vim.log.levels.INFO)
  end
end

--- Prompt for an optional interval (minutes, empty = 0), then call cb.
---@param cb fun(interval:number)
function M.prompt_interval(cb)
  vim.ui.input({ prompt = "Repeat every N minutes (empty = one-shot): " }, function(input)
    local mins = tonumber(input) or 0
    cb(mins)
  end)
end

--- Backing for :AgentAutomationRemove (picker).
function M.remove_cmd()
  local entries = M.list()
  if #entries == 0 then
    vim.notify("No automations", vim.log.levels.WARN)
    return
  end
  local labels = vim.tbl_map(function(e)
    return e.id .. "  |  " .. e.prompt:sub(1, 40)
  end, entries)
  vim.ui.select(labels, { prompt = "Remove automation" }, function(choice)
    for _, e in ipairs(entries) do
      local label = e.id .. "  |  " .. e.prompt:sub(1, 40)
      if label == choice then
        local err = M.remove(e.id)
        if err then
          vim.notify("Automation: " .. err, vim.log.levels.ERROR)
        else
          vim.notify("Automation removed", vim.log.levels.INFO)
        end
        return
      end
    end
  end)
end

--- Backing for :AgentAutomationRun (picker, or run the first/only entry).
function M.run_cmd()
  local entries = M.list()
  if #entries == 0 then
    vim.notify("No automations", vim.log.levels.WARN)
    return
  end
  local labels = vim.tbl_map(function(e)
    return e.id .. "  |  " .. e.prompt:sub(1, 40)
  end, entries)
  vim.ui.select(labels, { prompt = "Run automation" }, function(choice)
    for _, e in ipairs(entries) do
      local label = e.id .. "  |  " .. e.prompt:sub(1, 40)
      if label == choice then
        M.run(e)
        return
      end
    end
  end)
end

function M.setup()
  local cfg = require("agent_core").config
  M.config = vim.tbl_deep_extend("force", M.config, cfg.automation or {})
  vim.fn.mkdir(vim.fn.fnamemodify(M.path(), ":h"), "p")
  if M.config.enabled ~= false then
    vim.schedule(M.arm_all)
  end
end

return M
