---@mod agent_core.runtime.providers.gemini Google Gemini provider.
---@brief [[
--- Owned implementation of the Gemini generateContent API (streaming, SSE via
--- alt=sse). Maps normalized content into Gemini `parts` and parses text and
--- functionCall parts from streamed candidates.
---@brief ]]

local Transport = require("agent_core.runtime.transport")

local M = {}

--- Convert normalized content (string or parts array) into Gemini parts.
---@param content string|table
---@return table[]
local function wire_content(content)
  if type(content) == "string" then
    return { { text = content } }
  end
  local parts = {}
  for _, p in ipairs(content) do
    if p.type == "text" then
      parts[#parts + 1] = { text = p.text }
    elseif p.type == "image" then
      local src = p.source or {}
      parts[#parts + 1] = {
        inlineData = {
          mimeType = src.media_type or "image/png",
          data = src.data or "",
        },
      }
    end
  end
  return parts
end

--- Build the generateContent request for a normalized completion.
---@param opts { endpoint:string, model:string, api_key:string, system?:string, messages:table[], tools?:table[], max_tokens?:number }
---@return { url:string, headers:string[], body:string }
function M.build_request(opts)
  local contents = {}
  for _, m in ipairs(opts.messages or {}) do
    if m.role == "tool" then
      -- Tool result: Gemini maps function results to a `function` role part.
      local result = m.content
      if type(result) == "string" then
        local ok, decoded = pcall(vim.json.decode, result)
        if ok and type(decoded) == "table" then
          result = decoded
        end
      end
      contents[#contents + 1] = {
        role = "tool",
        parts = { { functionResponse = { name = m.name, response = { result = result } } } },
      }
    else
      local role = m.role == "assistant" and "model" or "user"
      local parts = wire_content(m.content)
      if m.tool_calls and #m.tool_calls > 0 then
        for _, tc in ipairs(m.tool_calls) do
          local args = {}
          if tc.arguments and tc.arguments ~= "" then
            local ok, decoded = pcall(vim.json.decode, tc.arguments)
            if ok and type(decoded) == "table" then
              args = decoded
            end
          end
          parts[#parts + 1] = { functionCall = { name = tc.name, args = args } }
        end
      end
      contents[#contents + 1] = { role = role, parts = parts }
    end
  end

  local body = {
    contents = contents,
  }
  if opts.system and opts.system ~= "" then
    body.systemInstruction = { parts = { { text = opts.system } } }
  end
  if opts.max_tokens then
    body.generationConfig = { maxOutputTokens = opts.max_tokens }
  end
  if opts.tools and #opts.tools > 0 then
    body.tools = {}
    for _, t in ipairs(opts.tools) do
      body.tools[#body.tools + 1] = {
        functionDeclarations = {
          {
            name = t.name,
            description = t.description,
            parameters = t.parameters,
          },
        },
      }
    end
  end

  local model = opts.model:gsub("^models/", "")
  local url = opts.endpoint .. "/models/" .. model .. ":streamGenerateContent?alt=sse&key=" .. (opts.api_key or "")
  return {
    url = url,
    headers = {},
    body = vim.json.encode(body),
  }
end

--- Parse one Gemini SSE `data:` payload into `acc`.
---@param data string
---@param acc { text:string, tool_calls:table[], done:boolean }
function M.parse_delta(data, acc)
  acc = acc or { text = "", tool_calls = {}, done = false }
  local ok, json = pcall(vim.json.decode, data)
  if not ok or type(json) ~= "table" then
    return acc
  end
  local candidates = json.candidates or {}
  for _, cand in ipairs(candidates) do
    local parts = cand.content and cand.content.parts or {}
    for _, p in ipairs(parts) do
      if p.text and p.text ~= "" then
        acc.text = acc.text .. p.text
      elseif p.functionCall then
        acc.tool_calls[#acc.tool_calls + 1] = {
          id = p.functionCall.name or "",
          name = p.functionCall.name or "",
          arguments = vim.json.encode(p.functionCall.args or {}),
        }
      end
    end
    if cand.finishReason then
      acc.done = true
    end
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
      opts.on_stop({ error = err, text = acc.text, tool_calls = acc.tool_calls })
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
