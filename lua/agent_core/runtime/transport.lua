---@mod agent_core.runtime.transport Streaming HTTP client (owned).
---@brief [[
--- Owned streaming HTTP transport for the agent runtime. Talks to provider APIs
--- over a curl subprocess driven by vim.system, so each request streams in its
--- own OS process — the foundation for per-session concurrency (N sessions on N
--- models run in parallel because each owns an independent curl process).
---
--- No third-party runtime, no plenary. Two pieces:
---   * stream_json(opts)  — POST a JSON body and stream the response body as
---     incremental string chunks via on_data; on_exit reports (code, stderr).
---   * sse_frames(state, chunk) — pure incremental SSE frame splitter shared by
---     the OpenAI/Anthropic/Gemini providers (Ollama's NDJSON uses its own).
---@brief ]]

local M = {}

--- Resolve the curl binary, reusing agent_core.platform when present.
---@return string
local function curl_bin()
  local ok, Platform = pcall(require, "agent_core.platform")
  if ok and Platform.resolve_bin then
    return Platform.resolve_bin("curl")
  end
  return "curl"
end

--- POST a JSON body to `url` and stream the response body back as string chunks.
--- Returns a handle with `stop()` to cancel, or nil on spawn failure. When
--- `opts.on_handle` is set it is invoked with the handle as soon as it is ready
--- (before the first chunk) so callers can cancel the in-flight request.
---@param opts { url:string, method?:string, headers?:string[], body:string, timeout_ms?:number, on_data:fun(chunk:string), on_exit:fun(code:integer, stderr:string), on_handle?:fun(handle:table) }
---@return table|nil
function M.stream_json(opts)
  local method = opts.method or "POST"
  local timeout_ms = opts.timeout_ms or 120000

  local args = {
    curl_bin(),
    "-sS", -- silent except errors (goes to stderr)
    "-N", -- no buffering: stream as chunks arrive
    "-f", -- fail on HTTP >= 400 (non-zero exit; error message on stderr)
    "--max-time",
    tostring(math.max(1, math.floor(timeout_ms / 1000))),
    "-X",
    method,
    "-H",
    "Content-Type: application/json",
    "-H",
    "Accept: application/json",
  }
  for _, h in ipairs(opts.headers or {}) do
    args[#args + 1] = "-H"
    args[#args + 1] = h
  end
  args[#args + 1] = "--data-binary"
  args[#args + 1] = "@-"
  args[#args + 1] = opts.url

  local stderr_parts = {}
  local function on_stderr(_, data)
    if data and data ~= "" then
      stderr_parts[#stderr_parts + 1] = data
    end
  end

  local ok, handle = pcall(vim.system, args, {
    stdin = opts.body,
    text = true,
    stdout = function(_, data)
      if data and data ~= "" then
        -- vim.system callbacks run in a fast event context where nvim_* API
        -- calls are forbidden; defer to the main loop so providers can touch
        -- buffers (stream chunks) safely.
        vim.schedule(function()
          opts.on_data(data)
        end)
      end
    end,
    stderr = on_stderr,
  }, function(obj)
    local code = obj and obj.code or 0
    local err = table.concat(stderr_parts)
    vim.schedule(function()
      opts.on_exit(code, err)
    end)
  end)

  if not ok or not handle then
    return nil
  end
  local h = {
    stop = function()
      pcall(handle.kill, handle, 15)
    end,
  }
  if opts.on_handle then
    opts.on_handle(h)
  end
  return h
end

--- Append a chunk to an SSE parser state and extract any complete frames.
--- A frame is a run of `field: value` lines terminated by a blank line. Returns
--- the list of `{ event = <string|nil>, data = <string> }` frames (with `data:`
--- lines joined by newlines) and leaves any partial frame in `state.buf`.
---@param state { buf: string }
---@param chunk string
---@return { event:string|nil, data:string }[]
function M.sse_frames(state, chunk)
  state.buf = (state.buf or "") .. (chunk or "")
  -- Normalize line endings so \r\n\r\n and \n\n both terminate frames.
  state.buf = state.buf:gsub("\r\n", "\n")

  local frames = {}
  while true do
    local sep_start, sep_end = state.buf:find("\n\n", 1, true)
    if not sep_start then
      break
    end
    local frame_text = state.buf:sub(1, sep_start - 1)
    state.buf = state.buf:sub(sep_end + 1)

    local frame = { event = nil, data = nil }
    local data_lines = {}
    for line in (frame_text .. "\n"):gmatch("(.-)\n") do
      local key, value = line:match("^([%w%-]+):%s?(.*)$")
      if key then
        if key == "event" then
          frame.event = value
        elseif key == "data" then
          data_lines[#data_lines + 1] = value
        end
      end
    end
    if #data_lines > 0 then
      frame.data = table.concat(data_lines, "\n")
      frames[#frames + 1] = frame
    elseif frame.event ~= nil then
      -- An event-only frame (rare) still carries a signal.
      frames[#frames + 1] = frame
    end
  end
  return frames
end

return M
