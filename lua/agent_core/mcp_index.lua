---@mod agent_core.mcp_index Multi-root MCP server wiring.
---@brief [[
--- Owns the global ~/.config/mcphub/servers.json managed block. Registers a
--- single ripvec server (native multi-root: every retrieval tool accepts a
--- `root` parameter) plus one per-project `semnav-<slug>` server for each
--- registered project that supports a semnav language. Runs a one-time
--- `semnav index` when a graph DB is missing and stops tracked daemons on
--- VimLeavePre. Non-agent_core servers in the file are preserved.
---@brief ]]

local M = {}

local Indexer ---@type agent_core.indexer
local Workspace ---@type agent_core.workspace

local function get_indexer()
  if not Indexer then
    Indexer = require("agent_core.indexer")
  end
  return Indexer
end

local function get_workspace()
  if not Workspace then
    Workspace = require("agent_core.workspace")
  end
  return Workspace
end

--- Resolve the semnav binary to an absolute path when possible.
local function semnav_bin()
  local cfg = require("agent_core").config
  return require("agent_core.platform").resolve_bin(cfg.semnav_bin or "semnav")
end

--- Resolve the ripvec MCP binary to an absolute path when possible.
local function ripvec_bin()
  local cfg = require("agent_core").config
  return require("agent_core.platform").resolve_bin(cfg.ripvec_bin or "ripvec-mcp")
end

--- Global servers.json path. Best-effort: track mcphub's own resolved config
--- (which the user may override via mcphub.setup), falling back to mcphub's
--- default location (identical on Linux, macOS, and Windows).
function M.global_servers_path()
  local ok, hub = pcall(require, "mcphub.config")
  if ok and type(hub) == "table" then
    local ok2, path = pcall(function()
      return hub.config
    end)
    if ok2 and type(path) == "string" and path ~= "" then
      return path
    end
  end
  return vim.fn.expand("~/.config/mcphub/servers.json")
end

--- Unique, filesystem-safe slug for a project root.
function M.slug_for(root)
  local name = root:match("([^/\\]+)$") or root
  name = name:lower()
  name = name:gsub("[^%w%-]", "-")
  name = name:gsub("-+", "-"):gsub("^-+", ""):gsub("-+$", "")
  if name == "" then
    name = "project"
  end
  local hash = 0
  for i = 1, #root do
    hash = (hash * 31 + root:byte(i)) % 65536
  end
  return string.format("semnav-%s-%04x", name, hash)
end

--- Atomic JSON write (tmp + rename) so a crash mid-write never corrupts the
--- file.
local function atomic_write(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then
    return false
  end
  f:write(content)
  f:close()
  if vim.fn.has("win32") == 1 then
    vim.fn.delete(path)
  end
  return vim.fn.rename(tmp, path) == 0
end

--- Rebuild the global servers.json from the registry. Preserves any non-
--- agent_core servers and always recomputes the managed keys (ripvec + one
--- semnav server per supported project). A one-time .bak backup is written
--- before the first managed rewrite.
function M.write_global()
  local path = M.global_servers_path()

  local servers = {}
  local f = io.open(path, "r")
  if f then
    local content = f:read("*a")
    f:close()
    local ok, decoded = pcall(vim.json.decode, content)
    if ok and type(decoded) == "table" and type(decoded.mcpServers) == "table" then
      servers = decoded.mcpServers
    end
  end

  local backup = path .. ".bak"
  if vim.fn.filereadable(path) == 1 and vim.fn.filereadable(backup) ~= 1 then
    vim.fn.writefile(vim.fn.readfile(path, "b"), backup, "b")
  end

  -- Drop agent_core-managed keys so they are always recomputed from the
  -- registry (stale roots get removed on the next write).
  for key in pairs(servers) do
    if key == "ripvec" or key:match("^semnav%-") then
      servers[key] = nil
    end
  end

  -- ripvec: native multi-root; the agent passes a `root` per tool call.
  servers.ripvec = {
    command = ripvec_bin(),
    args = {},
    cwd = "${workspaceFolder}",
    env = { RIPVEC_MCP_ENGINE = "ripvec" },
  }

  -- One semnav server per supported project.
  local idx = get_indexer()
  for _, p in ipairs(get_workspace().list()) do
    local files = idx.file_list_for(p.path)
    if idx.supports_semnav(files) then
      local slug = M.slug_for(p.path)
      servers[slug] = {
        command = semnav_bin(),
        args = { "serve", p.path },
        cwd = p.path,
        env = { SEMNAV_CACHE_DIR = p.path .. "/.semnav" },
      }
    end
  end

  atomic_write(path, vim.json.encode({ mcpServers = servers }))
end

--- Run a one-time `semnav index <root>` if the graph DB is missing. Returns
--- true when the project is eligible (supported language), false otherwise.
---@param root string
---@param opts? { notify?: boolean }
---@return boolean
function M.index_project(root, opts)
  opts = opts or {}
  local idx = get_indexer()
  local files = idx.file_list_for(root)
  if not idx.supports_semnav(files) then
    return false
  end

  local graph_db = root .. "/.semnav/graph.db"
  if vim.fn.filereadable(graph_db) == 1 then
    return true
  end

  if opts.notify then
    vim.notify("Indexing " .. root .. " with semnav (one-time)…", vim.log.levels.INFO)
  end

  vim.system({ semnav_bin(), "index", root }, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code == 0 then
        if opts.notify then
          vim.notify("semnav index complete: " .. root, vim.log.levels.INFO)
        end
      elseif opts.notify then
        vim.notify("semnav index failed (exit " .. tostring(obj.code) .. "): " .. root, vim.log.levels.ERROR)
      end
    end)
  end)

  return true
end

--- Index every registered, semnav-eligible project. Returns the count of
--- projects kicked off.
---@param opts? { notify?: boolean }
---@return integer
function M.index_all(opts)
  local count = 0
  for _, p in ipairs(get_workspace().list()) do
    if M.index_project(p.path, opts) then
      count = count + 1
    end
  end
  return count
end

--- Stop any running semnav daemons for registered projects (VimLeavePre).
function M.stop_daemons()
  for _, p in ipairs(get_workspace().list()) do
    vim.fn.jobstart({ semnav_bin(), "daemon", "stop", p.path }, { detach = true })
  end
end

function M.setup()
  local ws = require("agent_core").config.workspace or {}

  -- Refresh the global servers.json only when there is something to register.
  -- With an empty registry (headless tests, first run) we leave the file alone.
  -- mcphub starts servers lazily (auto_toggle_mcp_servers), so N registered
  -- projects do not spawn N daemons at startup.
  if ws.enabled ~= false and #get_workspace().list() > 0 then
    M.write_global()
  end

  vim.api.nvim_create_augroup("agent_core_mcp_index", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = "agent_core_mcp_index",
    callback = function()
      M.stop_daemons()
    end,
  })
end

return M
