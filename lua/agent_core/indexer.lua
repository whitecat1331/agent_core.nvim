---@mod agent_core.indexer Generates a committable project brief (AVANTE.md)
--- and refreshes it on file changes. The brief is structural only: file
--- paths, language counts, key files, and build/test commands. It never
--- embeds file contents, so it cannot leak secrets.
---@brief ]]

local M = {}

--- Detect the project root for an arbitrary directory: git root if available,
--- otherwise the nearest ancestor containing a .git directory, otherwise the
--- directory itself.
---@param dir string
---@return string
function M.root_for(dir)
  dir = dir or vim.fn.getcwd()
  local ok, out = pcall(vim.fn.systemlist, { "git", "-C", dir, "rev-parse", "--show-toplevel" })
  if ok and out and #out > 0 and out[1] ~= "" and vim.fn.isdirectory(out[1]) == 1 then
    return out[1]:gsub("[\r\n]", "")
  end

  -- Walk up to the nearest .git directory (handles subdirectories inside a repo
  -- and shallow worktrees where rev-parse might be unavailable).
  local cur = vim.fn.fnamemodify(dir, ":p"):gsub("[\\/]+$", "")
  while cur ~= "" do
    if vim.fn.isdirectory(cur .. "/.git") == 1 then
      return cur
    end
    local parent = vim.fn.fnamemodify(cur, ":h")
    if parent == cur then
      break
    end
    cur = parent
  end
  return vim.fn.fnamemodify(dir, ":p"):gsub("[\\/]+$", "")
end

--- Detect the active project root: git root if available, otherwise cwd.
function M.root()
  return M.root_for(vim.fn.getcwd())
end

function M.brief_path()
  local cfg = require("agent_core").config
  return M.root() .. "/" .. cfg.brief_filename
end

local EXT_LANG = {
  go = "Go",
  py = "Python",
  js = "JavaScript",
  mjs = "JavaScript",
  cjs = "JavaScript",
  ts = "TypeScript",
  tsx = "TypeScript",
  jsx = "JavaScript",
  rs = "Rust",
  java = "Java",
  c = "C",
  h = "C/C++",
  cpp = "C++",
  cc = "C++",
  hpp = "C++",
  cs = "C#",
  rb = "Ruby",
  php = "PHP",
  lua = "Lua",
  sh = "Shell",
  bash = "Shell",
  html = "HTML",
  css = "CSS",
  scss = "SCSS",
  vue = "Vue",
  svelte = "Svelte",
  sql = "SQL",
  md = "Markdown",
  json = "JSON",
  yml = "YAML",
  yaml = "YAML",
  toml = "TOML",
  tf = "Terraform",
  proto = "Protobuf",
}

local KEY_FILES = {
  "README.md",
  "README",
  "AGENTS.md",
  "CLAUDE.md",
  "CURSOR.md",
  "AVANTE.md",
  "WORKFLOW.md",
  "COMMIT_CONVENTION.md",
  "go.mod",
  "package.json",
  "pyproject.toml",
  "requirements.txt",
  "Cargo.toml",
  "pom.xml",
  "build.gradle",
  "Gemfile",
  "Makefile",
  "Dockerfile",
  "docker-compose.yml",
  "docker-compose.yaml",
  "main.go",
  "cmd",
  "main.py",
  "app.py",
  "manage.py",
  "main.rs",
  "main.js",
  "index.js",
  "init.lua",
  "main.lua",
  "schema.sql",
  ".env.example",
  ".gitignore",
}

-- Marker files that imply a language semnav can index (Go/Rust/JS/Python).
local SEMNAV_MARKERS = {
  "go.mod",
  "Cargo.toml",
  "package.json",
  "pyproject.toml",
  "requirements.txt",
}

-- Project roots where semnav was opted in (for daemon cleanup on exit).
local tracked_roots = {}

local function is_excluded(rel, excluded)
  for _, part in ipairs(vim.split(rel, "/", { plain = true })) do
    if vim.tbl_contains(excluded, part) then
      return true
    end
  end
  return false
end

--- Flat list of relative file paths for an arbitrary root (git-aware with find
--- fallback).
---@param root string
---@return string[]
function M.file_list_for(root)
  local cfg = require("agent_core").config
  local r = root or M.root()

  local ok, out = pcall(vim.fn.systemlist, { "git", "-C", r, "ls-files" })
  if ok and out and vim.v.shell_error == 0 and #out > 0 then
    local res = {}
    for _, line in ipairs(out) do
      line = line:gsub("[\r\n]", "")
      if line ~= "" and not is_excluded(line, cfg.excluded_dirs) then
        table.insert(res, line)
      end
    end
    return res
  end

  local ok2, out2 = pcall(vim.fn.systemlist, {
    "find",
    r,
    "-type",
    "f",
    "-not",
    "-path",
    "*/.git/*",
  })
  if not ok2 or not out2 or vim.v.shell_error ~= 0 then
    return {}
  end
  local prefix = r:gsub("\\", "/") .. "/"
  local res = {}
  for _, line in ipairs(out2) do
    local rel = line:gsub("\\", "/"):gsub("^" .. vim.pesc(prefix), "")
    rel = rel:gsub("[\r\n]", "")
    if rel ~= "" and not is_excluded(rel, cfg.excluded_dirs) then
      table.insert(res, rel)
    end
  end
  return res
end

--- Flat list of relative file paths for the active project root.
function M.file_list()
  return M.file_list_for(M.root())
end

local function language_counts(files)
  local counts = {}
  for _, f in ipairs(files) do
    local ext = f:match("%.([%w]+)$")
    if ext then
      local lang = EXT_LANG[ext:lower()]
      if lang then
        counts[lang] = (counts[lang] or 0) + 1
      end
    end
  end
  local list = {}
  for lang, n in pairs(counts) do
    table.insert(list, { lang = lang, n = n })
  end
  table.sort(list, function(a, b)
    return a.n > b.n
  end)
  return list
end

--- One-line structural summary for a root: top language counts. Used by the
--- workspace registry; no full brief is required. Empty string when no files.
---@param root string
---@return string
function M.summary_for(root)
  local files = M.file_list_for(root)
  if #files == 0 then
    return ""
  end
  local langs = language_counts(files)
  if #langs == 0 then
    return "(" .. #files .. " files)"
  end
  local top = {}
  for i = 1, math.min(3, #langs) do
    top[#top + 1] = langs[i].lang
  end
  return table.concat(top, ", ") .. " (" .. #files .. " files)"
end

local function key_files(files)
  local found = {}
  local seen = {}
  for _, f in ipairs(files) do
    local base = f:match("([^/]+)$")
    if base and vim.tbl_contains(KEY_FILES, base) and not seen[f] then
      table.insert(found, f)
      seen[f] = true
    end
  end
  table.sort(found)
  return found
end

local function top_level_entries(files)
  local entries = {}
  local seen = {}
  for _, f in ipairs(files) do
    local top = f:match("^([^/]+)")
    if top and not seen[top] then
      table.insert(entries, top)
      seen[top] = true
    end
  end
  table.sort(entries)
  return entries
end

local function detect_commands(files)
  local set = {}
  for _, f in ipairs(files) do
    set[f] = true
  end
  local has = function(name)
    for _, f in ipairs(files) do
      if f == name or f:find("/" .. vim.pesc(name) .. "$") then
        return true
      end
    end
    return false
  end

  local cmds = {}
  if has("go.mod") then
    table.insert(cmds, "go mod tidy && go run .")
    table.insert(cmds, "go test ./...")
  end
  if has("package.json") then
    table.insert(cmds, "npm install")
    table.insert(cmds, "npm run build  |  npm test")
  end
  if has("Cargo.toml") then
    table.insert(cmds, "cargo build --release")
    table.insert(cmds, "cargo test")
  end
  if has("pyproject.toml") or has("requirements.txt") then
    table.insert(cmds, "pip install -r requirements.txt")
    table.insert(cmds, "pytest")
  end
  if has("Makefile") then
    table.insert(cmds, "make")
  end
  return cmds
end

local function escape_md(s)
  return s:gsub("([*_`#|%[%]])", "\\%1")
end

function M.assemble(files)
  local root = M.root()
  local name = root:match("([^/]+)$") or root
  local langs = language_counts(files)
  local keys = key_files(files)
  local entries = top_level_entries(files)
  local cmds = detect_commands(files)

  local out = {}
  out[#out + 1] = "<!-- AUTO-GENERATED by agent_core (Neovim). Do not edit by hand."
  out[#out + 1] = "     Regenerated automatically as the project changes."
  out[#out + 1] = "     NEVER store secrets, API keys, tokens, or passwords in this file. -->"
  out[#out + 1] = ""
  out[#out + 1] = "# Project Brief"
  out[#out + 1] = ""
  out[#out + 1] = "## Overview"
  out[#out + 1] = ""
  out[#out + 1] = "- Project: `" .. escape_md(name) .. "`"
  out[#out + 1] = "- Tracked files: " .. #files

  if #langs > 0 then
    local lang_parts = {}
    for _, l in ipairs(langs) do
      table.insert(lang_parts, l.lang .. " (" .. l.n .. ")")
    end
    out[#out + 1] = "- Languages: " .. table.concat(lang_parts, ", ")
  end
  out[#out + 1] = ""

  out[#out + 1] = "## Directory layout (top level)"
  out[#out + 1] = ""
  for _, e in ipairs(entries) do
    out[#out + 1] = "- `" .. escape_md(e) .. "`"
  end
  out[#out + 1] = ""

  out[#out + 1] = "## Key files"
  out[#out + 1] = ""
  if #keys > 0 then
    for _, k in ipairs(keys) do
      out[#out + 1] = "- `" .. escape_md(k) .. "`"
    end
  else
    out[#out + 1] = "- (none detected)"
  end
  out[#out + 1] = ""

  if #cmds > 0 then
    out[#out + 1] = "## Build & test"
    out[#out + 1] = ""
    for _, c in ipairs(cmds) do
      out[#out + 1] = "- `" .. escape_md(c) .. "`"
    end
    out[#out + 1] = ""
  end

  out[#out + 1] = "## Notes for the agent"
  out[#out + 1] = ""
  out[#out + 1] = "- This brief is structural only; for deeper context use the MCP `search` tool"
  out[#out + 1] = "  (semantic) or `get_repo_map` (PageRank-ranked architecture map)."
  out[#out + 1] = "- The brief reflects the repo at a point in time; it is refreshed on save."

  return table.concat(out, "\n") .. "\n"
end

--- Regenerate the brief and write it to disk.
function M.refresh(opts)
  opts = opts or {}
  local path = M.brief_path()
  local files = M.file_list()
  if #files == 0 then
    if opts.notify then
      vim.notify("No files found under " .. M.root(), vim.log.levels.WARN)
    end
    return
  end

  local content = M.assemble(files)
  local f = io.open(path, "w")
  if not f then
    if opts.notify then
      vim.notify("Could not write " .. path, vim.log.levels.ERROR)
    end
    return
  end
  f:write(content)
  f:close()

  if opts.notify then
    vim.notify("Wrote brief: " .. path .. " (" .. #files .. " files)", vim.log.levels.INFO)
  end

  -- Opt into semnav (project-scoped MCP graph indexer) on explicit :AgentIndex.
  if opts.notify then
    M.ensure_semnav({ notify = true })
  end
end

--- Resolve the semnav binary to an absolute path (mcphub spawns it reliably
--- regardless of the parent process PATH).
local function semnav_bin()
  local cfg = require("agent_core").config
  local bin = cfg.semnav_bin or "semnav"
  if not bin:match("^/") then
    local resolved = vim.fn.exepath(bin)
    if resolved and resolved ~= "" then
      bin = resolved
    end
  end
  return bin
end

--- True when any tracked file implies a semnav-supported language.
function M.supports_semnav(files)
  for _, f in ipairs(files) do
    if vim.tbl_contains(SEMNAV_MARKERS, f) then
      return true
    end
  end
  return false
end

--- Write the project-scoped .mcphub/servers.json registering semnav for root.
function M.write_semnav_config(root)
  local dir = root .. "/.mcphub"
  vim.fn.mkdir(dir, "p")
  local content = vim.json.encode({
    mcpServers = {
      semnav = {
        command = semnav_bin(),
        args = { "serve", root },
        cwd = root,
        env = { SEMNAV_CACHE_DIR = root .. "/.semnav" },
      },
    },
  })
  local f = io.open(dir .. "/servers.json", "w")
  if f then
    f:write(content)
    f:close()
  end
end

--- Opt a project into semnav: write its MCP config, run a one-time `semnav
--- index` if the graph DB is missing, and track the root for daemon cleanup.
--- Subsequent freshness is handled by semnav's own FsWatcher while `serve` runs.
function M.ensure_semnav(opts)
  opts = opts or {}
  local root = M.root()
  local files = M.file_list()
  if not M.supports_semnav(files) then
    return false
  end

  M.write_semnav_config(root)
  tracked_roots[root] = true

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
          vim.notify("semnav index complete for " .. root, vim.log.levels.INFO)
        end
      elseif opts.notify then
        vim.notify("semnav index failed (exit " .. tostring(obj.code) .. "): " .. root, vim.log.levels.ERROR)
      end
    end)
  end)

  return true
end

--- Stop any tracked semnav daemons (called on VimLeavePre).
function M.stop_daemons()
  for root in pairs(tracked_roots) do
    vim.fn.jobstart({ semnav_bin(), "daemon", "stop", root }, { detach = true })
  end
  tracked_roots = {}
end

local pending = false

--- Debounced refresh; only runs if a brief already exists (non-intrusive).
function M.schedule_refresh()
  if vim.fn.filereadable(M.brief_path()) ~= 1 then
    return
  end
  if pending then
    return
  end
  pending = true
  local cfg = require("agent_core").config
  vim.defer_fn(function()
    pending = false
    M.refresh()
  end, cfg.refresh_debounce_ms)
end

function M.setup()
  vim.api.nvim_create_augroup("agent_core_indexer", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = "agent_core_indexer",
    callback = function()
      M.schedule_refresh()
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = "agent_core_indexer",
    callback = function()
      M.stop_daemons()
    end,
  })
end

return M
