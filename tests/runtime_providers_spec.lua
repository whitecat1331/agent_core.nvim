---@mod tests.runtime_providers_spec Unit tests for the owned runtime providers.

local h = require("tests.harness")
local Transport = require("agent_core.runtime.transport")
local Schema = require("agent_core.runtime.schema")
local Providers = require("agent_core.runtime.providers")
local OpenAI = require("agent_core.runtime.providers.openai_compat")
local Anthropic = require("agent_core.runtime.providers.anthropic")
local Gemini = require("agent_core.runtime.providers.gemini")
local Ollama = require("agent_core.runtime.providers.ollama")

h.describe("runtime.transport sse_frames", function()
  h.it("splits complete frames and retains partial buffers", function()
    local state = { buf = "" }
    local frames = Transport.sse_frames(state, 'data: {"a":1}\n\ndata: {"b":')
    h.equals(1, #frames)
    h.equals('{"a":1}', frames[1].data)
    h.equals(nil, frames[1].event)
    h.equals('data: {"b":', state.buf)
  end)

  h.it("parses event and data fields", function()
    local state = { buf = "" }
    local frames = Transport.sse_frames(state, 'event: content_block_delta\ndata: {"t":1}\n\n')
    h.equals(1, #frames)
    h.equals("content_block_delta", frames[1].event)
    h.equals('{"t":1}', frames[1].data)
  end)

  h.it("joins multiple data lines", function()
    local state = { buf = "" }
    local frames = Transport.sse_frames(state, "data: line1\ndata: line2\n\n")
    h.equals(1, #frames)
    h.equals("line1\nline2", frames[1].data)
  end)

  h.it("normalizes CRLF line endings", function()
    local state = { buf = "" }
    local frames = Transport.sse_frames(state, 'data: {"x":1}\r\n\r\n')
    h.equals(1, #frames)
    h.equals('{"x":1}', frames[1].data)
  end)
end)

h.describe("runtime.schema", function()
  h.it("normalizes a simple tool", function()
    local tool = {
      name = "run_command",
      description = "run a command",
      param = {
        type = "table",
        fields = {
          { name = "name", description = "command name", type = "string" },
        },
        required = { "name" },
      },
    }
    local out = Schema.normalize_tool(tool)
    h.equals("run_command", out.name)
    h.equals("object", out.parameters.type)
    h.equals("string", out.parameters.properties.name.type)
    h.equals(1, #out.parameters.required)
    h.equals("name", out.parameters.required[1])
  end)

  h.it("maps array and integer types", function()
    local out = Schema.normalize_tool({
      name = "t",
      description = "d",
      param = {
        type = "table",
        fields = {
          { name = "items", type = "string[]" },
          { name = "count", type = "integer" },
          { name = "flag", type = "boolean" },
        },
      },
    })
    h.equals("array", out.parameters.properties.items.type)
    h.equals("string", out.parameters.properties.items.items.type)
    h.equals("integer", out.parameters.properties.count.type)
    h.equals("boolean", out.parameters.properties.flag.type)
  end)

  h.it("normalizes a tool with no param to empty object schema", function()
    local out = Schema.normalize_tool({ name = "t", description = "d" })
    h.equals("object", out.parameters.type)
  end)

  h.it("encodes empty properties as a JSON object, not an array", function()
    local out = Schema.normalize_tool({
      name = "debug_restart",
      description = "restart",
      param = { type = "table", fields = {}, usage = {} },
    })
    local json = vim.json.encode(out.parameters)
    h.matches('"properties":%s*{}', json, "empty properties encodes as {}")
    h.falsy(json:find('"properties":%s*%[', 1), "empty properties must not encode as []")
  end)
end)

h.describe("runtime.providers registry", function()
  h.it("resolves deepseek and claude modules", function()
    h.truthy(Providers.get("deepseek"))
    h.truthy(Providers.get("claude"))
    h.truthy(Providers.get("gemini"))
    h.truthy(Providers.get("ollama"))
  end)

  h.it("returns nil for unknown provider", function()
    local p, m = Providers.get("nope")
    h.falsy(p)
    h.equals(nil, m)
  end)

  h.it("merges defaults into opts", function()
    local opts = Providers.with_defaults({ provider = "deepseek", model = "deepseek-chat" })
    h.equals("https://api.deepseek.com/v1/chat/completions", opts.endpoint)
    h.equals("DEEPSEEK_API_KEY", opts.api_key_name)
  end)

  h.it("does not override explicit endpoint", function()
    local opts = Providers.with_defaults({ provider = "deepseek", endpoint = "http://local" })
    h.equals("http://local", opts.endpoint)
  end)
end)

h.describe("runtime.providers.openai_compat", function()
  h.it("builds a chat-completions request with system and messages", function()
    local req = OpenAI.build_request({
      endpoint = "https://api.deepseek.com/v1/chat/completions",
      model = "deepseek-chat",
      api_key = "k",
      system = "you are helpful",
      messages = { { role = "user", content = "hi" } },
    })
    h.equals("https://api.deepseek.com/v1/chat/completions", req.url)
    h.contains(req.headers, "Authorization: Bearer k")
    local body = vim.json.decode(req.body)
    h.equals("deepseek-chat", body.model)
    h.equals("system", body.messages[1].role)
    h.equals("user", body.messages[2].role)
    h.equals(true, body.stream)
  end)

  h.it("converts image parts to data URLs", function()
    local req = OpenAI.build_request({
      endpoint = "https://x/v1",
      model = "m",
      messages = {
        {
          role = "user",
          content = {
            { type = "text", text = "what is this" },
            { type = "image", source = { media_type = "image/png", data = "AAAA" } },
          },
        },
      },
    })
    local body = vim.json.decode(req.body)
    local content = body.messages[1].content
    h.equals("table", type(content))
    h.equals("text", content[1].type)
    h.equals("image_url", content[2].type)
    h.matches("data:image/png;base64,AAAA", content[2].image_url.url)
  end)

  h.it("parses text delta and tool-call accumulation", function()
    local acc = { text = "", tool_calls = {}, done = false }
    OpenAI.parse_delta('{"choices":[{"delta":{"content":"Hel"}}]}', acc)
    OpenAI.parse_delta('{"choices":[{"delta":{"content":"lo"}}]}', acc)
    OpenAI.parse_delta(
      '{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"bash","arguments":"{\\"cmd\\":"}}]}}]}',
      acc
    )
    OpenAI.parse_delta(
      '{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"ls\\"}"}}]},"finish_reason":"tool_calls"}]}',
      acc
    )
    h.equals("Hello", acc.text)
    h.equals(true, acc.done)
    h.equals("bash", acc.tool_calls[1].name)
    h.equals('{"cmd":"ls"}', acc.tool_calls[1].arguments)
  end)

  h.it("handles [DONE] sentinel", function()
    local acc = { text = "", tool_calls = {}, done = false }
    OpenAI.parse_delta("[DONE]", acc)
    h.equals(true, acc.done)
  end)
end)

h.describe("runtime.providers.anthropic", function()
  h.it("builds a messages request with tool_use blocks", function()
    local req = Anthropic.build_request({
      endpoint = "https://api.anthropic.com/v1/messages",
      model = "claude-sonnet-4-5",
      api_key = "k",
      system = "sys",
      messages = {
        { role = "assistant", tool_calls = { { id = "t1", name = "bash", arguments = '{"cmd":"ls"}' } }, content = "" },
      },
      tools = { { name = "bash", description = "run", parameters = { type = "object" } } },
    })
    h.contains(req.headers, "x-api-key: k")
    h.contains(req.headers, "anthropic-version: 2023-06-01")
    local body = vim.json.decode(req.body)
    h.equals("sys", body.system)
    h.equals("tool_use", body.messages[1].content[1].type)
    h.equals("bash", body.messages[1].content[1].name)
    h.equals("bash", body.tools[1].name)
  end)

  h.it("parses text_delta and input_json_delta", function()
    local acc = { text = "", tool_calls = {}, done = false, blocks = {} }
    Anthropic.parse_delta('{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}', acc)
    Anthropic.parse_delta('{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}', acc)
    Anthropic.parse_delta(
      '{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t1","name":"bash","input":{}}}',
      acc
    )
    Anthropic.parse_delta(
      '{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"cmd\\":\\"ls\\"}"}}',
      acc
    )
    Anthropic.parse_delta('{"type":"message_stop"}', acc)
    h.equals("Hi", acc.text)
    h.equals("bash", acc.tool_calls[1].name)
    h.equals('{"cmd":"ls"}', acc.tool_calls[1].arguments)
    h.equals(true, acc.done)
  end)
end)

h.describe("runtime.providers.gemini", function()
  h.it("builds a generateContent request", function()
    local req = Gemini.build_request({
      endpoint = "https://generativelanguage.googleapis.com/v1beta",
      model = "gemini-2.0-flash",
      api_key = "k",
      system = "sys",
      messages = { { role = "user", content = "hi" } },
    })
    h.matches("streamGenerateContent%?alt=sse&key=k", req.url)
    local body = vim.json.decode(req.body)
    h.equals("user", body.contents[1].role)
    h.equals("hi", body.contents[1].parts[1].text)
    h.equals("sys", body.systemInstruction.parts[1].text)
  end)

  h.it("strips models/ prefix from the model id", function()
    local req = Gemini.build_request({
      endpoint = "https://generativelanguage.googleapis.com/v1beta",
      model = "models/gemini-2.0-flash",
      api_key = "k",
      messages = {},
    })
    h.matches("/models/gemini%-2.0%-flash:", req.url)
  end)

  h.it("parses text and functionCall parts", function()
    local acc = { text = "", tool_calls = {}, done = false }
    Gemini.parse_delta('{"candidates":[{"content":{"parts":[{"text":"Hi"}]},"finishReason":null}]}', acc)
    Gemini.parse_delta(
      '{"candidates":[{"content":{"parts":[{"functionCall":{"name":"bash","args":{"cmd":"ls"}}}]},"finishReason":"STOP"}]}',
      acc
    )
    h.equals("Hi", acc.text)
    h.equals("bash", acc.tool_calls[1].name)
    h.equals('{"cmd":"ls"}', acc.tool_calls[1].arguments)
    h.equals(true, acc.done)
  end)
end)

h.describe("runtime.providers.ollama", function()
  h.it("builds a chat request", function()
    local req = Ollama.build_request({
      endpoint = "http://127.0.0.1:11434",
      model = "deepseek-coder:1.3b",
      system = "sys",
      messages = { { role = "user", content = "hi" } },
    })
    h.equals("http://127.0.0.1:11434/api/chat", req.url)
    local body = vim.json.decode(req.body)
    h.equals("deepseek-coder:1.3b", body.model)
    h.equals(true, body.stream)
    h.equals("sys", body.messages[1].content)
  end)

  h.it("splits NDJSON lines and retains partial", function()
    local state = { buf = "" }
    local lines = Ollama.split_lines(state, '{"a":1}\n{"b":')
    h.equals(1, #lines)
    h.equals('{"a":1}', lines[1])
    h.equals('{"b":', state.buf)
  end)

  h.it("parses text and tool_calls from NDJSON", function()
    local acc = { text = "", tool_calls = {}, done = false }
    Ollama.parse_delta('{"message":{"role":"assistant","content":"Hi"}}', acc)
    Ollama.parse_delta('{"message":{"tool_calls":[{"function":{"name":"bash","arguments":{"cmd":"ls"}}}]}}', acc)
    Ollama.parse_delta('{"done":true}', acc)
    h.equals("Hi", acc.text)
    h.equals("bash", acc.tool_calls[1].name)
    h.equals('{"cmd":"ls"}', acc.tool_calls[1].arguments)
    h.equals(true, acc.done)
  end)
end)
