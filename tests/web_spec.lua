---@mod tests.web_spec Unit tests for agent_core.web pure helpers.

local h = require("tests.harness")
local Web = require("agent_core.web")

h.describe("web", function()
  h.it("urlencode percent-encodes spaces and special chars", function()
    h.equals("hello%20world", Web.urlencode("hello world"))
    h.equals("a%26b", Web.urlencode("a&b"))
  end)

  h.it("urldecode reverses percent-encoding", function()
    h.equals("hello world", Web.urldecode("hello%20world"))
    h.equals("a&b", Web.urldecode("a%26b"))
  end)

  h.it("urldecode converts common HTML entities", function()
    h.equals('a&b<c>"', Web.urldecode("a&amp;b&lt;c&gt;&quot;"))
  end)

  h.it("urlencode/urldecode roundtrip", function()
    local s = "hello world & <test>"
    h.equals(s, Web.urldecode(Web.urlencode(s)))
  end)

  h.it("html_to_text strips tags and scripts", function()
    local html = "<p>Hello <b>world</b></p><script>alert(1)</script>tail"
    local text = Web.html_to_text(html)
    h.truthy(text:find("Hello", 1, true), "keeps visible text")
    h.truthy(text:find("world", 1, true), "keeps inner text")
    h.falsy(text:find("alert", 1, true), "removes script content")
    h.falsy(text:find("<b>", 1, true), "removes tags")
  end)

  h.it("parse_ddg extracts results from sample HTML", function()
    local html = [[
      <a rel="nofollow" class="result__a" href="https://example.com/page">Example Title</a>
      <a class="result__snippet" >A short snippet</a>
    ]]
    local results = Web.parse_ddg(html, 10)
    h.equals(1, #results)
    h.equals("Example Title", results[1].title)
    h.equals("A short snippet", results[1].snippet)
    h.truthy(results[1].url:find("^https?://"), "url should be http(s)")
  end)

  h.it("parse_ddg returns empty on non-matching HTML", function()
    h.equals(0, #Web.parse_ddg("<html>nothing</html>", 10))
  end)
end)
