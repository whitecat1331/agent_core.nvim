---@mod agent_core.runtime.providers.ollama Local Ollama provider.
---@brief [[
--- Owned implementation of the Ollama chat API (streaming, NDJSON). Ollama
--- streams newline-delimited JSON objects (not SSE `data:` frames), so this
--- provider has its own line-based frame splitter. Reuses OpenAI-compatible
--- message content conversion for the wire format.
---@brief ]]

local Transport = require("agent_core.runtime.transport")

local M = {}

--- Convert normalized content into Ollama's OpenAI-style wire content.
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

--- Build the Ollama chat request.
---@param opts { endpoint:string, model:string, system?:string, messages:table[], tools?:table[], max_tokens?:number, temperature?:number }
---@return { url:string, headers:string[], body:string }
function M.build_request(opts)
  local messages = {}
  if opts.system and opts.system ~= "" then
    messages[#messages + 1] = { role = "system", content = opts.system }
  end
  for _, m in ipairs(opts.messages or {}) do
    if m.role == "tool" then
      messages[#messages + 1] = { role = "tool", content = tostring(m.content), tool_call_id = m.tool_call_id }
    else
      local entry = { role = m.role, content = wire_content(m.content) }
      if m.tool_calls and #m.tool_calls > 0 then
        entry.tool_calls = {}
        for _, tc in ipairs(m.tool_calls) do
          entry.tool_calls[#entry.tool_calls + 1] = {
            ["function"] = { name = tc.name, arguments = tc.arguments or "{}" },
          }
        end
        entry.content = entry.content or ""
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
    body.options = { num_predict = opts.max_tokens }
  end
  if opts.temperature ~= nil then
    body.options = body.options or {}
    body.options.temperature = opts.temperature
  end
  if opts.tools and #opts.tools > 0 then
    body.tools = {}
    for _, t in ipairs(opts.tools) do
      body.tools[#body.tools + 1] = {
        type = "function",
        ["function"] = { name = t.name, description = t.description, parameters = t.parameters },
      }
    end
  end

  return {
    url = opts.endpoint .. "/api/chat",
    headers = {},
    body = vim.json.encode(body),
  }
end

--- Split a raw chunk into complete NDJSON lines, returning complete lines and
--- leaving any partial line in state.buf.
---@param state { buf: string }
---@param chunk string
---@return string[]
function M.split_lines(state, chunk)
  state.buf = (state.buf or "") .. (chunk or "")
  local lines = {}
  while true do
    local nl = state.buf:find("\n", 1, true)
    if not nl then
      break
    end
    local line = state.buf:sub(1, nl - 1)
    state.buf = state.buf:sub(nl + 1)
    line = line:gsub("\r", "")
    if line ~= "" then
      lines[#lines + 1] = line
    end
  end
  return lines
end

--- Parse one Ollama NDJSON object into `acc`.
---@param line string
---@param acc { text:string, tool_calls:table[], done:boolean }
function M.parse_delta(line, acc)
  acc = acc or { text = "", tool_calls = {}, done = false }
  local ok, json = pcall(vim.json.decode, line)
  if not ok or type(json) ~= "table" then
    return acc
  end
  local msg = json.message or {}
  if msg.content and msg.content ~= "" then
    acc.text = acc.text .. msg.content
  end
  if msg.tool_calls then
    for _, tc in ipairs(msg.tool_calls) do
      local fn = tc["function"] or {}
      acc.tool_calls[#acc.tool_calls + 1] = {
        id = fn.name or "",
        name = fn.name or "",
        arguments = vim.json.encode(fn.arguments or {}),
      }
    end
  end
  if json.done then
    acc.done = true
  end
  if json.error and json.error ~= "" then
    acc.error = tostring(json.error)
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
  local acc = { text = "", tool_calls = {}, done = false }
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
      for _, line in ipairs(M.split_lines(state, chunk)) do
        M.parse_delta(line, acc)
        if opts.on_chunk and acc.text ~= "" then
          local emitted = acc.emitted or 0
          if #acc.text > emitted then
            local delta = acc.text:sub(emitted + 1)
            acc.emitted = #acc.text
            opts.on_chunk(delta)
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
