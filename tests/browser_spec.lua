---@mod tests.browser_spec Unit tests for agent_core.browser (pure + tool surface).

local h = require("tests.harness")
local Browser = require("agent_core.browser")

h.describe("browser", function()
  h.it("resolve_bin returns the configured bin when set", function()
    local saved = Browser.config.bin
    Browser.config.bin = "/fake/chrome"
    h.equals("/fake/chrome", Browser.resolve_bin())
    Browser.config.bin = saved
  end)

  h.it("extract_title pulls the <title>", function()
    h.equals("Hello", Browser.extract_title("<html><head><title>Hello</title></head></html>"))
  end)

  h.it("extract_title returns nil without a title", function()
    h.equals(nil, Browser.extract_title("<html></html>"))
  end)

  h.it("candidates prefers playwright then chrome", function()
    local c = Browser.candidates()
    h.equals("npx playwright", c[1])
  end)

  h.it("exposes the three browser tools", function()
    h.equals("browser_open", Browser.browser_open_tool().name)
    h.equals("browser_screenshot", Browser.browser_screenshot_tool().name)
    h.equals("browser_snapshot", Browser.browser_snapshot_tool().name)
  end)

  h.it("browser_open rejects non-http URLs", function()
    local err
    Browser.browser_open_tool().func({ url = "ftp://example.com" }, {
      on_complete = function(_, e)
        err = e
      end,
    })
    h.equals("only http(s) URLs are supported", err)
  end)
end)
