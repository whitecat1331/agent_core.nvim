---@mod agent_core.multitask Write-capable parallel subagents for Multi-task mode
---@brief [[
--- Registers a `run_agent` custom tool (wired into the owned runtime's tool
--- registry) that fans out subagents on the owned agent loop. Unlike the
--- read-only research path, `run_agent` subagents get the full write-capable
--- tool set and can optionally run in an isolated git worktree.
---
--- The model emits multiple `run_agent` tool calls in a single message to run
--- them concurrently; the owned runtime processes those tool calls in parallel.
--- Parallel fan-out uses the shared tree (worktree = false). Worktree isolation
--- is sequential-only: a worktree run needs an isolated cwd, and the global
--- chdir would collide across concurrent worktree runs, so a second worktree
--- run is rejected while one is active.
---@brief ]]

local M = {}

-- Number of worktree-isolated subagent runs currently in flight. Because
-- `vim.fn.chdir` is global, worktrees must run sequentially; the guard below
-- rejects concurrent worktree runs and steers the model to worktree = false.
local active_worktrees = 0

--- Resolve a transient profile for a run_agent `profile`/`model` override, or
--- (nil, nil) when no override is requested. Returns (nil, err) on failure.
---@param input table
---@return table|nil
---@return string|nil
local function resolve_override_profile(input)
  local Profiles = require("agent_core.profiles")
  local has_profile = input.profile ~= nil and input.profile ~= ""
  local has_model = input.model ~= nil and input.model ~= ""

  local profile
  if has_profile then
    profile = Profiles.find(input.profile)
    if not profile then
      return nil, "unknown profile: " .. tostring(input.profile)
    end
  elseif has_model then
    local active_name = Profiles.get_active()
    profile = active_name and Profiles.find(active_name) or nil
    if not profile then
      return nil, "no active profile to override; pass `profile` instead"
    end
  else
    return nil, nil
  end

  if has_model then
    profile = vim.deepcopy(profile)
    profile.model = input.model
  end
  return profile, nil
end

--- Full tool set for a subagent: the owned built-ins (bash/file/glob/grep/todos)
--- plus agent_core's custom tools, so subagents get write-capable parity. When
--- `allowlist` is non-empty, only those tool names are exposed to the subagent.
---@param allowlist string[]|nil
---@return AgentTool[]
local function resolve_tools(allowlist)
  local all = require("agent_core.runtime.tools").full_set(require("agent_core").get_custom_tools())
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
- Set `worktree = true` to isolate a subagent in its own git worktree. Worktrees are sequential-only (only one at a time); use the shared tree (default) for parallel fan-out.
- Set `tools` to restrict which tools a subagent may use (an allowlist of tool names).
- Set `profile` to run the subagent under a different named profile, or `model` to override the active profile's model. Each subagent is its own session with its own provider/model, so overridden subagents fan out in parallel.]]

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
      description = "Run the subagent in an isolated detached git worktree. Sequential-only (one at a time); default false (shared tree, safe for parallel fan-out).",
      type = "boolean",
      optional = true,
    },
    {
      name = "profile",
      description = "Optional profile name to run the subagent under (its own session, so it runs in parallel).",
      type = "string",
      optional = true,
    },
    {
      name = "model",
      description = "Optional model override for the active profile (per-session, so it runs in parallel).",
      type = "string",
      optional = true,
    },
  },
  required = { "prompt" },
  usage = {
    prompt = "The task for the subagent to perform",
    tools = "Optional allowlist of tool names",
    worktree = "Whether to run in an isolated git worktree",
    profile = "Optional profile name to run the subagent under",
    model = "Optional model override for the active profile",
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

---@type AgentToolFunc<{ prompt: string, tools?: string[], worktree?: boolean, profile?: string, model?: string }>
function M_tool.func(input, opts)
  local on_log = opts.on_log
  local on_complete = opts.on_complete
  local session_ctx = opts.session_ctx

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

  -- Per-session provider/model: a run_agent profile/model override becomes the
  -- subagent session's own provider/model (not a global switch), so overridden
  -- subagents fan out in parallel.
  local Runner = require("agent_core.runner")
  local session_opts = {}
  if input.profile or input.model then
    local p, perr = resolve_override_profile(input)
    if not p then
      return false, perr
    end
    session_opts = {
      provider = p.provider,
      model = p.model,
      api_key = Runner.resolve_key(p),
      endpoint = p.endpoint,
      api_key_name = p.api_key_name,
    }
  else
    local p = Runner.resolve_profile(nil)
    if p then
      session_opts = {
        provider = p.provider,
        model = p.model,
        api_key = Runner.resolve_key(p),
        endpoint = p.endpoint,
        api_key_name = p.api_key_name,
      }
    end
  end

  -- Optional worktree isolation. Chdir is global, so worktrees run sequentially
  -- (a guard rejects a second concurrent worktree run). Parallel fan-out must
  -- use the default shared tree (worktree = false).
  local root = vim.fn.getcwd()
  local worktree_dir
  local original_cwd
  if input.worktree == true then
    if active_worktrees > 0 then
      return false,
        "another worktree-isolated subagent is already running; worktrees are sequential-only. "
          .. "Use worktree = false for parallel fan-out."
    end
    local dir, err = create_worktree(root)
    if not dir then
      return false, err
    end
    worktree_dir = dir
    original_cwd = vim.fn.getcwd()
    active_worktrees = active_worktrees + 1
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

  local Session = require("agent_core.runtime.session")
  Session.new(session_opts):run({
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
        if msg.role == "tool" and msg.name == "attempt_completion" then
          result = msg.content
        end
      end
    end,
    session_ctx = session_ctx,
    on_start = session_ctx and session_ctx.on_start,
    on_complete = function(err)
      if worktree_dir and original_cwd then
        vim.fn.chdir(original_cwd)
        active_worktrees = math.max(0, active_worktrees - 1)
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
  })
end

--- Plain-text render of a subagent run (the owned Agents Window renders tool
--- results as text, so no UI-line / highlight rendering dependency remains).
function M_tool.on_render(input, opts)
  local state = opts and opts.result_message and "completed" or "running"
  local lines = { "Subtask " .. state, "", "  Task:" }
  for _, l in ipairs(vim.split(input.prompt or "", "\n")) do
    lines[#lines + 1] = "    " .. l
  end
  return lines
end

--- Return the run_agent custom tool for wiring into the owned runtime's tool registry.
function M.run_agent_tool()
  return M_tool
end

--- Exposed for tests: resolve a run_agent `profile`/`model` override.
--- Returns (profile, nil), (nil, nil) when no override, or (nil, err).
M.resolve_override_profile = resolve_override_profile

return M
