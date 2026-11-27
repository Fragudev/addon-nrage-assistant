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

  it("reports precisely which platform step ignored self and group deaths", function()
    local ignored, detail = platform.GetPlayerDeathInfo("Player-self")
    assert.is_false(ignored)
    assert.are.equal("self", detail.platformReason)
    ignored, detail = platform.GetPlayerDeathInfo("Player-ally")
    assert.is_false(ignored)
    assert.are.equal("group_ally", detail.platformReason)
    assert.are.equal("party1", detail.matchedUnit)
  end)

  it("distinguishes query failure from GUID restrictions and missing identity fields", function()
    _G.GetPlayerInfoByGUID = function()
      error("query rejected")
    end
    local info, detail = platform.GetPlayerDeathInfo("Player-enemy")
    assert.are.equal("Player-enemy", info.guid)
    assert.are.equal("error", detail.query)
    assert.is_truthy(detail.queryError:find("query rejected", 1, true))
    assert.is_false(detail.nameReadable)
    local restricted = {}
    _G.issecretvalue = function(value)
      return rawequal(value, restricted)
    end
    info, detail = platform.GetPlayerDeathInfo(restricted)
    assert.is_nil(info)
    assert.are.equal("guid_restricted", detail.platformReason)
    assert.are.equal("restricted", detail.guidState)
  end)

  it("measures a hostile party target by exact GUID even when no local unit exposes the victim", function()
    units.target, units.party4, units.party4target = nil, "Player-friend", "Player-enemy"
    _G.UnitIsPlayer = function(unit)
      return unit == "party4target"
    end
    _G.UnitIsEnemy = function(_, unit)
      return unit == "party4target"
    end
    local evidence = platform.GetWorldKillHostilityEvidence("Player-enemy", "Player-friend")
    assert.are.equal("enemy", evidence.hostility)
    assert.are.equal("party4target", evidence.groupHostileUnit)
    assert.are.equal("party4", evidence.attackerUnit)
    assert.is_nil(evidence.visibleHostileUnit)
    evidence = platform.GetWorldKillHostilityEvidence("Player-different", "Player-friend")
    assert.are.equal("unknown", evidence.hostility)
    assert.are.equal(0, evidence.matchedUnits)
  end)

  it("does not classify a friendly group target as hostile and contains individual unit errors", function()
    units.target, units.party4target = nil, "Player-enemy"
    _G.UnitIsPlayer = function()
      return true
    end
    _G.UnitIsEnemy = function()
      return false
    end
    local readGuid = _G.UnitGUID
    _G.UnitGUID = function(unit)
      if unit == "party1target" then
        error("restricted")
      end
      return readGuid(unit)
    end
    local evidence = platform.GetWorldKillHostilityEvidence("Player-enemy")
    assert.are.equal("friendly", evidence.hostility)
    assert.are.equal("party4target", evidence.friendlyUnit)
    assert.is_nil(evidence.groupHostileUnit)
    assert.are.equal(1, evidence.readErrors)
    assert.is_truthy(evidence.lastReadError:find("restricted", 1, true))
  end)
end)
