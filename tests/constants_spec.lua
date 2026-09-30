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

  local function run(command)
    dofile("tests/support/addon.lua")({})
    local printed = {}
    local original = _G.print
    _G.print = function(text) printed[#printed + 1] = text end
    local ok, err = pcall(SlashCmdList.NRAGE, command)
    _G.print = original
    assert(ok, err)
    return table.concat(printed, "\n")
  end

  it("prints the version for a bare /nrage while the addon is disabled", function()
    assert.is_truthy(run(""):find("version dev", 1, true))
  end)

  it("prints the version for /nrage version", function()
    assert.is_truthy(run("version"):find("version dev", 1, true))
  end)

  it("lists the commands for /nrage help", function()
    local text = run("help")
    assert.is_truthy(text:find("/nrage publish", 1, true))
    assert.is_truthy(text:find("/nrage consent", 1, true))
  end)

  it("points to help for an unknown command", function()
    local text = run("frobnicate")
    assert.is_truthy(text:find("unknown command 'frobnicate'", 1, true))
    assert.is_truthy(text:find("/nrage help", 1, true))
  end)

  it("refuses data commands while the addon is disabled instead of raising", function()
    local commands = {
      "profile", "ready", "sync", "consent", "publish", "event", "attendance", "assign", "export", "import", "loot",
    }
    for _, command in ipairs(commands) do
      assert.is_truthy(run(command):find("unavailable while the addon is disabled", 1, true), command)
    end
  end)
end)
