---@mod agent_core.runtime.context Context editing + compaction (owned).
---@brief [[
--- Owned context management for long conversations: a cheap token estimator, a
--- two-threshold compaction policy (a soft threshold that triggers a summary via
--- a cheaper compaction model, and a hard threshold that force-truncates the
--- oldest messages), plus message-list editing (drop / replace / truncate).
---
--- Borrowed from CodeCompanion's compaction model: the compaction summary is
--- produced by a *separate, cheaper* model (config `context.compaction_provider`
--- / `compaction_model`), never the primary agent model. All decision functions
--- are pure and headless-testable; the only impure part is the async summary
--- call, which callers provide as an injectable function.
---@brief ]]

local M = {}

--- Default compaction config. Soft threshold triggers a summary; hard threshold
--- force-drops the oldest messages regardless of summary availability.
M.defaults = {
  soft_threshold = 16000, -- tokens
  hard_threshold = 32000, -- tokens
  tokens_per_char = 0.25, -- rough chars -> tokens heuristic
  keep_last_turns = 2, -- recent user/assistant turns always kept intact
  compaction_provider = nil, -- cheaper model for the summary (nil = primary)
  compaction_model = nil,
  compaction_system = "You are a conversation summarizer. Produce a concise, factual summary.",
  compaction_prompt = "Summarize the conversation below, preserving key decisions, facts, file paths, and any unresolved items. Be concise.",
}

--- Rough token count for an arbitrary string. Tokens ~= ceil(len * tokens_per_char).
---@param text string|nil
---@param tokens_per_char number|nil
---@return integer
function M.estimate_text(text, tokens_per_char)
  text = text or ""
  local ratio = tokens_per_char or M.defaults.tokens_per_char
  if ratio <= 0 then
    return 0
  end
  return math.ceil(#text * ratio)
end

--- Serialize a message into a single string for estimation.
---@param msg table
---@return string
local function message_text(msg)
  if type(msg) == "string" then
    return msg
  end
  if type(msg) ~= "table" then
    return ""
  end
  local parts = {}
  local content = msg.content
  if type(content) == "string" then
    parts[#parts + 1] = content
  elseif type(content) == "table" then
    for _, part in ipairs(content) do
      if type(part) == "table" and type(part.text) == "string" then
        parts[#parts + 1] = part.text
      end
    end
  end
  if type(msg.tool_calls) == "table" then
    for _, tc in ipairs(msg.tool_calls) do
      parts[#parts + 1] = tostring(tc.name or "")
      parts[#parts + 1] = tostring(tc.arguments or "")
    end
  end
  if msg.name then
    parts[#parts + 1] = tostring(msg.name)
  end
  return table.concat(parts, "\n")
end

--- Estimate the token count of a single message (content + fixed role overhead).
---@param msg table
---@param tokens_per_char number|nil
---@return integer
function M.estimate_message(msg, tokens_per_char)
  return M.estimate_text(message_text(msg), tokens_per_char) + 4
end

--- Estimate the total tokens of a message list.
---@param messages table[]
---@param tokens_per_char number|nil
---@return integer
function M.total_tokens(messages, tokens_per_char)
  local total = 0
  for _, msg in ipairs(messages or {}) do
    total = total + M.estimate_message(msg, tokens_per_char)
  end
  return total
end

--- Classify whether a message list needs compaction under a config.
--- Returns "hard" (force-truncate), "soft" (summarize), or nil (no action).
---@param messages table[]
---@param cfg table|nil
---@return string|nil
function M.should_compact(messages, cfg)
  cfg = cfg and vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), cfg) or M.defaults
  local tokens = M.total_tokens(messages, cfg.tokens_per_char)
  if cfg.hard_threshold and tokens > cfg.hard_threshold then
    return "hard"
  end
  if cfg.soft_threshold and tokens > cfg.soft_threshold then
    return "soft"
  end
  return nil
end

--- Split a message list into { older = ..., recent = ... } keeping the last N
--- user turns intact (a "turn" starts at a user message and extends through the
--- following assistant/tool messages until the next user message).
---@param messages table[]
---@param keep_last_turns integer|nil
---@return table older
---@return table recent
function M.keep_recent(messages, keep_last_turns)
  local n = keep_last_turns or M.defaults.keep_last_turns
  local older, recent = {}, {}
  if n <= 0 then
    for _, m in ipairs(messages or {}) do
      recent[#recent + 1] = m
    end
    return older, recent
  end

  local user_indices = {}
  for i, msg in ipairs(messages or {}) do
    if msg.role == "user" then
      user_indices[#user_indices + 1] = i
    end
  end

  local split = 0
  if #user_indices >= n then
    split = user_indices[#user_indices - n + 1] - 1
  end
  for j = 1, split do
    older[#older + 1] = messages[j]
  end
  for j = split + 1, #messages do
    recent[#recent + 1] = messages[j]
  end
  return older, recent
end

--- Hard-truncate a message list to fit under the hard threshold: drop the oldest
--- non-system messages until the estimate is under `hard_threshold` (or only the
--- recent turns remain). System messages are preserved at the front.
---@param messages table[]
---@param cfg table|nil
---@return table[]
function M.hard_truncate(messages, cfg)
  cfg = cfg and vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), cfg) or M.defaults
  local out = vim.deepcopy(messages or {})
  while M.total_tokens(out, cfg.tokens_per_char) > (cfg.hard_threshold or M.defaults.hard_threshold) do
    -- Find the first non-system message to drop.
    local idx = nil
    for i, msg in ipairs(out) do
      if msg.role ~= "system" then
        idx = i
        break
      end
    end
    if not idx or #out <= 1 then
      break
    end
    table.remove(out, idx)
  end
  return out
end

--- Build the request the cheaper compaction model should answer.
---@param messages table[]
---@param cfg table|nil
---@return { system:string, prompt:string, provider:string|nil, model:string|nil }
function M.build_compaction_request(messages, cfg)
  cfg = cfg and vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), cfg) or M.defaults
  local older, _ = M.keep_recent(messages, cfg.keep_last_turns)
  local lines = {}
  for _, msg in ipairs(older) do
    local role = msg.role or "unknown"
    local body = message_text(msg)
    if body ~= "" then
      lines[#lines + 1] = role .. ": " .. body
    end
  end
  return {
    system = cfg.compaction_system,
    prompt = cfg.compaction_prompt .. "\n\n" .. table.concat(lines, "\n\n"),
    provider = cfg.compaction_provider,
    model = cfg.compaction_model,
  }
end

--- Apply an edit operation to a message list. Edits are { index?, find?, op }:
---   { index = i, op = "drop" }                 remove message i
---   { index = i, op = "truncate", max_chars }  truncate message i's content
---   { find = {role="assistant"}, op = "drop", first = true }  drop first match
--- Returns a NEW list (input is not mutated).
---@param messages table[]
---@param edits table[]
---@return table[]
function M.edit(messages, edits)
  local out = vim.deepcopy(messages or {})
  for _, e in ipairs(edits or {}) do
    local idx = e.index
    if idx == nil and e.find then
      for j, msg in ipairs(out) do
        local match = true
        for k, v in pairs(e.find) do
          if msg[k] ~= v then
            match = false
            break
          end
        end
        if match then
          idx = j
          break
        end
      end
    end
    if idx and out[idx] then
      if e.op == "drop" then
        table.remove(out, idx)
      elseif e.op == "truncate" then
        local max = e.max_chars or 1000
        local content = out[idx].content
        if type(content) == "string" and #content > max then
          local copy = vim.deepcopy(out[idx])
          copy.content = content:sub(1, max)
          out[idx] = copy
        end
      end
    end
  end
  return out
end

return M
