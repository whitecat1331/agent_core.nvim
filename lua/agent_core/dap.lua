---@mod agent_core.dap Real-debugger bridge over nvim-dap (debugger parity)
---@brief [[
--- Turns Debug mode from a print-instrumentation loop into a genuine interactive
--- debugger the AI drives end-to-end: set breakpoints, launch, step over/into/out,
--- inspect threads, stack frames, scopes and variables, and evaluate expressions —
--- all as custom tools. The bridge is a thin adapter over nvim-dap: it only
--- speaks nvim-dap's generic API, so every DAP adapter (codelldb, delve, debugpy,
--- js-debug, java-debug, netcoredbg, one-small-step-for-vimkind, ...) is supported
--- without any per-language code here.
---
--- Blocking tools (debug_start / debug_continue / debug_step_*) hold their
--- on_complete callback until the debugger actually stops, then return the full
--- paused state. From the model's perspective this is identical to an
--- injected "paused at file:line" event — the tool_result is the injection channel,
--- so no upstream fork is required.
---
--- nvim-dap is soft-required: when it (or a debug adapter) is absent the tools
--- return a clear error instead of throwing, and the existing instrumentation
--- loop in agent_core.debug remains the fallback.
---@brief ]]

local M = {}

--- Defaults. Override with require("agent_core").setup({ dap = { ... } }).
M.config = {
  timeout_ms = 15000, -- max wait (ms) for a stop/terminate event before the tool returns
  max_frames = 20, -- cap on stack frames returned per stop
  max_variables = 100, -- cap on variables returned per scope
  max_output_chars = 4000, -- cap on captured debug-console output returned to the model
  auto_start_on_switch = false, -- reserved: auto-run debug_list_adapters into the persona
}

--- Internal state (exposed for tests and introspection).
---@class agent_core.dap.State
---@field dap table|false|nil cached nvim-dap module (false = not installed)
---@field pending fun(snapshot: table|nil, err: string|nil)[] resolvers waiting for a stop/terminate event
---@field last_snapshot table|nil most recent serialized stop (paused/terminated/exited)
---@field output string captured stdout/stderr debug-console output (ring-buffered by max_output_chars)
---@field listeners_registered boolean whether our dap listeners are installed
M.state = {
  dap = nil,
  pending = {},
  last_snapshot = nil,
  output = "",
  listeners_registered = false,
}

local state = M.state
local LISTENER_KEY = "agent_core.dap"

--- Return the nvim-dap module, or nil when it is not installed. Caches the
--- result and registers our listeners on first successful require.
---@return table|nil
function M.get_dap()
  if state.dap == nil then
    local ok, dap = pcall(require, "dap")
    if ok and dap then
      state.dap = dap
      M._register_listeners()
    else
      state.dap = false
    end
  end
  if state.dap == false then
    return nil
  end
  return state.dap
end

--- Return the active dap session, or nil.
---@return table|nil
function M.get_session()
  local dap = M.get_dap()
  if not dap then
    return nil
  end
  local ok, s = pcall(dap.session, dap)
  if not ok then
    return nil
  end
  return s
end

--- Captured debug-console output (bounded by config.dap.max_output_chars).
---@return string
function M.output()
  return state.output
end

-- ── pure formatters (unit-testable, no dap dependency) ─────────────────────

--- Normalise a single stack frame into a plain table.
---@param frame table
---@return table
function M.format_frame(frame)
  local source = "<unknown>"
  if frame.source then
    source = frame.source.path or frame.source.name or "<unknown>"
  end
  return {
    id = frame.id,
    name = frame.name or "<unknown>",
    source = source,
    line = frame.line,
    column = frame.column,
  }
end

--- Normalise a list of stack frames, capped by max_frames.
---@param stack_frames table[]
---@param max_frames integer|nil
---@return table[]
function M.format_frames(stack_frames, max_frames)
  local out = {}
  local cap = max_frames or M.config.max_frames
  for i, frame in ipairs(stack_frames or {}) do
    if i > cap then
      break
    end
    out[#out + 1] = M.format_frame(frame)
  end
  return out
end

--- Normalise a list of variables, capped by max_variables.
---@param vars table[]
---@param max_variables integer|nil
---@return table[]
function M.format_variables(vars, max_variables)
  local out = {}
  local cap = max_variables or M.config.max_variables
  for i, v in ipairs(vars or {}) do
    if i > cap then
      break
    end
    out[#out + 1] = {
      name = v.name,
      value = v.value,
      type = v.type,
      variablesReference = v.variablesReference or 0,
      evaluateName = v.evaluateName,
    }
  end
  return out
end

--- Render a serialized snapshot as readable text for the model.
---@param snap table|nil
---@return string
function M.render_snapshot(snap)
  if not snap then
    return "no debugger snapshot available"
  end
  if snap.kind ~= "paused" then
    return snap.kind .. (snap.description and (": " .. snap.description) or "")
  end
  local lines = {}
  local top = snap.top_frame
  local loc = top and (top.source .. ":" .. tostring(top.line)) or "<unknown>"
  lines[#lines + 1] = string.format(
    "Paused at %s in %s (reason: %s, thread: %s)",
    loc,
    top and top.name or "<unknown>",
    tostring(snap.reason or "?"),
    tostring(snap.threadId or "?")
  )
  if snap.description and snap.description ~= "" then
    lines[#lines + 1] = "  " .. snap.description
  end
  lines[#lines + 1] = "Stack frames:"
  for i, f in ipairs(snap.frames or {}) do
    lines[#lines + 1] = string.format("  #%d %s  %s:%s", i - 1, f.name or "?", f.source or "?", tostring(f.line or "?"))
  end
  for _, sc in ipairs(snap.scopes or {}) do
    local vars = sc.variables or {}
    local label = string.format("Scope [%s] (%d variable(s)):", sc.name or "?", #vars)
    if sc.expensive then
      label = label .. " (expensive)"
    end
    lines[#lines + 1] = label
    for _, v in ipairs(vars) do
      local suffix = ""
      if v.variablesReference and v.variablesReference > 0 then
        suffix = string.format("  [ref %d]", v.variablesReference)
      end
      lines[#lines + 1] = string.format("    %s = %s  %s%s", v.name or "?", tostring(v.value), v.type or "", suffix)
    end
  end
  return table.concat(lines, "\n")
end

-- ── async request helpers (thin wrappers over session:request) ─────────────

--- Fetch the stack trace for a thread.
---@param session table
---@param thread_id integer
---@param cb fun(frames: table[]|nil, err: string|nil)
function M.request_frames(session, thread_id, cb)
  if not session or not session.request then
    cb(nil, "no active session")
    return
  end
  local ok, req_err = pcall(session.request, session, "stackTrace", { threadId = thread_id }, function(err, response)
    if err then
      cb(nil, tostring(err))
      return
    end
    cb(response and response.stackFrames or {}, nil)
  end)
  if not ok then
    cb(nil, "request stackTrace failed: " .. tostring(req_err))
  end
end

--- Fetch the scopes for a frame.
---@param session table
---@param frame_id integer
---@param cb fun(scopes: table[]|nil, err: string|nil)
function M.request_scopes(session, frame_id, cb)
  if not session or not session.request then
    cb(nil, "no active session")
    return
  end
  local ok, req_err = pcall(session.request, session, "scopes", { frameId = frame_id }, function(err, response)
    if err then
      cb(nil, tostring(err))
      return
    end
    cb(response and response.scopes or {}, nil)
  end)
  if not ok then
    cb(nil, "request scopes failed: " .. tostring(req_err))
  end
end

--- Fetch the variables for a variablesReference.
---@param session table
---@param variables_ref integer
---@param cb fun(vars: table[]|nil, err: string|nil)
function M.request_variables(session, variables_ref, cb)
  if not session or not session.request then
    cb(nil, "no active session")
    return
  end
  local ok, req_err = pcall(
    session.request,
    session,
    "variables",
    { variablesReference = variables_ref },
    function(err, response)
      if err then
        cb(nil, tostring(err))
        return
      end
      cb(response and response.variables or {}, nil)
    end
  )
  if not ok then
    cb(nil, "request variables failed: " .. tostring(req_err))
  end
end

--- Evaluate an expression in a paused frame.
---@param session table
---@param expression string
---@param frame_id integer|nil
---@param cb fun(result: table|nil, err: string|nil)
function M.evaluate(session, expression, frame_id, cb)
  if not session or not session.request then
    cb(nil, "no active session")
    return
  end
  local args = { expression = expression, context = "repl" }
  if frame_id then
    args.frameId = frame_id
  end
  local ok, req_err = pcall(session.request, session, "evaluate", args, function(err, response)
    if err then
      cb(nil, tostring(err))
      return
    end
    cb(response or {}, nil)
  end)
  if not ok then
    cb(nil, "request evaluate failed: " .. tostring(req_err))
  end
end

--- Serialize a full "stopped" event into a snapshot: reason, thread, frames,
--- top-frame scopes, and (non-expensive) scope variables. Async; cb receives
--- (snapshot, err).
---@param session table
---@param body table
---@param cb fun(snapshot: table|nil, err: string|nil)
function M.serialize_stop(session, body, cb)
  local thread_id = (body and body.threadId) or session.stopped_thread_id
  local snapshot = {
    kind = "paused",
    reason = (body and body.reason) or "stopped",
    description = body and (body.description or body.text) or nil,
    threadId = thread_id,
    frames = {},
    top_frame = nil,
    scopes = {},
  }
  if not thread_id then
    cb(snapshot, nil)
    return
  end
  M.request_frames(session, thread_id, function(stack_frames, ferr)
    if ferr then
      snapshot.error = ferr
      cb(snapshot, nil)
      return
    end
    snapshot.frames = M.format_frames(stack_frames)
    if #stack_frames == 0 then
      cb(snapshot, nil)
      return
    end
    local top = stack_frames[1]
    snapshot.top_frame = M.format_frame(top)
    M.request_scopes(session, top.id, function(scopes, serr)
      if serr then
        snapshot.error = serr
        cb(snapshot, nil)
        return
      end
      local remaining = #scopes
      if remaining == 0 then
        cb(snapshot, nil)
        return
      end
      local function finish()
        cb(snapshot, nil)
      end
      for _, scope in ipairs(scopes) do
        local entry = {
          name = scope.name,
          variablesReference = scope.variablesReference or 0,
          expensive = scope.expensive,
          presentationHint = scope.presentationHint,
          variables = {},
        }
        snapshot.scopes[#snapshot.scopes + 1] = entry
        local ref = scope.variablesReference
        if not ref or ref <= 0 or scope.expensive then
          remaining = remaining - 1
          if remaining == 0 then
            finish()
          end
        else
          M.request_variables(session, ref, function(vars, verr)
            if not verr then
              entry.variables = M.format_variables(vars)
            else
              entry.error = verr
            end
            remaining = remaining - 1
            if remaining == 0 then
              finish()
            end
          end)
        end
      end
    end)
  end)
end

-- ── pending-resolver plumbing ──────────────────────────────────────────────

--- Resolve every pending resolver with a snapshot/err (one-shot). Exposed for
--- tests; normally invoked by the stop/terminate/exited listeners.
---@param snapshot table|nil
---@param err string|nil
function M._resolve_pending(snapshot, err)
  local list = state.pending
  state.pending = {}
  for _, r in ipairs(list) do
    r(snapshot, err)
  end
end

--- Run `command` (a function issuing one DAP command) and call
--- `cb(snapshot, err)` when the debugger next stops, terminates, or exits —
--- or after timeout_ms. Fully async: dap events arrive on the event loop.
---@param command fun()
---@param cb fun(snapshot: table|nil, err: string|nil)
---@param timeout_ms integer|nil
function M.wait_for_stop(command, cb, timeout_ms)
  if not M.get_dap() then
    cb(nil, "nvim-dap is not installed; install nvim-dap plus a debug adapter to use the debugger")
    return
  end
  local finished = false
  local timer = nil
  local function finish(snapshot, err)
    if finished then
      return
    end
    finished = true
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
    cb(snapshot, err)
  end

  table.insert(state.pending, finish)

  local timeout = timeout_ms or M.config.timeout_ms
  if timeout and timeout > 0 then
    timer = vim.defer_fn(function()
      for i = #state.pending, 1, -1 do
        if state.pending[i] == finish then
          table.remove(state.pending, i)
          break
        end
      end
      finish(nil, "timed out after " .. tostring(timeout) .. "ms waiting for the debugger to stop")
    end, timeout)
  end

  local ok, err = pcall(command)
  if not ok then
    for i = #state.pending, 1, -1 do
      if state.pending[i] == finish then
        table.remove(state.pending, i)
        break
      end
    end
    finish(nil, "debug command failed: " .. tostring(err))
  end
end

-- ── listeners ──────────────────────────────────────────────────────────────

--- event_stopped handler: serialize the pause and resolve any pending tool.
---@param session table
---@param body table
function M._on_stopped(session, body)
  M.serialize_stop(session, body, function(snapshot, err)
    if err then
      M._resolve_pending(nil, err)
      return
    end
    state.last_snapshot = snapshot
    M._resolve_pending(snapshot, nil)
  end)
end

--- event_terminated handler: the debuggee ended; resolve pending with a terminal snapshot.
---@param session table
---@param body table
function M._on_terminated(session, body)
  state.last_snapshot = { kind = "terminated", description = "debuggee terminated" }
  M._resolve_pending(state.last_snapshot, nil)
end

--- event_exited handler: resolve pending with the exit code.
---@param session table
---@param body table
function M._on_exited(session, body)
  local code = body and body.exitCode
  local description = "debuggee exited"
  if code ~= nil then
    description = description .. " with code " .. tostring(code)
  end
  state.last_snapshot = { kind = "exited", exitCode = code, description = description }
  M._resolve_pending(state.last_snapshot, nil)
end

--- event_output handler: capture stdout/stderr/console into a bounded buffer.
---@param session table
---@param body table
function M._on_output(session, body)
  if body and body.output then
    state.output = state.output .. body.output
    local cap = M.config.max_output_chars
    if cap and #state.output > cap then
      state.output = state.output:sub(#state.output - cap + 1)
    end
  end
end

--- Register our listeners on nvim-dap (idempotent). Called from get_dap() and
--- setup(). Safe to call when dap is absent.
function M._register_listeners()
  local dap = M.get_dap()
  if not dap or state.listeners_registered then
    return
  end
  if not dap.listeners or not dap.listeners.after then
    return
  end
  dap.listeners.after.event_stopped[LISTENER_KEY] = M._on_stopped
  dap.listeners.after.event_terminated[LISTENER_KEY] = M._on_terminated
  dap.listeners.after.event_exited[LISTENER_KEY] = M._on_exited
  dap.listeners.after.event_output[LISTENER_KEY] = M._on_output
  state.listeners_registered = true
end

-- ── adapter / config introspection ─────────────────────────────────────────

--- Sorted list of adapter names registered with nvim-dap.
---@return string[]
function M.list_adapters()
  local dap = M.get_dap()
  if not dap then
    return {}
  end
  local out = {}
  for name in pairs(dap.adapters or {}) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

--- Raw launch-config list for a filetype (resolving function-valued entries).
---@param filetype string|nil
---@return table[]
function M.get_configs(filetype)
  local dap = M.get_dap()
  if not dap then
    return {}
  end
  filetype = filetype or vim.bo.filetype
  local cfgs = (dap.configurations or {})[filetype] or {}
  if type(cfgs) == "function" then
    local ok, res = pcall(cfgs)
    if ok then
      cfgs = res or {}
    else
      cfgs = {}
    end
  end
  if type(cfgs) ~= "table" then
    return {}
  end
  return cfgs
end

--- Summarised launch configs ({ name, type, request }) for the model.
---@param filetype string|nil
---@return table[]
function M.list_configs(filetype)
  local out = {}
  for _, c in ipairs(M.get_configs(filetype)) do
    out[#out + 1] = {
      name = c.name,
      type = c.type,
      request = c.request,
    }
  end
  return out
end

--- Resolve a launch config from a name (string) or inline config (table).
--- Searches the current filetype first, then every registered filetype.
---@param spec string|table
---@return table|nil
function M.resolve_config(spec)
  if type(spec) == "table" then
    return spec
  end
  for _, c in ipairs(M.get_configs()) do
    if c.name == spec then
      return c
    end
  end
  local dap = M.get_dap()
  if not dap then
    return nil
  end
  for _, cfgs in pairs(dap.configurations or {}) do
    local list = cfgs
    if type(list) == "function" then
      local ok, res = pcall(list)
      if ok then
        list = res or {}
      else
        list = {}
      end
    end
    if type(list) == "table" then
      for _, c in ipairs(list) do
        if c.name == spec then
          return c
        end
      end
    end
  end
  return nil
end

--- First launch config for the current filetype, or nil.
---@return table|nil
function M.default_config()
  return M.get_configs()[1]
end

-- ── breakpoint helpers (arbitrary file:line, not caret-bound) ─────────────

--- Sync local breakpoints to an active session (mirrors nvim-dap's broadcast).
function M.sync_breakpoints()
  local s = M.get_session()
  if not s or not s.set_breakpoints then
    return
  end
  local ok, bp = pcall(require, "dap.breakpoints")
  if not ok then
    return
  end
  pcall(s.set_breakpoints, s, bp.get())
end

--- Set a breakpoint at an arbitrary file:line (1-based) with optional
--- condition / log message / hit condition. Returns (ok, err).
---@param bp table
---@return boolean, string|nil
function M.set_breakpoint_at(bp)
  local dap = M.get_dap()
  if not dap then
    return false, "nvim-dap is not installed"
  end
  local file = bp.file or bp.path
  if not file or file == "" then
    return false, "file is required"
  end
  local line = tonumber(bp.line)
  if not line or line < 1 then
    return false, "line is required (1-based integer)"
  end
  local ok_bp, bpmod = pcall(require, "dap.breakpoints")
  if not ok_bp then
    return false, "dap.breakpoints unavailable"
  end
  local bufnr = vim.fn.bufadd(file)
  if bufnr < 1 then
    return false, "could not resolve buffer for " .. file
  end
  vim.fn.bufload(bufnr)
  bpmod.set({
    condition = bp.condition,
    log_message = bp.log_message,
    hit_condition = bp.hit_condition,
  }, bufnr, line)
  M.sync_breakpoints()
  return true, nil
end

--- Clear one breakpoint (file:line) or all breakpoints. Returns (ok, err).
---@param bp table|nil
---@return boolean, string|nil
function M.clear_breakpoint_at(bp)
  local dap = M.get_dap()
  if not dap then
    return false, "nvim-dap is not installed"
  end
  local ok_bp, bpmod = pcall(require, "dap.breakpoints")
  if not ok_bp then
    return false, "dap.breakpoints unavailable"
  end
  if bp and bp.file and bp.line then
    local bufnr = vim.fn.bufadd(bp.file)
    bpmod.remove(bufnr, tonumber(bp.line))
  else
    dap.clear_breakpoints()
  end
  M.sync_breakpoints()
  return true, nil
end

-- ── user commands ──────────────────────────────────────────────────────────

--- :AgentDebugStart [config] — launch a debug session by config name (or the
--- default config for the current filetype).
---@param arg string|nil
function M.start_cmd(arg)
  local dap = M.get_dap()
  if not dap then
    vim.notify("Debug: nvim-dap is not installed", vim.log.levels.WARN)
    return
  end
  local cfg
  if arg and arg ~= "" then
    cfg = M.resolve_config(arg)
    if not cfg then
      vim.notify("Debug: no launch config named '" .. arg .. "'", vim.log.levels.WARN)
      return
    end
  else
    cfg = M.default_config()
  end
  if not cfg then
    vim.notify("Debug: no launch config for filetype '" .. vim.bo.filetype .. "'", vim.log.levels.WARN)
    return
  end
  dap.run(cfg)
end

--- :AgentDebugContinue — resume the current session.
function M.continue_cmd()
  local dap = M.get_dap()
  if not dap or not M.get_session() then
    vim.notify("Debug: no active session", vim.log.levels.WARN)
    return
  end
  dap.continue()
end

--- :AgentDebugStepOver — step over the current line.
function M.step_over_cmd()
  local dap = M.get_dap()
  if not dap or not M.get_session() then
    vim.notify("Debug: no active session", vim.log.levels.WARN)
    return
  end
  dap.step_over()
end

--- :AgentDebugStepInto — step into the current call.
function M.step_into_cmd()
  local dap = M.get_dap()
  if not dap or not M.get_session() then
    vim.notify("Debug: no active session", vim.log.levels.WARN)
    return
  end
  dap.step_into()
end

--- :AgentDebugStepOut — step out of the current function.
function M.step_out_cmd()
  local dap = M.get_dap()
  if not dap or not M.get_session() then
    vim.notify("Debug: no active session", vim.log.levels.WARN)
    return
  end
  dap.step_out()
end

--- :AgentDebugStop — terminate the current session.
function M.stop_cmd()
  local dap = M.get_dap()
  if not dap or not M.get_session() then
    vim.notify("Debug: no active session", vim.log.levels.WARN)
    return
  end
  dap.terminate()
end

--- :AgentDebugStatus — show adapters, launch configs, and the last snapshot.
function M.status_cmd()
  local dap = M.get_dap()
  if not dap then
    vim.notify("Debug: nvim-dap is not installed", vim.log.levels.WARN)
    return
  end
  local lines = { "Adapters: " .. table.concat(M.list_adapters(), ", ") }
  lines[#lines + 1] = "Launch configs (" .. vim.bo.filetype .. "): " .. vim.inspect(M.list_configs())
  local s = M.get_session()
  if s then
    if s.stopped_thread_id then
      lines[#lines + 1] = "Session: paused (thread " .. tostring(s.stopped_thread_id) .. ")"
    else
      lines[#lines + 1] = "Session: running"
    end
  else
    lines[#lines + 1] = "Session: none"
  end
  if state.last_snapshot and state.last_snapshot.kind == "paused" then
    lines[#lines + 1] = M.render_snapshot(state.last_snapshot)
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

-- ── custom tools ───────────────────────────────────────────────────────────

--- Shared guard: validates on_complete and an active dap/session.
---@param opts table
---@return string|nil error
local function require_session(opts)
  if not opts.on_complete then
    return "on_complete not provided"
  end
  if not M.get_dap() then
    return "nvim-dap is not installed; install nvim-dap plus a debug adapter to use the debugger"
  end
  if not M.get_session() then
    return "no active debug session; call debug_list_adapters then debug_start first"
  end
  return nil
end

--- Issue a blocking DAP command and resolve on_complete from the next stop.
---@param command fun()
---@param opts table
local function run_and_await(command, opts)
  M.wait_for_stop(command, function(snapshot, err)
    if err then
      opts.on_complete(nil, err)
      return
    end
    opts.on_complete(M.render_snapshot(snapshot), nil)
  end)
end

---@type AgentTool
local debug_list_adapters = {
  name = "debug_list_adapters",
  description = "List the debug adapters and launch configurations available via nvim-dap for the current buffer. "
    .. "Use this first in Debug mode to discover whether a real debugger can be attached for the active language.",
  param = {
    type = "table",
    fields = {},
    usage = {},
  },
  returns = {
    {
      name = "result",
      description = "Available adapters and launch configs",
      type = "string",
    },
    {
      name = "error",
      description = "Error message when nvim-dap is not installed",
      type = "string",
      optional = true,
    },
  },
}

---@type AgentToolFunc<{}>
function debug_list_adapters.func(input, opts)
  if not opts.on_complete then
    return nil, "on_complete not provided"
  end
  if not M.get_dap() then
    opts.on_complete(nil, "nvim-dap is not installed; install nvim-dap plus a debug adapter to use the debugger")
    return
  end
  local adapters = M.list_adapters()
  local cfgs = M.list_configs()
  local out = "Available adapters: " .. table.concat(adapters, ", ")
  out = out .. "\nLaunch configs for '" .. vim.bo.filetype .. "':\n" .. vim.inspect(cfgs)
  opts.on_complete(out, nil)
end

---@type AgentTool
local debug_start = {
  name = "debug_start",
  description = "Launch a debug session by config name or inline config, optionally placing breakpoints first. "
    .. "Blocks until the debugger stops (or the program exits) and returns the paused state (source line, stack, "
    .. "scopes, variables).",
  param = {
    type = "table",
    fields = {
      {
        name = "config_name",
        description = "Name of a launch config from debug_list_adapters (dap.configurations).",
        type = "string",
        optional = true,
      },
      {
        name = "config",
        description = "Full inline launch config table (type, request, program, ...) when no named config fits.",
        type = "table",
        optional = true,
      },
      {
        name = "breakpoints",
        description = "Optional list of breakpoints to set before launching: [{ file, line, condition?, log_message?, hit_condition? }].",
        type = "table",
        optional = true,
      },
    },
    usage = {
      config_name = "Launch config name (optional)",
      config = "Inline launch config (optional)",
      breakpoints = "Breakpoints to set first (optional)",
    },
  },
  returns = {
    {
      name = "result",
      description = "Paused-state snapshot (or termination notice)",
      type = "string",
    },
    {
      name = "error",
      description = "Error message when the launch failed",
      type = "string",
      optional = true,
    },
  },
}

---@type AgentToolFunc<{ config_name?: string, config?: table, breakpoints?: table[] }>
function debug_start.func(input, opts)
  if not opts.on_complete then
    return nil, "on_complete not provided"
  end
  local dap = M.get_dap()
  if not dap then
    opts.on_complete(nil, "nvim-dap is not installed; install nvim-dap plus a debug adapter to use the debugger")
    return
  end
  local cfg = input.config
  if not cfg and input.config_name then
    cfg = M.resolve_config(input.config_name)
  end
  if not cfg then
    cfg = M.default_config()
  end
  if not cfg then
    opts.on_complete(nil, "no launch config provided and none for filetype '" .. vim.bo.filetype .. "'")
    return
  end

  if input.breakpoints then
    for _, bp in ipairs(input.breakpoints) do
      local ok, err = M.set_breakpoint_at(bp)
      if not ok then
        opts.on_complete(nil, err)
        return
      end
    end
  end

  run_and_await(function()
    dap.run(cfg)
  end, opts)
end

---@type AgentTool
local debug_set_breakpoint = {
  name = "debug_set_breakpoint",
  description = "Set a breakpoint at an arbitrary file:line (1-based) with an optional condition, log message, "
    .. "and/or hit condition.",
  param = {
    type = "table",
    fields = {
      { name = "file", description = "Path of the file to break in.", type = "string" },
      { name = "line", description = "1-based line number.", type = "number" },
      {
        name = "condition",
        description = "Optional expression that must be true for the breakpoint to hit.",
        type = "string",
        optional = true,
      },
      {
        name = "log_message",
        description = "Optional log message to print when hit (a logpoint).",
        type = "string",
        optional = true,
      },
      {
        name = "hit_condition",
        description = "Optional hit count condition (e.g. '>= 3').",
        type = "string",
        optional = true,
      },
    },
    required = { "file", "line" },
    usage = {
      file = "File path",
      line = "Line number (1-based)",
    },
  },
  returns = {
    {
      name = "result",
      description = "Confirmation the breakpoint was set",
      type = "string",
    },
    {
      name = "error",
      description = "Error message when the breakpoint could not be set",
      type = "string",
      optional = true,
    },
  },
}

---@type AgentToolFunc<{ file: string, line: number }>
function debug_set_breakpoint.func(input, opts)
  if not opts.on_complete then
    return nil, "on_complete not provided"
  end
  local ok, err = M.set_breakpoint_at(input)
  if not ok then
    opts.on_complete(nil, err)
    return
  end
  opts.on_complete(string.format("Breakpoint set at %s:%s", input.file, tostring(input.line)), nil)
end

---@type AgentTool
local debug_clear_breakpoint = {
  name = "debug_clear_breakpoint",
  description = "Clear one breakpoint (file + 1-based line) or, with no arguments, all breakpoints.",
  param = {
    type = "table",
    fields = {
      { name = "file", description = "Path of the file.", type = "string", optional = true },
      { name = "line", description = "1-based line number.", type = "number", optional = true },
    },
    usage = {},
  },
  returns = {
    {
      name = "result",
      description = "Confirmation the breakpoint(s) were cleared",
      type = "string",
    },
    {
      name = "error",
      description = "Error message when the breakpoint could not be cleared",
      type = "string",
      optional = true,
    },
  },
}

---@type AgentToolFunc<{ file?: string, line?: number }>
function debug_clear_breakpoint.func(input, opts)
  if not opts.on_complete then
    return nil, "on_complete not provided"
  end
  local ok, err = M.clear_breakpoint_at(input)
  if not ok then
    opts.on_complete(nil, err)
    return
  end
  opts.on_complete("Breakpoint(s) cleared", nil)
end

---@type AgentTool
local debug_continue = {
  name = "debug_continue",
  description = "Resume execution. Blocks until the debugger next stops (breakpoint/exception) or the program "
    .. "terminates, then returns the new paused state.",
  param = { type = "table", fields = {}, usage = {} },
  returns = {
    {
      name = "result",
      description = "New paused-state snapshot (or termination notice)",
      type = "string",
    },
    {
      name = "error",
      description = "Error message when there is no active session",
      type = "string",
      optional = true,
    },
  },
}

---@type AgentToolFunc<{}>
function debug_continue.func(input, opts)
  local err = require_session(opts)
  if err then
    if opts.on_complete then
      opts.on_complete(nil, err)
    end
    return
  end
  run_and_await(function()
    M.get_dap().continue()
  end, opts)
end

---@type AgentTool
local debug_step_over = {
  name = "debug_step_over",
  description = "Step over the current line. Blocks until the debugger stops and returns the new paused state.",
  param = { type = "table", fields = {}, usage = {} },
  returns = {
    {
      name = "result",
      description = "New paused-state snapshot",
      type = "string",
    },
    {
      name = "error",
      description = "Error message when there is no active session",
      type = "string",
      optional = true,
    },
  },
}

---@type AgentToolFunc<{}>
function debug_step_over.func(input, opts)
  local err = require_session(opts)
  if err then
    if opts.on_complete then
      opts.on_complete(nil, err)
    end
    return
  end
  run_and_await(function()
    M.get_dap().step_over()
  end, opts)
end

---@type AgentTool
local debug_step_into = {
  name = "debug_step_into",
  description = "Step into the current call. Blocks until the debugger stops and returns the new paused state.",
  param = { type = "table", fields = {}, usage = {} },
  returns = {
    {
      name = "result",
      description = "New paused-state snapshot",
      type = "string",
    },
    {
      name = "error",
      description = "Error message when there is no active session",
      type = "string",
      optional = true,
    },
  },
}

---@type AgentToolFunc<{}>
function debug_step_into.func(input, opts)
  local err = require_session(opts)
  if err then
    if opts.on_complete then
      opts.on_complete(nil, err)
    end
    return
  end
  run_and_await(function()
    M.get_dap().step_into()
  end, opts)
end

---@type AgentTool
local debug_step_out = {
  name = "debug_step_out",
  description = "Step out of the current function. Blocks until the debugger stops and returns the new paused state.",
  param = { type = "table", fields = {}, usage = {} },
  returns = {
    {
      name = "result",
      description = "New paused-state snapshot",
      type = "string",
    },
    {
      name = "error",
      description = "Error message when there is no active session",
      type = "string",
      optional = true,
    },
  },
}

---@type AgentToolFunc<{}>
function debug_step_out.func(input, opts)
  local err = require_session(opts)
  if err then
    if opts.on_complete then
      opts.on_complete(nil, err)
    end
    return
  end
  run_and_await(function()
    M.get_dap().step_out()
  end, opts)
end

---@type AgentTool
local debug_pause = {
  name = "debug_pause",
  description = "Interrupt a running debuggee. Blocks until it pauses and returns the paused state.",
  param = {
    type = "table",
    fields = {
      { name = "threadId", description = "Optional thread id to pause.", type = "number", optional = true },
    },
    usage = {},
  },
  returns = {
    {
      name = "result",
      description = "New paused-state snapshot",
      type = "string",
    },
    {
      name = "error",
      description = "Error message when there is no active session",
      type = "string",
      optional = true,
    },
  },
}

---@type AgentToolFunc<{ threadId?: number }>
function debug_pause.func(input, opts)
  local err = require_session(opts)
  if err then
    if opts.on_complete then
      opts.on_complete(nil, err)
    end
    return
  end
  run_and_await(function()
    M.get_dap().pause(input.threadId)
  end, opts)
end

---@type AgentTool
local debug_get_state = {
  name = "debug_get_state",
  description = "Non-blocking snapshot of the debugger: paused state, threads/frames/scopes/variables (from the last "
    .. "stop), plus captured debug-console output.",
  param = { type = "table", fields = {}, usage = {} },
  returns = {
    {
      name = "result",
      description = "Current debugger state",
      type = "string",
    },
    {
      name = "error",
      description = "Error message when there is no active session",
      type = "string",
      optional = true,
    },
  },
}

---@type AgentToolFunc<{}>
function debug_get_state.func(input, opts)
  if not opts.on_complete then
    return nil, "on_complete not provided"
  end
  local s = M.get_session()
  if not s then
    opts.on_complete(nil, "no active debug session")
    return
  end
  local snap = state.last_snapshot
  local body
  if snap and snap.kind == "paused" then
    body = M.render_snapshot(snap)
  else
    if s.stopped_thread_id then
      body = "Debug session paused (thread " .. tostring(s.stopped_thread_id) .. "); no snapshot captured yet."
    else
      body = "Debug session running."
    end
  end
  if state.output and state.output ~= "" then
    body = body .. "\n\n[debug console output]\n" .. state.output
  end
  opts.on_complete(body, nil)
end

---@type AgentTool
local debug_get_variables = {
  name = "debug_get_variables",
  description = "Expand a variablesReference (from a scope or variable) into its child variables.",
  param = {
    type = "table",
    fields = {
      { name = "variablesReference", description = "The variablesReference integer to expand.", type = "number" },
    },
    required = { "variablesReference" },
    usage = {
      variablesReference = "Variables reference to expand",
    },
  },
  returns = {
    {
      name = "result",
      description = "Expanded variables",
      type = "string",
    },
    {
      name = "error",
      description = "Error message when there is no active session",
      type = "string",
      optional = true,
    },
  },
}

---@type AgentToolFunc<{ variablesReference: number }>
function debug_get_variables.func(input, opts)
  local err = require_session(opts)
  if err then
    if opts.on_complete then
      opts.on_complete(nil, err)
    end
    return
  end
  local ref = tonumber(input.variablesReference)
  if not ref then
    opts.on_complete(nil, "variablesReference (integer) is required")
    return
  end
  M.request_variables(M.get_session(), ref, function(vars, verr)
    if verr then
      opts.on_complete(nil, verr)
      return
    end
    opts.on_complete(vim.inspect(M.format_variables(vars)), nil)
  end)
end

---@type AgentTool
local debug_evaluate = {
  name = "debug_evaluate",
  description = "Evaluate an expression in the paused frame (optionally specifying a frame id).",
  param = {
    type = "table",
    fields = {
      { name = "expression", description = "The expression to evaluate.", type = "string" },
      {
        name = "frameId",
        description = "Optional frame id; defaults to the current frame.",
        type = "number",
        optional = true,
      },
    },
    required = { "expression" },
    usage = {
      expression = "Expression to evaluate",
    },
  },
  returns = {
    {
      name = "result",
      description = "Evaluation result",
      type = "string",
    },
    {
      name = "error",
      description = "Error message when there is no active session",
      type = "string",
      optional = true,
    },
  },
}

---@type AgentToolFunc<{ expression: string, frameId?: number }>
function debug_evaluate.func(input, opts)
  local err = require_session(opts)
  if err then
    if opts.on_complete then
      opts.on_complete(nil, err)
    end
    return
  end
  if not input.expression or input.expression == "" then
    opts.on_complete(nil, "expression is required")
    return
  end
  local s = M.get_session()
  local frame_id = tonumber(input.frameId)
  if not frame_id and s.current_frame then
    frame_id = s.current_frame.id
  end
  M.evaluate(s, input.expression, frame_id, function(result, eerr)
    if eerr then
      opts.on_complete(nil, eerr)
      return
    end
    local out = tostring(result.result)
    if result.variablesReference and result.variablesReference > 0 then
      out = out
        .. "\n[variablesReference="
        .. tostring(result.variablesReference)
        .. " — expand with debug_get_variables]"
    end
    if result.type then
      out = out .. "\n[type: " .. tostring(result.type) .. "]"
    end
    opts.on_complete(out, nil)
  end)
end

---@type AgentTool
local debug_stop = {
  name = "debug_stop",
  description = "Terminate (or disconnect) the current debug session.",
  param = { type = "table", fields = {}, usage = {} },
  returns = {
    {
      name = "result",
      description = "Confirmation the session was terminated",
      type = "string",
    },
    {
      name = "error",
      description = "Error message when there is no active session",
      type = "string",
      optional = true,
    },
  },
}

---@type AgentToolFunc<{}>
function debug_stop.func(input, opts)
  local err = require_session(opts)
  if err then
    if opts.on_complete then
      opts.on_complete(nil, err)
    end
    return
  end
  M.get_dap().terminate()
  opts.on_complete("Debug session terminated", nil)
end

---@type AgentTool
local debug_restart = {
  name = "debug_restart",
  description = "Restart the current debug session. Blocks until the debugger stops and returns the paused state.",
  param = { type = "table", fields = {}, usage = {} },
  returns = {
    {
      name = "result",
      description = "New paused-state snapshot",
      type = "string",
    },
    {
      name = "error",
      description = "Error message when there is no active session",
      type = "string",
      optional = true,
    },
  },
}

---@type AgentToolFunc<{}>
function debug_restart.func(input, opts)
  local err = require_session(opts)
  if err then
    if opts.on_complete then
      opts.on_complete(nil, err)
    end
    return
  end
  run_and_await(function()
    M.get_dap().restart()
  end, opts)
end

function M.setup()
  local cfg = require("agent_core").config
  M.config = vim.tbl_deep_extend("force", M.config, cfg.dap or {})
  M.get_dap() -- registers listeners if nvim-dap is already installed
end

-- ── tool factory exports ───────────────────────────────────────────────────

function M.debug_list_adapters_tool()
  return debug_list_adapters
end

function M.debug_start_tool()
  return debug_start
end

function M.debug_set_breakpoint_tool()
  return debug_set_breakpoint
end

function M.debug_clear_breakpoint_tool()
  return debug_clear_breakpoint
end

function M.debug_continue_tool()
  return debug_continue
end

function M.debug_step_over_tool()
  return debug_step_over
end

function M.debug_step_into_tool()
  return debug_step_into
end

function M.debug_step_out_tool()
  return debug_step_out
end

function M.debug_pause_tool()
  return debug_pause
end

function M.debug_get_state_tool()
  return debug_get_state
end

function M.debug_get_variables_tool()
  return debug_get_variables
end

function M.debug_evaluate_tool()
  return debug_evaluate
end

function M.debug_stop_tool()
  return debug_stop
end

function M.debug_restart_tool()
  return debug_restart
end

return M
