---@mod agent_core.hooks Agent lifecycle hooks (before/after prompt, tool, run end)
---@brief [[
--- Emits lifecycle events so users can extend agent_core with their own Lua:
---   before_prompt / after_prompt   around the owned AgentInputSubmitted event
---   before_tool   / after_tool     around agent_core's own custom tools
---   on_run_end                     when a headless run completes
--- Each event fires a `User` autocmd (AgentHookBeforePrompt, AgentHookBeforeTool,
--- etc.) and invokes the matching callback in `config.hooks` when present.
---
--- Scope note: `before/after_tool` wraps agent_core custom tools only (they are
--- wired through `get_custom_tools()`). The owned built-ins (bash/write_to_file)
--- are dispatched through agent_core.runtime.tools, not wrapped here.
---@brief ]]

local M = {}

M.config = {
  before_prompt = nil,
  after_prompt = nil,
  before_tool = nil,
  after_tool = nil,
  on_run_end = nil,
}

local group = vim.api.nvim_create_augroup("AgentCoreHooks", { clear = true })

--- Map event name -> User autocmd name.
local AUTOCMD = {
  before_prompt = "AgentHookBeforePrompt",
  after_prompt = "AgentHookAfterPrompt",
  before_tool = "AgentHookBeforeTool",
  after_tool = "AgentHookAfterTool",
  on_run_end = "AgentHookRunEnd",
}

--- Fire an event: invoke the config callback (if any) and emit a User autocmd.
---@param event string
---@param data table
function M.emit(event, data)
  local cb = M.config[event]
  if cb and type(cb) == "function" then
    local ok, err = pcall(cb, data or {})
    if not ok then
      vim.notify("agent_core hooks: " .. tostring(event) .. " callback failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
  local name = AUTOCMD[event]
  if name then
    vim.api.nvim_exec_autocmds("User", { pattern = name, modeline = false, data = data or {} })
  end
end

--- Wrap an agent_core custom tool so its func emits before_tool/after_tool.
---@param tool AgentTool
---@return AgentTool
function M.wrap(tool)
  if not tool or type(tool) ~= "table" or not tool.func then
    return tool
  end
  local wrapped = vim.deepcopy(tool)
  local inner = tool.func
  wrapped.func = function(input, opts)
    M.emit("before_tool", { name = tool.name, input = input })
    local orig_complete = opts.on_complete
    opts.on_complete = function(result, err)
      M.emit("after_tool", { name = tool.name, error = err })
      if orig_complete then
        orig_complete(result, err)
      end
    end
    return inner(input, opts)
  end
  return wrapped
end

--- Wrap every tool in a list.
---@param tools AgentTool[]
---@return AgentTool[]
function M.wrap_all(tools)
  local out = {}
  for _, t in ipairs(tools) do
    out[#out + 1] = M.wrap(t)
  end
  return out
end

function M.setup()
  local cfg = require("agent_core").config
  M.config = vim.tbl_deep_extend("force", M.config, cfg.hooks or {})

  -- before/after_prompt around the owned input-submitted event.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "AgentInputSubmitted",
    callback = function(ev)
      local input = ev.data and ev.data.input or ""
      M.emit("before_prompt", { input = input })
      vim.schedule(function()
        M.emit("after_prompt", { input = input })
      end)
    end,
  })
end

return M
