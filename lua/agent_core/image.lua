---@mod agent_core.image Image generation tool (best-effort, configurable provider)
---@brief [[
--- Exposes a `generate_image` custom tool that calls a configurable
--- OpenAI-compatible images endpoint via curl, returning the generated image
--- URL(s). Configure `config.image = { endpoint, model, api_key_name }` (defaults
--- to OpenAI's DALL-E 3). Image *input* (vision) flows through the owned
--- clipboard bridge; this module only covers generation.
---@brief ]]

local M = {}

M.config = {
  endpoint = "https://api.openai.com/v1/images/generations",
  model = "dall-e-3",
  api_key_name = "OPENAI_API_KEY",
  -- Vision (image input) settings.
  vision_profile = nil, -- profile to use for image understanding; nil = auto
  vision_model = nil, -- override model for vision calls; nil = profile's model
  max_image_bytes = 10 * 1024 * 1024, -- refuse to encode images larger than this
  paste_guard = "block", -- vision paste policy: "block" | "warn" | "auto_switch" | false
}

local TIMEOUT_MS = 60000

--- Pure-Lua base64 encoder (RFC 4648, standard alphabet). Avoids relying on an
--- external `base64` binary that may be absent on Windows and keeps the encoder
--- unit-testable. Returns "" for empty input.
---@param data string raw bytes
---@return string
function M.base64_encode(data)
  data = data or ""
  if data == "" then
    return ""
  end
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local out = {}
  local i = 1
  while i <= #data do
    local b1, b2, b3 = data:byte(i, i + 2)
    b2 = b2 or 0
    b3 = b3 or 0
    local n = b1 * 65536 + b2 * 256 + b3
    out[#out + 1] = alphabet:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
    out[#out + 1] = alphabet:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
    if i + 1 <= #data then
      out[#out + 1] = alphabet:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1)
    else
      out[#out + 1] = "="
    end
    if i + 2 <= #data then
      out[#out + 1] = alphabet:sub(n % 64 + 1, n % 64 + 1)
    else
      out[#out + 1] = "="
    end
    i = i + 3
  end
  return table.concat(out)
end

--- Infer a MIME media type from a file extension.
---@param path string
---@return string media_type
function M.media_type_for(path)
  local ext = (path or ""):lower():match("%.([%w]+)$") or ""
  if ext == "png" then
    return "image/png"
  elseif ext == "jpg" or ext == "jpeg" then
    return "image/jpeg"
  elseif ext == "gif" then
    return "image/gif"
  elseif ext == "webp" then
    return "image/webp"
  end
  return "image/png"
end

--- Resolve an image path (relative to the project root) to an absolute path.
---@param path string
---@return string absolute path
function M.resolve_path(path)
  if require("agent_core.platform").is_abs(path) then
    return path
  end
  return require("agent_core.indexer").root() .. "/" .. (path or "")
end

--- Read a file's raw bytes, or nil when unreadable.
---@param path string
---@return string|nil
function M.read_bytes(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

--- Resolve a vision-capable profile: an explicit config.image.vision_profile,
--- else the first enabled registry entry tagged `vision`, else the active
--- profile (only when it is itself vision-capable). Returns nil when no
--- vision-capable model is available, so callers can fail cleanly instead of
--- sending an image to a text-only model (e.g. DeepSeek).
---@return table|nil
function M.resolve_vision_profile()
  local Runner = require("agent_core.runner")
  local profile = Runner.resolve_profile(M.config.vision_profile)
  if profile then
    return profile
  end
  local ok, Registry = pcall(require, "agent_core.registry")
  if ok and Registry.for_capability then
    for _, e in ipairs(Registry.for_capability("vision")) do
      if e.enabled ~= false then
        local p = Runner.resolve_profile(e.name)
        if p then
          return p
        end
      end
    end
  end
  local active = Runner.resolve_profile(nil)
  if active and ok and Registry.is_vision and Registry.is_vision(active.model) then
    return active
  end
  return nil
end

--- Resolve the active chat model name ("" when unknown). Best-effort so the
--- paste guard degrades to a warn rather than crashing when no profile is set.
---@return string
function M.active_model()
  local Profiles = require("agent_core.profiles")
  local name = Profiles.get_active()
  if name then
    local p = Profiles.find(name)
    if p then
      return Profiles.effective_model(p) or ""
    end
  end
  return ""
end

--- Whether the given model can accept images (vision-capable). Pure helper that
--- wraps registry.is_vision in a pcall so the guard never throws when the
--- registry is unavailable.
---@param model string|nil
---@return boolean
function M.paste_allowed(model)
  local ok, Registry = pcall(require, "agent_core.registry")
  if not ok or type(Registry) ~= "table" or not Registry.is_vision then
    return false
  end
  return Registry.is_vision(model) == true
end

--- Decide whether an interactive image paste may proceed for the given model.
--- Returns true (allow) or false (block). Emits a vim.notify for the block and
--- warn modes; "auto_switch" is handled by the caller so this stays
--- side-effect-free and unit-testable.
---@param model string|nil
---@param mode string|false|nil
---@return boolean allow
function M.guard_paste(model, mode)
  mode = mode == nil and M.config.paste_guard or mode
  if mode == false then
    return true
  end
  if M.paste_allowed(model) then
    return true
  end
  if mode == "auto_switch" then
    return true
  end
  if mode == "warn" then
    vim.notify(
      "The active model ("
        .. tostring(model or "unknown")
        .. ") cannot see images. "
        .. "The paste will be sent anyway and may be rejected by the API. Switch to a vision "
        .. "model (e.g. Gemini or Claude) to see images.",
      vim.log.levels.WARN
    )
    return true
  end
  vim.notify(
    "Image paste blocked: the active model ("
      .. tostring(model or "unknown")
      .. ") cannot see images. "
      .. 'Switch to a vision-capable profile (e.g. Gemini or Claude) or set config.image.paste_guard = "warn".',
    vim.log.levels.ERROR
  )
  return false
end

--- Read + describe an image (or answer a question about it) via a vision model.
--- Returns (description, err) through the callback.
---@param path string
---@param question string|nil
---@param cb fun(text:string|nil, err:string|nil)
function M.read_image(path, question, cb)
  cb = cb or function() end
  local abs = M.resolve_path(path)
  if vim.fn.filereadable(abs) ~= 1 then
    cb(nil, "image not readable: " .. tostring(path))
    return
  end
  local bytes = M.read_bytes(abs)
  if not bytes then
    cb(nil, "could not read image: " .. tostring(path))
    return
  end
  local max = M.config.max_image_bytes or (10 * 1024 * 1024)
  if #bytes > max then
    cb(nil, string.format("image too large (%d bytes > %d)", #bytes, max))
    return
  end

  local profile = M.resolve_vision_profile()
  if not profile then
    cb(nil, "no vision-capable profile resolved (set config.image.vision_profile or enable a vision model)")
    return
  end
  local p = vim.deepcopy(profile)
  if M.config.vision_model and M.config.vision_model ~= "" then
    p.model = M.config.vision_model
  end

  local prompt = question and question ~= "" and ("Answer the question about this image:\n" .. question)
    or "Describe this image in detail, including any visible text, UI elements, code, or diagrams."

  local Runner = require("agent_core.runner")
  Runner.llm_curl(p, {
    system_prompt = "You are a vision assistant. Describe the attached image accurately and concisely.",
    user_prompt = prompt,
    images = {
      { data = M.base64_encode(bytes), media_type = M.media_type_for(abs) },
    },
  }, function(result)
    cb(result.text, result.error)
  end)
end

--- POST a JSON payload to a URL with optional headers via curl.
---@param url string
---@param headers string[]
---@param payload string
---@param cb fun(body:string|nil, err:string|nil)
local function post_json(url, headers, payload, cb)
  local bin = require("agent_core.platform").resolve_bin("curl")
  if bin == "curl" or bin == "" then
    cb(nil, "curl not found on PATH; install curl to use image generation")
    return
  end
  local args = { bin, "-sS", "-m", "60", "-H", "Content-Type: application/json" }
  for _, h in ipairs(headers) do
    args[#args + 1] = "-H"
    args[#args + 1] = h
  end
  args[#args + 1] = "-d"
  args[#args + 1] = payload
  args[#args + 1] = url
  vim.system(args, { text = true, timeout = TIMEOUT_MS }, function(obj)
    if obj.code == 0 then
      cb(obj.stdout or "", nil)
    else
      cb(nil, (obj.stderr and obj.stderr ~= "") and obj.stderr or ("curl exited " .. tostring(obj.code)))
    end
  end)
end

---@type AgentTool
local generate_image = {
  name = "generate_image",
  description = "Generate an image from a text prompt via a configurable OpenAI-compatible images endpoint. "
    .. "Returns the generated image URL(s). Configure the endpoint/model/API key under config.image.",
  param = {
    type = "table",
    fields = {
      {
        name = "prompt",
        description = "The image prompt (a detailed description of the image to generate).",
        type = "string",
      },
      {
        name = "size",
        description = "Image size (default 1024x1024), e.g. 1024x1024, 1792x1024, 1024x1792.",
        type = "string",
        optional = true,
      },
      {
        name = "n",
        description = "Number of images to generate (default 1).",
        type = "integer",
        optional = true,
      },
    },
    required = { "prompt" },
    usage = {
      prompt = "The image prompt",
      size = "Image size",
      n = "Number of images",
    },
  },
  returns = {
    {
      name = "images",
      description = "Newline-separated image URLs (or base64 size notes)",
      type = "string",
    },
    {
      name = "error",
      description = "Error message if generation failed",
      type = "string",
      optional = true,
    },
  },
}

---@type AgentToolFunc<{ prompt: string, size?: string, n?: integer }>
function generate_image.func(input, opts)
  if not opts.on_complete then
    return nil, "on_complete not provided"
  end
  local prompt = input.prompt
  if not prompt or prompt == "" then
    return nil, "prompt is required"
  end
  local size = input.size or "1024x1024"
  local n = tonumber(input.n) or 1

  local key = os.getenv(M.config.api_key_name)
  if not key or key == "" then
    opts.on_complete(nil, "no API key; set " .. M.config.api_key_name .. " (or configure config.image.api_key_name)")
    return
  end

  local payload = vim.fn.json_encode({
    model = M.config.model,
    prompt = prompt,
    size = size,
    n = n,
  })
  if opts.on_log then
    opts.on_log("generate_image: " .. prompt)
  end
  post_json(M.config.endpoint, { "Authorization: Bearer " .. key }, payload, function(body, err)
    if err then
      opts.on_complete(nil, err)
      return
    end
    local ok, data = pcall(vim.json.decode, body or "")
    if not ok or type(data) ~= "table" then
      opts.on_complete(nil, "invalid image response")
      return
    end
    local items = data.data or {}
    if #items == 0 then
      opts.on_complete(nil, "no images returned")
      return
    end
    local lines = {}
    for i, it in ipairs(items) do
      if it.url then
        lines[#lines + 1] = string.format("%d. %s", i, it.url)
      elseif it.b64_json then
        lines[#lines + 1] = string.format("%d. (base64 image, %d chars)", i, #it.b64_json)
      end
    end
    opts.on_complete(table.concat(lines, "\n"), nil)
  end)
end

--- Return the generate_image custom tool for wiring into the owned runtime's tool registry.
function M.generate_image_tool()
  return generate_image
end

---@type AgentTool
local read_image = {
  name = "read_image",
  description = "Read an image file (screenshot, diagram, photo, or UI mock) and describe it, "
    .. "or answer a specific question about it. Uses a vision-capable model. Configure the model "
    .. "under config.image (vision_profile / vision_model).",
  param = {
    type = "table",
    fields = {
      {
        name = "path",
        description = "Path to the image file (relative to the project root or absolute).",
        type = "string",
      },
      {
        name = "question",
        description = "Optional question to answer about the image (e.g. 'what does this error say?').",
        type = "string",
        optional = true,
      },
    },
    required = { "path" },
    usage = {
      path = "Image file path",
      question = "Question about the image (optional)",
    },
  },
  returns = {
    {
      name = "description",
      description = "The model's description/answer about the image.",
      type = "string",
    },
    {
      name = "error",
      description = "Error message if reading/describing failed.",
      type = "string",
      optional = true,
    },
  },
}

---@type AgentToolFunc<{ path: string, question?: string }>
function read_image.func(input, opts)
  if not opts.on_complete then
    return nil, "on_complete not provided"
  end
  local path = input.path
  if not path or path == "" then
    opts.on_complete(nil, "path is required")
    return
  end
  if opts.on_log then
    opts.on_log("read_image: " .. path)
  end
  M.read_image(path, input.question, function(text, err)
    opts.on_complete(text, err)
  end)
end

--- Return the read_image (vision input) custom tool.
function M.read_image_tool()
  return read_image
end

function M.setup()
  local cfg = require("agent_core").config
  M.config = vim.tbl_deep_extend("force", M.config, cfg.image or {})
end

return M
