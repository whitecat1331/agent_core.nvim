---@mod agent_core.session_edits Per-session edit journal (keep / discard).
---@brief [[
--- Tracks every file mutation the active chat session makes (write_to_file and
--- str_replace) so the user can "keep" a turn (advance the baseline) or
--- "discard" the un-kept turns (revert to before-bytes). Mirrors Cursor's
--- per-turn Keep / Undo All: keep = lock in this turn, discard = revert only the
--- turns since the last keep.
---
--- A journal is a JSON file per session id:
---   { "kept_turn": 0, "entries": [ { "turn", "tool", "path", "existed", "before" } ] }
--- `before` holds the file's exact bytes (binary readfile) prior to the edit, or
--- nil when the file did not exist (so discard deletes it). Entries are reversed
--- in LIFO order on discard so two edits to the same file restore correctly.
---@brief ]]

local M = {}

---@class AgentSessionEditsConfig
---@field enabled boolean
---@field dir string|nil  nil = <data>/agent_core/session_edits
M.config = {
  enabled = true,
  dir = nil,
}

--- Directory where per-session journals live.
---@return string
function M.dir()
  if M.config.dir and M.config.dir ~= "" then
    return vim.fn.expand(M.config.dir)
  end
  return vim.fn.stdpath("data") .. "/agent_core/session_edits"
end

--- Journal file path for a session id.
---@param session_id string
---@return string
function M.path(session_id)
  return M.dir() .. "/" .. (session_id or "session") .. ".json"
end

--- Resolve a possibly-relative path onto the project cwd (mirrors builtins.abs).
---@param path string
---@return string
local function abs(path)
  if path:match("^%a:[/\\]") or path:match("^[/\\]") then
    return path
  end
  return vim.fn.getcwd() .. "/" .. path
end

--- Load a journal, or an empty default on missing/corrupt.
---@param session_id string
---@return {kept_turn:integer, entries:table[]}
function M.load(session_id)
  local path = M.path(session_id)
  if vim.fn.filereadable(path) ~= 1 then
    return { kept_turn = 0, entries = {} }
  end
  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(data) ~= "table" then
    return { kept_turn = 0, entries = {} }
  end
  return {
    kept_turn = tonumber(data.kept_turn) or 0,
    entries = type(data.entries) == "table" and data.entries or {},
  }
end

--- Persist a journal. Returns true on write.
---@param session_id string
---@param journal table
---@return boolean
function M.save(session_id, journal)
  vim.fn.mkdir(M.dir(), "p")
  local f = io.open(M.path(session_id), "w")
  if not f then
    return false
  end
  f:write(vim.json.encode(journal))
  f:close()
  return true
end

--- Record the before-state of a file the model is about to mutate. No-op when
--- disabled or given an empty path. Returns false when nothing was captured.
---@param session_id string
---@param turn integer
---@param tool string
---@param file_path string
---@return boolean
function M.capture(session_id, turn, tool, file_path)
  if M.config.enabled == false then
    return false
  end
  if not session_id or session_id == "" or not file_path or file_path == "" then
    return false
  end
  local path = abs(file_path)
  local existed = vim.fn.filereadable(path) == 1
  local before = existed and vim.fn.readfile(path, "b") or nil
  local journal = M.load(session_id)
  journal.entries[#journal.entries + 1] = {
    turn = tonumber(turn) or 0,
    tool = tool,
    path = path,
    existed = existed,
    before = before,
  }
  return M.save(session_id, journal)
end

--- Advance the baseline to the latest turn: everything up to and including it
--- is now kept. Files are already persisted, so this is pure bookkeeping.
---@param session_id string
---@return boolean
function M.keep(session_id)
  local journal = M.load(session_id)
  local max = 0
  for _, e in ipairs(journal.entries) do
    if e.turn > max then
      max = e.turn
    end
  end
  journal.kept_turn = max
  return M.save(session_id, journal)
end

--- Revert every un-kept edit (turn > kept_turn) in LIFO order and clear them.
--- Deletes files that did not exist before the edit; restores before-bytes
--- otherwise. Returns the number of edits reverted.
---@param session_id string
---@return integer
function M.discard(session_id)
  local journal = M.load(session_id)
  local kept = journal.kept_turn or 0
  local remaining = {}
  local reverted = 0
  for i = #journal.entries, 1, -1 do
    local e = journal.entries[i]
    if e.turn > kept then
      if not e.existed then
        vim.fn.delete(e.path)
      else
        vim.fn.mkdir(vim.fn.fnamemodify(e.path, ":h"), "p")
        vim.fn.writefile(e.before or {}, e.path, "b")
      end
      reverted = reverted + 1
    else
      table.insert(remaining, 1, e)
    end
  end
  journal.entries = remaining
  journal.kept_turn = kept
  M.save(session_id, journal)
  return reverted
end

--- Count of edits that would be reverted by discard (turn > kept_turn).
---@param session_id string
---@return integer
function M.pending_count(session_id)
  local journal = M.load(session_id)
  local kept = journal.kept_turn or 0
  local n = 0
  for _, e in ipairs(journal.entries) do
    if e.turn > kept then
      n = n + 1
    end
  end
  return n
end

--- :AgentKeep — advance the active session's baseline to the current turn.
function M.keep_cmd()
  local rt = require("agent_core.runtime")
  local session = rt.active_session()
  if not session then
    vim.notify("Agent keep: no active session", vim.log.levels.WARN)
    return
  end
  M.keep(session.id)
  vim.notify("Agent keep: edits kept up to the current turn", vim.log.levels.INFO)
end

--- :AgentDiscard — revert the active session's un-kept turns and reload buffers.
function M.discard_cmd()
  local rt = require("agent_core.runtime")
  local session = rt.active_session()
  if not session then
    vim.notify("Agent discard: no active session", vim.log.levels.WARN)
    return
  end
  local n = M.discard(session.id)
  vim.notify(string.format("Agent discard: reverted %d edit(s)", n), vim.log.levels.INFO)
  vim.cmd("silent checktime")
end

--- Merge config.session_edits into M.config and ensure the journal dir exists.
---@param opts table|nil
function M.setup(opts)
  local cfg = require("agent_core").config
  M.config = vim.tbl_deep_extend("force", M.config, cfg.session_edits or {})
  if opts then
    M.config = vim.tbl_deep_extend("force", M.config, opts)
  end
  vim.fn.mkdir(M.dir(), "p")
end

return M
