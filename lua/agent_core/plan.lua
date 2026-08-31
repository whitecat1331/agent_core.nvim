---@mod agent_core.plan Plan-mode Markdown artifact + Build step
---@brief [[
--- Plan mode: instead of editing code, the model researches the
--- codebase, asks clarifying questions, and writes an editable Markdown plan
--- (with file paths, an ordered TODO checklist, and trade-offs) to disk via the
--- `create_plan` / `update_plan` custom tools. The user reviews the file and
--- then triggers the build with :AgentPlanBuild (or :AgentPlanBuildNew for a
--- fresh agent session). Plans land in config.plan.dir (default .agent_core/plans/).
---@brief ]]

local M = {}

--- Statuses that count as "unfinished" (drafted but not yet done).
M.UNFINISHED = { draft = true, in_progress = true }

--- Emit a `User AgentPlanChanged` autocmd so consumers (plan_manager badge)
--- can react to plan/idea mutations without a circular require. Headless-safe:
--- nvim_exec_autocmds is a no-op when no listeners exist.
local function notify_change()
  vim.api.nvim_exec_autocmds("User", { pattern = "AgentPlanChanged", modeline = false })
end

--- Directory where plans live. Override with config.plan.dir.
---@return string
function M.dir()
  local cfg = require("agent_core").config
  local p = cfg.plan or {}
  if p.dir and p.dir ~= "" then
    return vim.fn.expand(p.dir)
  end
  return vim.fn.getcwd() .. "/.agent_core/plans"
end

--- Filesystem-safe slug for a title.
---@param s string
---@return string
function M.slugify(s)
  s = s:lower()
  s = s:gsub("[^%w%-]+", "-")
  s = s:gsub("-+", "-"):gsub("^-+", ""):gsub("-+$", "")
  if s == "" then
    s = "plan"
  end
  return s
end

--- Write a plan file to disk. Returns (ok, path, err).
---@param title string
---@param content string
---@return boolean, string|nil, string|nil
function M.write_plan(title, content)
  vim.fn.mkdir(M.dir(), "p")
  local path = M.dir() .. "/" .. M.slugify(title) .. "-" .. os.date("%Y-%m-%d-%H%M%S") .. ".md"
  local f = io.open(path, "w")
  if not f then
    return false, nil, "could not write " .. path
  end
  f:write("---\n")
  f:write("status: draft\n")
  f:write("created: " .. os.date("%Y-%m-%d %H:%M") .. "\n")
  f:write("---\n\n")
  f:write("# " .. title .. "\n\n")
  f:write("> Plan created " .. os.date("%Y-%m-%d %H:%M") .. " by agent_core plan mode\n\n")
  f:write(content)
  f:write("\n")
  f:close()
  notify_change()
  return true, path, nil
end

--- Minimal frontmatter reader for a plan file: returns (status, created, body).
--- `status` defaults to "draft" and `created` to "" when frontmatter is missing
--- or malformed, so pre-existing bare-Markdown plans stay readable. This is a
--- plan-specific parser (rules.parse_frontmatter is rules-oriented).
---@param content string
---@return string, string, string
local function parse_frontmatter(content)
  local status, created = "draft", ""
  local body = content or ""
  local lines = vim.split(body, "\n")
  if #lines > 0 and lines[1]:match("^%s*%-%-%-%s*$") then
    local i = 2
    local closed = false
    while i <= #lines do
      if lines[i]:match("^%s*%-%-%-%s*$") then
        if i + 1 <= #lines then
          body = table.concat(vim.list_slice(lines, i + 1, #lines), "\n")
        else
          body = ""
        end
        closed = true
        break
      end
      local key, val = lines[i]:match("^%s*([%w_%-]+)%s*:%s*(.-)%s*$")
      if key == "status" and val and val ~= "" then
        status = val
      elseif key == "created" and val and val ~= "" then
        created = val
      end
      i = i + 1
    end
    if not closed then
      body = content
    end
  end
  return status, created, body
end

--- Read the status of a plan file (missing frontmatter defaults to "draft").
---@param path string
---@return string
function M.read_status(path)
  if vim.fn.filereadable(path) ~= 1 then
    return "draft"
  end
  local content = table.concat(vim.fn.readfile(path), "\n")
  local status = parse_frontmatter(content)
  return status
end

--- Set the status of a plan file, rewriting the leading frontmatter and
--- preserving the body. Creates frontmatter when none exists.
---@param path string
---@param status string
---@return boolean, string|nil
function M.set_status(path, status)
  if vim.fn.filereadable(path) ~= 1 then
    return false, "no such plan: " .. path
  end
  local content = table.concat(vim.fn.readfile(path), "\n")
  local _, created, body = parse_frontmatter(content)
  if created == "" then
    created = os.date("%Y-%m-%d %H:%M")
  end
  local f = io.open(path, "w")
  if not f then
    return false, "could not write " .. path
  end
  f:write("---\n")
  f:write("status: " .. status .. "\n")
  f:write("created: " .. created .. "\n")
  f:write("---\n\n")
  f:write(body)
  f:close()
  notify_change()
  return true, nil
end

--- Next status in the lifecycle: draft → in_progress → completed → abandoned → draft.
---@param status string
---@return string
function M.status_cycle(status)
  local order = { draft = 1, in_progress = 2, completed = 3, abandoned = 4 }
  local idx = order[status] or 1
  local next_status = ({ "in_progress", "completed", "abandoned", "draft" })[idx]
  return next_status
end

--- Cycle the status of the plan at `path` in place. Returns the new status.
---@param path string
---@return string
function M.cycle_status(path)
  local status = M.read_status(path)
  local next_status = M.status_cycle(status)
  M.set_status(path, next_status)
  return next_status
end

--- List all plans in plan.dir with their parsed status, sorted newest-first.
--- The title is read from the leading `# ` heading (falling back to the file
--- stem), so it stays human-readable rather than echoing the slug + timestamp.
---@return { path: string, title: string, status: string, mtime: number }[]
function M.list()
  local out = {}
  local files = vim.fn.glob(M.dir() .. "/*.md", false, true)
  for _, p in ipairs(files) do
    local content = table.concat(vim.fn.readfile(p), "\n")
    local status, _, body = parse_frontmatter(content)
    local title = body:match("#%s*(.-)%s*\n")
    if not title or title == "" then
      title = p:gsub(".*[/\\]", ""):gsub("%.md$", "")
    end
    out[#out + 1] = {
      path = p,
      title = title,
      status = status,
      mtime = vim.fn.getftime(p),
    }
  end
  table.sort(out, function(a, b)
    return a.mtime > b.mtime
  end)
  return out
end

--- Canonical outstanding-work summary for the reminder UI: unfinished plans
--- (draft + in_progress), archived plans (completed + abandoned), and undrafted
--- ideas. Pure — derives from list()/ideas() with no extra IO.
---@return { unfinished: number, archived: number, ideas: number }
function M.summary()
  local unfinished, archived, ideas = 0, 0, #M.ideas()
  for _, p in ipairs(M.list()) do
    if M.UNFINISHED[p.status] then
      unfinished = unfinished + 1
    else
      archived = archived + 1
    end
  end
  return { unfinished = unfinished, archived = archived, ideas = ideas }
end

--- Most recently modified plan file in the plans dir, or nil.
---@return string|nil
function M.latest_plan()
  local files = vim.fn.glob(M.dir() .. "/*.md", false, true)
  local best_path, best_time
  for _, p in ipairs(files) do
    local t = vim.fn.getftime(p)
    if not best_time or t > best_time then
      best_path, best_time = p, t
    end
  end
  return best_path
end

--- Path of the ideas backlog JSON file (project-scoped). Override with
--- config.plan.ideas_file; nil → <plan.dir>/../plan_ideas.json.
---@return string
function M.ideas_file()
  local cfg = require("agent_core").config
  local p = cfg.plan or {}
  if p.ideas_file and p.ideas_file ~= "" then
    return vim.fn.expand(p.ideas_file)
  end
  return vim.fn.fnamemodify(M.dir(), ":h") .. "/plan_ideas.json"
end

--- Load the ideas backlog as a list of { id, title, notes, created }.
---@return table[]
function M.ideas()
  local path = M.ideas_file()
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(data) ~= "table" then
    return {}
  end
  local out = {}
  for _, e in ipairs(data) do
    if type(e) == "table" and e.title then
      out[#out + 1] = e
    end
  end
  return out
end

--- Persist the ideas backlog.
---@param items table[]
---@return boolean, string|nil
local function write_ideas(items)
  local path = M.ideas_file()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = io.open(path, "w")
  if not f then
    return false, "could not write " .. path
  end
  f:write(vim.json.encode(items))
  f:write("\n")
  f:close()
  notify_change()
  return true, nil
end

--- Monotonic counter to disambiguate ideas created within the same second.
local idea_seq = 0

--- Add an idea to the backlog. Returns (ok, id).
---@param title string
---@param notes string|nil
---@return boolean, string|nil, string|nil
function M.add_idea(title, notes)
  if not title or title == "" then
    return false, nil, "title is required"
  end
  local items = M.ideas()
  idea_seq = idea_seq + 1
  local id = tostring(os.time()) .. "-" .. tostring(idea_seq)
  items[#items + 1] = {
    id = id,
    title = title,
    notes = notes or "",
    created = os.date("%Y-%m-%d %H:%M"),
  }
  local ok, err = write_ideas(items)
  if not ok then
    return false, nil, err
  end
  return true, id, nil
end

--- Remove an idea by id. Returns (ok, err).
---@param id string
---@return boolean, string|nil
function M.remove_idea(id)
  local items = M.ideas()
  local out = {}
  for _, e in ipairs(items) do
    if e.id ~= id then
      out[#out + 1] = e
    end
  end
  if #out == #items then
    return false, "no such idea: " .. id
  end
  return write_ideas(out)
end

--- Promote an idea into a real plan file (then remove it from the backlog).
--- Returns (ok, path, err).
---@param id string
---@return boolean, string|nil, string|nil
function M.promote_idea(id)
  local items = M.ideas()
  local idea
  for _, e in ipairs(items) do
    if e.id == id then
      idea = e
      break
    end
  end
  if not idea then
    return false, nil, "no such idea: " .. id
  end
  local body = ""
  if idea.notes and idea.notes ~= "" then
    body = idea.notes .. "\n"
  end
  local ok, path, err = M.write_plan(idea.title, body)
  if not ok then
    return false, nil, err
  end
  M.remove_idea(id)
  return true, path, nil
end

--- Resolve a plan path from an explicit arg, the active plan, or the latest.
---@param arg string|nil
---@return string|nil
function M.resolve_path(arg)
  if arg and arg ~= "" then
    return vim.fn.fnamemodify(arg, ":p")
  end
  return vim.g.agent_plan_path or M.latest_plan()
end

---@type AgentTool
local create_plan = {
  name = "create_plan",
  description = "Write an implementation plan to a Markdown file for the user to review before any "
    .. "code changes. Include exact file paths, the specific changes per file, an ordered "
    .. "TODO checklist (use '- [ ]' items), and trade-offs/risks. Do NOT edit code while planning.",
  param = {
    type = "table",
    fields = {
      {
        name = "title",
        description = "Short plan title (used as the file name and heading).",
        type = "string",
      },
      {
        name = "content",
        description = "The full Markdown plan body (file paths, steps, TODO checklist, trade-offs).",
        type = "string",
      },
    },
    required = { "title", "content" },
    usage = {
      title = "Short plan title",
      content = "Full Markdown plan body",
    },
  },
  returns = {
    {
      name = "result",
      description = "Confirmation with the written plan path",
      type = "string",
    },
    {
      name = "error",
      description = "Error message if the plan could not be written",
      type = "string",
      optional = true,
    },
  },
}

---@type AgentToolFunc<{ title: string, content: string }>
function create_plan.func(input, opts)
  if not opts.on_complete then
    return nil, "on_complete not provided"
  end
  local title = input.title
  local content = input.content
  if not title or title == "" then
    return nil, "title is required"
  end
  if not content or content == "" then
    return nil, "content is required"
  end
  local ok, path, err = M.write_plan(title, content)
  if not ok then
    opts.on_complete(nil, err)
    return
  end
  vim.g.agent_plan_path = path
  if opts.on_log then
    opts.on_log("wrote plan: " .. path)
  end
  opts.on_complete("Plan written to " .. path, nil)
end

---@type AgentTool
local update_plan = {
  name = "update_plan",
  description = "Update the current plan Markdown file with a revised version (full replacement). "
    .. "Use after clarifying questions change the approach, or to add/remove steps.",
  param = {
    type = "table",
    fields = {
      {
        name = "content",
        description = "The full revised Markdown plan body.",
        type = "string",
      },
      {
        name = "path",
        description = "Plan file to update; omit to use the current/latest plan.",
        type = "string",
        optional = true,
      },
    },
    required = { "content" },
    usage = {
      content = "Full revised Markdown plan body",
      path = "Plan file to update (optional)",
    },
  },
  returns = {
    {
      name = "result",
      description = "Confirmation with the updated plan path",
      type = "string",
    },
    {
      name = "error",
      description = "Error message if the plan could not be updated",
      type = "string",
      optional = true,
    },
  },
}

---@type AgentToolFunc<{ content: string, path?: string }>
function update_plan.func(input, opts)
  if not opts.on_complete then
    return nil, "on_complete not provided"
  end
  local content = input.content
  if not content or content == "" then
    return nil, "content is required"
  end
  local path = M.resolve_path(input.path)
  if not path or vim.fn.filereadable(path) ~= 1 then
    return nil, "no plan file to update; create one first with create_plan"
  end
  local f = io.open(path, "w")
  if not f then
    return nil, "could not write " .. path
  end
  f:write(content)
  f:write("\n")
  f:close()
  vim.g.agent_plan_path = path
  notify_change()
  opts.on_complete("Plan updated at " .. path, nil)
end

--- Build a plan: switch to agent mode and submit the plan content to the agent.
---@param arg string|nil plan path
---@param opts? { new_chat?: boolean, switch_mode?: boolean }
function M.build(arg, opts)
  opts = opts or {}
  local path = M.resolve_path(arg)
  if not path or vim.fn.filereadable(path) ~= 1 then
    vim.notify("Plan: no plan file found (create one first, or pass a path to :AgentPlanBuild)", vim.log.levels.ERROR)
    return
  end

  -- Mark the plan in_progress so the plan manager reflects the transition
  -- (set_status creates frontmatter when a hand-written plan lacks it).
  M.set_status(path, "in_progress")

  local cfg = require("agent_core").config
  local p = cfg.plan or {}
  if (opts.switch_mode == nil and p.build_switch_mode ~= false) or opts.switch_mode == true then
    local mode = require("agent_core.modes").find("agent")
    if mode then
      require("agent_core.modes").switch(mode)
    end
  end

  local content = table.concat(vim.fn.readfile(path), "\n")
  require("agent_core.runtime").submit(
    "Implement the plan below end-to-end. Follow its steps and TODO checklist in order:\n\n" .. content,
    { new = opts.new_chat == true }
  )
end

--- Return the create_plan custom tool for wiring into the owned runtime's tool registry.
function M.create_plan_tool()
  return create_plan
end

--- Return the update_plan custom tool for wiring into the owned runtime's tool registry.
function M.update_plan_tool()
  return update_plan
end

return M
