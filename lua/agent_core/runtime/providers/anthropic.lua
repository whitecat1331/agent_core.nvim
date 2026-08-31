---@mod agent_core.runtime.providers.anthropic Anthropic Messages API provider.
---@brief [[
--- Owned implementation of the Anthropic Messages API (streaming) for Claude.
--- Maps normalized messages/content into Anthropic's content-block format and
--- parses SSE `text_delta` / `input_json_delta` events for text and tool calls.
---@brief ]]

local Transport = require("agent_core.runtime.transport")

local M = {}

--- Convert normalized content (string or parts array) into Anthropic content blocks.
---@param content string|table
---@return table[]
local function wire_content(content)
  if type(content) == "string" then
    return { { type = "text", text = content } }
  end
  local blocks = {}
  for _, p in ipairs(content) do
    if p.type == "text" then
      blocks[#blocks + 1] = { type = "text", text = p.text }
    elseif p.type == "image" then
      local src = p.source or {}
      blocks[#blocks + 1] = {
        type = "image",
        source = {
          type = "base64",
          media_type = src.media_type or "image/png",
          data = src.data or "",
        },
      }
    end
  end
  return blocks
end

--- Build the Messages API request for a normalized completion.
---@param opts { model:string, system?:string, messages:table[], tools?:table[], max_tokens?:number }
---@return { url:string, headers:string[], body:string }
function M.build_request(opts)
  local messages = {}
  for _, m in ipairs(opts.messages or {}) do
    if m.role == "tool" then
      -- Tool result: Anthropic requires a `user` turn with a tool_result block.
      messages[#messages + 1] = {
        role = "user",
        content = {
          { type = "tool_result", tool_use_id = m.tool_call_id, content = tostring(m.content) },
        },
      }
    elseif m.role == "assistant" and m.tool_calls and #m.tool_calls > 0 then
      -- Assistant tool-use turn: emit tool_use blocks plus any text content.
      local blocks = {}
      if type(m.content) == "string" and m.content ~= "" then
        blocks[#blocks + 1] = { type = "text", text = m.content }
      elseif type(m.content) == "table" then
        for _, p in ipairs(m.content) do
          if p.type == "text" and p.text ~= "" then
            blocks[#blocks + 1] = { type = "text", text = p.text }
          elseif p.type == "image" then
            local src = p.source or {}
            blocks[#blocks + 1] = {
              type = "image",
              source = { type = "base64", media_type = src.media_type or "image/png", data = src.data or "" },
            }
          end
        end
      end
      for _, tc in ipairs(m.tool_calls) do
        local input = {}
        if tc.arguments and tc.arguments ~= "" then
          local ok, decoded = pcall(vim.json.decode, tc.arguments)
          if ok and type(decoded) == "table" then
            input = decoded
          end
        end
        blocks[#blocks + 1] = { type = "tool_use", id = tc.id, name = tc.name, input = input }
      end
      messages[#messages + 1] = { role = "assistant", content = blocks }
    else
      messages[#messages + 1] = { role = m.role, content = wire_content(m.content) }
    end
  end

  local body = {
    model = opts.model,
    messages = messages,
    max_tokens = opts.max_tokens or 4096,
    stream = true,
  }
  if opts.system and opts.system ~= "" then
    body.system = opts.system
  end
  if opts.temperature ~= nil then
    body.temperature = opts.temperature
  end
  if opts.tools and #opts.tools > 0 then
    body.tools = {}
    for _, t in ipairs(opts.tools) do
      body.tools[#body.tools + 1] = {
        name = t.name,
        description = t.description,
        input_schema = t.parameters,
      }
    end
  end

  return {
    url = opts.endpoint,
    headers = {
      "x-api-key: " .. (opts.api_key or ""),
      "anthropic-version: 2023-06-01",
    },
    body = vim.json.encode(body),
  }
end

--- Parse one Anthropic SSE `data:` payload into `acc`.
---@param data string
---@param acc { text:string, tool_calls:table[], done:boolean, blocks:table[] }
function M.parse_delta(data, acc)
  acc = acc or { text = "", tool_calls = {}, done = false, blocks = {} }
  local ok, json = pcall(vim.json.decode, data)
  if not ok or type(json) ~= "table" then
    return acc
  end

  local etype = json.type
  if etype == "content_block_start" then
    local cb = json.content_block or {}
    acc.blocks[json.index or 1] = cb
    if cb.type == "tool_use" then
      local has_input = cb.input and next(cb.input) ~= nil
      acc.tool_calls[json.index or 1] = {
        id = cb.id or "",
        name = cb.name or "",
        arguments = has_input and vim.json.encode(cb.input) or "",
      }
    end
  elseif etype == "content_block_delta" then
    local delta = json.delta or {}
    local idx = json.index or 1
    if delta.type == "text_delta" and delta.text then
      acc.text = acc.text .. delta.text
    elseif delta.type == "input_json_delta" and delta.partial_json then
      local tc = acc.tool_calls[idx]
      if not tc then
        tc = { id = "", name = "", arguments = "" }
        acc.tool_calls[idx] = tc
      end
      tc.arguments = tc.arguments .. delta.partial_json
    end
  elseif etype == "message_stop" then
    acc.done = true
  elseif etype == "error" then
    acc.error = json.error and json.error.message or "anthropic error"
    acc.done = true
  end
  return acc
end

--- Stream a completion (see openai_compat for the callback contract).
---@param opts table
---@return boolean ok
---@return string|nil err
function M.stream(opts)
  local req = M.build_request(opts)
  local acc = { text = "", tool_calls = {}, done = false, blocks = {} }
  local state = { buf = "" }
  local finished = false

  local function finish(err)
    if finished then
      return
    end
    finished = true
    if opts.on_stop then
      opts.on_stop({ error = err or acc.error, text = acc.text, tool_calls = acc.tool_calls })
    end
  end

  local handle = Transport.stream_json({
    url = req.url,
    headers = req.headers,
    body = req.body,
    timeout_ms = opts.timeout_ms,
    on_handle = opts.on_handle,
    on_data = function(chunk)
      for _, frame in ipairs(Transport.sse_frames(state, chunk)) do
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
        finish(stderr ~= "" and stderr or ("curl exited " .. tostring(code)))
        return
      end
      finish(nil)
    end,
  })

  if not handle then
    return false, "failed to spawn curl"
  end
  return true, nil
end

return M
