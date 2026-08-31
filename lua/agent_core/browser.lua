---@mod agent_core.browser Headless browser control tools
---@brief [[
--- Thin wrapper over a headless browser CLI so an agent can open a page, take a
--- screenshot, or capture readable page text. Uses Playwright (`npx playwright`)
--- when available, else a Chrome/Edge/Chromium headless dump. Tools degrade to
--- an actionable "browser unavailable" message rather than erroring. The
--- low-level runners take an explicit `bin` so they are testable with a stub CLI.
---@brief ]]

local M = {}

M.config = {
  enabled = true,
  bin = nil, -- nil = auto-detect (npx playwright, else chrome/edge/chromium)
}

--- Browser CLI candidates, in preference order.
---@return string[]
function M.candidates()
  return { "npx playwright", "msedge", "chrome", "chromium", "google-chrome", "chromium-browser" }
end

--- Resolve a browser CLI command prefix, or "" when none is available.
---@return string
function M.resolve_bin()
  if M.config.bin and M.config.bin ~= "" then
    return M.config.bin
  end
  for _, name in ipairs(M.candidates()) do
    local space = name:find(" ", 1, true)
    if space then
      local base = name:sub(1, space - 1)
      if vim.fn.exepath(base) ~= "" then
        return name
      end
    elseif vim.fn.exepath(name) ~= "" then
      return name
    end
  end
  return ""
end

--- Extract the <title> from raw HTML, or nil.
---@param html string
---@return string|nil
function M.extract_title(html)
  local title = html:match("<title[^>]*>(.-)</title>")
  if title then
    return require("agent_core.web").urldecode(title):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  end
  return nil
end

--- Dump the rendered DOM of a URL via Chrome/Edge `--dump-dom`.
---@param bin string
---@param url string
---@param cb fun(html:string|nil, err:string|nil)
function M.dump(bin, url, cb)
  local args = { bin, "--headless", "--disable-gpu", "--dump-dom", url }
  vim.system(args, { text = true }, function(obj)
    if obj.code == 0 and obj.stdout and obj.stdout ~= "" then
      cb(obj.stdout, nil)
    else
      cb(nil, "browser dump failed: " .. tostring(obj.code))
    end
  end)
end

--- Navigate to a URL and return the page title + URL, or an error.
---@param bin string
---@param url string
---@param cb fun(result:string|nil, err:string|nil)
function M.open(bin, url, cb)
  if bin:match("^npx") then
    cb(nil, "browser_open is not supported via Playwright CLI; install Chrome/Edge for page open")
    return
  end
  M.dump(bin, url, function(html, err)
    if err then
      cb(nil, err)
      return
    end
    local title = M.extract_title(html) or url
    cb("Title: " .. title .. "\nURL: " .. url, nil)
  end)
end

--- Capture a screenshot of a URL to `path`.
---@param bin string
---@param url string
---@param path string
---@param cb fun(result:string|nil, err:string|nil)
function M.screenshot(bin, url, path, cb)
  local args
  if bin:match("^npx") then
    args = { "npx", "playwright", "screenshot", "--wait-for-timeout=1500", url, path }
  else
    args = { bin, "--headless", "--disable-gpu", "--screenshot=" .. path, "--window-size=1280,800", url }
  end
  vim.system(args, { text = true }, function(obj)
    if obj.code == 0 and vim.fn.filereadable(path) == 1 then
      cb("screenshot saved to " .. path, nil)
    else
      cb(nil, "screenshot failed: " .. tostring(obj.code))
    end
  end)
end

--- Capture the readable text of a URL.
---@param bin string
---@param url string
---@param cb fun(text:string|nil, err:string|nil)
function M.snapshot(bin, url, cb)
  if bin:match("^npx") then
    cb(nil, "browser_snapshot is not supported via Playwright CLI; install Chrome/Edge for page text")
    return
  end
  M.dump(bin, url, function(html, err)
    if err then
      cb(nil, err)
      return
    end
    local text = require("agent_core.web").html_to_text(html)
    if #text > 12000 then
      text = text:sub(1, 12000) .. "\n\n[... truncated ...]"
    end
    cb(text, nil)
  end)
end

--- Shared guard: resolve the browser CLI, then hand it to `cb`.
---@param opts table
---@param cb fun(bin:string)
---@return string|nil error
local function with_bin(opts, cb)
  if M.config.enabled == false then
    return "browser tools are disabled"
  end
  local bin = M.resolve_bin()
  if bin == "" then
    return "no headless browser available (install Chrome/Edge or Playwright)"
  end
  if not opts.on_complete then
    return "on_complete not provided"
  end
  cb(bin)
  return nil
end

---@param input table
---@param opts table
---@param name string
---@param run fun(bin:string)
local function dispatch(input, opts, name, run)
  local err = with_bin(opts, function(bin)
    if opts.on_log then
      opts.on_log(name .. ": " .. tostring(input.url))
    end
    run(bin)
  end)
  if err then
    opts.on_complete(nil, err)
  end
end

---@type AgentTool
local browser_open = {
  name = "browser_open",
  description = "Open a URL in a headless browser and return the page title and final URL.",
  param = {
    type = "table",
    fields = {
      { name = "url", description = "The fully-qualified http(s) URL to open.", type = "string" },
    },
    required = { "url" },
    usage = {
      url = "The fully-qualified http(s) URL to open",
    },
  },
  returns = {
    { name = "result", description = "Page title and URL.", type = "string" },
    { name = "error", description = "Error message if the browser is unavailable.", type = "string", optional = true },
  },
}
---@type AgentToolFunc<{ url: string }>
function browser_open.func(input, opts)
  if not opts.on_complete then
    return nil, "on_complete not provided"
  end
  local url = input.url
  if not url or not url:match("^https?://") then
    opts.on_complete(nil, "only http(s) URLs are supported")
    return
  end
  dispatch(input, opts, "open", function(bin)
    M.open(bin, url, function(result, err)
      opts.on_complete(result, err)
    end)
  end)
end

---@type AgentTool
local browser_screenshot = {
  name = "browser_screenshot",
  description = "Take a screenshot of a URL in a headless browser and save it to a file.",
  param = {
    type = "table",
    fields = {
      { name = "url", description = "The fully-qualified http(s) URL to capture.", type = "string" },
      {
        name = "path",
        description = "Optional output path; defaults to <data>/agent_core/screenshots/<ts>.png.",
        type = "string",
        optional = true,
      },
    },
    required = { "url" },
    usage = {
      url = "The fully-qualified http(s) URL to capture",
      path = "Output path (optional)",
    },
  },
  returns = {
    { name = "result", description = "Where the screenshot was saved.", type = "string" },
    { name = "error", description = "Error message if the browser is unavailable.", type = "string", optional = true },
  },
}
---@type AgentToolFunc<{ url: string, path?: string }>
function browser_screenshot.func(input, opts)
  if not opts.on_complete then
    return nil, "on_complete not provided"
  end
  local url = input.url
  if not url or not url:match("^https?://") then
    opts.on_complete(nil, "only http(s) URLs are supported")
    return
  end
  local dir = vim.fn.stdpath("data") .. "/agent_core/screenshots"
  vim.fn.mkdir(dir, "p")
  local path = input.path
  if not path or path == "" then
    path = dir .. "/" .. os.date("%Y%m%d-%H%M%S") .. ".png"
  else
    path = vim.fn.expand(path)
  end
  dispatch(input, opts, "screenshot", function(bin)
    M.screenshot(bin, url, path, function(result, err)
      opts.on_complete(result, err)
    end)
  end)
end

---@type AgentTool
local browser_snapshot = {
  name = "browser_snapshot",
  description = "Capture the readable text content of a URL in a headless browser.",
  param = {
    type = "table",
    fields = {
      { name = "url", description = "The fully-qualified http(s) URL to capture.", type = "string" },
    },
    required = { "url" },
    usage = {
      url = "The fully-qualified http(s) URL to capture",
    },
  },
  returns = {
    { name = "result", description = "The readable page text.", type = "string" },
    { name = "error", description = "Error message if the browser is unavailable.", type = "string", optional = true },
  },
}
---@type AgentToolFunc<{ url: string }>
function browser_snapshot.func(input, opts)
  if not opts.on_complete then
    return nil, "on_complete not provided"
  end
  local url = input.url
  if not url or not url:match("^https?://") then
    opts.on_complete(nil, "only http(s) URLs are supported")
    return
  end
  dispatch(input, opts, "snapshot", function(bin)
    M.snapshot(bin, url, function(result, err)
      opts.on_complete(result, err)
    end)
  end)
end

function M.browser_open_tool()
  return browser_open
end
function M.browser_screenshot_tool()
  return browser_screenshot
end
function M.browser_snapshot_tool()
  return browser_snapshot
end

function M.setup()
  local cfg = require("agent_core").config
  M.config = vim.tbl_deep_extend("force", M.config, cfg.browser or {})
end

return M
