---@mod agent_core.import One-time migration of rules/skills from another IDE
---@brief [[
--- Migrates an existing third-party IDE setup into agent_core's own neutral
--- directories (.agent_core/rules, .agent_core/skills, and
--- <data>/agent_core/{rules,skills}). This module is the ONLY place in the
--- plugin that names the source IDE on-disk paths (Cursor's .cursor/* and
--- CURSOR.md, and VSCode's copilot-instructions.md); every other module is
--- brand-neutral. Import is single-source (a user picks Cursor OR VSCode, not a
--- combined migration) and non-destructive: existing files are never
--- overwritten.
---@brief ]]

local M = {}

--- Read a file as a string, or nil when unreadable.
---@param path string
---@return string|nil
local function read_file(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  return table.concat(vim.fn.readfile(path), "\n")
end

--- Last path component.
---@param p string
---@return string
local function basename(p)
  return p:match("([^/\\]+)$") or p
end

--- Resolve the project root and data dir (overridable for tests).
---@return string root
---@return string data_dir
local function roots(root, data_dir)
  return root or require("agent_core.indexer").root(), data_dir or vim.fn.stdpath("data")
end

--- Compute the {src, dst} copy plan for the Cursor source. Pure mapping:
--- no files are written. Only readable sources are included.
---@param root string|nil project root (nil = detected)
---@param data_dir string|nil user data dir (nil = stdpath("data"))
---@return {src:string,dst:string}[]
function M.cursor_plan(root, data_dir)
  local r, d = roots(root, data_dir)
  local home = vim.fn.expand("~")
  local plan = {}

  local function add(src, dst)
    if vim.fn.filereadable(src) == 1 then
      plan[#plan + 1] = { src = src, dst = dst }
    end
  end

  local function add_glob(src_dir, pattern, dst_dir, rel)
    if vim.fn.isdirectory(src_dir) ~= 1 then
      return
    end
    for _, p in ipairs(vim.fn.glob(src_dir .. "/" .. pattern, false, true)) do
      add(p, dst_dir .. "/" .. rel(p))
    end
  end

  -- Project rules + skills.
  add_glob(r .. "/.cursor/rules", "*.mdc", r .. "/.agent_core/rules", basename)
  add_glob(r .. "/.cursor/rules", "*.md", r .. "/.agent_core/rules", basename)
  add_glob(r .. "/.cursor/skills", "*/SKILL.md", r .. "/.agent_core/skills", function(p)
    return (p:match("([^/\\]+)[/\\]SKILL%.md$") or "skill") .. "/SKILL.md"
  end)

  -- User rules + skills.
  add_glob(home .. "/.cursor/rules", "*.mdc", d .. "/agent_core/rules", basename)
  add_glob(home .. "/.cursor/rules", "*.md", d .. "/agent_core/rules", basename)
  add_glob(home .. "/.cursor/skills", "*/SKILL.md", d .. "/agent_core/skills", function(p)
    return (p:match("([^/\\]+)[/\\]SKILL%.md$") or "skill") .. "/SKILL.md"
  end)

  -- Root instruction files, rewritten to neutral filenames.
  add(r .. "/CURSOR.md", r .. "/.agent_core/rules/ide_instructions.md")
  add(r .. "/.cursorrules", r .. "/.agent_core/rules/legacy_instructions.md")

  return plan
end

--- Compute the {src, dst} copy plan for the VSCode source (Copilot instructions).
---@param root string|nil project root (nil = detected)
---@param data_dir string|nil user data dir (unused; kept for a uniform signature)
---@return {src:string,dst:string}[]
function M.vscode_plan(root, data_dir)
  local r = roots(root, data_dir)
  local plan = {}

  local function add(src, dst)
    if vim.fn.filereadable(src) == 1 then
      plan[#plan + 1] = { src = src, dst = dst }
    end
  end

  add(r .. "/.github/copilot-instructions.md", r .. "/.agent_core/rules/copilot_instructions.md")
  add(r .. "/copilot-instructions.md", r .. "/.agent_core/rules/copilot_instructions.md")

  return plan
end

--- Execute a copy plan non-destructively. Returns a report of what happened.
---@param plan {src:string,dst:string}[]
---@return {copied:string[],skipped:string[]}
function M.import_plan(plan)
  local report = { copied = {}, skipped = {} }
  for _, item in ipairs(plan) do
    local src, dst = item.src, item.dst
    if vim.fn.filereadable(dst) == 1 then
      report.skipped[#report.skipped + 1] = dst
    else
      local content = read_file(src)
      if content ~= nil then
        vim.fn.mkdir(vim.fn.fnamemodify(dst, ":h"), "p")
        local f = io.open(dst, "w")
        if f then
          f:write(content)
          f:close()
          report.copied[#report.copied + 1] = dst
        end
      end
    end
  end
  return report
end

--- Run the Cursor migration and report.
---@return {copied:string[],skipped:string[]}
function M.import_from_cursor()
  return M.import_plan(M.cursor_plan())
end

--- Run the VSCode migration and report.
---@return {copied:string[],skipped:string[]}
function M.import_from_vscode()
  return M.import_plan(M.vscode_plan())
end

--- Notify the result of an import.
---@param label string
---@param report {copied:string[],skipped:string[]}
local function notify_report(label, report)
  local copied, skipped = #report.copied, #report.skipped
  if copied == 0 and skipped == 0 then
    vim.notify("AgentImport: no " .. label .. " files found to import", vim.log.levels.WARN)
    return
  end
  local msg = string.format("AgentImport (%s): %d copied, %d skipped (already present)", label, copied, skipped)
  vim.notify(msg, vim.log.levels.INFO)
end

--- Backing for :AgentImport: pick a single source and migrate it.
function M.import_cmd()
  local sources = {
    { label = "Cursor", run = M.import_from_cursor },
    { label = "VSCode", run = M.import_from_vscode },
  }

  local ok, Snacks = pcall(require, "snacks.picker")
  if ok and type(Snacks) == "table" and type(Snacks.pick) == "function" then
    Snacks.pick({
      title = "Import from",
      items = sources,
      layout = { preview = false },
      format = function(item)
        return { { item.label } }
      end,
      confirm = function(picker, item)
        picker:close()
        if item then
          notify_report(item.label, item.run())
        end
      end,
    })
    return
  end

  local labels = vim.tbl_map(function(s)
    return s.label
  end, sources)
  vim.ui.select(labels, { prompt = "Import from" }, function(choice)
    for _, s in ipairs(sources) do
      if s.label == choice then
        notify_report(s.label, s.run())
        return
      end
    end
  end)
end

function M.setup() end

return M
