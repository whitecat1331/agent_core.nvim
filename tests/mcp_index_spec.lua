---@mod tests.mcp_index_spec Unit tests for agent_core.mcp_index global wiring.

local h = require("tests.harness")
local M = require("agent_core.mcp_index")
local Platform = require("agent_core.platform")
local Indexer = require("agent_core.indexer")
local Workspace = require("agent_core.workspace")

h.describe("mcp_index.write_global", function()
  h.it("preserves foreign servers, writes ripvec + semnav, and backs up once", function()
    local tmp = vim.fn.tempname()
    local f = io.open(tmp, "w")
    f:write(vim.json.encode({ mcpServers = { other = { command = "echo", args = {} } } }))
    f:close()

    local saved_path = M.global_servers_path
    M.global_servers_path = function()
      return tmp
    end

    local saved_resolve = Platform.resolve_bin
    Platform.resolve_bin = function(bin)
      return "/opt/bin/" .. bin
    end

    local saved_list = Workspace.list
    Workspace.list = function()
      return { { path = "/projects/acme", name = "acme" } }
    end

    local saved_flf = Indexer.file_list_for
    local saved_supports = Indexer.supports_semnav
    Indexer.file_list_for = function()
      return { "/projects/acme/main.py" }
    end
    Indexer.supports_semnav = function()
      return true
    end

    local ok, err = pcall(M.write_global)

    if ok then
      local content = table.concat(vim.fn.readfile(tmp), "\n")
      local decoded = vim.json.decode(content)
      h.truthy(decoded.mcpServers.ripvec, "ripvec should be written")
      h.equals("/opt/bin/ripvec-mcp", decoded.mcpServers.ripvec.command)
      h.truthy(decoded.mcpServers.other, "foreign server preserved")
      local slug = M.slug_for("/projects/acme")
      h.truthy(decoded.mcpServers[slug], "semnav server should be written")
      h.equals("/opt/bin/semnav", decoded.mcpServers[slug].command)
      h.equals(1, vim.fn.filereadable(tmp .. ".bak"), ".bak should be written once")
      h.equals(0, vim.fn.filereadable(tmp .. ".tmp"), "no .tmp leftover after rename")
    end

    vim.fn.delete(tmp)
    vim.fn.delete(tmp .. ".bak")
    M.global_servers_path = saved_path
    Platform.resolve_bin = saved_resolve
    Workspace.list = saved_list
    Indexer.file_list_for = saved_flf
    Indexer.supports_semnav = saved_supports

    if not ok then
      error(err, 0)
    end
  end)
end)
