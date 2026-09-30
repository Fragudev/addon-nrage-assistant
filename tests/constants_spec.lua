describe("Constants", function()
  local ns

  before_each(function()
    ns = {}
    assert(loadfile("NrageAssistant/Core/Constants.lua"))("NrageAssistant", ns)
  end)

  it("exposes the addon message prefix", function()
    assert.are.equal("NRAGE", ns.Constants.ADDON_PREFIX)
  end)

  it("starts at schema version 1", function()
    assert.are.equal(1, ns.Constants.SCHEMA_VERSION)
  end)
end)

describe("Init", function()
  it("loads and registers the /nrage slash command", function()
    local ns = {}
    assert(loadfile("NrageAssistant/Core/Constants.lua"))("NrageAssistant", ns)
    assert(loadfile("NrageAssistant/Core/Platform.lua"))("NrageAssistant", ns)
    assert(loadfile("NrageAssistant/Core/AccessGuard.lua"))("NrageAssistant", ns)
    assert(loadfile("NrageAssistant/Core/Init.lua"))("NrageAssistant", ns)
    assert.is_function(SlashCmdList.NRAGE)
  end)
end)
