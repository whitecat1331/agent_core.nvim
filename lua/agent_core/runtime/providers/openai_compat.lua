---@mod agent_core.runtime.providers.openai_compat OpenAI-compatible chat provider.
---@brief [[
--- Owned implementation of the OpenAI chat-completions API (streaming) for
--- DeepSeek and any OpenAI-compatible endpoint. Handles text deltas and
--- incremental tool-call argument accumulation from SSE chunks.
---
--- Normalized message content is either a plain string or an array of parts:
---   { type="text", text=... }
---   { type="image", source={ type="base64", media_type=..., data=... } }
--- (the latter mirrors agent_core.runner.build_user_content so vision prompts
--- flow through unchanged).
---@brief ]]

local Transport = require("agent_core.runtime.transport")

local M = {}

--- Convert a normalized content (string or parts array) into OpenAI wire content.
---@param content string|table
---@return string|table
local function wire_content(content)
  if type(content) == "string" then
    return content
  end
  local parts = {}
  for _, p in ipairs(content) do
    if p.type == "text" then
      parts[#parts + 1] = { type = "text", text = p.text }
    elseif p.type == "image" then
      local src = p.source or {}
      parts[#parts + 1] = {
        type = "image_url",
        image_url = { url = "data:" .. (src.media_type or "image/png") .. ";base64," .. (src.data or "") },
      }
    end
  end
  return parts
end

--- Build the chat-completions request for a normalized completion.
---@param opts { model:string, system?:string, messages:table[], tools?:table[], max_tokens?:number, temperature?:number }
---@return { url:string, headers:string[], body:string }
function M.build_request(opts)
  local messages = {}
  if opts.system and opts.system ~= "" then
    messages[#messages + 1] = { role = "system", content = opts.system }
  end
  for _, m in ipairs(opts.messages or {}) do
    if m.role == "tool" then
      -- Tool result from the agent loop.
      messages[#messages + 1] = { role = "tool", tool_call_id = m.tool_call_id, content = tostring(m.content) }
    else
      local role = m.role
      local content = wire_content(m.content)
      -- OpenAI rejects an empty assistant content when tool_calls are present;
      -- keep null content out entirely and let tool_calls ride alongside.
      local entry = { role = role, content = content }
      if m.tool_calls and #m.tool_calls > 0 then
        entry.tool_calls = {}
        for _, tc in ipairs(m.tool_calls) do
          entry.tool_calls[#entry.tool_calls + 1] = {
            id = tc.id,
            type = "function",
            ["function"] = { name = tc.name, arguments = tc.arguments or "{}" },
          }
        end
        entry.content = content or nil
      end
      messages[#messages + 1] = entry
    end
  end

  local body = {
    model = opts.model,
    messages = messages,
    stream = true,
  }
  if opts.max_tokens then
    body.max_tokens = opts.max_tokens
  end
  if opts.temperature ~= nil then
    body.temperature = opts.temperature
  end
  if opts.tools and #opts.tools > 0 then
    body.tools = {}
    for _, t in ipairs(opts.tools) do
      body.tools[#body.tools + 1] = {
        type = "function",
        ["function"] = {
          name = t.name,
          description = t.description,
          parameters = t.parameters,
        },
      }
    end
  end

  local headers = {}
  if opts.api_key and opts.api_key ~= "" then
    headers[#headers + 1] = "Authorization: Bearer " .. opts.api_key
  end
  return {
    url = opts.endpoint,
    headers = headers,
    body = vim.json.encode(body),
  }
end

--- Parse one SSE `data:` payload (JSON string) and accumulate into `acc`.
--- Handles `[DONE]`, text deltas, and incremental tool-call arguments.
---@param data string
---@param acc { text:string, tool_calls:table[], done:boolean }
function M.parse_delta(data, acc)
  acc = acc or { text = "", tool_calls = {}, done = false }
  if data == "[DONE]" then
    acc.done = true
    return acc
  end
  -- JSON `null` decodes to vim.NIL (a truthy userdata sentinel) by default.
  -- Decode with luanil so nulls become real nil and string/truthiness checks
  -- behave — DeepSeek thinking mode emits "content":null during reasoning.
  local ok, json = pcall(vim.json.decode, data, { luanil = { object = true, array = true } })
  if not ok or type(json) ~= "table" then
    return acc
  end
  local choices = json.choices or {}
  for _, choice in ipairs(choices) do
    local delta = choice.delta or {}
    if delta.content and delta.content ~= "" then
      acc.text = acc.text .. delta.content
    end
    if delta.tool_calls then
      for _, tc in ipairs(delta.tool_calls) do
        local idx = (tc.index or 0) + 1
        acc.tool_calls[idx] = acc.tool_calls[idx]
          or {
            id = tc.id or "",
            name = "",
            arguments = "",
          }
        if tc.id and tc.id ~= "" then
          acc.tool_calls[idx].id = tc.id
        end
        local fn = tc["function"] or {}
        if fn.name and fn.name ~= "" then
          acc.tool_calls[idx].name = fn.name
        end
        if fn.arguments and fn.arguments ~= "" then
          acc.tool_calls[idx].arguments = acc.tool_calls[idx].arguments .. fn.arguments
        end
      end
    end
    if choice.finish_reason then
      acc.done = true
    end
  end
  return acc
end

--- Stream a completion. Calls opts.on_chunk(text) for deltas and
--- opts.on_stop({ error=..., text=..., tool_calls=... }) once on completion.
---@param opts table
---@return boolean ok
---@return string|nil err
function M.stream(opts)
  local req = M.build_request(opts)
  local acc = { text = "", tool_calls = {}, done = false }
  local state = { buf = "" }
  local finished = false

  local function finish(res, err)
    if finished then
      return
    end
    finished = true
    if opts.on_stop then
      opts.on_stop({
        error = err,
        text = res and res.text or acc.text,
        tool_calls = res and res.tool_calls or acc.tool_calls,
      })
    end
  end

  local handle = Transport.stream_json({
    url = req.url,
    headers = req.headers,
    body = req.body,
    timeout_ms = opts.timeout_ms,
    on_handle = opts.on_handle,
    on_data = function(chunk)
      local frames = Transport.sse_frames(state, chunk)
      for _, frame in ipairs(frames) do
        if frame.data then
          M.parse_delta(frame.data, acc)
          if opts.on_chunk and acc.text ~= "" then
            local emitted = acc.emitted or 0
            if #acc.text > emitted then
              local delta = acc.text:sub(emitted + 1)
              acc.emitted = #acc.text
              opts.on_chunk(delta)
            end
          end
        end
      end
    end,
    on_exit = function(code, stderr)
      if code ~= 0 and not acc.done then
        finish(nil, stderr ~= "" and stderr or ("curl exited " .. tostring(code)))
        return
      end
      finish(nil, nil)
    end,
  })

  if not handle then
    return false, "failed to spawn curl"
  end
  return true, nil
end

return M
