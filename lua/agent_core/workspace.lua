---@mod agent_core.workspace Persistent multi-root workspace registry.
---@brief [[
--- Registers multiple project roots so the agent can search and reason across
--- every project, not just the active repo. Persists a compact index (name,
--- path, one-line summary) in <data>/agent_core/workspace.json and injects it
--- into the system prompt via get_workspace_prompt(). The registry only stores
--- structural metadata (paths + language summaries); it never embeds file
--- contents or secrets.
---@brief ]]

local M = {}

local Indexer ---@type agent_core.indexer

--- Resolve the indexer lazily to avoid load-order coupling.
local function get_indexer()
  if not Indexer then
    Indexer = require("agent_core.indexer")
  end
  return Indexer
end

--- Resolve mcp_index lazily (workspace.add/scan trigger indexing).
local function get_mcp_index()
  return require("agent_core.mcp_index")
end

--- Registry file path. Override with config.workspace.registry_dir.
function M.registry_path()
  local cfg = require("agent_core").config
  local ws = cfg.workspace or {}
  if ws.registry_dir and ws.registry_dir ~= "" then
    return vim.fn.expand(ws.registry_dir) .. "/workspace.json"
  end
  return vim.fn.stdpath("data") .. "/agent_core/workspace.json"
end

--- Atomic JSON write (tmp + rename) so a crash mid-write never corrupts the
--- registry.
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

--- Read the registry as a plain list of project entries, or {} on any error.
function M.load()
  local f = io.open(M.registry_path(), "r")
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

--- Persist the registry (list of project entries).
---@return boolean success
function M.save(projects)
  return atomic_write(M.registry_path(), vim.json.encode(projects))
end

--- Normalize a user-supplied path: expand ~/env vars, make absolute, strip a
--- trailing separator. Returns nil for empty input.
local function normalize_path(p)
  if not p or p == "" then
    return nil
  end
  p = vim.fn.expand(p)
  p = vim.fn.fnamemodify(p, ":p")
  return p:gsub("[\\/]+$", "")
end

--- Add a project (by directory) to the registry. Detects the git root, derives
--- a name and a one-line summary, dedupes, saves, and (optionally) triggers a
--- one-time semantic index. Returns the entry, or nil if the path is invalid.
---@param path string
---@param opts? { notify?: boolean }
---@return {path:string,name:string,summary:string,added_at:integer}|nil
function M.add(path, opts)
  opts = opts or {}
  local dir = normalize_path(path)
  if not dir then
    return nil
  end
  if vim.fn.isdirectory(dir) ~= 1 then
    if opts.notify then
      vim.notify("Workspace: not a directory: " .. dir, vim.log.levels.ERROR)
    end
    return nil
  end

  local idx = get_indexer()
  local root = idx.root_for(dir) or dir
  local name = root:match("([^/\\]+)$") or root
  local summary = idx.summary_for(root)

  for _, existing in ipairs(M.load()) do
    if existing.path == root then
      if opts.notify then
        vim.notify("Workspace: already registered: " .. name, vim.log.levels.INFO)
      end
      return existing
    end
  end

  local entry = { path = root, name = name, summary = summary, added_at = os.time() }
  local projects = M.load()
  table.insert(projects, entry)
  M.save(projects)

  local cfg = require("agent_core").config
  local ws = cfg.workspace or {}
  if ws.auto_index_on_add ~= false then
    get_mcp_index().write_global()
    get_mcp_index().index_project(root, opts)
  end

  if opts.notify then
    vim.notify("Workspace: added " .. name, vim.log.levels.INFO)
  end
  return entry
end

--- Find git repositories under a parent directory (portable glob walk, bounded
--- by depth). Returns a list of absolute repo roots.
---@param base string
---@param maxdepth integer
---@return string[]
local function find_repos(base, maxdepth)
  local repos = {}
  local function walk(dir, depth)
    if depth > maxdepth then
      return
    end
    local children = vim.fn.glob(dir .. "/*", false, true)
    for _, child in ipairs(children) do
      if vim.fn.isdirectory(child) == 1 then
        if vim.fn.isdirectory(child .. "/.git") == 1 then
          repos[#repos + 1] = normalize_path(child)
        else
          walk(child, depth + 1)
        end
      end
    end
  end
  walk(base, 1)
  return repos
end

--- Scan a parent directory for git repos and register each. When `base` is
--- itself a repo it is added directly. Returns the number of newly added repos.
---@param parent string|nil
---@param opts? { notify?: boolean, depth?: integer }
---@return integer added
function M.scan(parent, opts)
  opts = opts or {}
  local base = normalize_path(parent) or vim.fn.getcwd()
  if vim.fn.isdirectory(base) ~= 1 then
    if opts.notify then
      vim.notify("Workspace: not a directory: " .. base, vim.log.levels.ERROR)
    end
    return 0
  end

  local candidates = {}
  if vim.fn.isdirectory(base .. "/.git") == 1 then
    candidates[#candidates + 1] = base
  end
  for _, repo in ipairs(find_repos(base, opts.depth or 2)) do
    candidates[#candidates + 1] = repo
  end

  local before = #M.load()
  for _, repo in ipairs(candidates) do
    M.add(repo, { notify = false })
  end

  local cfg = require("agent_core").config
  local ws = cfg.workspace or {}
  if ws.auto_index_on_scan ~= false then
    get_mcp_index().write_global()
    get_mcp_index().index_all({ notify = opts.notify })
  end

  local added = #M.load() - before
  if opts.notify then
    vim.notify("Workspace: scanned " .. base .. " — " .. added .. " new project(s)", vim.log.levels.INFO)
  end
  return added
end

--- Open a picker over the registry (snacks.nvim if present, else vim.ui.select).
---@param cb fun(project: {path:string,name:string,summary:string,added_at:integer}|nil)
function M.pick(cb)
  local projects = M.load()
  if #projects == 0 then
    vim.notify("Workspace: empty — run :AgentWorkspaceAdd or :AgentWorkspaceScan", vim.log.levels.WARN)
    cb(nil)
    return
  end

  local items = {}
  for _, p in ipairs(projects) do
    table.insert(items, {
      text = string.format("%s  |  %s", p.name, p.summary or p.path),
      project = p,
    })
  end

  local ok, Snacks = pcall(require, "snacks.picker")
  if ok and type(Snacks) == "table" and type(Snacks.pick) == "function" then
    Snacks.pick({
      title = "Workspace",
      items = items,
      layout = { preview = false },
      format = function(item)
        return { { item.text } }
      end,
      confirm = function(picker, item)
        picker:close()
        cb(item and item.project or nil)
      end,
    })
    return
  end

  local labels = {}
  for _, p in ipairs(projects) do
    table.insert(labels, string.format("%s (%s)", p.name, p.path))
  end
  vim.ui.select(labels, { prompt = "Workspace project" }, function(choice)
    for _, p in ipairs(projects) do
      if choice == string.format("%s (%s)", p.name, p.path) then
        cb(p)
        return
      end
    end
    cb(nil)
  end)
end

--- Return the registered projects. When `notify` is set, print a one-line-per
--- project summary.
---@param notify? boolean
---@return {path:string,name:string,summary:string,added_at:integer}[]
function M.list(notify)
  local projects = M.load()
  if notify then
    if #projects == 0 then
      vim.notify("Workspace: empty", vim.log.levels.INFO)
    else
      local lines = {}
      for _, p in ipairs(projects) do
        table.insert(lines, "- " .. p.name .. " (" .. p.path .. ")")
      end
      vim.notify("Workspace (" .. #projects .. "):\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
    end
  end
  return projects
end

--- Remove a project (picker over the registry).
function M.remove()
  M.pick(function(project)
    if not project then
      return
    end
    local projects = M.load()
    local kept = {}
    for _, p in ipairs(projects) do
      if p.path ~= project.path then
        table.insert(kept, p)
      end
    end
    M.save(kept)
    get_mcp_index().write_global()
    vim.notify("Workspace: removed " .. project.name, vim.log.levels.INFO)
  end)
end

--- Activate a project: chdir into it and refresh its brief.
function M.activate(project)
  if not project or not project.path then
    return
  end
  vim.fn.chdir(project.path)
  get_indexer().refresh()
  vim.notify("Workspace: " .. project.name, vim.log.levels.INFO)
end

--- Pick a project and activate it.
function M.switch()
  M.pick(function(project)
    if project then
      M.activate(project)
    end
  end)
end

--- Build the compact workspace index for the system prompt. Empty string when
--- no projects are registered. Bounded by config.workspace.prompt_max_chars.
---@return string
function M.get_workspace_prompt()
  local projects = M.load()
  if #projects == 0 then
    return ""
  end

  local cfg = require("agent_core").config
  local ws = cfg.workspace or {}
  local active_root = get_indexer().root()

  local lines = {
    "## Registered workspace projects",
    "",
    "You may search, read, and edit across these registered projects. Reference",
    "them by name or path. The active project already has its full brief above;",
    "for other projects use the MCP tools (ripvec `search`/`get_repo_map` with a",
    "`root` parameter, or the per-project `semnav-*` servers) before reading files.",
    "",
  }
  for _, p in ipairs(projects) do
    local marker = p.path == active_root and " (active)" or ""
    lines[#lines + 1] = "- " .. p.name .. marker .. ": " .. p.path
    if p.summary and p.summary ~= "" then
      lines[#lines + 1] = "  " .. p.summary
    end
  end

  local content = table.concat(lines, "\n")
  local max = ws.prompt_max_chars or 6000
  if #content > max then
    content = content:sub(1, max) .. "\n\n[... workspace index truncated ...]"
  end
  return content
end

function M.setup()
  -- Touch the registry once at startup so a corrupt file is surfaced early
  -- (and to give users a discoverable location for the JSON).
  M.load()
end

return M
