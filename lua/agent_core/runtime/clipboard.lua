---@mod agent_core.runtime.clipboard Owned clipboard → vision-message bridge.
---@brief [[
--- Owned clipboard/image-input module: turns raw image bytes (from a file or the
--- OS clipboard) into the normalized vision-message part every provider consumes
--- (`{ type="image", source={ type="base64", media_type, data } }`). Replaces
--- the upstream clipboard bridge's paste_image path; the higher-level generate_image /
--- read_image tools in agent_core.image keep working unchanged and re-wire onto
--- this module in Phase 5.
---
--- `vision_part` / `image_part` are pure and headless-testable; `read` shells
--- out to the platform clipboard (best-effort) and is not exercised in tests.
---@brief ]]

local M = {}

M.config = {
  max_image_bytes = 10 * 1024 * 1024, -- refuse to encode images larger than this
  media_type = "image/png", -- default for clipboard data without a known type
}

--- Pure-Lua base64 encoder (RFC 4648, standard alphabet).
---@param data string raw bytes
---@return string
local function base64_encode(data)
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

--- Infer a MIME media type from a file extension (defaults to image/png).
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

--- Build the normalized vision-message part from raw image bytes.
---@param data string raw bytes
---@param media_type string|nil
---@return table part
function M.vision_part(data, media_type)
  return {
    type = "image",
    source = {
      type = "base64",
      media_type = media_type or M.config.media_type or "image/png",
      data = base64_encode(data or ""),
    },
  }
end

--- Read an image file into a vision-message part. Returns (part, err).
---@param path string
---@return table|nil part
---@return string|nil err
function M.image_part(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil, "image not readable: " .. tostring(path)
  end
  local f = io.open(path, "rb")
  if not f then
    return nil, "could not open image: " .. tostring(path)
  end
  local bytes = f:read("*a")
  f:close()
  if not bytes then
    return nil, "could not read image: " .. tostring(path)
  end
  local max = M.config.max_image_bytes or (10 * 1024 * 1024)
  if #bytes > max then
    return nil, string.format("image too large (%d bytes > %d)", #bytes, max)
  end
  return M.vision_part(bytes, M.media_type_for(path)), nil
end

--- The platform clipboard command (nil when unsupported). Returns a descriptor
--- the `read` runner understands.
---@return {cmd:string,args:string[],is_base64:boolean,media_type:string}|nil
function M.backend()
  local ok, Platform = pcall(require, "agent_core.platform")
  if ok and Platform.is_windows and Platform.is_windows() then
    return {
      cmd = "powershell",
      args = {
        "-NoProfile",
        "-Command",
        "Add-Type -AssemblyName System.Windows.Forms; "
          .. "$img = [System.Windows.Forms.Clipboard]::GetImage(); "
          .. "if ($img) { $ms = New-Object System.IO.MemoryStream; "
          .. "$img.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); "
          .. "[Convert]::ToBase64String($ms.ToArray()) }",
      },
      is_base64 = true,
      media_type = "image/png",
    }
  end
  -- macOS: pngpaste (raw PNG bytes on stdout) when available.
  if vim.fn.has("mac") == 1 then
    return {
      cmd = "pngpaste",
      args = { "-" },
      is_base64 = false,
      media_type = "image/png",
    }
  end
  -- Linux: prefer wl-paste (Wayland) then xclip (X11).
  if vim.fn.executable("wl-paste") == 1 then
    return {
      cmd = "wl-paste",
      args = { "--type", "image/png" },
      is_base64 = false,
      media_type = "image/png",
    }
  end
  if vim.fn.executable("xclip") == 1 then
    return {
      cmd = "xclip",
      args = { "-selection", "clipboard", "-t", "image/png", "-o" },
      is_base64 = false,
      media_type = "image/png",
    }
  end
  return nil
end

--- Read the clipboard image and deliver { data, media_type, err }. `data` is
--- base64 when the backend returns base64, else raw bytes.
---@param cb fun(result: { data:string|nil, media_type:string|nil, err:string|nil })
function M.read(cb)
  cb = cb or function() end
  local b = M.backend()
  if not b then
    cb({ err = "no clipboard image backend available on this platform" })
    return
  end
  vim.system({ b.cmd, unpack(b.args) }, { text = true }, function(obj)
    if obj.code ~= 0 then
      cb({ err = "clipboard read failed: " .. tostring(obj.stderr or obj.code) })
      return
    end
    local out = (obj.stdout or ""):gsub("%s+$", "")
    if out == "" then
      cb({ err = "no image on the clipboard" })
      return
    end
    if b.is_base64 then
      cb({ data = out, media_type = b.media_type })
    else
      cb({ data = base64_encode(out), media_type = b.media_type })
    end
  end)
end

return M
