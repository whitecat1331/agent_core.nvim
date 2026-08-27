---@mod agent_core.modes Cursor-style behavior modes (ask/plan/debug/agent/multitask)
---@brief [[
--- A mode is orthogonal to a profile: profiles bundle provider/model/API key,
--- modes bundle behavior (read-only vs full), tool permissions, and a persona.
--- Modes map onto avante's runtime `avante.config.override` (disabled_tools +
--- auto_approve_tool_permissions) plus a persona injected via
--- `vim.g.agent_mode_prompt`, which the avante system_prompt function reads.
---@brief ]]

local M = {}

--- avante tool names that mutate state. Used to build the read-only allowlist
--- for ask/plan modes. Keep this in sync with avante's built-in tools and any
--- custom tools that can change the filesystem.
M.WRITE_TOOLS = {
  "bash",
  "run_python",
  "git_commit",
  "str_replace",
  "write_to_file",
  "insert",
  "undo_edit",
  "edit_file",
  "write_global_file",
  "move_path",
  "copy_path",
  "delete_path",
  "create_dir",
  "write_todos",
  -- agent_core.multitask custom tool (write-capable subagents)
  "run_agent",
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
    system_prompt = [[
MODE: Plan — you are in a read-only planning mode.
- Research the codebase thoroughly and produce a concrete, step-by-step implementation plan.
- Identify the exact files and changes needed, and call out trade-offs and risks.
- Do NOT edit files or run mutating commands.]],
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
- Make changes directly and verify them with tests or builds.]],
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
MODE: Debug — investigate failures with runtime evidence.
- Reproduce the issue, gather evidence (errors, logs, diagnostics, tests), find the root cause, then fix it.
- Prefer evidence over assumptions; add targeted logging or assertions only when necessary.]],
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

function M.all()
  local cfg = require("agent_core").config
  return cfg.modes or M.defaults
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

--- True once avante.setup() has run (its config module has providers populated).
local function avante_ready()
  local ok, Config = pcall(require, "avante.config")
  if not ok then
    return false
  end
  return Config.providers ~= nil
end

--- Compute the auto-approve policy for a mode.
--- - read_only -> false (read tools never prompt; write tools are disabled anyway)
--- - auto_approve == "all" -> true (full Cursor parity)
--- - otherwise -> every tool except the destructive list
---@param mode table
---@param tools string[] all tool names currently registered by avante
function M.auto_approve(mode, tools)
  if mode.read_only then
    return false
  end
  if mode.auto_approve == "all" then
    return true
  end
  local cfg = require("agent_core").config
  local destructive = cfg.destructive_tools or {}
  local allow = {}
  for _, t in ipairs(tools) do
    if not vim.tbl_contains(destructive, t) then
      table.insert(allow, t)
    end
  end
  return allow
end

--- Apply a mode: persona, tool policy, auto-approve, optional provider/model.
--- The persona and persistence always apply; the avante tool policy is applied
--- only once avante is loaded (otherwise it is applied on restore).
function M.switch(mode)
  vim.g.agent_mode = mode.name
  vim.g.agent_mode_prompt = mode.system_prompt or ""
  require("agent_core.keys").save_active_mode(mode.name)

  if not avante_ready() then
    vim.notify(
      "Agent mode: " .. (mode.label or mode.name) .. " (tool policy applies once avante loads)",
      vim.log.levels.INFO
    )
    return
  end

  local Config = require("avante.config")

  local tools = {}
  local ok_tools, Tools = pcall(require, "avante.llm_tools")
  if ok_tools and Tools.get_tool_names then
    tools = Tools.get_tool_names()
  end

  local disabled = {}
  if mode.read_only then
    disabled = vim.tbl_filter(function(t)
      return vim.tbl_contains(M.WRITE_TOOLS, t)
    end, tools)
  end

  pcall(Config.override, {
    mode = "agentic",
    disabled_tools = disabled,
    behaviour = { auto_approve_tool_permissions = M.auto_approve(mode, tools) },
  })

  if mode.provider then
    pcall(require("avante.api").switch_provider, mode.provider)
  end

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
  -- avante lazy-loads on VeryLazy, so restore the mode once its config is ready.
  local attempts = 0
  local function try_restore()
    local ok = pcall(require, "avante.config")
    if not ok then
      return -- avante not installed; nothing to restore
    end
    attempts = attempts + 1
    if avante_ready() then
      M.restore()
      return
    end
    if attempts < 10 then
      vim.defer_fn(try_restore, 300)
    end
  end
  vim.schedule(try_restore)
end

return M
