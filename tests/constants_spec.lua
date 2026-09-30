describe("Constants", function()
  local ns

  before_each(function()
    ns = {}
    assert(loadfile("NrageAssistant/Core/Constants.lua"))("NrageAssistant", ns)
  end)

  it("exposes the addon message prefix", function()
    assert.are.equal("NRAGE", ns.Constants.ADDON_PREFIX)
  end)

  it("is at schema version 2", function()
    assert.are.equal(2, ns.Constants.SCHEMA_VERSION)
  end)
end)

describe("Addon load", function()
  it("loads every file listed in the TOC and registers the /nrage slash command", function()
    dofile("tests/support/addon.lua")({})
    assert.is_function(SlashCmdList.NRAGE)
  end)

  it("prints the version for a bare /nrage", function()
    dofile("tests/support/addon.lua")({})
    local printed
    local original = _G.print
    _G.print = function(text) printed = text end
    SlashCmdList.NRAGE("")
    _G.print = original
    assert.is_truthy(printed:find("version dev", 1, true))
  end)
end)
