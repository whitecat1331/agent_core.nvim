---@mod tests.hooks_spec Unit tests for agent_core.hooks.

local h = require("tests.harness")
local Hooks = require("agent_core.hooks")

h.describe("hooks.wrap", function()
  h.it("preserves tool shape and emits before/after", function()
    local saved_before = Hooks.config.before_tool
    local saved_after = Hooks.config.after_tool
    local events = {}
    Hooks.config.before_tool = function(d)
      events[#events + 1] = "before:" .. d.name
    end
    Hooks.config.after_tool = function(d)
      events[#events + 1] = "after:" .. d.name
    end

    local tool = {
      name = "my_tool",
      description = "desc",
      param = { type = "object" },
      func = function(input, opts)
        opts.on_complete("ok", nil)
      end,
    }
    local wrapped = Hooks.wrap(tool)
    h.equals("my_tool", wrapped.name)
    h.equals("desc", wrapped.description)
    h.equals("object", wrapped.param.type)

    local result
    wrapped.func({}, {
      on_complete = function(r)
        result = r
      end,
    })
    h.equals("ok", result)
    h.equals("before:my_tool", events[1])
    h.equals("after:my_tool", events[2])

    Hooks.config.before_tool = saved_before
    Hooks.config.after_tool = saved_after
  end)

  h.it("returns non-tool values unchanged", function()
    h.equals(nil, Hooks.wrap(nil))
    h.equals("x", Hooks.wrap("x"))
  end)
end)

h.describe("hooks.wrap_all", function()
  h.it("maps wrap over a tool list", function()
    local out = Hooks.wrap_all({
      {
        name = "a",
        func = function(i, o)
          o.on_complete("a", nil)
        end,
      },
      {
        name = "b",
        func = function(i, o)
          o.on_complete("b", nil)
        end,
      },
    })
    h.equals(2, #out)
    h.equals("a", out[1].name)
    h.equals("b", out[2].name)
    h.truthy(out[1].func ~= nil)
  end)
end)

h.describe("hooks.emit", function()
  h.it("fires a User autocmd without error", function()
    local ok = pcall(Hooks.emit, "before_prompt", { input = "hi" })
    h.truthy(ok, "emit should not error")
  end)
end)
