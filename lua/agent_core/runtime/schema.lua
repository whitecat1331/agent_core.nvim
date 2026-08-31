---@mod agent_core.runtime.schema Owned tool-schema normalization (owned).
---@brief [[
--- Converts the existing agent_core custom-tool shape (the "AgentTool"
--- contract: name, description, param {type, fields[], required[]}, returns) into
--- the JSON-schema form each provider API expects. Keeping this a pure function
--- means the ~30 existing tools feed the owned runtime UNCHANGED (no rewrite):
--- only the wire format is translated, not the tool bodies.
---
--- Normalized tool descriptor consumed by providers:
---   { name:string, description:string, parameters:table(json-schema) }
---@brief ]]

local M = {}

--- Map a legacy field `type` string to a JSON-schema type descriptor.
--- Handles the scalar/array/object forms the existing tools use.
---@param t string
---@return table
local function type_descriptor(t)
  if not t then
    return { type = "string" }
  end
  if t:sub(-2) == "[]" then
    local item = t:sub(1, -3)
    return { type = "array", items = type_descriptor(item) }
  end
  if t == "table" or t == "object" then
    return { type = "object" }
  end
  if t == "integer" or t == "int" then
    return { type = "integer" }
  end
  if t == "number" or t == "float" then
    return { type = "number" }
  end
  if t == "boolean" or t == "bool" then
    return { type = "boolean" }
  end
  return { type = "string" }
end

--- Build the JSON-schema `properties`/`required` from a legacy `param` table.
---@param param table
---@return table properties
---@return string[] required
local function param_schema(param)
  local properties = {}
  local required = {}
  for _, f in ipairs(param.fields or {}) do
    local desc = f.description or ""
    local d = type_descriptor(f.type)
    d.description = desc
    if d.type == "object" and f.fields then
      local sub_props, sub_req = param_schema({ fields = f.fields, required = f.required })
      d.properties = next(sub_props) and sub_props or vim.empty_dict()
      if #sub_req > 0 then
        d.required = sub_req
      end
    end
    properties[f.name] = d
  end
  for _, r in ipairs(param.required or {}) do
    required[#required + 1] = r
  end
  return properties, required
end

--- Convert a tool (legacy shape) into the normalized provider descriptor.
--- Also accepts tools that already carry a full JSON schema (`parameters` or
--- `inputSchema`, e.g. MCP tools from agent_core.runtime.mcp) unchanged.
---@param tool { name:string, description:string, param?:table, parameters?:table, inputSchema?:table }
---@return { name:string, description:string, parameters:table }
function M.normalize_tool(tool)
  if tool.parameters then
    return { name = tool.name, description = tool.description or "", parameters = tool.parameters }
  end
  if tool.inputSchema then
    return { name = tool.name, description = tool.description or "", parameters = tool.inputSchema }
  end
  local properties, required = {}, {}
  if tool.param then
    properties, required = param_schema(tool.param)
  end
  local parameters = { type = "object", properties = next(properties) and properties or vim.empty_dict() }
  if #required > 0 then
    parameters.required = required
  end
  return {
    name = tool.name,
    description = tool.description or "",
    parameters = parameters,
  }
end

--- Convert a list of tools into normalized descriptors (skipping non-tables).
---@param tools table[]
---@return table[]
function M.normalize_tools(tools)
  local out = {}
  for _, t in ipairs(tools or {}) do
    if type(t) == "table" and t.name then
      out[#out + 1] = M.normalize_tool(t)
    end
  end
  return out
end

return M
