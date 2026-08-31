---@mod agent_core.runtime.history Owned session-history persistence (owned).
---@brief [[
--- Owned JSON persistence for agent sessions. Each session is a self-contained
--- JSON record holding its `title`, `provider`, `model`, and `messages`, so
--- rename/fork/rewind/resume and per-session model binding are plain record
--- edits — no sticky side-stores (the old session_titles.json workaround is
--- gone, and the profile binding lives on the record itself).
---
--- Every function takes an explicit directory so it is trivially testable and
--- usable before any UI surface is wired up.
---@brief ]]

local M = {}

---@param id string
---@return string filename
local function filename_for(id)
  if id:sub(-5) == ".json" then
    return id
  end
  return id .. ".json"
end

---@param dir string
---@param id string
---@return string path
local function path_for(dir, id)
  return dir .. "/" .. filename_for(id)
end

--- Read and decode a JSON file, or return {} on any failure.
---@param path string
---@return table
local function read_json(path)
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(data) ~= "table" then
    return {}
  end
  return data
end

--- Write a table as pretty JSON (creating parent dirs).
---@param path string
---@param data table
---@return boolean
local function write_json(path, data)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = io.open(path, "w")
  if not f then
    return false
  end
  f:write(vim.json.encode(data))
  f:close()
  return true
end

--- List session files in `dir` as {id, title, provider, model, path} (newest first).
---@param dir string|nil
---@return {id:string,title:string,provider:string|nil,model:string|nil,path:string}[]
function M.list(dir)
  dir = dir or ""
  if vim.fn.isdirectory(dir) ~= 1 then
    return {}
  end
  local files = vim.fn.glob(dir .. "/*.json", false, true)
  local out = {}
  for _, f in ipairs(files) do
    local id = f:match("([^/\\]+)%.json$")
    if id and id ~= "metadata" then
      local data = read_json(f)
      out[#out + 1] = {
        id = id,
        title = (type(data.title) == "string" and data.title ~= "" and data.title) or id,
        provider = data.provider,
        model = data.model,
        path = f,
      }
    end
  end
  table.sort(out, function(a, b)
    return (vim.fn.getftime(a.path) or 0) > (vim.fn.getftime(b.path) or 0)
  end)
  return out
end

--- Load a session record by id, or nil,error.
---@param dir string|nil
---@param id string
---@return table|nil, string|nil
function M.load(dir, id)
  dir = dir or ""
  local path = path_for(dir, id)
  if vim.fn.filereadable(path) ~= 1 then
    return nil, "session not found: " .. id
  end
  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(data) ~= "table" then
    return nil, "could not decode session: " .. id
  end
  return data, nil
end

--- Save a decoded session record to disk under its id.
---@param dir string
---@param id string
---@param data table
---@return boolean
function M.save(dir, id, data)
  return write_json(path_for(dir, id), data)
end

--- Delete a session record by id. Returns true when a file was removed.
---@param dir string
---@param id string
---@return boolean
function M.delete(dir, id)
  if not id or id == "" then
    return false
  end
  local path = path_for(dir, id)
  if vim.fn.filereadable(path) ~= 1 then
    return false
  end
  return vim.fn.delete(path) == 0
end

--- The title of a session id (record title, else the id itself).
---@param dir string|nil
---@param id string
---@return string
function M.title_for(dir, id)
  local data, err = M.load(dir, id)
  if not data then
    return id
  end
  if type(data.title) == "string" and data.title ~= "" then
    return data.title
  end
  return id
end

--- Rename a session by setting the record's title (no side-store).
---@param dir string
---@param id string
---@param title string
---@return boolean
function M.rename(dir, id, title)
  if not id or id == "" or not title or title == "" then
    return false
  end
  local data, err = M.load(dir, id)
  if not data then
    return false
  end
  data.title = title
  return M.save(dir, id, data)
end

--- Fork a session: deep-copy its record to a new id (with optional title).
--- Copies provider/model so the fork reopens on the same model.
---@param dir string
---@param id string
---@param title string|nil
---@return string|nil new_id, string|nil err
function M.fork(dir, id, title)
  if not id or id == "" then
    return nil, "no session to fork"
  end
  local data, err = M.load(dir, id)
  if not data then
    return nil, err
  end
  local new_id = id .. "-fork-" .. tostring(os.time())
  local copy = vim.deepcopy(data)
  copy.id = new_id
  copy.title = title or ((type(data.title) == "string" and data.title ~= "" and data.title .. " (fork)") or new_id)
  if not M.save(dir, new_id, copy) then
    return nil, "could not write forked session"
  end
  return new_id, nil
end

--- Bind a session record to a provider + model (per-session model memory).
---@param dir string
---@param id string
---@param provider string
---@param model string
---@return boolean
function M.set_model(dir, id, provider, model)
  if not id or id == "" then
    return false
  end
  local data, err = M.load(dir, id)
  if not data then
    return false
  end
  data.provider = provider
  data.model = model
  return M.save(dir, id, data)
end

--- Return the provider + model bound to a session, or nil,nil.
---@param dir string
---@param id string
---@return string|nil provider
---@return string|nil model
function M.get_model(dir, id)
  if not id or id == "" then
    return nil, nil
  end
  local data = M.load(dir, id)
  if not data then
    return nil, nil
  end
  return data.provider, data.model
end

--- Rewind a session to a message index (keep 1..index), backing up first.
---@param dir string
---@param id string
---@param index integer
---@return boolean, string|nil
function M.rewind(dir, id, index)
  if not id or id == "" then
    return false, "no session to rewind"
  end
  local data, err = M.load(dir, id)
  if not data then
    return false, err
  end
  if not vim.islist(data.messages) then
    return false, "session has no message list"
  end
  if type(index) ~= "number" or index < 1 or index > #data.messages then
    return false, "invalid message index: " .. tostring(index)
  end

  local bak_path = path_for(dir, id) .. ".rewind-bak"
  local f = io.open(bak_path, "w")
  if f then
    f:write(vim.json.encode(data))
    f:close()
  end

  local truncated = {}
  for i = 1, index do
    truncated[i] = data.messages[i]
  end
  data.messages = truncated
  if not M.save(dir, id, data) then
    return false, "could not write rewound session"
  end
  return true, nil
end

return M
