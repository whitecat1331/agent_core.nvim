---@mod agent_core.multitask Write-capable parallel subagents for Multi-task mode
---@brief [[
--- Registers a `run_agent` custom tool (wired into avante's `custom_tools`)
--- that fans out subagents on avante's agent loop. Unlike avante's built-in
--- `dispatch_agent` (read-only research), `run_agent` subagents get the full
--- write-capable tool set and can optionally run in an isolated git worktree.
---
--- The model emits multiple `run_agent` tool calls in a single message to run
--- them concurrently; avante already processes those tool calls in parallel.
---@brief ]]

local M = {}

--- Full tool set for a subagent, resolved from avante's live registry so it
--- tracks custom tools and disabled_tools automatically. When `allowlist` is
--- non-empty, only those tool names are exposed to the subagent.
---@param allowlist string[]|nil
---@return AvanteLLMTool[]
local function resolve_tools(allowlist)
  local ok, Tools = pcall(require, "avante.llm_tools")
  if not ok or not Tools.get_tools then
    return {}
  end
  local all = Tools.get_tools("", {}) or {}
  if not allowlist or #allowlist == 0 then
    return all
  end
  local wanted = {}
  for _, name in ipairs(allowlist) do
    wanted[name] = true
  end
  local out = {}
  for _, tool in ipairs(all) do
    if wanted[tool.name] then
      table.insert(out, tool)
    end
  end
  return out
end

--- Create a detached git worktree under <root>/.agent_core/worktrees/<id>.
--- Returns the worktree path, or nil plus an error string.
local function create_worktree(root)
  local ok, out = pcall(vim.fn.systemlist, { "git", "-C", root, "rev-parse", "--show-toplevel" })
  if not ok or vim.v.shell_error ~= 0 or not out or #out == 0 then
    return nil, "not a git repository"
  end
  root = out[1]:gsub("[\r\n]", "")

  local base = vim.fn.fnamemodify(root, ":h") .. "/.agent_core/worktrees"
  vim.fn.mkdir(base, "p")
  local name = "subagent-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999))
  local dir = base .. "/" .. name

  local res = vim.fn.systemlist({ "git", "-C", root, "worktree", "add", "--detach", dir, "HEAD" })
  if vim.v.shell_error ~= 0 then
    return nil, "git worktree add failed: " .. table.concat(res, "\n")
  end
  return dir, nil
end

local function remove_worktree(root, dir)
  vim.fn.systemlist({ "git", "-C", root, "worktree", "remove", "--force", dir })
end

---@class AvanteLLMToolParam
---@class AvanteLLMToolReturn
local M_tool = {}

M_tool.name = "run_agent"

M_tool.description =
  [[Launch a write-capable subagent to perform a self-contained task in parallel. The subagent gets its own context window and the full edit tool set (read, write, edit, bash, git, diagnostics), so it can actually implement changes — not just research.

WHEN TO USE:
- The task can be split into independent parts (e.g. "fix the frontend", "fix the backend") that don't touch the same files.
- Each part is large enough to justify a separate context window.

WHEN NOT TO USE:
- Simple or tightly-coupled edits — just do them directly.
- Tasks that would write to the same files concurrently.

USAGE:
- Launch multiple subagents concurrently by emitting MULTIPLE `run_agent` tool calls in a SINGLE message.
- Each subagent is stateless: give it a highly detailed, self-contained prompt and say exactly what to return.
- The subagent returns its final `attempt_completion` summary to you; that summary is NOT visible to the user, so synthesize and report it yourself.
- Set `worktree = true` to isolate a subagent in its own git worktree (rarely needed; only for tasks that would otherwise conflict).
- Set `tools` to restrict which tools a subagent may use (an allowlist of tool names).]]

M_tool.param = {
  type = "table",
  fields = {
    {
      name = "prompt",
      description = "The task for the subagent to perform autonomously, with enough detail to work without follow-up questions.",
      type = "string",
    },
    {
      name = "tools",
      description = "Optional allowlist of tool names the subagent may use. Omit to give it the full tool set.",
      type = "string[]",
      optional = true,
    },
    {
      name = "worktree",
      description = "Run the subagent in an isolated detached git worktree. Default false (shared tree).",
      type = "boolean",
      optional = true,
    },
  },
  required = { "prompt" },
  usage = {
    prompt = "The task for the subagent to perform",
    tools = "Optional allowlist of tool names",
    worktree = "Whether to run in an isolated git worktree",
  },
}

M_tool.returns = {
  {
    name = "result",
    description = "The subagent's final summary",
    type = "string",
  },
  {
    name = "error",
    description = "The error message if the subagent fails",
    type = "string",
    optional = true,
  },
}

---@type AvanteLLMToolFunc<{ prompt: string, tools?: string[], worktree?: boolean }>
function M_tool.func(input, opts)
  local on_log = opts.on_log
  local on_complete = opts.on_complete
  local session_ctx = opts.session_ctx

  local Llm = require("avante.llm")
  if not on_complete then
    return false, "on_complete not provided"
  end

  local prompt = input.prompt
  if not prompt or prompt == "" then
    return false, "prompt is required"
  end

  local tools = resolve_tools(input.tools)
  if #tools == 0 then
    return false, "no tools available for subagent"
  end

  -- Optional worktree isolation. Chdir is global, so we restore it in the
  -- completion callback. Parallel subagents should use the default shared tree.
  local root = vim.fn.getcwd()
  local worktree_dir
  local original_cwd
  if input.worktree == true then
    local dir, err = create_worktree(root)
    if not dir then
      return false, err
    end
    worktree_dir = dir
    original_cwd = vim.fn.getcwd()
    vim.fn.chdir(dir)
  end

  if on_log then
    on_log("prompt: " .. prompt)
  end

  local system_prompt = string.format(
    [[You are a coding subagent spawned to complete an isolated task in parallel.
Working directory: %s

TASK:
%s

Work autonomously using the tools available to you. Do not ask for clarification;
make reasonable assumptions and note them. When finished, call the
`attempt_completion` tool with a concise summary of what you changed and why.]],
    vim.fn.getcwd(),
    prompt
  )

  local history_messages = {}
  local result = ""

  local agent_loop_options = {
    system_prompt = system_prompt,
    user_input = "start",
    tools = tools,
    on_tool_log = session_ctx and session_ctx.on_tool_log,
    on_messages_add = function(msgs)
      msgs = vim.islist(msgs) and msgs or { msgs }
      for _, msg in ipairs(msgs) do
        local idx
        for i, m in ipairs(history_messages) do
          if m.uuid == msg.uuid then
            idx = i
            break
          end
        end
        if idx ~= nil then
          history_messages[idx] = msg
        else
          table.insert(history_messages, msg)
        end
      end
      if opts.set_store then
        opts.set_store("messages", history_messages)
      end
      for _, msg in ipairs(msgs) do
        local History = require("avante.history")
        local tool_use = History.Helpers.get_tool_use_data(msg)
        if tool_use and tool_use.name == "attempt_completion" and tool_use.input and tool_use.input.result then
          result = tool_use.input.result
        end
      end
    end,
    session_ctx = session_ctx,
    on_start = session_ctx and session_ctx.on_start,
    on_complete = function(err)
      if worktree_dir and original_cwd then
        vim.fn.chdir(original_cwd)
      end
      if err ~= nil then
        if worktree_dir then
          remove_worktree(root, worktree_dir)
        end
        on_complete(nil, "run_agent failed: " .. vim.inspect(err))
        return
      end
      if worktree_dir then
        -- Report the diff summary and leave the worktree for the lead to review.
        local stat = vim.fn.systemlist({ "git", "-C", worktree_dir, "diff", "--stat" })
        if result ~= "" then
          result = result .. "\n\n"
        end
        result = result .. "[worktree " .. worktree_dir .. "]\n" .. table.concat(stat, "\n")
      end
      on_complete(result, nil)
    end,
  }

  Llm.agent_loop(agent_loop_options)
end

--- Minimal sidebar rendering for a subagent run (mirrors dispatch_agent).
function M_tool.on_render(input, opts)
  local result_message = opts.result_message
  local Line = require("avante.ui.line")
  local Highlights = require("avante.highlights")

  local state = "running"
  local hl = Highlights.AVANTE_TASK_RUNNING
  if result_message then
    local History = require("avante.history")
    local result = History.Helpers.get_tool_result_data(result_message)
    if result then
      if result.is_error then
        state = "failed"
        hl = Highlights.AVANTE_TASK_FAILED
      else
        state = "completed"
        hl = Highlights.AVANTE_TASK_COMPLETED
      end
    end
  end

  local lines = {}
  table.insert(lines, Line:new({ { "Subtask " .. state, hl } }))
  table.insert(lines, Line:new({ { "" } }))
  table.insert(lines, Line:new({ { "  Task:" } }))
  for _, l in ipairs(vim.split(input.prompt or "", "\n")) do
    table.insert(lines, Line:new({ { "    " .. l } }))
  end
  return lines
end

--- Return the run_agent custom tool for wiring into avante's `custom_tools`.
function M.run_agent_tool()
  return M_tool
end

return M
