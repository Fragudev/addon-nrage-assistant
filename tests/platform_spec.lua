-- Platform is the seam over the client API; only the date helpers are pure enough to test here
-- (the stubs give it the standard library's time and date, like the real client).
local function load_platform()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/Platform.lua"))("NrageAssistant", ns)
  return ns.Platform
end

local Platform = load_platform()

describe("Platform.ParseDate", function()
  it("parses a local date and time and round-trips through FormatDate", function()
    local timestamp = Platform.ParseDate("2026-10-03 20:30")
    assert.is_number(timestamp)
    assert.are.equal("2026-10-03 20:30", Platform.FormatDate(timestamp))
  end)

  it("orders dates chronologically", function()
    assert.is_true(Platform.ParseDate("2026-10-03 20:30") < Platform.ParseDate("2026-10-03 20:31"))
    assert.is_true(Platform.ParseDate("2026-10-03 23:59") < Platform.ParseDate("2026-10-04 00:00"))
  end)

  it("refuses text that is not in the expected format", function()
    for _, text in ipairs({
      "", "tomorrow", "2026-10-03", "20:30", "2026/10/03 20:30", "2026-10-3 20:30", "2026-10-03T20:30",
      "2026-10-03 8:30", "2026-10-03 20:30:00", "  2026-10-03 20:30", "2026-10-03 20:30 ",
    }) do
      assert.is_nil(Platform.ParseDate(text), text)
    end
    assert.is_nil(Platform.ParseDate(nil))
    assert.is_nil(Platform.ParseDate(5))
  end)

  it("refuses dates that do not exist instead of rolling them over", function()
    for _, text in ipairs({
      "2026-02-31 10:00", "2026-13-01 10:00", "2026-00-10 10:00", "2026-10-00 10:00",
      "2026-10-03 24:00", "2026-10-03 10:60", "2026-04-31 12:00",
    }) do
      assert.is_nil(Platform.ParseDate(text), text)
    end
  end)
end)
