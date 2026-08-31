---@mod agent_core.runtime.session Owned per-session agent runtime.
---@brief [[
--- The owned Session: provider + model + API key are PER-SESSION fields (not a
--- process-global), so N sessions on N different models run concurrently, each
--- in its own libuv curl subprocess. Replaces the retired upstream agent loop
--- native tool-calling loop:
---
---   stream -> parse text/tool calls -> execute tools (parallel) ->
---     append tool results -> loop until the model stops calling tools.
---
--- The tool contract is the existing AgentTool shape; `run` takes the same
--- options the upstream agent loop took (system_prompt, user_input, tools,
--- on_tool_log, on_messages_add, session_ctx, on_start, on_complete) so existing
--- callers (multitask.run_agent, bugbot.autofix) rewire unchanged in Phase 5.
---@brief ]]

local Tools = require("agent_core.runtime.tools")
local Providers = require("agent_core.runtime.providers")
local Schema = require("agent_core.runtime.schema")

local M = {}

---@class Session
---@field id string
---@field title string
---@field provider string
---@field model string
---@field api_key string|nil
---@field endpoint string|nil
---@field api_key_name string|nil
---@field messages table[]
---@field status string
---@field max_iterations integer
---@field on_text fun(chunk:string)|nil
local Session = {}
Session.__index = Session

--- The owned built-in tools (attempt_completion + bash/file/glob/grep/todos).
---@return table[]
function M.builtin_tools()
  return require("agent_core.runtime.tools.builtins").all()
end

--- Create a new Session.
---@param opts { id?:string, title?:string, provider:string, model:string, api_key?:string, endpoint?:string, api_key_name?:string }
---@return Session
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    id = opts.id or tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999)),
    title = opts.title or "untitled",
    provider = opts.provider,
    model = opts.model,
    api_key = opts.api_key,
    endpoint = opts.endpoint,
    api_key_name = opts.api_key_name,
    messages = {},
    status = "idle",
    max_iterations = 25,
    _edit_turn = 0,
    on_text = nil,
  }, Session)
end

--- A history-store record for this session (id + title + provider + model +
--- messages), matching the agent_core.runtime.history schema.
---@return table
function Session:to_record()
  return {
    id = self.id,
    title = self.title,
    provider = self.provider,
    model = self.model,
    messages = self.messages or {},
  }
end

--- Persist this session into the owned history directory. Returns true on write.
---@param dir string
---@return boolean
function Session:persist(dir)
  if not dir or dir == "" then
    return false
  end
  return require("agent_core.runtime.history").save(dir, self.id, self:to_record())
end

---@param msg table
---@return string
local function make_uuid(msg)
  return tostring(msg and msg.uuid or (os.time() .. "-" .. math.random(100000, 999999)))
end

--- Decode tool-call arguments (a JSON string from providers) into a Lua table.
---@param arguments string
---@return table
local function decode_arguments(arguments)
  if arguments == nil or arguments == "" then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, arguments)
  if ok and type(decoded) == "table" then
    return decoded
  end
  return {}
end

--- Run the native agent loop.
---@param opts { system_prompt?:string, user_input:string, tools?:table[], on_tool_log?:fun(string), on_messages_add?:fun(table|table[]), session_ctx?:table, on_start?:fun(), on_complete:fun(err:string|nil), max_iterations?:integer, approve?:fun(name:string, cb:fun(allow:boolean)) }
function Session:run(opts)
  opts = opts or {}
  if opts.max_iterations then
    self.max_iterations = opts.max_iterations
  end

  -- One submit = one edit batch; every file mutation in this run journals
  -- under the same turn number for per-turn keep/discard.
  self._edit_turn = (self._edit_turn or 0) + 1

  if opts.on_start then
    opts.on_start()
  end
  self.status = "running"
  self.handle = nil
  self._finish = nil

  -- Register tools for this run: owned built-ins + caller-provided custom tools.
  Tools.clear()
  Tools.register_all(M.builtin_tools())
  Tools.register_all(opts.tools or {})

  local descriptors = Tools.descriptors()
  local function log(msg)
    if opts.on_tool_log then
      opts.on_tool_log(msg)
    end
  end

  -- Normalized message history (fed to providers on each turn).
  local history = {
    { role = "user", content = opts.user_input },
  }

  local function emit_messages(msgs)
    if not opts.on_messages_add then
      return
    end
    for _, m in ipairs(msgs) do
      m.uuid = m.uuid or make_uuid(m)
    end
    opts.on_messages_add(msgs)
  end

  local function emit_text(chunk)
    if self.on_text and chunk and chunk ~= "" then
      self.on_text(chunk)
    end
  end

  -- Execute one tool call and append its result message to history.
  local function run_tool(tc, on_done)
    local input = decode_arguments(tc.arguments)
    log("tool call: " .. tc.name .. " " .. vim.json.encode(input))
    local tool = Tools.get(tc.name)
    if not tool then
      history[#history + 1] = {
        role = "tool",
        tool_call_id = tc.id,
        name = tc.name,
        content = "unknown tool: " .. tostring(tc.name),
      }
      emit_messages({ history[#history] })
      on_done()
      return
    end

    local function do_execute()
      if tc.name == "write_to_file" or tc.name == "str_replace" then
        require("agent_core.session_edits").capture(self.id, self._edit_turn, tc.name, input.file_path)
      end
      Tools.execute(tool, input, {
        on_complete = function(result, err)
          local content = err ~= nil and ("tool error: " .. tostring(err))
            or (type(result) == "string" and result or vim.json.encode(result or ""))
          history[#history + 1] = {
            role = "tool",
            tool_call_id = tc.id,
            name = tc.name,
            content = content,
          }
          emit_messages({ history[#history] })
          on_done()
        end,
        on_log = log,
        session_ctx = opts.session_ctx,
      })
    end

    -- Optional approval gate: only invoked when a caller (the interactive
    -- submit path) supplies opts.approve. Headless callers (run_agent, bugbot)
    -- omit it and their subagent tools run with auto-approve.
    if opts.approve then
      opts.approve(tc.name, function(allow)
        if not allow then
          history[#history + 1] = {
            role = "tool",
            tool_call_id = tc.id,
            name = tc.name,
            content = "tool call cancelled by user",
          }
          emit_messages({ history[#history] })
          on_done()
          return
        end
        do_execute()
      end)
    else
      do_execute()
    end
  end

  local function finish(err)
    if self.status == "done" or self.status == "cancelled" then
      return
    end
    self.status = (err == "cancelled") and "cancelled" or "done"
    self.handle = nil
    self.messages = history
    if opts.on_complete then
      opts.on_complete(err)
    end
  end
  self._finish = finish

  local Context ---@type table|nil
  if opts.context then
    Context = require("agent_core.runtime.context")
  end

  local iteration = 0
  local turn ---@type fun()
  local function do_stream()
    local ok, err = Providers.stream({
      provider = self.provider,
      model = self.model,
      api_key = self.api_key,
      endpoint = self.endpoint,
      api_key_name = self.api_key_name,
      system = opts.system_prompt,
      messages = history,
      tools = descriptors,
      on_chunk = emit_text,
      on_handle = function(h)
        self.handle = h
      end,
      on_stop = function(res)
        if res.error then
          finish(res.error)
          return
        end

        -- Append the assistant turn to history.
        local assistant = {
          role = "assistant",
          content = res.text or "",
          tool_calls = res.tool_calls or {},
        }
        history[#history + 1] = assistant
        emit_messages({ assistant })

        local tool_calls = res.tool_calls or {}
        if #tool_calls == 0 then
          finish(nil)
          return
        end

        -- Run all tool calls in parallel; continue when every result is back.
        local pending = #tool_calls
        for _, tc in ipairs(tool_calls) do
          run_tool(tc, function()
            pending = pending - 1
            if pending == 0 then
              turn()
            end
          end)
        end
      end,
    })
    if not ok then
      finish(tostring(err))
    end
  end

  -- Optional two-threshold compaction before each turn (owned context manager).
  -- Hard threshold force-drops the oldest messages (pure); the soft threshold
  -- summarizes via the injected opts.compact_fn (cheaper model) when available.
  turn = function()
    iteration = iteration + 1
    if iteration > self.max_iterations then
      finish("max iterations reached (" .. tostring(self.max_iterations) .. ")")
      return
    end

    if not Context then
      do_stream()
      return
    end

    local action = Context.should_compact(history, opts.context)
    if action == "hard" then
      history = Context.hard_truncate(history, opts.context)
      do_stream()
    elseif action == "soft" and opts.compact_fn then
      local older, recent = Context.keep_recent(history, opts.context.keep_last_turns)
      if #older == 0 then
        do_stream()
        return
      end
      opts.compact_fn(older, opts.context, function(summary)
        if summary and summary ~= "" then
          history = { { role = "system", content = "Prior conversation summary:\n" .. summary } }
        else
          history = Context.hard_truncate(history, opts.context)
        end
        for _, m in ipairs(recent) do
          history[#history + 1] = m
        end
        do_stream()
      end)
    else
      do_stream()
    end
  end

  turn()
end

--- Cancel an in-flight run: kill the curl subprocess and finish with "cancelled".
--- The cancelled turn is not persisted (callers skip persist on cancel).
--- Returns true when a run was actually cancelled.
---@return boolean
function Session:cancel()
  if self.status ~= "running" then
    return false
  end
  if self.handle then
    self.handle.stop()
    self.handle = nil
  end
  if self._finish then
    self._finish("cancelled")
  end
  return true
end

return M
