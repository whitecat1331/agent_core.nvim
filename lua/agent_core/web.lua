---@mod agent_core.web Read-only web access tools (web_fetch, web_search)
---@brief [[
--- Exposes two read-only custom tools: `web_fetch` (retrieve a URL and
--- return readable plain text) and `web_search` (best-effort DuckDuckGo HTML
--- search returning titles, URLs, and snippets). Both are network read-only, so
--- they are safe to auto-approve in full modes. They run through `curl` and are
--- wired into the owned runtime's tool registry.
---@brief ]]

local M = {}

local USER_AGENT = "Mozilla/5.0 (compatible; agent_core.nvim/1.0)"
local MAX_BODY_CHARS = 12000
local MAX_RESULTS = 8
local TIMEOUT_MS = 20000

--- Percent-encode a query string for a URL (no external deps).
---@param s string
---@return string
function M.urlencode(s)
  s = s:gsub("\n", " ")
  s = s:gsub("([^%w%-_%.%~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  return s
end

--- Decode %xx sequences and common HTML entities in a URL.
---@param s string
---@return string
function M.urldecode(s)
  s = s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end)
  s = s:gsub("&amp;", "&")
  s = s:gsub("&lt;", "<")
  s = s:gsub("&gt;", ">")
  s = s:gsub("&quot;", '"')
  s = s:gsub("&#39;", "'")
  return s
end

--- Convert raw HTML to readable plain text (best-effort, no external deps).
---@param html string
---@return string
function M.html_to_text(html)
  local text = html
  text = text:gsub("<!%-%-.-%-%->", " ")
  text = text:gsub("<script[^>]*>.-</script>", " ")
  text = text:gsub("<style[^>]*>.-</style>", " ")
  text = text:gsub("<[^>]+>", " ")
  text = M.urldecode(text)
  text = text:gsub("%s+", " ")
  return text
end

--- Run curl against the given args and return stdout/err via cb. Resolves the
--- binary, enforces a user agent and a hard timeout, and runs asynchronously so
--- the tool never blocks the UI.
---@param args string[]
---@param cb fun(body: string|nil, err: string|nil)
local function curl(args, cb)
  local bin = vim.fn.exepath("curl")
  if bin == "" then
    cb(nil, "curl not found on PATH; install curl to use web tools")
    return
  end
  local full = { bin, "-sSL", "--max-time", "20", "-A", USER_AGENT }
  for _, a in ipairs(args) do
    full[#full + 1] = a
  end
  vim.system(full, { text = true, timeout = TIMEOUT_MS }, function(obj)
    if obj.code == 0 then
      cb(obj.stdout or "", nil)
    else
      local err = (obj.stderr and obj.stderr ~= "") and obj.stderr or ("curl exited " .. tostring(obj.code))
      cb(nil, err)
    end
  end)
end

---@type AgentTool
local web_fetch = {
  name = "web_fetch",
  description = "Fetch the content of a web URL and return it as readable plain text. "
    .. "Use this to read documentation, web pages, or plain-text API responses. "
    .. "Only http(s) URLs are supported.",
  param = {
    type = "table",
    fields = {
      {
        name = "url",
        description = "The fully-qualified http(s) URL to fetch.",
        type = "string",
      },
    },
    required = { "url" },
    usage = {
      url = "The fully-qualified http(s) URL to fetch",
    },
  },
  returns = {
    {
      name = "content",
      description = "The readable text content of the page",
      type = "string",
    },
    {
      name = "error",
      description = "Error message if the fetch failed",
      type = "string",
      optional = true,
    },
  },
}

---@type AgentToolFunc<{ url: string }>
function web_fetch.func(input, opts)
  if not opts.on_complete then
    return nil, "on_complete not provided"
  end
  local url = input.url
  if not url or url == "" then
    return nil, "url is required"
  end
  if not url:match("^https?://") then
    return nil, "only http(s) URLs are supported"
  end
  if opts.on_log then
    opts.on_log("fetch: " .. url)
  end
  curl({ url }, function(body, err)
    if err then
      opts.on_complete(nil, err)
      return
    end
    local text = M.html_to_text(body)
    if #text > MAX_BODY_CHARS then
      text = text:sub(1, MAX_BODY_CHARS) .. "\n\n[... truncated ...]"
    end
    opts.on_complete(text, nil)
  end)
end

--- Parse DuckDuckGo HTML results into {title,url,snippet} entries.
---@param html string
---@param max integer
---@return {title:string,url:string,snippet:string}[]
function M.parse_ddg(html, max)
  local results = {}
  for href, title in html:gmatch('<a rel="nofollow" class="result__a" href="([^"]+)"[^>]*>(.-)</a>') do
    local target = href:match("uddg=([^&]+)") or href
    target = M.urldecode(target)
    if target:match("^https?://") then
      results[#results + 1] = { title = M.html_to_text(title), url = target, snippet = "" }
      if #results >= max then
        break
      end
    end
  end

  local snippets = {}
  for s in html:gmatch('<a class="result__snippet"[^>]*>(.-)</a>') do
    snippets[#snippets + 1] = M.html_to_text(s)
  end
  for i, r in ipairs(results) do
    r.snippet = snippets[i] or ""
  end
  return results
end

---@type AgentTool
local web_search = {
  name = "web_search",
  description = "Search the web (via DuckDuckGo) and return a list of result titles, URLs, "
    .. "and short snippets. Best-effort: results may be rate-limited or blocked. "
    .. "Use web_fetch on a specific result URL to read the full page.",
  param = {
    type = "table",
    fields = {
      {
        name = "query",
        description = "The search query.",
        type = "string",
      },
      {
        name = "max_results",
        description = "Maximum number of results to return (default 8, max 20).",
        type = "integer",
        optional = true,
      },
    },
    required = { "query" },
    usage = {
      query = "The search query",
      max_results = "Maximum number of results to return",
    },
  },
  returns = {
    {
      name = "results",
      description = "Markdown list of result titles, URLs, and snippets",
      type = "string",
    },
    {
      name = "error",
      description = "Error message if the search failed",
      type = "string",
      optional = true,
    },
  },
}

---@type AgentToolFunc<{ query: string, max_results?: integer }>
function web_search.func(input, opts)
  if not opts.on_complete then
    return nil, "on_complete not provided"
  end
  local query = input.query
  if not query or query == "" then
    return nil, "query is required"
  end
  local max = tonumber(input.max_results) or MAX_RESULTS
  if max > 20 then
    max = 20
  end

  local url = "https://html.duckduckgo.com/html/?q=" .. M.urlencode(query)
  if opts.on_log then
    opts.on_log("search: " .. query)
  end
  curl({ url }, function(body, err)
    if err then
      opts.on_complete(nil, err)
      return
    end
    local results = M.parse_ddg(body, max)
    if #results == 0 then
      opts.on_complete(
        "No parseable results returned (the search engine may have rate-limited the request). "
          .. "Try rephrasing the query, or use web_fetch on a known search URL.",
        nil
      )
      return
    end
    local lines = {}
    for i, r in ipairs(results) do
      lines[#lines + 1] = string.format("%d. %s\n   %s", i, r.title, r.url)
      if r.snippet and r.snippet ~= "" then
        lines[#lines + 1] = "   " .. r.snippet
      end
    end
    opts.on_complete(table.concat(lines, "\n"), nil)
  end)
end

--- Return the web_fetch custom tool for wiring into the owned runtime's tool registry.
function M.web_fetch_tool()
  return web_fetch
end

--- Return the web_search custom tool for wiring into the owned runtime's tool registry.
function M.web_search_tool()
  return web_search
end

return M
