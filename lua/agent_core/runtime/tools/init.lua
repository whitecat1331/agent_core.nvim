---@mod agent_core.runtime.tools Owned tool registry + dispatch (owned).
---@brief [[
--- Declarative tool registry that consumes the EXISTING agent_core custom tools
--- unchanged. Every tool in agent_core already carries the AgentTool shape
--- (name, description, param, returns, func(input, opts) with opts.on_complete /
--- opts.on_log / opts.session_ctx / opts.set_store) — see
--- agent_core.init.get_custom_tools(). This module only dispatches them; it does
--- NOT rewrite any tool body.
---
--- `execute` reconciles the two completion styles existing tools use:
---   * synchronous  — `return result` / `return nil, err` / `return false, err`
---   * asynchronous — `opts.on_complete(result, err)` (the common case)
--- Both collapse into a single opts.on_complete(result, err) callback.
---@brief ]]

--- Canonical tool-shape type definitions. Every agent_core custom tool (and the
--- owned built-ins) conforms to this contract: a `func(input, opts)` that either
--- returns a result synchronously or calls `opts.on_complete(result, err)`, with
--- `opts.on_log` / `opts.session_ctx` / `opts.set_store` for streaming context.
---@class AgentToolParam
---@class AgentToolReturn
---@class AgentToolFunc
---@class AgentTool

local M = {}

---@class AgentToolRegistry
local registry = {} ---@type table<string, table>

--- Register a single tool (AgentTool shape).
---@param tool table
function M.register(tool)
  if type(tool) == "table" and tool.name then
    registry[tool.name] = tool
  end
end

--- Register a list of tools.
---@param tools table[]
function M.register_all(tools)
  for _, t in ipairs(tools or {}) do
    M.register(t)
  end
end

--- Clear the registry (used by tests and setup re-wires).
function M.clear()
  registry = {}
end

--- Look up a tool by name.
---@param name string
---@return table|nil
function M.get(name)
  return registry[name]
end

--- All registered tools in insertion order.
---@return table[]
function M.all()
  local out = {}
  for _, t in pairs(registry) do
    out[#out + 1] = t
  end
  return out
end

--- Names of all registered tools.
---@return string[]
function M.names()
  local out = {}
  for name in pairs(registry) do
    out[#out + 1] = name
  end
  return out
end

--- Convert every registered tool into normalized provider descriptors.
---@return table[]
function M.descriptors()
  return require("agent_core.runtime.schema").normalize_tools(M.all())
end

--- The owned built-in tools (attempt_completion + bash/file/glob/grep/todos).
---@return table[]
function M.builtin_tools()
  return require("agent_core.runtime.tools.builtins").all()
end

--- The full tool set: owned built-ins + the caller's custom tools (deduped by
--- name; built-ins win on collision so a custom tool can't shadow attempt_completion).
---@param custom table[]|nil
---@return table[]
function M.full_set(custom)
  local seen = {}
  local out = {}
  for _, t in ipairs(M.builtin_tools()) do
    if t and t.name and not seen[t.name] then
      seen[t.name] = true
      out[#out + 1] = t
    end
  end
  for _, t in ipairs(custom or {}) do
    if t and t.name and not seen[t.name] then
      seen[t.name] = true
      out[#out + 1] = t
    end
  end
  return out
end

--- Filter a tool list against an agent_core.modes mode, honoring the read-only
--- allowlist (mode.allow_tools) and the WRITE_TOOLS destructive list so ask/plan
--- modes never see mutating tools. Non-read-only modes pass through unchanged.
---@param tools table[]
---@param mode table|nil mode definition from agent_core.modes (nil = no filtering)
---@return table[]
function M.filter_for_mode(tools, mode)
  if not mode or not mode.read_only then
    return tools
  end
  local modes = require("agent_core.modes")
  local allow = mode.allow_tools or {}
  local out = {}
  for _, t in ipairs(tools) do
    local name = t.name
    if vim.tbl_contains(allow, name) or not vim.tbl_contains(modes.WRITE_TOOLS, name) then
      out[#out + 1] = t
    end
  end
  return out
end

--- Execute one tool, collapsing sync and async completion into `opts.on_complete`.
--- The wrapped callback is idempotent so a tool that both returns and calls
--- on_complete cannot double-fire.
---@param tool table
---@param input table|string
---@param opts { on_complete: fun(result:any, err:string|nil), on_log?:fun(string), session_ctx?:table, set_store?:fun(string,any) }
function M.execute(tool, input, opts)
  local on_complete = opts and opts.on_complete
  if not tool or type(tool) ~= "table" or not tool.func then
    if on_complete then
      on_complete(nil, "unknown tool")
    end
    return
  end

  local done = false
  local function finish(result, err)
    if done then
      return
    end
    done = true
    if on_complete then
      on_complete(result, err)
    end
  end

  local tool_opts = {
    on_complete = finish,
    on_log = opts and opts.on_log,
    session_ctx = opts and opts.session_ctx,
    set_store = opts and opts.set_store,
  }

  local ok, r1, r2 = pcall(tool.func, input, tool_opts)
  if not ok then
    finish(nil, tostring(r1))
    return
  end
  if r1 == nil and r2 == nil then
    return -- async: finish() fires via on_complete
  end
  if r1 == false or (r1 == nil and r2 ~= nil) then
    finish(nil, r2 or "tool failed")
    return
  end
  finish(r1, r2)
end

--- Execute a tool by name (returns false via on_complete when unknown).
---@param name string
---@param input table|string
---@param opts table
function M.execute_by_name(name, input, opts)
  local tool = M.get(name)
  if not tool then
    if opts and opts.on_complete then
      opts.on_complete(nil, "unknown tool: " .. tostring(name))
    end
    return
  end
  M.execute(tool, input, opts)
end

return M
