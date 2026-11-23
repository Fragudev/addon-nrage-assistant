describe("Platform world kill evidence", function()
  local saved, platform, units, queried
  local globals = {
    "GetPlayerInfoByGUID",
    "UnitGUID",
    "UnitIsPlayer",
    "UnitIsEnemy",
    "GetUnitName",
    "UnitClass",
    "UnitRace",
    "GetPVPSessionStats",
    "GetPVPLifetimeStats",
    "issecretvalue",
    "UnitIsFeignDeath",
    "UnitIsDeadOrGhost",
  }
  before_each(function()
    saved, units, queried = {}, { player = "Player-self", party1 = "Player-ally", target = "Player-enemy" }, {}
    for _, key in ipairs(globals) do
      saved[key] = _G[key]
    end
    _G.issecretvalue = nil
    _G.UnitGUID = function(unit)
      return units[unit]
    end
    _G.GetPlayerInfoByGUID = function(guid)
      queried[#queried + 1] = guid
      return "Hunter", "HUNTER", "Orc", "Orc", 3, "Xtrap Xtratos", ""
    end
    _G.UnitIsPlayer = function(unit)
      return unit == "target"
    end
    _G.UnitIsEnemy = function(_, unit)
      return unit == "target"
    end
    _G.GetUnitName = function()
      return "Xtrap Xtratos"
    end
    _G.UnitClass = function()
      return "Hunter", "HUNTER"
    end
    _G.UnitRace = function()
      return "Orc", "Orc"
    end
    _G.GetPVPSessionStats = function()
      return 2, 0
    end
    _G.GetPVPLifetimeStats = function()
      return 173, 0
    end
    local ns = {}
    assert(loadfile("NrageAssistant/Core/Constants.lua"))("NrageAssistant", ns)
    assert(loadfile("NrageAssistant/Core/Platform.lua"))("NrageAssistant", ns)
    platform = ns.Platform
  end)
  after_each(function()
    for _, key in ipairs(globals) do
      _G[key] = saved[key]
    end
  end)

  it("provides validated GUIDs in enemy unit observations and normalized death class/race", function()
    local visible = platform.GetEnemyPlayerInfo("target")
    assert.are.equal("Player-enemy", visible.guid)
    local death = platform.GetPlayerDeathInfo("Player-enemy")
    assert.are.equal("Xtrap Xtratos", death.name)
    assert.are.equal("ORC", death.race)
    assert.are.equal("HUNTER", death.class)
  end)

  it("excludes self, group members and readable NPC GUIDs", function()
    for _, guid in ipairs({ "Player-self", "Player-ally", "Creature-npc", "Pet-test" }) do
      assert.is_false(platform.GetPlayerDeathInfo(guid))
    end
  end)

  it("rejects a currently friendly player even if earlier observations might call them hostile", function()
    _G.UnitIsEnemy = function()
      return false
    end
    assert.is_false(platform.GetPlayerDeathInfo("Player-enemy"))
  end)

  it("queries restricted GUIDs first but leaves their identity unresolved for production", function()
    local restricted = {}
    _G.issecretvalue = function(value)
      if rawequal(value, restricted) then
        assert.are.equal(1, #queried)
        return true
      end
      return false
    end
    assert.is_nil(platform.GetPlayerDeathInfo(restricted))
    assert.is_true(rawequal(restricted, queried[1]))
  end)

  it("keeps unit name/class/race usable when its GUID cannot be read", function()
    _G.UnitGUID = function()
      error("restricted unit")
    end
    local info = platform.GetEnemyPlayerInfo("target")
    assert.are.equal("Xtrap Xtratos", info.name)
    assert.are.equal("ORC", info.race)
    assert.is_nil(info.guid)
  end)

  it("does not turn missing or secret counter data into zero HKs", function()
    assert.are.same({ sessionHK = 2, lifetimeHK = 173 }, platform.GetPvPKillCounters())
    _G.GetPVPLifetimeStats = nil
    assert.is_truthy(platform.GetPvPKillCounters().error)
    _G.GetPVPLifetimeStats = function()
      error("restricted")
    end
    assert.is_truthy(platform.GetPvPKillCounters().error)
  end)

  it("vetoes Feign Death or a living visible player, never a mismatched GUID", function()
    _G.UnitIsFeignDeath = function()
      return true
    end
    assert.is_true(platform.IsWorldVictimAlive("Player-enemy"))
    assert.is_nil(platform.IsWorldVictimAlive("Player-unseen"))
    _G.UnitIsFeignDeath = function()
      return false
    end
    _G.UnitIsDeadOrGhost = function()
      return false
    end
    assert.is_true(platform.IsWorldVictimAlive("Player-enemy"))
    _G.UnitIsDeadOrGhost = function()
      return true
    end
    assert.is_nil(platform.IsWorldVictimAlive("Player-enemy"))
  end)
end)
