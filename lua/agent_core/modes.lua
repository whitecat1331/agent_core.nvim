---@mod agent_core.modes Behavior modes (ask/plan/debug/agent/multitask)
---@brief [[
--- A mode is orthogonal to a profile: profiles bundle provider/model/API key,
--- modes bundle behavior (read-only vs full), tool permissions, and a persona.
--- The persona is persisted in `vim.g.agent_mode_prompt`; the read_only /
--- allow_tools / auto_approve policy is applied per submission by the owned
--- runtime (agent_core.runtime.tools.filter_for_mode + the approve gate).
---@brief ]]

local M = {}

--- Tool names that mutate state. Used to build the read-only allowlist for
--- ask/plan modes. Keep this in sync with the owned built-ins (runtime.tools.builtins)
--- and any custom tools that can change the filesystem.
M.WRITE_TOOLS = {
  -- owned built-ins that mutate the repo or session state
  "bash",
  "create",
  "edit_file",
  "insert",
  "replace_in_file",
  "str_replace",
  "undo_edit",
  "write_to_file",
  "write_todos",
  -- agent_core custom tools that mutate state
  "run_agent",
  "create_plan",
  "update_plan",
  "add_debug_instrumentation",
  "remove_debug_instrumentation",
  "checkpoint",
  "rollback",
}

M.defaults = {
  {
    name = "ask",
    label = "Ask",
    read_only = true,
    -- Realm hints used by agent_core.recommend to detect when a prompt is
    -- outside this mode's scope. keywords = weighted phrases (higher weight =
    -- stronger signal). when_to_use = one-line reason for switch prompts.
    keywords = {
      "what is",
      "what does",
      "how does",
      "how do",
      "explain",
      "describe",
      "why is",
      "why does",
      "what's the difference",
      "where is",
    },
    when_to_use = "asking questions and understanding code without changing it",
    system_prompt = [[
MODE: Ask — you are in a read-only question-and-answer mode.
- Answer questions and explain code. Do NOT edit files or run state-changing commands.
- You have read/search tools only; never attempt writes.]],
  },
  {
    name = "plan",
    label = "Plan",
    read_only = true,
    keywords = {
      { "plan", 2 },
      { "design", 2 },
      "approach",
      "architecture",
      "steps",
      "how should",
      "how would you",
      "refactor strategy",
      "before implementing",
      "propose",
      "outline",
    },
    when_to_use = "researching and producing a step-by-step implementation plan",
    -- Plan mode stays read-only for repo code, but may write its own Markdown
    -- artifact and a todo list. Reconciles with M.WRITE_TOOLS in M.switch.
    allow_tools = { "create_plan", "update_plan", "write_todos", "read_todos" },
    system_prompt = [[
MODE: Plan — you produce a reviewable implementation plan, not code changes.
1. Research the codebase thoroughly: locate the relevant files and understand the existing architecture.
2. Ask clarifying questions and WAIT for the user's answers before finalizing the plan.
3. Write the plan to a Markdown file using the `create_plan` tool, with a title and content that includes:
   - the exact file paths and the specific change for each file,
   - an ordered, step-by-step TODO checklist (use "- [ ]" items),
   - trade-offs and risks.
4. If the approach changes, revise the file with the `update_plan` tool.
5. After writing the plan, STOP. Do NOT edit code or run mutating commands; the user reviews the plan and
   triggers the build separately.
You may use read/search tools plus create_plan, update_plan, read_todos, and write_todos only.]],
  },
  {
    name = "agent",
    label = "Agent",
    read_only = false,
    keywords = {
      { "implement", 2 },
      { "build", 2 },
      "add",
      "create",
      "rename",
      "delete",
      "change",
      "write",
      "refactor",
      "update",
      "modify",
      "wire up",
      "scaffold",
    },
    when_to_use = "autonomously building, editing, and implementing changes end-to-end",
    system_prompt = [[
MODE: Agent — autonomous build/edit mode.
- Work through the task end-to-end: read, edit, and run commands as needed.
- Make changes directly and verify them with tests or builds.
- Before a large or risky change, take a `checkpoint` snapshot so you can `rollback` if it goes wrong.]],
  },
  {
    name = "debug",
    label = "Debug",
    read_only = false,
    keywords = {
      { "fix", 2 },
      { "bug", 2 },
      { "error", 2 },
      "crash",
      "fails",
      "broken",
      "why won't",
      "why doesn't",
      "reproduce",
      "root cause",
      "debug",
      "stack trace",
      "not working",
      "traceback",
    },
    when_to_use = "investigating a failure with runtime evidence and fixing the root cause",
    system_prompt = [[
MODE: Debug — find the root cause using a REAL debugger when one is available, and fall back to
print-instrumentation only when no adapter fits. Prefer the interactive debugger loop:

1. Explore the relevant files and generate MULTIPLE ranked hypotheses for the root cause.
2. Call `debug_list_adapters` to discover available debug adapters and launch configs.
   - If a usable adapter + launch config exist, drive the real debugger:
     a. `debug_set_breakpoint` at the most likely failure sites for each hypothesis
        (use conditions / hit conditions to skip noise).
     b. `debug_start` (by config name or an inline config). It returns the paused state.
     c. Inspect: `debug_step_over` / `debug_step_into` / `debug_step_out` to walk execution,
        `debug_evaluate` to test expressions in the paused frame, `debug_get_variables` to expand
        object/array values, and `debug_get_state` for the current snapshot + console output.
     d. `debug_continue` to run to the next breakpoint. Repeat (b)-(d) to isolate the root cause.
     e. When done, `debug_stop` to end the session.
   - If NO usable adapter (or the bug is timing/network/async and hard to attach), use the
     instrumentation loop: insert temporary log/print statements, record each with
     `add_debug_instrumentation`, call `request_reproduction` to ask the user to reproduce, then
     analyze `read_captured_logs` (or the user's pasted output).
3. Apply a focused, minimal fix (a separate edit, not the instrumentation).
4. Clean up: call `remove_debug_instrumentation` (instrumentation path) and/or `debug_stop`
   (debugger path) once the fix is verified.]],
  },
  {
    name = "multitask",
    label = "Multi-task",
    read_only = false,
    keywords = {
      "in parallel",
      "separately",
      "independently",
      "fan out",
      "subagent",
      "subagents",
      "each task",
      "multiple tasks",
      "split this",
      "concurrently",
    },
    when_to_use = "splitting work across multiple parallel subagents and synthesizing the results",
    system_prompt = [[
MODE: Multi-task — parallelize work across subagents.
- Break the task into independent parts and fan out using the `run_agent` tool (multiple tool calls in one message run concurrently).
- Give each subagent a detailed, self-contained prompt and specify exactly what it should return.
- Synthesize the results into a coherent whole.]],
  },
}

--- User-defined custom modes, loaded from config `modes.extra` (array) plus
--- `<data>/agent_core/modes.json` (an array, or `{ modes = [...] }`).
---@return table[]
function M.custom_modes()
  local out = {}
  local cfg = require("agent_core").config
  local extra = cfg.modes and cfg.modes.extra
  if type(extra) == "table" then
    for _, m in ipairs(extra) do
      out[#out + 1] = m
    end
  end
  local path = vim.fn.stdpath("data") .. "/agent_core/modes.json"
  if vim.fn.filereadable(path) == 1 then
    local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
    if ok and type(data) == "table" then
      local list = data.modes or data
      if type(list) == "table" then
        for _, m in ipairs(list) do
          out[#out + 1] = m
        end
      end
    end
  end
  return out
end

function M.all()
  local cfg = require("agent_core").config
  -- A plain array in `config.modes` is a full replacement (back-compat).
  if type(cfg.modes) == "table" and cfg.modes[1] ~= nil then
    return cfg.modes
  end
  local seen = {}
  local out = {}
  local function add(m)
    if type(m) == "table" and m.name and not seen[m.name] then
      seen[m.name] = true
      out[#out + 1] = m
    end
  end
  for _, m in ipairs(M.defaults) do
    add(m)
  end
  for _, m in ipairs(M.custom_modes()) do
    add(m)
  end
  return out
end

function M.find(name)
  for _, m in ipairs(M.all()) do
    if m.name == name then
      return m
    end
  end
end

function M.get_active()
  return require("agent_core.keys").get_active_mode()
end

--- Compute the auto-approve policy for a mode.
--- - read_only -> false (read tools never prompt; write tools are disabled anyway)
--- - auto_approve == "all" -> true (full agent parity)
--- - otherwise -> every tool except the destructive list
---@param mode table
---@param tools string[] all tool names currently registered by the runtime
function M.auto_approve(mode, tools)
  if mode.read_only then
    return false
  end
  if mode.auto_approve == "all" then
    return true
  end
  local cfg = require("agent_core").config
  local destructive = nil
  local ok_pol, Policy = pcall(require, "agent_core.policy")
  if ok_pol and Policy.effective_destructive_tools then
    destructive = Policy.effective_destructive_tools()
  else
    destructive = cfg.destructive_tools or {}
  end
  local allow = {}
  for _, t in ipairs(tools) do
    if not vim.tbl_contains(destructive, t) then
      table.insert(allow, t)
    end
  end
  return allow
end

--- Apply a mode: persona, persistence, and tool-permission gating.
--- Tool gating is applied at submit time (see runtime.tools.filter_for_mode and
--- the auto_approve policy below), not via a global override, so the owned
--- runtime honors read_only/allow_tools/auto_approve per submission.
function M.switch(mode)
  vim.g.agent_mode = mode.name
  vim.g.agent_mode_prompt = mode.system_prompt or ""
  require("agent_core.keys").save_active_mode(mode.name)

  vim.notify("Agent mode: " .. (mode.label or mode.name), vim.log.levels.INFO)
end

--- Return the mode persona for the system prompt, or "" when no mode is set.
function M.get_mode_prompt()
  if vim.g.agent_mode_prompt and vim.g.agent_mode_prompt ~= "" then
    return "## Active mode (" .. tostring(vim.g.agent_mode) .. ")\n\n" .. vim.g.agent_mode_prompt
  end
  return ""
end

--- Re-apply the last-used mode (best-effort).
function M.restore()
  local name = M.get_active()
  if not name then
    return
  end
  local mode = M.find(name)
  if mode then
    M.switch(mode)
  end
end

function M.setup()
  -- The owned runtime applies the mode persona/tool policy per submission, so
  -- restoring the last-used mode is a simple immediate call.
  vim.schedule(M.restore)
end

return M
