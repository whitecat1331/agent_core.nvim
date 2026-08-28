---@mod agent_core.plan Plan-mode Markdown artifact + Build step
---@brief [[
--- Plan mode: instead of editing code, the model researches the
--- codebase, asks clarifying questions, and writes an editable Markdown plan
--- (with file paths, an ordered TODO checklist, and trade-offs) to disk via the
--- `create_plan` / `update_plan` custom tools. The user reviews the file and
--- then triggers the build with :AgentPlanBuild (or :AgentPlanBuildNew for a
--- fresh avante session). Plans land in config.plan.dir (default .agent_core/plans/).
---@brief ]]

local M = {}

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
  f:write("# " .. title .. "\n\n")
  f:write("> Plan created " .. os.date("%Y-%m-%d %H:%M") .. " by agent_core plan mode\n\n")
  f:write(content)
  f:write("\n")
  f:close()
  return true, path, nil
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

--- Resolve a plan path from an explicit arg, the active plan, or the latest.
---@param arg string|nil
---@return string|nil
function M.resolve_path(arg)
  if arg and arg ~= "" then
    return vim.fn.fnamemodify(arg, ":p")
  end
  return vim.g.agent_plan_path or M.latest_plan()
end

---@type AvanteLLMTool
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

---@type AvanteLLMToolFunc<{ title: string, content: string }>
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

---@type AvanteLLMTool
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

---@type AvanteLLMToolFunc<{ content: string, path?: string }>
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
  opts.on_complete("Plan updated at " .. path, nil)
end

--- Build a plan: switch to agent mode and submit the plan content to avante.
---@param arg string|nil plan path
---@param opts? { new_chat?: boolean, switch_mode?: boolean }
function M.build(arg, opts)
  opts = opts or {}
  local path = M.resolve_path(arg)
  if not path or vim.fn.filereadable(path) ~= 1 then
    vim.notify("Plan: no plan file found (create one first, or pass a path to :AgentPlanBuild)", vim.log.levels.ERROR)
    return
  end

  local cfg = require("agent_core").config
  local p = cfg.plan or {}
  if (opts.switch_mode == nil and p.build_switch_mode ~= false) or opts.switch_mode == true then
    local mode = require("agent_core.modes").find("agent")
    if mode then
      require("agent_core.modes").switch(mode)
    end
  end

  local content = table.concat(vim.fn.readfile(path), "\n")
  local ok, api = pcall(require, "avante.api")
  if not ok then
    vim.notify("Plan: avante not available; plan is at " .. path, vim.log.levels.WARN)
    return
  end
  api.ask({
    question = "Implement the plan below end-to-end. Follow its steps and TODO checklist in order:\n\n" .. content,
    new_chat = opts.new_chat == true,
  })
end

--- Return the create_plan custom tool for wiring into avante's `custom_tools`.
function M.create_plan_tool()
  return create_plan
end

--- Return the update_plan custom tool for wiring into avante's `custom_tools`.
function M.update_plan_tool()
  return update_plan
end

return M
