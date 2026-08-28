---@mod tests.completion_spec Unit tests for the agent_core.completion router.

local h = require("tests.harness")
local Completion = require("agent_core.completion")
local Policy = require("agent_core.policy")
local core = require("agent_core")

h.describe("completion router", function()
  h.it("legacy_backend is a local FIM ollama fallback", function()
    local b = Completion.legacy_backend()
    h.equals("local", b.trust)
    h.equals(true, b.fim)
    h.equals("ollama", b.provider)
    h.equals(Completion.config.fim_model, b.model)
  end)

  h.it("effective_max_tokens trims under cheap", function()
    local saved = vim.deepcopy(core.config.policy)
    core.config.policy = { model_policy = "balanced", trust_scope = "any", caution = "act_first" }
    h.equals(Completion.config.max_tokens, Completion.effective_max_tokens())

    core.config.policy = { model_policy = "cheap", trust_scope = "any", caution = "act_first" }
    h.equals(math.floor(Completion.config.max_tokens / 2), Completion.effective_max_tokens())
    core.config.policy = saved
  end)

  h.it("candidates filters by trust scope", function()
    local saved = vim.deepcopy(core.config.completion)
    core.config.completion = {
      backends = {
        {
          name = "gpu",
          provider = "ollama",
          model = "deepseek-coder:6.7b",
          endpoint = "http://gpu:11434",
          trust = "private-remote",
          fim = true,
          quality_tier = "high",
          latency = "low",
          cost = "metered",
        },
        {
          name = "local",
          provider = "ollama",
          model = "deepseek-coder:1.3b",
          endpoint = "http://127.0.0.1:11434",
          trust = "local",
          fim = true,
          quality_tier = "low",
          latency = "medium",
          cost = "free",
        },
        {
          name = "cloud",
          provider = "openai",
          model = "gpt",
          trust = "third-party-cloud",
          fim = false,
          quality_tier = "high",
          latency = "low",
          cost = "metered",
        },
      },
    }

    -- private scope: gpu (private-remote) allowed, cloud non-fim excluded
    local priv = Completion.candidates(Policy.apply({ trust_scope = "private" }))
    local names = {}
    for _, e in ipairs(priv) do
      names[e.name] = true
    end
    h.truthy(names["gpu"], "gpu allowed under private")
    h.truthy(names["local"], "local allowed under private")
    h.falsy(names["cloud"], "cloud excluded (non-fim)")

    -- local scope: only local survives
    local loc = Completion.candidates(Policy.apply({ trust_scope = "local" }))
    h.equals(1, #loc)
    h.equals("local", loc[1].name)

    core.config.completion = saved
  end)

  h.it("parse_line_number clamps to file bounds", function()
    h.equals(42, Completion.parse_line_number("line 42", 100))
    h.equals(1, Completion.parse_line_number("0", 100))
    h.equals(100, Completion.parse_line_number("999", 100))
    h.equals(nil, Completion.parse_line_number("no number here", 100))
  end)

  h.it("select_backend fails over to the first reachable candidate", function()
    local saved_cfg = vim.deepcopy(core.config.completion)
    core.config.completion = {
      backends = {
        {
          name = "gpu",
          provider = "ollama",
          model = "deepseek-coder:6.7b",
          endpoint = "http://gpu:11434",
          trust = "private-remote",
          fim = true,
          quality_tier = "high",
          latency = "low",
          cost = "metered",
        },
        {
          name = "local",
          provider = "ollama",
          model = "deepseek-coder:1.3b",
          endpoint = "http://127.0.0.1:11434",
          trust = "local",
          fim = true,
          quality_tier = "high",
          latency = "medium",
          cost = "free",
        },
      },
    }

    -- Stub the health check: gpu down, local up.
    local saved_check = Completion.check_backend
    Completion.check_backend = function(backend, cb)
      cb(backend.name == "local")
    end

    local done = false
    Completion.select_backend(function(b)
      done = true
      h.equals("local", b.name)
    end)
    h.truthy(done, "select_backend delivered a result synchronously")

    Completion.check_backend = saved_check
    core.config.completion = saved_cfg
  end)
end)

h.describe("ghost-text highlighting", function()
  h.it("highlight_chunks reconstructs the display text", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "lua"
    local chunks = Completion.highlight_chunks(buf, "local x = ", "1 + 2")
    h.truthy(#chunks >= 1, "returns at least one chunk")
    local joined = {}
    for _, c in ipairs(chunks) do
      h.equals(2, #c)
      h.equals("string", type(c[1]))
      h.equals("string", type(c[2]))
      joined[#joined + 1] = c[1]
    end
    h.equals("1 + 2", table.concat(joined))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  h.it("highlight_chunks collapses newlines to spaces", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "lua"
    local chunks = Completion.highlight_chunks(buf, "", "line one\nline two")
    local joined = {}
    for _, c in ipairs(chunks) do
      joined[#joined + 1] = c[1]
    end
    h.equals("line one line two", table.concat(joined))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
