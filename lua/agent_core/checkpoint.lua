---@mod agent_core.checkpoint Agent-mode checkpoints
---@brief [[
--- Agent-mode checkpoints: snapshot the working tree before a
--- risky change and restore it later if the change goes wrong. Checkpoints are
--- non-intrusive — no commits, no stash — a `git diff --binary` patch is written
--- to <data>/agent_core/checkpoints/<label>.patch for tracked changes, and any
--- untracked files are snapshotted into a sidecar <label>.untracked.json manifest
--- so rollback can delete files created after the snapshot and restore files that
--- existed at snapshot time. A registry JSON lets the `rollback` tool /
--- :AgentRollback pick and reverse a snapshot with `git apply -R`.
---@brief ]]

local M = {}

--- Directory where checkpoint patches + registry live.
---@return string
function M.dir()
  return vim.fn.stdpath("data") .. "/agent_core/checkpoints"
end

function M.index_path()
  return M.dir() .. "/index.json"
end

--- Filesystem-safe slug for a label.
---@param s string
---@return string
function M.slugify(s)
  s = s:lower()
  s = s:gsub("[^%w%-]+", "-")
  s = s:gsub("-+", "-"):gsub("^-+", ""):gsub("-+$", "")
  if s == "" then
    s = "checkpoint"
  end
  return s
end

--- Load the checkpoint registry (list), or {} on any error.
---@return table[]
function M.load()
  local f = io.open(M.index_path(), "r")
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

--- Persist the checkpoint registry.
---@param list table[]
---@return boolean
function M.save(list)
  vim.fn.mkdir(M.dir(), "p")
  local f = io.open(M.index_path(), "w")
  if not f then
    return false
  end
  f:write(vim.json.encode(list))
  f:close()
  return true
end

--- List untracked (but not ignored) files under the repo root.
---@param root string
---@return string[]
local function untracked_files(root)
  local ok, out = pcall(vim.fn.systemlist, { "git", "-C", root, "ls-files", "--others", "--exclude-standard" })
  if not ok or vim.v.shell_error ~= 0 then
    return {}
  end
  return out
end

--- Snapshot the working tree into a patch plus an untracked-file manifest.
--- Returns (ok, entry, err).
---@param label string|nil
---@return boolean, table|nil, string|nil
function M.create(label)
  label = (label and label ~= "") and label or "checkpoint"
  local root = require("agent_core.indexer").root()
  local ok_diff, diff = pcall(vim.fn.systemlist, { "git", "-C", root, "diff", "--binary" })
  if not ok_diff or vim.v.shell_error ~= 0 then
    return false, nil, "git diff failed (is " .. root .. " a git repo?)"
  end
  local untracked = untracked_files(root)
  if #diff == 0 and #untracked == 0 then
    return false, nil, "no changes to checkpoint"
  end

  vim.fn.mkdir(M.dir(), "p")
  local stamp = os.date("%Y-%m-%d-%H%M%S")
  local slug = M.slugify(label)
  local path = M.dir() .. "/" .. slug .. "-" .. stamp .. ".patch"

  local entry = {
    label = label,
    path = path,
    created = os.time(),
    files = #diff,
    untracked = nil,
  }

  if #diff > 0 then
    local f = io.open(path, "w")
    if not f then
      return false, nil, "could not write " .. path
    end
    f:write(table.concat(diff, "\n"))
    f:write("\n")
    f:close()
  end

  if #untracked > 0 then
    local manifest = {}
    for _, rel in ipairs(untracked) do
      local abs = root .. "/" .. rel
      if vim.fn.filereadable(abs) == 1 then
        manifest[#manifest + 1] = { path = rel, content = vim.fn.readfile(abs, "b") }
      end
    end
    local manifest_path = M.dir() .. "/" .. slug .. "-" .. stamp .. ".untracked.json"
    local mf = io.open(manifest_path, "w")
    if not mf then
      return false, nil, "could not write " .. manifest_path
    end
    mf:write(vim.json.encode(manifest))
    mf:close()
    entry.untracked = manifest_path
  end

  local list = M.load()
  list[#list + 1] = entry
  M.save(list)
  return true, entry, nil
end

--- Load the untracked-file manifest for an entry, or {} on any error.
---@param entry table
---@return {path:string,content:string[]}[]
function M.load_manifest(entry)
  if not entry or not entry.untracked or vim.fn.filereadable(entry.untracked) ~= 1 then
    return {}
  end
  local mf = io.open(entry.untracked, "r")
  if not mf then
    return {}
  end
  local content = mf:read("*a")
  mf:close()
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then
    return {}
  end
  return data
end

--- Reverse a checkpoint: `git apply -R` the tracked patch, then restore or
--- remove untracked files so the tree matches the snapshot. Returns (ok, msg).
---@param entry table
---@return boolean, string
function M.rollback(entry)
  local root = require("agent_core.indexer").root()
  local manifest = M.load_manifest(entry)
  local has_patch = entry and entry.path and vim.fn.filereadable(entry.path) == 1
  if not has_patch and #manifest == 0 then
    return false, "checkpoint not found (no patch or untracked manifest)"
  end

  if has_patch then
    local ok, out = pcall(vim.fn.systemlist, { "git", "-C", root, "apply", "-R", entry.path })
    if not ok or vim.v.shell_error ~= 0 then
      local detail = out and table.concat(out, "\n") or ""
      return false, "git apply -R failed: " .. detail
    end
  end

  if #manifest > 0 then
    local known = {}
    for _, m in ipairs(manifest) do
      known[m.path] = m
    end
    -- Restore files that existed at snapshot time; delete files created after.
    for _, rel in ipairs(untracked_files(root)) do
      local abs = root .. "/" .. rel
      if known[rel] then
        vim.fn.writefile(known[rel].content, abs, "b")
        known[rel] = nil
      else
        vim.fn.delete(abs)
      end
    end
    -- Recreate snapshot files that were deleted after the snapshot.
    for rel, m in pairs(known) do
      local abs = root .. "/" .. rel
      vim.fn.mkdir(vim.fn.fnamemodify(abs, ":h"), "p")
      vim.fn.writefile(m.content, abs, "b")
    end
  end

  return true, "rolled back to checkpoint '" .. (entry.label or "") .. "'"
end

--- Entry picker for rollback. cb receives the selected entry or nil.
---@param cb fun(entry: table|nil)
function M.pick(cb)
  local list = M.load()
  if #list == 0 then
    vim.notify("Checkpoint: no checkpoints recorded", vim.log.levels.WARN)
    cb(nil)
    return
  end
  -- Newest first.
  local sorted = {}
  for i = #list, 1, -1 do
    sorted[#sorted + 1] = list[i]
  end
  local items = {}
  for _, e in ipairs(sorted) do
    local stamp = os.date("%Y-%m-%d %H:%M", e.created)
    items[#items + 1] = string.format("%s  (%s)", e.label, stamp)
  end
  vim.ui.select(items, {
    prompt = "Rollback to checkpoint",
  }, function(choice)
    if not choice then
      cb(nil)
      return
    end
    for _, e in ipairs(sorted) do
      local stamp = os.date("%Y-%m-%d %H:%M", e.created)
      if choice == string.format("%s  (%s)", e.label, stamp) then
        cb(e)
        return
      end
    end
    cb(nil)
  end)
end

--- :AgentCheckpoint — snapshot now.
---@param arg string|nil label
function M.checkpoint_cmd(arg)
  local ok, entry, err = M.create(arg)
  if not ok then
    vim.notify("Checkpoint: " .. tostring(err), vim.log.levels.WARN)
    return
  end
  vim.notify("Checkpoint saved: " .. entry.path, vim.log.levels.INFO)
end

--- :AgentRollback — restore a checkpoint (by label or via picker).
---@param arg string|nil label
function M.rollback_cmd(arg)
  local function do_rollback(entry)
    if not entry then
      return
    end
    local ok, msg = M.rollback(entry)
    vim.notify("Checkpoint: " .. msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
  end

  if arg and arg ~= "" then
    for _, e in ipairs(M.load()) do
      if e.label == arg then
        do_rollback(e)
        return
      end
    end
    vim.notify("Checkpoint: no checkpoint labelled '" .. arg .. "'", vim.log.levels.WARN)
    return
  end
  M.pick(do_rollback)
end

function M.setup()
  vim.fn.mkdir(M.dir(), "p")
end

---@type AgentTool
local checkpoint = {
  name = "checkpoint",
  description = "Snapshot the current working tree (tracked changes plus any untracked files) so it can be "
    .. "restored later with the `rollback` tool. Use before a large or risky change.",
  param = {
    type = "table",
    fields = {
      {
        name = "label",
        description = "Short human-readable label for this checkpoint.",
        type = "string",
        optional = true,
      },
    },
    usage = {
      label = "Checkpoint label (optional)",
    },
  },
  returns = {
    {
      name = "result",
      description = "Confirmation with the checkpoint path",
      type = "string",
    },
    {
      name = "error",
      description = "Error message if the snapshot failed",
      type = "string",
      optional = true,
    },
  },
}

---@type AgentToolFunc<{ label?: string }>
function checkpoint.func(input, opts)
  if not opts.on_complete then
    return nil, "on_complete not provided"
  end
  local ok, entry, err = M.create(input.label)
  if not ok then
    opts.on_complete(nil, err)
    return
  end
  opts.on_complete("Checkpoint saved to " .. entry.path, nil)
end

---@type AgentTool
local rollback = {
  name = "rollback",
  description = "Restore the working tree to a previous checkpoint by reversing its recorded patch and undoing "
    .. "untracked-file changes (files created after the snapshot are deleted, snapshot files are restored).",
  param = {
    type = "table",
    fields = {},
    usage = {},
  },
  returns = {
    {
      name = "result",
      description = "Result of the rollback",
      type = "string",
    },
    {
      name = "error",
      description = "Error message if the rollback failed",
      type = "string",
      optional = true,
    },
  },
}

function rollback.func(input, opts)
  if not opts.on_complete then
    return nil, "on_complete not provided"
  end
  local list = M.load()
  if #list == 0 then
    opts.on_complete(nil, "no checkpoints recorded")
    return
  end
  local entry = list[#list]
  local ok, msg = M.rollback(entry)
  if not ok then
    opts.on_complete(nil, msg)
    return
  end
  opts.on_complete(msg, nil)
end

--- Return the checkpoint custom tool.
function M.checkpoint_tool()
  return checkpoint
end

--- Return the rollback custom tool.
function M.rollback_tool()
  return rollback
end

return M
