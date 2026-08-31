---@mod agent_core.completion Tab parity: FIM insert + predictive edits
---@brief [[
--- Closes the biggest remaining Tab-completion gap: autocomplete that predicts
--- code (not just keywords). Three modes:
---   Ghost text       a streaming inline suggestion (extmark virt_text) fed by a
---                    local Ollama FIM model (default qwen2.5-coder), accepted
---                    with a key — the "ghost text" equivalent of Tab completion.
---   FIM insert       a blink.cmp source fed the final streamed completion.
---   Predictive edit  :AgentPredictEdit predicts the next edit with no
---                    instruction; :AgentInlineEdit rewrites a window around
---                    the caret per an explicit instruction. Both are grounded
---                    in code, LSP diagnostics, and recent edits, and rely on a
---                    checkpoint for one-command undo.
--- Cloud providers fall back to a completion prompt through the shared
--- agent_core.runner client when FIM is unavailable.
---@brief ]]

local M = {}

M.config = {
  enabled = true,
  provider = "ollama", -- completion provider: "ollama" (FIM) or a profile provider name
  fim_model = "qwen2.5-coder:7b-instruct", -- must ship an insert template (qwen2.5-coder/codellama/starcoder2/codegemma/deepseek-coder-v2, or a deepseek-coder-fim:* alias; base deepseek-coder:* does NOT support insert)
  edit_model = nil, -- predictive-edit model; nil = active profile
  edit_profile = nil, -- predictive-edit profile; nil = active profile
  ollama_endpoint = nil, -- nil = $OLLAMA_HOST or http://127.0.0.1:11434
  -- Completion backends (declared endpoints). Each entry: { name, trust,
  -- provider, model, endpoint, fim, cost, latency, quality_tier }. nil =
  -- derive from local Ollama auto-discovery plus the legacy fallback.
  backends = nil,
  max_tokens = 64,
  debounce_ms = 150,
  context_chars = 4096, -- FIM prefix/suffix budget
  edit_context_lines = 60, -- predictive-edit window size
  recent_edits = 5, -- how many recent edit snippets to feed predictive edit
  ghost_text = {
    enabled = true, -- render streaming FIM as inline ghost text (Tab)
    accept_key = "<C-l>", -- insert-mode key to accept the ghost text
  },
}

--- Ring of recent edits (per-session, in-memory).
local recent_edits = {}
local recent_max = 20

---@param endpoint string|nil
---@return string
function M.ollama_endpoint()
  if M.config.ollama_endpoint and M.config.ollama_endpoint ~= "" then
    return M.config.ollama_endpoint
  end
  return os.getenv("OLLAMA_HOST") or "http://127.0.0.1:11434"
end

--- The legacy single-backend fallback (used when no FIM backends are known).
---@return table
function M.legacy_backend()
  return {
    name = "legacy",
    roles = { "completion", "edit" },
    trust = "local",
    cost = "free",
    latency = "medium",
    fim = true,
    reasoning = false,
    quality_tier = "medium",
    provider = "ollama",
    model = M.config.fim_model,
    endpoint = M.ollama_endpoint(),
  }
end

--- All FIM-capable completion backends: declared + auto-discovered, deduplicated,
--- with the legacy fallback when nothing else is registered.
---@return table[]
function M.backends()
  local Registry = require("agent_core.registry")
  local out = {}
  local seen = {}
  for _, e in ipairs(Registry.for_role("completion")) do
    if e.fim and not seen[e.name] then
      seen[e.name] = true
      out[#out + 1] = e
    end
  end
  if #out == 0 then
    out[#out + 1] = M.legacy_backend()
  end
  return out
end

--- Candidates under a policy: FIM backends that survive the trust/hard filter,
--- ranked best-first by the policy score.
---@param pol table|nil
---@return table[]
function M.candidates(pol)
  pol = pol or require("agent_core.policy").apply()
  local out = {}
  for _, e in ipairs(M.backends()) do
    if pol.score(e) > -1e15 then
      out[#out + 1] = e
    end
  end
  table.sort(out, function(a, b)
    return pol.score(a) > pol.score(b)
  end)
  return out
end

--- Rolling measured latency per backend (name -> {sum, count}), an exponential
--- prior that the fast policy ranks on. Measured, not hinted.
local latencies = {}

--- Record a measured round-trip (ms) for a backend and stamp its rolling mean
--- onto the entry as `latency_ms` so policy scoring can rank on observed latency.
---@param backend table
---@param ms number
function M.record_latency(backend, ms)
  if not backend or not backend.name or not ms or ms <= 0 then
    return
  end
  local rec = latencies[backend.name] or { sum = 0, count = 0 }
  rec.sum = rec.sum + ms
  rec.count = rec.count + 1
  if rec.count > 20 then
    -- decay the running total to keep it responsive to drift.
    rec.sum = rec.sum * 0.8
    rec.count = rec.count * 0.8
  end
  latencies[backend.name] = rec
  backend.latency_ms = math.floor(rec.sum / rec.count)
end

--- The measured latency (ms) for a backend, or nil when never observed.
---@param backend table
---@return number|nil
function M.measured_latency(backend)
  local rec = backend and latencies[backend.name]
  if not rec or rec.count == 0 then
    return nil
  end
  return math.floor(rec.sum / rec.count)
end

--- Reachability check for a backend (curl its /api/tags with a short timeout),
--- recording the observed round-trip for latency-aware ranking.
---@param backend table
---@param cb fun(ok:boolean)
function M.check_backend(backend, cb)
  local bin = require("agent_core.platform").resolve_bin("curl")
  if bin == "curl" or bin == "" then
    cb(false)
    return
  end
  local t0 = os.clock()
  vim.system({
    bin,
    "-sS",
    "-m",
    "3",
    (backend.endpoint or M.ollama_endpoint()) .. "/api/tags",
  }, { text = true }, function(obj)
    local ms = (os.clock() - t0) * 1000
    if obj.code == 0 then
      M.record_latency(backend, ms)
      cb(true)
    else
      cb(false)
    end
  end)
end

--- Fire-and-forget keep-alive so a freshly selected backend is not cold on the
--- first keystroke.
---@param backend table
function M.warm_backend(backend)
  local bin = require("agent_core.platform").resolve_bin("curl")
  if bin == "curl" or bin == "" then
    return
  end
  local payload = vim.json.encode({
    model = backend.model or M.config.fim_model,
    prompt = "",
    stream = false,
    options = { num_predict = 1 },
  })
  vim.system({
    bin,
    "-sS",
    "-m",
    "30",
    (backend.endpoint or M.ollama_endpoint()) .. "/api/generate",
    "-H",
    "Content-Type: application/json",
    "-d",
    payload,
  }, { text = true }, function() end)
end

--- Select the best healthy backend: walk candidates in policy order, first
--- reachable wins, falling back to the legacy backend when none respond.
---@param cb fun(backend: table)
function M.select_backend(cb)
  local Policy = require("agent_core.policy")
  local cands = M.candidates(Policy.apply())
  if #cands == 0 then
    cb(M.legacy_backend())
    return
  end
  local i = 0
  local function next_check()
    i = i + 1
    local b = cands[i]
    if not b then
      cb(M.legacy_backend())
      return
    end
    M.check_backend(b, function(ok)
      if ok then
        cb(b)
      else
        next_check()
      end
    end)
  end
  next_check()
end

--- Cached backend resolution (TTL) so tab completion does not health-check on
--- every keystroke. Warms the model when the selection changes.
local selected = { backend = nil, at = 0 }
local SELECT_TTL_MS = 30000

---@param cb fun(backend: table)
function M.resolve_backend(cb)
  local now = os.clock() * 1000
  if selected.backend and (now - selected.at) < SELECT_TTL_MS then
    cb(selected.backend)
    return
  end
  M.select_backend(function(backend)
    local prev = selected.backend
    selected = { backend = backend, at = os.clock() * 1000 }
    if prev and prev.name ~= backend.name then
      M.warm_backend(backend)
    end
    cb(backend)
  end)
end

--- Effective max_tokens, trimmed under a cheap model_policy.
---@return integer
function M.effective_max_tokens()
  local Policy = require("agent_core.policy")
  local base = M.config.max_tokens or 64
  if Policy.apply().trim_loops then
    return math.max(16, math.floor(base / 2))
  end
  return base
end

--- Record a recent edit snippet (bounded ring).
---@param text string
function M.record_edit(text)
  if not text or text == "" then
    return
  end
  recent_edits[#recent_edits + 1] = text
  if #recent_edits > recent_max then
    table.remove(recent_edits, 1)
  end
end

---@return string[]
function M.get_recent_edits()
  return recent_edits
end

--- Split the current buffer into prefix (before caret) and suffix (after caret).
---@return string prefix
---@return string suffix
local function prefix_suffix()
  local row, col = require("agent_core.platform").get_caret(0)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

  local prefix = {}
  for i = 1, row do
    prefix[#prefix + 1] = lines[i]
  end
  local cur = lines[row + 1] or ""
  prefix[#prefix + 1] = cur:sub(1, col)

  local suffix = { cur:sub(col + 1) }
  for i = row + 2, #lines do
    suffix[#suffix + 1] = lines[i]
  end

  return table.concat(prefix, "\n"), table.concat(suffix, "\n")
end

--- Trim a string to the last `n` chars (keep the tail most relevant to the caret).
---@param s string
---@param n integer
---@return string
local function tail(s, n)
  if #s <= n then
    return s
  end
  return s:sub(#s - n + 1)
end

--- Trim a string to the first `n` chars.
---@param s string
---@param n integer
---@return string
local function head(s, n)
  if #s <= n then
    return s
  end
  return s:sub(1, n)
end

--- Fill-in-the-middle via Ollama /api/generate (prompt + suffix), streamed.
--- Resolves the policy-selected backend, then streams from it.
---@param prefix string
---@param suffix string
---@param cb fun(text:string|nil, err:string|nil)
---@param on_chunk fun(token:string)|nil
function M.fim(prefix, suffix, cb, on_chunk)
  M.resolve_backend(function(backend)
    M.fim_on(backend, prefix, suffix, cb, on_chunk)
  end)
end

--- Stream a FIM completion from a specific backend. Accumulates `response`
--- tokens from NDJSON lines, invoking `on_chunk(token)` as they arrive and
--- delivering the full text to `cb` on completion.
---@param backend table
---@param prefix string
---@param suffix string
---@param cb fun(text:string|nil, err:string|nil)
---@param on_chunk fun(token:string)|nil
function M.fim_on(backend, prefix, suffix, cb, on_chunk)
  local payload = vim.json.encode({
    model = backend.model or M.config.fim_model,
    prompt = prefix,
    suffix = suffix,
    stream = true,
    options = {
      num_predict = M.effective_max_tokens(),
      temperature = 0.2,
    },
  })

  local bin = require("agent_core.platform").resolve_bin("curl")
  if bin == "curl" or bin == "" then
    cb(nil, "curl not found on PATH; install curl to use completion FIM")
    return
  end

  local args = {
    bin,
    "-sS",
    "--no-buffer",
    "-m",
    "30",
    (backend.endpoint or M.ollama_endpoint()) .. "/api/generate",
    "-H",
    "Content-Type: application/json",
    "-d",
    payload,
  }

  local full = ""
  local buf = ""
  local done = false
  local t0 = os.clock()
  local function finish(text, err)
    if done then
      return
    end
    done = true
    if err == nil then
      M.record_latency(backend, (os.clock() - t0) * 1000)
    end
    cb(text, err)
  end

  -- Parse and emit complete NDJSON lines buffered in `buf`.
  local function drain()
    local pos = 1
    while true do
      local nl = buf:find("\n", pos, true)
      if not nl then
        break
      end
      local line = buf:sub(pos, nl - 1)
      pos = nl + 1
      line = line:gsub("^%s+", ""):gsub("%s+$", "")
      if line ~= "" then
        local ok, obj = pcall(vim.json.decode, line)
        if ok and type(obj) == "table" and obj.response and obj.response ~= "" then
          full = full .. obj.response
          if on_chunk then
            on_chunk(obj.response)
          end
        end
      end
    end
    buf = buf:sub(pos)
  end

  vim.system(args, {
    stdout = function(_, data)
      if data == nil then
        return -- EOF; the exit callback finalizes
      end
      buf = buf .. data
      drain()
    end,
    stderr = function() end,
  }, function(obj)
    if obj.code ~= 0 then
      finish(nil, "curl failed: " .. tostring(obj.code))
      return
    end
    drain() -- flush any final partial line
    if full == "" then
      finish(nil, "empty FIM response")
      return
    end
    finish(full, nil)
  end)
end

--- Generic completion via the active cloud profile (completion prompt fallback).
---@param prefix string
---@param cb fun(text:string|nil, err:string|nil)
function M.complete_via_cloud(prefix, cb)
  local Runner = require("agent_core.runner")
  local profile = Runner.resolve_profile(M.config.provider ~= "ollama" and M.config.provider or nil)
  if not profile then
    cb(nil, "no profile resolved for completion")
    return
  end
  local prompt = string.format(
    "Continue writing this code. Return ONLY the code that should come next, "
      .. "with no explanation or surrounding text.\n\n```\n%s",
    tail(prefix, M.config.context_chars)
  )
  Runner.llm_curl(profile, {
    system_prompt = "You are a code-completion engine. Output only the completion text, never explanations.",
    user_prompt = prompt,
  }, function(result)
    cb(result.text, result.error)
  end)
end

--- Produce one completion candidate for the current caret position.
---@param cb fun(text:string|nil, err:string|nil)
function M.complete(cb)
  if not M.config.enabled then
    cb(nil, nil)
    return
  end
  local prefix, suffix = prefix_suffix()
  prefix = tail(prefix, M.config.context_chars)
  suffix = head(suffix, M.config.context_chars)

  if M.config.provider == "ollama" then
    M.fim(prefix, suffix, cb)
  else
    M.complete_via_cloud(prefix, cb)
  end
end

--- blink.cmp source adapter.
---@return table
--- The blink.cmp source object, exposed three ways:
---   - `module = "agent_core.completion"` in blink's `providers` (the modern
---     blink.cmp 1.x API: blink calls `require(...).new(opts, config)`),
---   - `blink_source()` returning a ready source instance,
---   - top-level `get_completions` / `enabled` for the legacy module API.
local source = {
  name = "agent_core",
  kind = "completion",
  enabled = function()
    return M.config.enabled == true
  end,
  get_completions = function(_, _, on_items)
    M.complete(function(text, cerr)
      if cerr or not text or text == "" then
        on_items({ is_incomplete_forward = false, is_incomplete_backward = false, items = {} })
        return
      end
      local label = text:gsub("\n+$", "")
      if label == "" then
        on_items({ is_incomplete_forward = false, is_incomplete_backward = false, items = {} })
        return
      end
      on_items({
        is_incomplete_forward = false,
        is_incomplete_backward = false,
        items = {
          {
            label = label,
            insertText = text,
            kind = 1, -- Text
          },
        },
      })
    end)
  end,
}

-- blink.cmp 1.x source constructor. blink calls `require(module).new(opts, config)`
-- and expects a `blink.cmp.Source` back; without this the module crashes with
-- "attempt to call field 'new' (a nil value)".
function source.new(opts, config)
  return setmetatable({}, { __index = source })
end

--- blink.cmp source adapter.
---@return table
function M.blink_source()
  return source.new()
end

-- Top-level source fields so `module = "agent_core.completion"` works in
-- blink.cmp's providers config (legacy module API; the 1.x API uses `new`).
M.get_completions = source.get_completions
M.enabled = source.enabled
M.new = source.new

-- Ghost text: streaming FIM rendered as an inline virtual-text suggestion that
-- can be accepted with a key, cleared on movement, or replaced by the next one.
local ghost_ns = vim.api.nvim_create_namespace("agent_core_ghost_text")
local ghost = { buf = nil, extmark = nil, text = "" }

--- Clear any active ghost-text suggestion.
function M.ghost_clear()
  if ghost.extmark and ghost.buf and vim.api.nvim_buf_is_valid(ghost.buf) then
    pcall(vim.api.nvim_buf_del_extmark, ghost.buf, ghost_ns, ghost.extmark)
  end
  ghost = { buf = nil, extmark = nil, text = "" }
end

--- True when there is an active ghost suggestion in the current buffer.
---@return boolean
function M.ghost_active()
  return ghost.extmark ~= nil and ghost.buf == vim.api.nvim_get_current_buf() and ghost.text ~= ""
end

--- Curated capture-name -> highlight-group fallback for treesitter ghost-text
--- highlighting (used when vim.treesitter.highlighter.hl_map is unavailable).
local CAPTURE_HL = {
  keyword = "Keyword",
  conditional = "Conditional",
  ["repeat"] = "Repeat",
  label = "Label",
  ["function"] = "Function",
  method = "Function",
  constructor = "Function",
  variable = "Identifier",
  parameter = "Identifier",
  property = "Identifier",
  field = "Identifier",
  attribute = "Identifier",
  type = "Type",
  ["type.builtin"] = "Type",
  string = "String",
  number = "Number",
  boolean = "Boolean",
  constant = "Constant",
  ["constant.builtin"] = "Constant",
  comment = "Comment",
  operator = "Operator",
  punctuation = "Delimiter",
  ["punctuation.delimiter"] = "Delimiter",
  ["punctuation.bracket"] = "Delimiter",
  builtin = "Special",
}

--- Map a capture name (with or without a leading `@`) to a highlight group.
---@param hl_map table|nil
---@param name string
---@return string|nil
local function resolve_hl(hl_map, name)
  name = name:gsub("^@", "")
  if hl_map then
    if hl_map["@" .. name] then
      return hl_map["@" .. name]
    end
    if hl_map[name] then
      return hl_map[name]
    end
  end
  if CAPTURE_HL[name] then
    return CAPTURE_HL[name]
  end
  local base = name:match("^([%w_]+)")
  return CAPTURE_HL[base]
end

--- Compute syntax-highlighted virt_text chunks for the ghost text using
--- treesitter when a parser is available. `prefix` is the current line up to the
--- caret, prepended so treesitter has context; only the span after `prefix` is
--- returned. Returns nil when treesitter/parser/query are unavailable.
---@param ft string
---@param lang string
---@param hl_map table
---@param prefix string
---@param display string
---@return table|nil chunks
function M.treesitter_chunks(ft, lang, hl_map, prefix, display)
  local sbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[sbuf].filetype = ft
  local full = prefix .. display
  vim.api.nvim_buf_set_lines(sbuf, 0, -1, false, { full })

  local okp, parser = pcall(vim.treesitter.get_parser, sbuf, lang)
  if not okp or not parser then
    pcall(vim.api.nvim_buf_delete, sbuf, { force = true })
    return nil
  end
  local okq, query = pcall(vim.treesitter.query.get, lang, "highlights")
  if not okq or not query then
    pcall(vim.api.nvim_buf_delete, sbuf, { force = true })
    return nil
  end
  local okparse, trees = pcall(parser.parse, parser)
  if not okparse or not trees or not trees[1] then
    pcall(vim.api.nvim_buf_delete, sbuf, { force = true })
    return nil
  end
  local root = trees[1]:root()

  local prefix_len = #prefix
  local spans = {}
  local ok_iter, iter = pcall(query.iter_captures, query, root, sbuf, 0, 0)
  if not ok_iter or not iter then
    pcall(vim.api.nvim_buf_delete, sbuf, { force = true })
    return nil
  end
  for capture_id, node in iter do
    local name = query.captures[capture_id]
    local hl = name and resolve_hl(hl_map, name)
    if hl and node then
      local _, scol, _, ecol = node:range()
      if ecol > prefix_len and scol < #full then
        local s = math.max(scol, prefix_len)
        local e = math.min(ecol, #full)
        if e > s then
          spans[#spans + 1] = { s = s, e = e, hl = hl }
        end
      end
    end
  end
  pcall(vim.api.nvim_buf_delete, sbuf, { force = true })

  if #spans == 0 then
    return nil
  end
  table.sort(spans, function(a, b)
    if a.s == b.s then
      return a.e < b.e
    end
    return a.s < b.s
  end)

  local chunks = {}
  local cursor = prefix_len
  for _, sp in ipairs(spans) do
    if sp.s > cursor then
      local gap = full:sub(cursor + 1, sp.s)
      if gap ~= "" then
        chunks[#chunks + 1] = { gap, "Comment" }
      end
    end
    if sp.e > sp.s then
      local seg = full:sub(sp.s + 1, sp.e)
      if seg ~= "" then
        chunks[#chunks + 1] = { seg, sp.hl }
      end
    end
    cursor = math.max(cursor, sp.e)
  end
  if cursor < #full then
    local tailseg = full:sub(cursor + 1)
    if tailseg ~= "" then
      chunks[#chunks + 1] = { tailseg, "Comment" }
    end
  end
  return chunks
end

--- Compute syntax-highlighted ghost-text chunks, falling back to a single
--- dimmed Comment chunk when treesitter or a parser is unavailable.
---@param buf integer source buffer (for filetype)
---@param prefix string current line up to the caret
---@param text string ghost text
---@return {string,string}[] chunks
function M.highlight_chunks(buf, prefix, text)
  prefix = prefix or ""
  text = text or ""
  local display = text:gsub("\n", " ")
  local ok_ts, ts = pcall(require, "vim.treesitter")
  if ok_ts and ts and ts.get_parser and ts.query and ts.language and ts.language.get_lang then
    local ft = vim.bo[buf] and vim.bo[buf].filetype or ""
    local lang = ts.language.get_lang(ft)
    local ok_hl, hlmod = pcall(require, "vim.treesitter.highlighter")
    if lang and ok_hl and hlmod then
      local chunks = M.treesitter_chunks(ft, lang, hlmod.hl_map, prefix, display)
      if chunks and #chunks > 0 then
        return chunks
      end
    end
  end
  return { { display, "Comment" } }
end

--- Render accumulated ghost text as a single-line inline suggestion at the caret.
---@param text string
local function ghost_render(text)
  local buf = vim.api.nvim_get_current_buf()
  if ghost.extmark and ghost.buf == buf then
    pcall(vim.api.nvim_buf_del_extmark, buf, ghost_ns, ghost.extmark)
  else
    M.ghost_clear()
  end
  local row, col = require("agent_core.platform").get_caret(0)
  local cur_line = vim.api.nvim_get_current_line()
  local prefix = cur_line:sub(1, col)
  local chunks = M.highlight_chunks(buf, prefix, text)
  ghost.buf = buf
  ghost.text = text
  ghost.extmark = vim.api.nvim_buf_set_extmark(buf, ghost_ns, row, col, {
    virt_text = chunks,
    virt_text_pos = "overlay",
    hl_mode = "combine",
  })
end

--- Trigger a ghost-text completion at the caret (streaming FIM, or a cloud
--- completion prompt when the provider is not Ollama).
function M.ghost_text()
  if not M.config.enabled then
    return
  end
  -- Ghost text is only meaningful in editable file buffers; never run the FIM
  -- cycle (or render virtual text) inside picker/prompt/scratch buffers.
  if vim.bo[vim.api.nvim_get_current_buf()].buftype ~= "" then
    return
  end
  local ghost_cfg = M.config.ghost_text or {}
  if ghost_cfg.enabled == false then
    return
  end
  local prefix, suffix = prefix_suffix()
  prefix = tail(prefix, M.config.context_chars)
  suffix = head(suffix, M.config.context_chars)

  if M.config.provider == "ollama" then
    local acc = ""
    M.fim(prefix, suffix, function(text, err)
      if err or not text or text == "" then
        M.ghost_clear()
      end
    end, function(token)
      acc = acc .. token
      ghost_render(acc)
    end)
  else
    M.complete_via_cloud(prefix, function(text, err)
      if err or not text or text == "" then
        M.ghost_clear()
        return
      end
      ghost_render(text)
    end)
  end
end

--- Accept the current ghost text into the buffer at the caret.
function M.ghost_accept()
  if not M.ghost_active() then
    M.ghost_clear()
    return
  end
  local text = ghost.text
  M.ghost_clear()

  local row, col = require("agent_core.platform").get_caret(0)
  local cur_line = vim.api.nvim_get_current_line()
  local before = cur_line:sub(1, col)
  local after = cur_line:sub(col + 1)

  local lines = vim.split(text, "\n", { plain = true })
  lines[1] = before .. lines[1]
  lines[#lines] = lines[#lines] .. after
  vim.api.nvim_buf_set_lines(0, row, row + 1, false, lines)

  local new_row = row + #lines - 1
  local new_col = #lines[#lines] - #after
  require("agent_core.platform").set_caret(0, new_row + 1, new_col)
end

--- Collect LSP diagnostics for the current buffer as a compact string.
---@return string
local function diagnostics_summary()
  local diags = vim.diagnostic.get(0) or {}
  if #diags == 0 then
    return ""
  end
  local lines = {}
  for _, d in ipairs(diags) do
    lines[#lines + 1] = string.format("L%d: %s", d.lnum + 1, d.message or "")
  end
  return table.concat(lines, "\n")
end

--- Compute the edit window around the caret.
---@return string[] window
---@return integer start_line
---@return integer end_line
local function edit_window_lines()
  local win_lines = M.config.edit_context_lines or 60
  local row = require("agent_core.platform").get_caret(0)
  local total = vim.api.nvim_buf_line_count(0)
  local start_line = math.max(0, row - math.floor(win_lines / 2))
  local end_line = math.min(total - 1, start_line + win_lines - 1)
  start_line = math.max(0, end_line - win_lines + 1)
  local window = vim.api.nvim_buf_get_lines(0, start_line, end_line + 1, false)
  return window, start_line, end_line
end

--- Build the grounding prompt for an edit. `instruction` is nil for the
--- instruction-less predictive edit.
---@param instruction string|nil
---@param window string[]
---@return string
local function edit_prompt(instruction, window)
  local diags = diagnostics_summary()
  local prompt = {}
  if instruction and instruction ~= "" then
    prompt[#prompt + 1] = "Rewrite the code below to satisfy the instruction. Return ONLY the complete"
    prompt[#prompt + 1] = "replacement code (the same window of lines), with no code fences, no"
    prompt[#prompt + 1] = "explanation, and no line numbers. Preserve the surrounding structure."
    prompt[#prompt + 1] = ""
    prompt[#prompt + 1] = "INSTRUCTION: " .. instruction
  else
    prompt[#prompt + 1] = "Predict the next edit the developer is about to make in the code below. Return ONLY the"
    prompt[#prompt + 1] = "complete replacement code (the same window of lines), with no code fences, no"
    prompt[#prompt + 1] = "explanation, and no line numbers. Preserve the surrounding structure."
  end
  if diags ~= "" then
    prompt[#prompt + 1] = ""
    prompt[#prompt + 1] = "Current LSP diagnostics:\n" .. diags
  end
  if #recent_edits > 0 then
    prompt[#prompt + 1] = ""
    prompt[#prompt + 1] = "Recent edits (for style/context):\n" .. table.concat(recent_edits, "\n---\n")
  end
  prompt[#prompt + 1] = ""
  prompt[#prompt + 1] = "CODE WINDOW:\n```\n" .. table.concat(window, "\n") .. "\n```"
  return table.concat(prompt, "\n")
end

--- Apply an edit prediction: checkpoints, asks the edit model, previews a diff,
--- and applies the result.
---@param instruction string|nil
---@param label string checkpoint label
---@param cb fun(ok:boolean, msg:string|nil)
local function apply_edit(instruction, label, cb)
  cb = cb or function() end
  local window, start_line, end_line = edit_window_lines()
  local prompt = edit_prompt(instruction, window)

  local Runner = require("agent_core.runner")
  local profile = Runner.resolve_profile(M.config.edit_profile)
  if not profile then
    cb(false, "no profile resolved for predictive edit")
    return
  end
  local p = vim.deepcopy(profile)
  if M.config.edit_model then
    p.model = M.config.edit_model
  end

  local ok_cp, Checkpoint = pcall(require, "agent_core.checkpoint")
  if ok_cp then
    Checkpoint.create(label)
  end

  Runner.llm_curl(p, {
    system_prompt = "You are a code-edit engine. Output only replacement code, never explanations or fences.",
    user_prompt = prompt,
  }, function(result)
    if result.error or not result.text then
      cb(false, result.error or "no response")
      return
    end
    local new_lines = vim.split(result.text:gsub("^```[%w]*\n", ""):gsub("\n```$", ""), "\n")
    if #new_lines == 0 then
      cb(false, "empty edit")
      return
    end
    local Diff = require("agent_core.diff")
    Diff.present({
      label = label,
      checkpoint = false, -- apply_edit already checkpointed before the model call
      old_lines = window,
      new_lines = new_lines,
      filetype = vim.bo.filetype,
      on_apply = function(final_lines)
        vim.api.nvim_buf_set_lines(0, start_line, end_line + 1, false, final_lines)
        cb(true, "edit applied; :AgentRollback to undo")
      end,
      on_dismiss = function()
        cb(false, "edit dismissed")
      end,
    })
  end)
end

--- Inline edit: rewrite a window around the caret to
--- satisfy an explicit instruction. Checkpoints first so :AgentRollback undoes it.
---@param instruction string
---@param cb fun(ok:boolean, msg:string|nil)
function M.inline_edit(instruction, cb)
  cb = cb or function() end
  if not instruction or instruction == "" then
    cb(false, "instruction required")
    return
  end
  apply_edit(instruction, "inline-edit", cb)
end

--- Predictive edit: predict the next edit without any instruction,
--- grounded in the code, diagnostics, and recent edits. Re-run to jump to the
--- next predicted edit.
---@param cb fun(ok:boolean, msg:string|nil)
function M.predict_next_edit(cb)
  apply_edit(nil, "predictive-edit", cb)
end

--- Parse a single line number out of a model response, clamped to [1, total].
---@param text string|nil
---@param total integer
---@return integer|nil
function M.parse_line_number(text, total)
  local num = text and text:match("(%d+)")
  if not num then
    return nil
  end
  local target = tonumber(num)
  if not target then
    return nil
  end
  return math.max(1, math.min(total, target))
end

--- Predict the next edit location (line number) and jump the caret there.
--- Grounded in the current buffer, diagnostics, and recent edits — the "jump"
--- gesture after accepting a predictive edit.
---@param cb fun(ok:boolean, msg:string|nil)
function M.predict_next_location(cb)
  cb = cb or function() end
  if not M.config.enabled then
    cb(false, "completion disabled")
    return
  end
  local Runner = require("agent_core.runner")
  local profile = Runner.resolve_profile(M.config.edit_profile)
  if not profile then
    cb(false, "no profile resolved for location prediction")
    return
  end
  local p = vim.deepcopy(profile)
  if M.config.edit_model then
    p.model = M.config.edit_model
  end

  local total = vim.api.nvim_buf_line_count(0)
  local row = require("agent_core.platform").get_caret(0)
  local diags = diagnostics_summary()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

  local prompt = {
    "Predict the next line number the developer is about to edit in the file below.",
    "Return ONLY a single line number (1-based), with no explanation.",
    "Current caret line: " .. (row + 1),
    "Total lines: " .. total,
  }
  if diags ~= "" then
    prompt[#prompt + 1] = "LSP diagnostics:\n" .. diags
  end
  if #recent_edits > 0 then
    prompt[#prompt + 1] = "Recent edits (for context):\n" .. table.concat(recent_edits, "\n---\n")
  end
  prompt[#prompt + 1] = "FILE:\n```\n" .. table.concat(lines, "\n") .. "\n```"

  Runner.llm_curl(p, {
    system_prompt = "You are a code-navigation engine. Output only a single line number.",
    user_prompt = table.concat(prompt, "\n"),
  }, function(result)
    if result.error or not result.text then
      cb(false, result.error or "no response")
      return
    end
    local target = M.parse_line_number(result.text, total)
    if not target then
      cb(false, "no line number in response")
      return
    end
    require("agent_core.platform").set_caret(0, target, 0)
    cb(true, "jumped to line " .. target)
  end)
end

--- Backing for :AgentNextLocation.
function M.next_location_cmd()
  M.predict_next_location(function(ok, msg)
    vim.notify("NextLocation: " .. tostring(msg), ok and vim.log.levels.INFO or vim.log.levels.ERROR)
  end)
end

--- Backing for :AgentInlineEdit.
---@param arg string
function M.inline_edit_cmd(arg)
  local text = arg
  if not text or text == "" then
    vim.ui.input({ prompt = "Inline edit (instruction): " }, function(input)
      if input and input ~= "" then
        M.inline_edit(input, function(ok, msg)
          vim.notify("InlineEdit: " .. tostring(msg), ok and vim.log.levels.INFO or vim.log.levels.ERROR)
        end)
      end
    end)
    return
  end
  M.inline_edit(text, function(ok, msg)
    vim.notify("InlineEdit: " .. tostring(msg), ok and vim.log.levels.INFO or vim.log.levels.ERROR)
  end)
end

--- Backing for :AgentPredictEdit (instruction-less predictive edit).
function M.predict_edit_cmd()
  M.predict_next_edit(function(ok, msg)
    vim.notify("PredictEdit: " .. tostring(msg), ok and vim.log.levels.INFO or vim.log.levels.ERROR)
  end)
end

function M.setup()
  local cfg = require("agent_core").config
  M.config = vim.tbl_deep_extend("force", M.config, cfg.completion or {})

  local group = vim.api.nvim_create_augroup("AgentCoreCompletion", { clear = true })

  -- Track recent edits for predictive-edit grounding.
  vim.api.nvim_create_autocmd({ "BufWritePost", "TextChangedI" }, {
    group = group,
    callback = function()
      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      if #lines > 0 then
        M.record_edit(table.concat(lines, "\n"))
      end
    end,
  })

  -- Ghost text: clear on movement / leaving insert mode.
  local ev = require("agent_core.platform").events
  vim.api.nvim_create_autocmd({ ev.caret_moved, ev.caret_moved_i, ev.insert_leave, ev.mode_changed }, {
    group = group,
    callback = function()
      M.ghost_clear()
    end,
  })

  -- Debounced ghost-text trigger on insert-mode edits.
  local timer
  vim.api.nvim_create_autocmd("TextChangedI", {
    group = group,
    callback = function()
      if timer then
        pcall(timer.stop, timer)
        pcall(timer.close, timer)
        timer = nil
      end
      timer = vim.defer_fn(function()
        timer = nil
        M.ghost_text()
      end, M.config.debounce_ms or 150)
    end,
  })

  -- Accept key (insert mode).
  local accept_key = (M.config.ghost_text and M.config.ghost_text.accept_key) or "<C-l>"
  if accept_key ~= "" then
    vim.keymap.set("i", accept_key, function()
      if M.ghost_active() then
        M.ghost_accept()
      else
        local key = vim.api.nvim_replace_termcodes(accept_key, true, false, true)
        vim.api.nvim_feedkeys(key, "in", false)
      end
    end, { desc = "Accept agent_core ghost text" })
  end
end

return M
