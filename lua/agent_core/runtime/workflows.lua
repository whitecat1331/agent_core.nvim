---@mod agent_core.runtime.workflows Successive-prompt workflows engine (owned).
---@brief [[
--- Owned workflows engine: a workflow is an ordered list of steps, each a prompt
--- (optionally referencing prior step outputs via `{1}`, `{2}`, ... or named
--- `{outputs.name}`). Steps run sequentially; each step's output is fed forward
--- into the next step's context. Maps to the existing plan/build and multitask
--- surfaces.
---
--- Definitions are plain Lua tables (or a serialized form for on-disk persistence
--- under config `workflows.dir`). `run` is decoupled from any transport: callers
--- inject `step_fn` (defaults to the owned single-shot runner) so the sequencing
--- logic is headless-testable.
---@brief ]]

local M = {}

M.defaults = {
  dir = nil, -- resolved lazily to stdpath("data") .. "/agent_core/workflows"
  max_steps = 20,
  max_output_chars = 12000, -- cap on how much of a prior output is forwarded
}

--- Substitute `{n}` / `{name}` placeholders using prior outputs and vars.
--- `{1}` = first output, `{outputs.foo}` / `{foo}` = named output, `{{var}}` = a
--- caller-supplied variable. Unknown placeholders are left verbatim.
---@param template string
---@param ctx { outputs?: table[], vars?: table }
---@return string
function M.substitute(template, ctx)
  ctx = ctx or {}
  local outputs = ctx.outputs or {}
  local vars = ctx.vars or {}
  local out = (template or ""):gsub("{{([%w_]+)}}", function(name)
    local v = vars[name]
    return v == nil and ("{{" .. name .. "}}") or tostring(v)
  end)
  out = out:gsub("{outputs%.([%w_]+)}", function(name)
    local v = outputs[name]
    return v == nil and ("{outputs." .. name .. "}") or tostring(v)
  end)
  out = out:gsub("{([%d]+)}", function(i)
    local v = outputs[tonumber(i)]
    return v == nil and ("{" .. i .. "}") or tostring(v)
  end)
  return out
end

--- Parse a serialized workflow definition into { name, description, steps }.
--- Accepts either a table or a string (frontmatter-style: `name:`, `description:`,
--- then `step:` blocks or `---`-separated step bodies).
---@param def table|string
---@return table|nil workflow
---@return string|nil err
function M.parse(def)
  if type(def) == "table" then
    if type(def.steps) ~= "table" or #def.steps == 0 then
      return nil, "workflow has no steps"
    end
    return def, nil
  end
  if type(def) ~= "string" then
    return nil, "workflow must be a table or string"
  end

  local name, description = nil, nil
  local steps = {}
  local current = {}
  local function flush()
    if #current > 0 then
      local body = table.concat(current, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
      if body ~= "" then
        steps[#steps + 1] = body
      end
      current = {}
    end
  end
  for line in (def .. "\n"):gmatch("([^\n]*)\n") do
    local n = line:match("^name:%s*(.-)%s*$")
    local d = line:match("^description:%s*(.-)%s*$")
    if n then
      name = n
    elseif d then
      description = d
    elseif line:match("^step:%s*$") or line == "---" then
      flush()
    else
      current[#current + 1] = line
    end
  end
  flush()
  if #steps == 0 then
    return nil, "workflow has no steps"
  end
  return { name = name or "workflow", description = description, steps = steps }, nil
end

--- Resolve the workflows directory (defaults to <data>/agent_core/workflows).
---@return string
function M.dir()
  return M.defaults.dir or (vim.fn.stdpath("data") .. "/agent_core/workflows")
end

--- List workflow files in a directory (best-effort; returns {} when absent).
---@param dir string|nil
---@return { name:string, path:string, description:string }[]
function M.list(dir)
  dir = dir or M.dir()
  local out = {}
  if vim.fn.isdirectory(dir) ~= 1 then
    return out
  end
  for _, f in ipairs(vim.fn.readdir(dir)) do
    if f:match("%.md$") then
      local path = dir .. "/" .. f
      local ok, wf = pcall(M.parse, table.concat(vim.fn.readfile(path), "\n"))
      if ok and wf then
        out[#out + 1] = {
          name = wf.name,
          path = path,
          description = wf.description or "",
        }
      end
    end
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

--- Save a workflow definition to a .md file (name becomes the filename slug).
---@param dir string|nil
---@param workflow table
---@return string path
---@return string|nil err
function M.save(dir, workflow)
  local wf, perr = M.parse(workflow)
  if not wf then
    return nil, perr
  end
  local slug = (wf.name or "workflow"):gsub("[^%w_-]+", "-"):lower()
  local path = (dir or M.dir()) .. "/" .. slug .. ".md"
  local lines = { "name: " .. (wf.name or slug), "description: " .. (wf.description or "") }
  for _, s in ipairs(wf.steps) do
    lines[#lines + 1] = "step:"
    for _, l in ipairs(vim.split(s, "\n")) do
      lines[#lines + 1] = l
    end
  end
  local okw = pcall(vim.fn.mkdir, dir or M.dir(), "p")
  if not okw then
    return nil, "failed to create workflows directory"
  end
  vim.fn.writefile(lines, path)
  return path, nil
end

--- Run a workflow sequentially. `step_fn(prompt, ctx, cb)` is called per step;
--- `ctx.outputs` accumulates prior outputs (latest at the end; named outputs via
--- `ctx.names`). Defaults to the owned single-shot runner when not injected.
---@param workflow table|string
---@param opts { vars?: table, step_fn?: fun(prompt:string, ctx:table, cb:fun(err:string|nil, out:string|nil)), on_step?: fun(i:integer, step:string), max_steps?: integer }
---@param cb fun(err:string|nil, outputs:table[]|nil)
function M.run(workflow, opts, cb)
  opts = opts or {}
  local wf, perr = M.parse(workflow)
  if not wf then
    cb(perr, nil)
    return
  end

  local max_steps = opts.max_steps or M.defaults.max_steps
  if #wf.steps > max_steps then
    cb("workflow exceeds max_steps (" .. tostring(max_steps) .. ")", nil)
    return
  end

  local step_fn = opts.step_fn
  if not step_fn then
    local Runner = require("agent_core.runner")
    step_fn = function(prompt, ctx, done)
      Runner.llm_curl({ prompt = prompt }, function(err, out)
        done(err, out)
      end)
    end
  end

  local ctx = { outputs = {}, names = {}, vars = opts.vars or {} }
  local i = 0
  local function next_step()
    i = i + 1
    if i > #wf.steps then
      cb(nil, ctx.outputs)
      return
    end
    local prompt = M.substitute(wf.steps[i], ctx)
    if opts.on_step then
      opts.on_step(i, prompt)
    end
    step_fn(prompt, ctx, function(err, out)
      if err then
        cb(err, ctx.outputs)
        return
      end
      local capped = tostring(out or "")
      if #capped > M.defaults.max_output_chars then
        capped = capped:sub(1, M.defaults.max_output_chars)
      end
      ctx.outputs[#ctx.outputs + 1] = capped
      next_step()
    end)
  end
  next_step()
end

return M
