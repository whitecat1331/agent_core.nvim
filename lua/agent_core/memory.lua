---@mod agent_core.memory Persistent agent-written memory (learn across runs)
---@brief [[
--- Agent-written, learn-across-runs memory — distinct from user-authored Notepads.
--- The model can `remember` facts, `recall` them later, and `forget` stale ones.
--- Stored as a single JSON map (<data>/agent_core/memory.json) keyed by topic with
--- values and timestamps. `get_memory_prompt()` injects a compact key index (never
--- full values) into the system prompt, and the model reads values on demand with
--- its read tools — the local analog of persistent automation memory.
---@brief ]]

local M = {}

--- Path to the memory store.
---@return string
function M.path()
  local cfg = require("agent_core").config
  local mem = cfg.memory or {}
  if mem.path and mem.path ~= "" then
    return vim.fn.expand(mem.path)
  end
  return vim.fn.stdpath("data") .. "/agent_core/memory.json"
end

--- Load the memory map, or {} when missing/corrupt.
---@return table<string, {value:string, updated_at:integer}>
function M.load()
  local path = M.path()
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local ok, data = pcall(function()
    return vim.fn.json_decode(table.concat(vim.fn.readfile(path), "\n"))
  end)
  if not ok or type(data) ~= "table" then
    return {}
  end
  return data
end

--- Persist the memory map.
---@param data table
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

---@param key string
---@param value string
---@return string|nil err
function M.remember(key, value)
  key = key:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if key == "" or not value or value == "" then
    return "remember requires a non-empty key and value"
  end
  local data = M.load()
  data[key] = { value = value, updated_at = os.time() }
  if not save(data) then
    return "could not write memory store"
  end
end

---@param key string
---@return string|nil value
function M.recall(key)
  local data = M.load()
  local entry = data[key]
  if entry then
    return entry.value
  end
  return nil
end

---@param key string
---@return string|nil err
function M.forget(key)
  local data = M.load()
  if data[key] == nil then
    return nil
  end
  data[key] = nil
  if not save(data) then
    return "could not write memory store"
  end
end

---@return {key:string,value:string,updated_at:integer}[]
function M.list()
  local data = M.load()
  local out = {}
  for key, entry in pairs(data) do
    out[#out + 1] = { key = key, value = entry.value, updated_at = entry.updated_at or 0 }
  end
  table.sort(out, function(a, b)
    return a.updated_at > b.updated_at
  end)
  return out
end

--- Compact key index for the system prompt (keys only, never values).
---@return string
function M.get_memory_prompt()
  local entries = M.list()
  if #entries == 0 then
    return ""
  end

  local cfg = require("agent_core").config
  local mem = cfg.memory or {}

  local lines = {
    "## Agent memory",
    "",
    "Persistent facts learned in previous runs. Reference a topic by key and",
    "read its file (" .. M.path() .. ") when relevant. Keys only:",
    "",
  }
  for _, e in ipairs(entries) do
    lines[#lines + 1] = "- " .. e.key
  end

  local content = table.concat(lines, "\n")
  local max = mem.prompt_max_chars or 2000
  if #content > max then
    content = content:sub(1, max) .. "\n[... memory index truncated ...]"
  end
  return content
end

---@type AgentTool
local remember = {
  name = "remember",
  description = "Persist a fact or decision into long-term agent memory so future runs can recall it.",
  param = {
    type = "table",
    fields = {
      { name = "key", description = "Short topic/title key for this memory.", type = "string" },
      { name = "value", description = "The fact to store (string).", type = "string" },
    },
    required = { "key", "value" },
    usage = {
      key = "Topic key",
      value = "Value to store",
    },
  },
  returns = {
    { name = "result", description = "Confirmation string.", type = "string" },
    { name = "error", description = "Error message if storing failed.", type = "string", optional = true },
  },
}
---@type AgentToolFunc<{ key: string, value: string }>
function remember.func(input, opts)
  if not opts.on_complete then
    return nil, "on_complete not provided"
  end
  local err = M.remember(input.key, input.value)
  if err then
    opts.on_complete(nil, err)
    return
  end
  opts.on_complete("remembered: " .. input.key, nil)
end

---@type AgentTool
local recall = {
  name = "recall",
  description = "Recall a fact or decision previously stored in long-term agent memory.",
  param = {
    type = "table",
    fields = {
      { name = "key", description = "Topic/title key to recall.", type = "string" },
    },
    required = { "key" },
    usage = {
      key = "Topic key",
    },
  },
  returns = {
    { name = "result", description = "The stored value (empty if not found).", type = "string" },
    { name = "error", description = "Error message if recall failed.", type = "string", optional = true },
  },
}
---@type AgentToolFunc<{ key: string }>
function recall.func(input, opts)
  if not opts.on_complete then
    return nil, "on_complete not provided"
  end
  local value = M.recall(input.key)
  if value == nil then
    opts.on_complete("", "no memory stored under key '" .. tostring(input.key) .. "'")
    return
  end
  opts.on_complete(value, nil)
end

---@type AgentTool
local forget = {
  name = "forget",
  description = "Delete a fact from long-term agent memory.",
  param = {
    type = "table",
    fields = {
      { name = "key", description = "Topic/title key to forget.", type = "string" },
    },
    required = { "key" },
    usage = {
      key = "Topic key",
    },
  },
  returns = {
    { name = "result", description = "Confirmation string.", type = "string" },
    { name = "error", description = "Error message if forgetting failed.", type = "string", optional = true },
  },
}
---@type AgentToolFunc<{ key: string }>
function forget.func(input, opts)
  if not opts.on_complete then
    return nil, "on_complete not provided"
  end
  local err = M.forget(input.key)
  if err then
    opts.on_complete(nil, err)
    return
  end
  opts.on_complete("forgotten: " .. input.key, nil)
end

--- Present memory in a scratch buffer (:AgentMemory).
function M.show()
  local entries = M.list()
  local lines = { "# Agent memory", "" }
  if #entries == 0 then
    lines[#lines + 1] = "(empty — the model stores memories via the `remember` tool)"
  else
    for _, e in ipairs(entries) do
      lines[#lines + 1] = string.format("## %s  (updated %s)", e.key, os.date("%Y-%m-%d %H:%M", e.updated_at))
      lines[#lines + 1] = ""
      for _, l in ipairs(vim.split(e.value or "", "\n")) do
        lines[#lines + 1] = l
      end
      lines[#lines + 1] = ""
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.api.nvim_open_win(buf, true, { split = "right" })
end

function M.setup()
  vim.fn.mkdir(vim.fn.fnamemodify(M.path(), ":h"), "p")
end

function M.remember_tool()
  return remember
end
function M.recall_tool()
  return recall
end
function M.forget_tool()
  return forget
end

return M
