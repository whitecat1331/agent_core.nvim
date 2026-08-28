---@mod tests.ask_spec Unit tests for agent_core.ask (ask_user tool).

local h = require("tests.harness")
local Ask = require("agent_core.ask")

h.describe("ask", function()
  h.it("ask_user_tool exposes the tool", function()
    local t = Ask.ask_user_tool()
    h.equals("ask_user", t.name)
    h.equals("function", type(t.func))
  end)

  h.it("rejects an empty question", function()
    local err
    Ask.ask_user_tool().func({ question = "" }, {
      on_complete = function(_, e)
        err = e
      end,
    })
    h.equals("question is required", err)
  end)

  h.it("errors when disabled", function()
    local saved = Ask.config.enabled
    Ask.config.enabled = false
    local err
    Ask.ask_user_tool().func({ question = "q" }, {
      on_complete = function(_, e)
        err = e
      end,
    })
    h.equals("ask_user is disabled", err)
    Ask.config.enabled = saved
  end)

  h.it("errors in headless and defers otherwise", function()
    local err
    Ask.ask_user_tool().func({ question = "q" }, {
      on_complete = function(_, e)
        err = e
      end,
    })
    if #vim.api.nvim_list_uis() == 0 then
      h.equals("no UI available (headless); state your assumption and proceed", err)
    else
      h.equals(nil, err) -- async: no synchronous completion under a real UI
    end
  end)
end)
