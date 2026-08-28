---@mod agent_core.history Session history resume
---@brief [[
--- Lists and loads prior agent chat sessions so the user can resume them. This
--- is the local analog of resuming a past session. The store is the avante
--- history directory (probed from avante.history when available, else a
--- config/fallback path); `list(dir)` and `load(dir, id)` are pure and take an
--- explicit directory so they are trivially testable without avante installed.
---@brief ]]

local M = {}

M.config = {
  enabled = true,
  dir = nil, -- nil = avante history dir (probed) or <data>/agent_core/history
}

--- Probe avante.history (best-effort) and return it, or nil when unavailable.
---@return table|nil
function M.get_history()
  local ok, History = pcall(require, "avante.history")
  if not ok then
    return nil
  end
  return History
end

--- Resolve the avante history directory (best-effort), or "" when unknown.
---@return string
function M.avante_history_dir()
  local History = M.get_history()
  if History then
    if type(History.avante_ignore_dir) == "function" then
      local ok, dir = pcall(History.avante_ignore_dir, History)
      if ok and type(dir) == "string" and dir ~= "" then
        return dir
      end
      local ok2, dir2 = pcall(History.avante_ignore_dir)
      if ok2 and type(dir2) == "string" and dir2 ~= "" then
        return dir2
      end
    end
  end
  return ""
end

--- The active history directory.
---@return string
function M.history_dir()
  if M.config.dir and M.config.dir ~= "" then
    return vim.fn.expand(M.config.dir)
  end
  local dir = M.avante_history_dir()
  if dir ~= "" then
    return dir
  end
  return vim.fn.stdpath("data") .. "/agent_core/history"
end

--- List session files in `dir` as {id, title} entries (sorted, newest first).
---@param dir string|nil
---@return {id:string,title:string,path:string}[]
function M.list(dir)
  dir = dir or M.history_dir()
  if vim.fn.isdirectory(dir) ~= 1 then
    return {}
  end
  local files = vim.fn.glob(dir .. "/*.json", false, true)
  local out = {}
  for _, f in ipairs(files) do
    local id = f:match("([^/\\]+)%.json$")
    out[#out + 1] = { id = id or f, title = id or f, path = f }
  end
  table.sort(out, function(a, b)
    return (vim.fn.getftime(a.path) or 0) > (vim.fn.getftime(b.path) or 0)
  end)
  return out
end

--- Load a session by id and return its decoded JSON, or nil,error.
---@param dir string|nil
---@param id string
---@return table|nil, string|nil
function M.load(dir, id)
  dir = dir or M.history_dir()
  local path = dir .. "/" .. id
  if path:sub(-5) ~= ".json" then
    path = path .. ".json"
  end
  if vim.fn.filereadable(path) ~= 1 then
    return nil, "session not found: " .. id
  end
  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok then
    return nil, "could not decode session: " .. id
  end
  return data, nil
end

--- Present session history in a scratch buffer (:AgentHistory).
function M.list_cmd()
  local entries = M.list()
  local lines = { "# Agent session history", "" }
  if #entries == 0 then
    lines[#lines + 1] = "(none)"
  else
    for _, e in ipairs(entries) do
      lines[#lines + 1] = "- " .. e.id
    end
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.api.nvim_open_win(buf, true, { split = "right" })
end

function M.setup()
  local cfg = require("agent_core").config
  M.config = vim.tbl_deep_extend("force", M.config, cfg.history or {})
  vim.fn.mkdir(vim.fn.fnamemodify(M.history_dir(), ":h"), "p")
end

return M
