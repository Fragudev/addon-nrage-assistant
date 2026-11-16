
local function load_commands()
  local ns = {}

  -- Stub for localization, so commands can be tested without the WoW client.
  ns.L = function(text)
    return text
  end

  assert(loadfile("NrageAssistant/Commands/LfgCommands.lua"))("NrageAssistant", ns)
  return ns
end

local LfgCommands = load_commands().LfgCommands

describe("LfgCommands", function()
  local icon
  local commands
  local visible

  before_each(function()
    visible = false

    icon = {
      SetAlwaysShow = function(value)
        visible = value
      end,

      AlwaysShow = function()
        return visible
      end,
    }

    commands = LfgCommands.New({
      groupsIcon = icon,
    })
  end)

  it("enables persistent icon visibility", function()
    local lines = commands:Run("icon show")

    assert.is_true(visible)
    assert.matches("ON", lines[1])
  end)

  it("disables persistent icon visibility", function()
    commands:Run("icon show")
    local lines = commands:Run("icon hide")

    assert.is_false(visible)
    assert.matches("OFF", lines[1])
  end)

  it("toggles persistent icon visibility", function()
    commands:Run("icon toggle")
    assert.is_true(visible)

    commands:Run("icon toggle")
    assert.is_false(visible)
  end)

  it("accepts case-insensitive commands", function()
    commands:Run("ICON SHOW")

    assert.is_true(visible)
  end)

  it("returns usage for unknown commands", function()
    local lines = commands:Run("unknown")

    assert.same(LfgCommands.Usage(), lines)
  end)

  it("does not change visibility for invalid actions", function()
    commands:Run("icon invalid")

    assert.is_false(visible)
  end)
end)
