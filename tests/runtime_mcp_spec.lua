---@mod tests.runtime_mcp_spec Unit tests for the owned MCP client bridge.

local h = require("tests.harness")
local MCP = require("agent_core.runtime.mcp")
local Schema = require("agent_core.runtime.schema")

h.describe("runtime.mcp json-rpc framing", function()
  h.it("encodes a request with id, method, params", function()
    local msg = MCP.parse_message(MCP.encode_request(1, "tools/list", nil))
    h.equals("2.0", msg.jsonrpc)
    h.equals(1, msg.id)
    h.equals("tools/list", msg.method)
  end)

  h.it("parse_message returns nil for non-JSON", function()
    h.equals(nil, MCP.parse_message("not json"))
    h.equals(nil, MCP.parse_message(""))
  end)
end)

h.describe("runtime.mcp extract_text", function()
  h.it("joins text content items", function()
    local text, err = MCP.extract_text({
      result = { content = { { type = "text", text = "line1" }, { type = "text", text = "line2" } } },
    })
    h.equals(nil, err)
    h.equals("line1\nline2", text)
  end)

  h.it("returns the error message on rpc error", function()
    local text, err = MCP.extract_text({ error = { code = -1, message = "nope" } })
    h.falsy(text)
    h.equals("nope", err)
  end)

  h.it("errors on missing text content", function()
    local _, err = MCP.extract_text({ result = { content = {} } })
    h.truthy(err)
  end)
end)

h.describe("runtime.mcp descriptor + tool", function()
  local mcp_tool = {
    name = "read_file",
    description = "read a file",
    inputSchema = { type = "object", properties = { path = { type = "string" } } },
  }

  h.it("converts an MCP tool to a normalized descriptor", function()
    local d = MCP.descriptor(mcp_tool)
    h.equals("read_file", d.name)
    h.equals("object", d.parameters.type)
  end)

  h.it("normalizes an MCP tool directly via schema", function()
    local t = MCP.tool(mcp_tool, "filesystem", function() end)
    local out = Schema.normalize_tool(t)
    h.equals("read_file", out.name)
    h.equals("string", out.parameters.properties.path.type)
  end)

  h.it("produces an executable tool that dispatches a call", function()
    local called = nil
    local t = MCP.tool(mcp_tool, "filesystem", function(server, name, args, cb)
      called = { server = server, name = name, args = args }
      cb("done", nil)
    end)
    h.equals("read_file", t.name)
    local completed
    t.func({ path = "/x" }, {
      on_complete = function(result, err)
        completed = result
      end,
    })
    h.equals("filesystem", called.server)
    h.equals("read_file", called.name)
    h.equals("/x", called.args.path)
    h.equals("done", completed)
  end)
end)

h.describe("runtime.mcp load_servers", function()
  h.it("returns configured servers sorted by name", function()
    MCP.config.servers = {
      filesystem = { command = "npx", args = { "-y", "mcp" } },
      memory = { command = "npx", args = { "-y", "mcp-memory" } },
    }
    local servers = MCP.load_servers()
    local names = {}
    for _, s in ipairs(servers) do
      names[s.name] = true
    end
    h.truthy(names["filesystem"], "filesystem server present")
    h.truthy(names["memory"], "memory server present")
    h.equals("filesystem", servers[1].name)
    h.equals("npx", servers[1].command)
    MCP.config.servers = {}
  end)

  h.it("reads a configured servers_path file and merges", function()
    local saved_path = MCP.config.servers_path
    local saved_servers = MCP.config.servers
    local tmp = vim.fn.tempname()
    local f = io.open(tmp, "w")
    f:write(vim.json.encode({
      mcpServers = {
        filesystem = { command = "npx", args = { "-y", "@modelcontextprotocol/server-filesystem" }, env = {} },
      },
    }))
    f:close()

    MCP.config.servers_path = tmp
    MCP.config.servers = {}
    local servers = MCP.load_servers()
    h.equals(1, #servers)
    h.equals("filesystem", servers[1].name)
    h.equals("npx", servers[1].command)

    vim.fn.delete(tmp)
    MCP.config.servers_path = saved_path
    MCP.config.servers = saved_servers
  end)
end)

h.describe("runtime.mcp call_tool", function()
  h.it("extracts text from a tools/call response", function()
    local saved_rpc = MCP.rpc
    MCP.rpc = function(server, method, params, cb)
      h.equals("tools/call", method)
      cb({ result = { content = { { type = "text", text = "the answer" } } } }, nil)
    end
    local result, err
    MCP.call_tool("filesystem", "read", { path = "/x" }, function(r, e)
      result, err = r, e
    end)
    h.equals(nil, err)
    h.equals("the answer", result)
    MCP.rpc = saved_rpc
  end)

  h.it("propagates rpc errors", function()
    local saved_rpc = MCP.rpc
    MCP.rpc = function(server, method, params, cb)
      cb(nil, "boom")
    end
    local result, err
    MCP.call_tool("filesystem", "read", {}, function(r, e)
      result, err = r, e
    end)
    h.equals("boom", err)
    h.falsy(result)
    MCP.rpc = saved_rpc
  end)
end)

h.describe("runtime.mcp discover", function()
  h.it("reports tools per server", function()
    local saved_load, saved_spawn, saved_rpc = MCP.load_servers, MCP.spawn, MCP.rpc
    MCP.load_servers = function()
      return { { name = "a", command = "x" } }
    end
    MCP.spawn = function()
      return true, nil
    end
    MCP.rpc = function(server, method, params, cb)
      if method == "initialize" then
        cb({}, nil)
      elseif method == "tools/list" then
        cb({ result = { tools = { { name = "t1" } } } }, nil)
      end
    end
    local entries = {}
    MCP.discover(function(server, tools, err)
      entries[#entries + 1] = { server = server, tools = tools, err = err }
    end)
    h.equals(1, #entries)
    h.equals("a", entries[1].server)
    h.equals(1, #entries[1].tools)
    h.equals("t1", entries[1].tools[1].name)
    MCP.load_servers, MCP.spawn, MCP.rpc = saved_load, saved_spawn, saved_rpc
  end)

  h.it("reports a spawn error entry", function()
    local saved_load, saved_spawn = MCP.load_servers, MCP.spawn
    MCP.load_servers = function()
      return { { name = "a", command = "x" } }
    end
    MCP.spawn = function()
      return false, "mcp disabled"
    end
    local entries = {}
    MCP.discover(function(server, tools, err)
      entries[#entries + 1] = { server = server, tools = tools, err = err }
    end)
    h.equals(1, #entries)
    h.equals("a", entries[1].server)
    h.equals(0, #entries[1].tools)
    h.truthy(entries[1].err)
    MCP.load_servers, MCP.spawn = saved_load, saved_spawn
  end)
end)

h.describe("runtime.mcp discover_all", function()
  h.it("aggregates tools from every server into one flat list", function()
    local saved_load, saved_spawn, saved_rpc, saved_tool = MCP.load_servers, MCP.spawn, MCP.rpc, MCP.tool
    MCP.load_servers = function()
      return { { name = "a", command = "x" }, { name = "b", command = "y" } }
    end
    MCP.spawn = function()
      return true, nil
    end
    MCP.rpc = function(server, method, params, cb)
      if method == "initialize" then
        cb({}, nil)
      elseif method == "tools/list" then
        cb({ result = { tools = { { name = server .. "_tool" } } } }, nil)
      end
    end
    MCP.tool = function(t, server, call_fn)
      return { name = t.name, server = server }
    end
    local result
    MCP.discover_all(function(tools)
      result = tools
    end)
    h.truthy(result, "callback should fire")
    h.equals(2, #result)
    h.equals("a_tool", result[1].name)
    h.equals("b_tool", result[2].name)
    MCP.load_servers, MCP.spawn, MCP.rpc, MCP.tool = saved_load, saved_spawn, saved_rpc, saved_tool
  end)

  h.it("calls back with an empty list when no servers are configured", function()
    local saved_load = MCP.load_servers
    MCP.load_servers = function()
      return {}
    end
    local result
    MCP.discover_all(function(tools)
      result = tools
    end)
    h.same({}, result)
    MCP.load_servers = saved_load
  end)
end)
