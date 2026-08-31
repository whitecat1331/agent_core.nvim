---@mod agent_core.runtime.mcp Owned MCP client bridge (owned).
---@brief [[
--- Owned Model Context Protocol *client*: JSON-RPC framing, server spawning over
--- stdio, and conversion of MCP tools into the owned runtime's tool contract.
--- Distinct from agent_core.mcp_index (which only manages the mcphub
--- servers.json wiring) — this module actually talks to MCP servers.
---
--- The pure framing/parsing/descriptor functions are headless-testable; the
--- subprocess client is guarded so headless require never spawns a server.
---@brief ]]

local M = {}

--- Client config: enabled toggle plus a name -> { command, args, env } map.
--- `servers_path` is the mcphub servers.json location (redirectable for tests).
M.config = {
  enabled = true,
  servers = {},
  servers_path = vim.fn.expand("~/.config/mcphub/servers.json"),
}

--- Encode a JSON-RPC 2.0 request.
---@param id integer
---@param method string
---@param params table|nil
---@return string
function M.encode_request(id, method, params)
  local msg = { jsonrpc = "2.0", id = id, method = method }
  if params ~= nil then
    msg.params = params
  end
  return vim.json.encode(msg)
end

--- Parse a single JSON-RPC message line. Returns nil for non-JSON / empty lines.
---@param line string
---@return table|nil
function M.parse_message(line)
  if not line or line == "" then
    return nil
  end
  local ok, msg = pcall(vim.json.decode, line)
  if not ok or type(msg) ~= "table" then
    return nil
  end
  return msg
end

--- Extract readable text from a JSON-RPC `tools/call` response (or a tools/list
--- error). Returns (text, err).
---@param msg table
---@return string|nil text
---@return string|nil err
function M.extract_text(msg)
  if not msg then
    return nil, "no response"
  end
  if msg.error then
    return nil, tostring(msg.error.message or msg.error.code or "mcp error")
  end
  local content = msg.result and msg.result.content
  if type(content) ~= "table" then
    return nil, "no content in result"
  end
  local parts = {}
  for _, item in ipairs(content) do
    if type(item) == "table" and item.type == "text" and item.text then
      parts[#parts + 1] = item.text
    end
  end
  if #parts == 0 then
    return nil, "no text content in result"
  end
  return table.concat(parts, "\n"), nil
end

--- Convert an MCP tool (from tools/list) into the normalized provider descriptor
--- { name, description, parameters }.
---@param tool table
---@return table
function M.descriptor(tool)
  return {
    name = tool.name,
    description = tool.description or "",
    parameters = tool.inputSchema or { type = "object", properties = {} },
  }
end

--- Convert an MCP tool into an executable owned tool (AgentTool shape). The
--- `inputSchema` is preserved for direct normalization by agent_core.runtime.schema;
--- `func` dispatches a `tools/call` through the supplied call_fn.
---@param tool table MCP tool from tools/list
---@param server string server name
---@param call_fn fun(server:string, name:string, args:table, cb:fun(result:string|nil, err:string|nil))
---@return table
function M.tool(tool, server, call_fn)
  return {
    name = tool.name,
    description = tool.description or "",
    inputSchema = tool.inputSchema,
    func = function(input, opts)
      call_fn(server, tool.name, input or {}, function(result, err)
        if opts and opts.on_complete then
          opts.on_complete(result, err)
        end
      end)
    end,
  }
end

--- Load server definitions: the configured `M.config.servers` map (highest
--- priority), then mcphub's `~/.config/mcphub/servers.json`
--- (`{ mcpServers = { name = { command, args, env } } }`) best-effort. Never
--- fails; returns an empty list when nothing is configured/readable.
---@return { name:string, command:string, args:string[], env:table }[]
function M.load_servers()
  local out = {}
  local seen = {}
  local function add(name, command, args, env)
    if name == nil or name == "" or command == nil or command == "" or seen[name] then
      return
    end
    seen[name] = true
    out[#out + 1] = { name = name, command = command, args = args or {}, env = env or {} }
  end

  for name, s in pairs(M.config.servers or {}) do
    add(name, s.command, s.args, s.env)
  end

  local path = M.config.servers_path or vim.fn.expand("~/.config/mcphub/servers.json")
  if vim.fn.filereadable(path) == 1 then
    local ok, decoded = pcall(function()
      return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    end)
    if ok and type(decoded) == "table" and type(decoded.mcpServers) == "table" then
      for name, s in pairs(decoded.mcpServers) do
        if type(s) == "table" then
          add(name, s.command, s.args, s.env)
        end
      end
    end
  end

  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

--- Live server registry: name -> { job_id, pending: id -> cb }.
M._servers = {}

--- Send a JSON-RPC call to a spawned server and route the response.
---@param server string
---@param method string
---@param params table|nil
---@param cb fun(msg:table|nil, err:string|nil)
---@return boolean ok
function M.rpc(server, method, params, cb)
  local st = M._servers[server]
  if not st or not st.job_id then
    cb(nil, "server not running: " .. tostring(server))
    return false
  end
  local id = (st.next_id or 0) + 1
  st.next_id = id
  st.pending[id] = cb
  local ok, err = pcall(vim.fn.chansend, st.job_id, M.encode_request(id, method, params) .. "\n")
  if not ok then
    st.pending[id] = nil
    cb(nil, tostring(err))
    return false
  end
  return true
end

--- Call an MCP tool on a running server and return the extracted text. Wraps
--- `rpc` + `extract_text` into a single (result, err) callback matching the
--- owned tool `on_complete` contract.
---@param server string
---@param name string
---@param args table|nil
---@param cb fun(result:string|nil, err:string|nil)
function M.call_tool(server, name, args, cb)
  M.rpc(server, "tools/call", { name = name, arguments = args or {} }, function(msg, err)
    if err then
      cb(nil, err)
      return
    end
    local text, terr = M.extract_text(msg)
    cb(text, terr)
  end)
end

--- Spawn an MCP server over stdio. Registers an on_exit/on_stdout handler that
--- decodes responses and routes them to pending callbacks.
---@param name string
---@param command string
---@param args string[]|nil
---@param env table|nil
---@return boolean ok
---@return string|nil err
function M.spawn(name, command, args, env)
  if not M.config.enabled then
    return false, "mcp disabled"
  end
  local job_id
  local ok, err = pcall(function()
    job_id = vim.fn.jobstart({ command, unpack(args or {}) }, {
      stdout_buffered = true,
      env = env or {},
      on_stdout = function(_, data)
        local st = M._servers[name]
        if not st then
          return
        end
        for _, chunk in ipairs(data or {}) do
          local msg = M.parse_message(chunk)
          if msg and msg.id and st.pending[msg.id] then
            local cb = st.pending[msg.id]
            st.pending[msg.id] = nil
            cb(msg, nil)
          end
        end
      end,
      on_exit = function()
        local st = M._servers[name]
        if st then
          for id, cb in pairs(st.pending or {}) do
            cb(nil, "mcp server exited")
          end
          M._servers[name] = nil
        end
      end,
    })
  end)
  if not ok then
    return false, tostring(err)
  end
  if job_id <= 0 then
    return false, "failed to start mcp server"
  end
  M._servers[name] = { job_id = job_id, pending = {}, next_id = 0 }
  return true, nil
end

--- Stop a spawned server.
---@param name string
function M.stop(name)
  local st = M._servers[name]
  if st and st.job_id then
    pcall(vim.fn.jobstop, st.job_id)
  end
  M._servers[name] = nil
end

--- Discover tools from every configured server. Calls back with
--- { server, tools[] } per server; calls back with an error entry on failure.
---@param cb fun(server:string, tools:table[], err:string|nil)
function M.discover(cb)
  local servers = M.load_servers()
  for _, s in ipairs(servers) do
    local ok, err = M.spawn(s.name, s.command, s.args, s.env)
    if not ok then
      cb(s.name, {}, err)
    else
      M.rpc(s.name, "initialize", {
        protocolVersion = "2024-11-05",
        capabilities = {},
        clientInfo = { name = "agent_core", version = "0.1.0" },
      }, function(_, ierr)
        if ierr then
          cb(s.name, {}, ierr)
          return
        end
        M.rpc(s.name, "tools/list", nil, function(msg, terr)
          local tools = {}
          if not terr and msg and msg.result and type(msg.result.tools) == "table" then
            tools = msg.result.tools
          end
          cb(s.name, tools, terr)
        end)
      end)
    end
  end
end

--- Discover and collect every tool from every configured server, calling back
--- once with a flat list of executable owned tools (AgentTool shape). Each
--- tool captures its server name so a `tools/call` routes back correctly.
---@param cb fun(tools:table[])
function M.discover_all(cb)
  cb = cb or function() end
  local servers = M.load_servers()
  if #servers == 0 then
    cb({})
    return
  end
  local collected = {}
  local pending = #servers
  local function done_one()
    pending = pending - 1
    if pending == 0 then
      cb(collected)
    end
  end
  for _, s in ipairs(servers) do
    local ok, err = M.spawn(s.name, s.command, s.args, s.env)
    if not ok then
      done_one()
    else
      M.rpc(s.name, "initialize", {
        protocolVersion = "2024-11-05",
        capabilities = {},
        clientInfo = { name = "agent_core", version = "0.1.0" },
      }, function(_, ierr)
        if ierr then
          done_one()
          return
        end
        M.rpc(s.name, "tools/list", nil, function(msg, terr)
          if not terr and msg and msg.result and type(msg.result.tools) == "table" then
            for _, t in ipairs(msg.result.tools) do
              collected[#collected + 1] = M.tool(t, s.name, function(server, name, args, done)
                M.call_tool(server, name, args, done)
              end)
            end
          end
          done_one()
        end)
      end)
    end
  end
end

return M
