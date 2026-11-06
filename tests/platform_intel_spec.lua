-- The client readers of Intel (docs/PVP_INTEL_PLAN.md section 3.1). None is measured on Forever yet, so each one has
-- to give nil (or false) for a missing API, an error and a secret value.
local function load_platform()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/Platform.lua"))("NrageAssistant", ns)
  return ns.Platform
end

local function with_globals(values, fn)
  local saved = {}
  for name, value in pairs(values) do
    saved[name] = _G[name]
    if value == false then
      _G[name] = nil
    else
      _G[name] = value
    end
  end
  local ok, err = pcall(fn)
  for name in pairs(values) do
    _G[name] = saved[name]
  end
  assert(ok, err)
end

local function secret()
  return setmetatable({}, {
    __lt = function()
      error("secret")
    end,
    __eq = function()
      error("secret")
    end,
    __concat = function()
      error("secret")
    end,
    __len = function()
      error("secret")
    end,
  })
end

-- A fake unit API: `units` maps a unit token to its fields.
local function unit_api(units)
  return {
    UnitIsPlayer = function(unit)
      return units[unit] and units[unit].player
    end,
    UnitIsEnemy = function(_, unit)
      return units[unit] and units[unit].enemy
    end,
    GetUnitName = function(unit)
      return units[unit] and units[unit].name
    end,
    UnitClass = function(unit)
      return "Pícaro", units[unit] and units[unit].class
    end,
    UnitRace = function(unit)
      return "Orco", units[unit] and units[unit].race
    end,
    UnitLevel = function(unit)
      return units[unit] and units[unit].level
    end,
    GetGuildInfo = function(unit)
      return units[unit] and units[unit].guild
    end,
    UnitFactionGroup = function(unit)
      return units[unit] and units[unit].faction
    end,
    UnitIsUnit = function(unit)
      return units[unit] and units[unit].targetsMe
    end,
  }
end

local function enemy(overrides)
  local unit =
    { player = true, enemy = true, name = "Zed", class = "ROGUE", race = "Orc", level = 60, faction = "Horde" }
  for key, value in pairs(overrides or {}) do
    unit[key] = value
  end
  return unit
end

describe("Platform.GetEnemyDetails", function()
  local function read(units, unit)
    local details
    local api = unit_api(units)
    with_globals(api, function()
      details = load_platform().GetEnemyDetails(unit or "target")
    end)
    return details
  end

  local own = { player = { faction = "Alliance" } }

  it("reads everything about an enemy player", function()
    local units = { player = own.player, target = enemy({ guild = "Evil", faction = "Horde" }) }
    assert.are.same(
      { name = "Zed", class = "ROGUE", race = "ORC", level = 60, guild = "Evil", faction = "Horde" },
      read(units)
    )
  end)

  it("gives a skull level as skull and no number", function()
    local details = read({ player = own.player, target = enemy({ level = -1 }) })
    assert.is_true(details.skull)
    assert.is_nil(details.level)
  end)

  it("leaves out what cannot be read and keeps the rest", function()
    local details = read({
      player = own.player,
      target = enemy({ level = secret(), guild = secret(), class = secret(), race = secret(), faction = secret() }),
    })
    assert.are.same({ name = "Zed" }, details)
    details = read({ player = own.player, target = enemy({ level = 0, guild = "" }) })
    assert.is_nil(details.level)
    assert.is_nil(details.guild)
    assert.is_nil(read({ player = own.player, target = enemy({ level = 12.5 }) }).level)
  end)

  it("rejects a player of the own faction, such as a duel opponent", function()
    assert.is_nil(read({ player = own.player, target = enemy({ faction = "Alliance" }) }))
  end)

  it("rejects friendly units, non players, unreadable names and secret answers", function()
    local units = {
      player = own.player,
      target = enemy({ enemy = false }),
      mouseover = enemy({ player = false }),
      nameplate1 = enemy({ name = secret() }),
      nameplate2 = enemy({ player = secret() }),
    }
    for _, unit in ipairs({ "target", "mouseover", "nameplate1", "nameplate2", "nameplate9" }) do
      assert.is_nil(read(units, unit), unit)
    end
    assert.is_nil(read(units, nil))
  end)

  it("gives nil when the API is missing or raises", function()
    with_globals({ UnitIsPlayer = false }, function()
      assert.is_nil(load_platform().GetEnemyDetails("target"))
    end)
    local api = unit_api({ target = enemy() })
    api.UnitLevel = function()
      error("restricted")
    end
    with_globals(api, function()
      assert.is_nil(load_platform().GetEnemyDetails("target"))
    end)
  end)

  it("works without the optional APIs", function()
    local api = unit_api({ target = enemy() })
    api.UnitLevel, api.GetGuildInfo, api.UnitFactionGroup, api.UnitClass, api.UnitRace =
      false, false, false, false, false
    with_globals(api, function()
      assert.are.same({ name = "Zed" }, load_platform().GetEnemyDetails("target"))
    end)
  end)
end)

describe("Platform.IsEnemyTargetingPlayer", function()
  local function targeting(value)
    local result
    with_globals({
      UnitIsUnit = function(unit, other)
        assert.are.equal("nameplate3target", unit)
        assert.are.equal("player", other)
        return value
      end,
    }, function()
      result = load_platform().IsEnemyTargetingPlayer("nameplate3")
    end)
    return result
  end

  it("says whether the unit has the player as its target", function()
    assert.is_true(targeting(true))
    assert.is_true(targeting(1))
    assert.is_false(targeting(false))
    assert.is_false(targeting(nil))
  end)

  it("gives nil for something the client cannot say", function()
    assert.is_nil(targeting("maybe"))
    with_globals({
      UnitIsUnit = function()
        error("secret")
      end,
    }, function()
      assert.is_nil(load_platform().IsEnemyTargetingPlayer("target"))
    end)
    with_globals({ UnitIsUnit = false }, function()
      assert.is_nil(load_platform().IsEnemyTargetingPlayer("target"))
    end)
    assert.is_nil(load_platform().IsEnemyTargetingPlayer(nil))
  end)
end)

describe("Platform zone and instance", function()
  it("reads the PvP type of the zone", function()
    with_globals({
      GetZonePVPInfo = function()
        return "sanctuary"
      end,
    }, function()
      assert.are.equal("sanctuary", load_platform().GetZonePvPType())
    end)
    for _, value in ipairs({ 5, "", "a b" }) do
      with_globals({
        GetZonePVPInfo = function()
          return value
        end,
      }, function()
        assert.is_nil(load_platform().GetZonePvPType())
      end)
    end
    with_globals({
      GetZonePVPInfo = function()
        error("restricted")
      end,
    }, function()
      assert.is_nil(load_platform().GetZonePvPType())
    end)
    with_globals({ GetZonePVPInfo = false }, function()
      assert.is_nil(load_platform().GetZonePvPType())
    end)
  end)

  it("names the kind of instance", function()
    local function kind(value)
      local result
      with_globals({
        IsInInstance = function()
          return value ~= "none", value
        end,
      }, function()
        result = load_platform().GetInstanceKind()
      end)
      return result
    end
    for _, expected in ipairs({ "none", "pvp", "arena", "party", "raid" }) do
      assert.are.equal(expected, kind(expected))
    end
    assert.are.equal("party", kind("scenario"))
    assert.is_nil(kind(nil))
    with_globals({
      IsInInstance = function()
        error("restricted")
      end,
    }, function()
      assert.is_nil(load_platform().GetInstanceKind())
    end)
    with_globals({ IsInInstance = false }, function()
      assert.is_nil(load_platform().GetInstanceKind())
    end)
  end)
end)

describe("Platform enemy nameplates", function()
  local function cvars(initial)
    local state = { value = initial, writes = {} }
    return state,
      {
        C_CVar = {
          GetCVar = function()
            return state.value
          end,
          SetCVar = function(name, value)
            state.writes[#state.writes + 1] = { name, value }
            state.value = value
          end,
        },
      }
  end

  it("reads the setting", function()
    for value, expected in pairs({ ["1"] = true, ["0"] = false }) do
      local _, api = cvars(value)
      with_globals(api, function()
        assert.are.equal(expected, load_platform().EnemyNameplatesEnabled())
      end)
    end
    local _, api = cvars("maybe")
    with_globals(api, function()
      assert.is_nil(load_platform().EnemyNameplatesEnabled())
    end)
    with_globals({ C_CVar = false, GetCVar = false }, function()
      assert.is_nil(load_platform().EnemyNameplatesEnabled())
    end)
    with_globals({
      C_CVar = {
        GetCVar = function()
          error("restricted")
        end,
      },
    }, function()
      assert.is_nil(load_platform().EnemyNameplatesEnabled())
    end)
  end)

  it("falls back to the global GetCVar", function()
    with_globals({
      C_CVar = false,
      GetCVar = function()
        return "1"
      end,
    }, function()
      assert.is_true(load_platform().EnemyNameplatesEnabled())
    end)
  end)

  it("turns them on outside combat only", function()
    local state, api = cvars("0")
    api.InCombatLockdown = function()
      return false
    end
    with_globals(api, function()
      assert.is_true(load_platform().EnableEnemyNameplates())
    end)
    assert.are.same({ { "nameplateShowEnemies", "1" } }, state.writes)

    local blocked, blockedApi = cvars("0")
    blockedApi.InCombatLockdown = function()
      return true
    end
    with_globals(blockedApi, function()
      assert.is_false(load_platform().EnableEnemyNameplates())
    end)
    assert.are.same({}, blocked.writes)
  end)

  it("says no when the setting cannot be written", function()
    with_globals({
      C_CVar = false,
      SetCVar = false,
      InCombatLockdown = function()
        return false
      end,
    }, function()
      assert.is_false(load_platform().EnableEnemyNameplates())
    end)
    with_globals({
      C_CVar = {
        SetCVar = function()
          error("restricted")
        end,
      },
      InCombatLockdown = function()
        return false
      end,
    }, function()
      assert.is_false(load_platform().EnableEnemyNameplates())
    end)
  end)
end)

describe("Platform.GetContinentMapId", function()
  local maps = {
    [1] = { mapType = 2, parentMapID = 0 },
    [10] = { mapType = 3, parentMapID = 1 },
    [11] = { mapType = 5, parentMapID = 10 },
    [20] = { mapType = 3, parentMapID = 0 },
    [30] = { mapType = 3, parentMapID = 31 },
    [31] = { mapType = 3, parentMapID = 30 },
  }

  local function continent(mapId)
    local result
    with_globals({
      C_Map = {
        GetMapInfo = function(id)
          return maps[id]
        end,
      },
    }, function()
      result = load_platform().GetContinentMapId(mapId)
    end)
    return result
  end

  it("walks the parents up to the continent", function()
    assert.are.equal(1, continent(11))
    assert.are.equal(1, continent(10))
    assert.are.equal(1, continent(1))
  end)

  it("gives nil when there is no continent above, the map is unknown or the parents loop", function()
    assert.is_nil(continent(20))
    assert.is_nil(continent(99))
    assert.is_nil(continent(30))
    assert.is_nil(continent("x"))
  end)

  it("gives nil when the API is missing or raises", function()
    with_globals({ C_Map = false }, function()
      assert.is_nil(load_platform().GetContinentMapId(11))
    end)
    with_globals({
      C_Map = {
        GetMapInfo = function()
          error("restricted")
        end,
      },
    }, function()
      assert.is_nil(load_platform().GetContinentMapId(11))
    end)
  end)
end)

describe("Platform.GroupDistribution", function()
  local function channel(state)
    local result
    with_globals({
      LE_PARTY_CATEGORY_INSTANCE = 2,
      IsInGroup = function(category)
        if category == 2 then
          return state.instance == true
        end
        return state.party == true
      end,
      IsInRaid = function()
        return state.raid == true
      end,
    }, function()
      result = load_platform().GroupDistribution()
    end)
    return result
  end

  it("names the channel of the group the player is in", function()
    assert.are.equal("INSTANCE_CHAT", channel({ instance = true, raid = true, party = true }))
    assert.are.equal("RAID", channel({ raid = true, party = true }))
    assert.are.equal("PARTY", channel({ party = true }))
  end)

  it("gives nil when the player is alone or the client does not say", function()
    assert.is_nil(channel({}))
    with_globals({ IsInGroup = false, IsInRaid = false }, function()
      assert.is_nil(load_platform().GroupDistribution())
    end)
    with_globals({
      IsInGroup = function()
        error("restricted")
      end,
      IsInRaid = false,
    }, function()
      assert.is_nil(load_platform().GroupDistribution())
    end)
  end)
end)

describe("Platform alert and result readers", function()
  it("shows error text in the error area, or says there is none", function()
    local shown
    with_globals({
      UIErrorsFrame = {
        AddMessage = function(_, text)
          shown = text
        end,
      },
    }, function()
      assert.is_true(load_platform().ShowErrorText("Beware"))
      assert.are.equal("Beware", shown)
      assert.is_false(load_platform().ShowErrorText(nil))
    end)
    with_globals({ UIErrorsFrame = false }, function()
      assert.is_false(load_platform().ShowErrorText("Beware"))
    end)
    with_globals({
      UIErrorsFrame = {
        AddMessage = function()
          error("restricted")
        end,
      },
    }, function()
      assert.is_false(load_platform().ShowErrorText("Beware"))
    end)
  end)

  it("plays the sound of an alert kind, with the legacy name when the client has no SOUNDKIT", function()
    local played = {}
    with_globals({
      SOUNDKIT = { RAID_WARNING = 8959 },
      PlaySound = function(id)
        played[#played + 1] = id
      end,
    }, function()
      assert.is_true(load_platform().PlayIntelSound("kos"))
      assert.is_true(load_platform().PlayIntelSound("stealth"))
      assert.is_false(load_platform().PlayIntelSound("nothing"))
    end)
    with_globals({
      SOUNDKIT = false,
      PlaySound = function(id)
        played[#played + 1] = id
      end,
    }, function()
      assert.is_true(load_platform().PlayIntelSound("kosGuild"))
    end)
    assert.are.same({ 8959, "AlarmClockWarning2", "AlarmClockWarning3" }, played)
    with_globals({ PlaySound = false }, function()
      assert.is_false(load_platform().PlayIntelSound("kos"))
    end)
    with_globals({
      PlaySound = function()
        error("no")
      end,
    }, function()
      assert.is_false(load_platform().PlayIntelSound("kos"))
    end)
  end)

  it("reads the unit and the spell id of a cast, and drops what is missing, wrong or secret", function()
    local platform = load_platform()
    assert.are.same({ "nameplate3", 1784 }, { platform.ReadSpellEvent("nameplate3", "guid", 1784) })
    assert.is_nil(platform.ReadSpellEvent(nil, "guid", 1784))
    assert.is_nil(platform.ReadSpellEvent("target", "guid", "1784"))
    assert.is_nil(platform.ReadSpellEvent("", "guid", 1784))
    assert.is_nil(platform.ReadSpellEvent("target", "guid", 1.5))
    assert.is_nil(platform.ReadSpellEvent("target", "guid", 0))
    local hidden = setmetatable({}, {
      __add = function()
        error("secret")
      end,
    })
    assert.is_nil(platform.ReadSpellEvent("target", "guid", hidden))
  end)

  it("sends a chat line and sends nothing during the lockdown", function()
    local sent = {}
    local function send(text, kind, language, target)
      sent[#sent + 1] = { text = text, kind = kind, language = language, target = target }
    end
    with_globals({ SendChatMessage = send, C_ChatInfo = false }, function()
      local platform = load_platform()
      assert.is_true(platform.SendChatLine("GUILD", "hi"))
      assert.is_true(platform.SendChatLine("INSTANCE_CHAT", "hi"))
      assert.is_false(platform.SendChatLine("YELL", "hi"))
      assert.is_false(platform.SendChatLine("GUILD", ""))
      assert.is_false(platform.SendChatLine("GUILD", nil))
    end)
    assert.are.same({ { text = "hi", kind = "GUILD" }, { text = "hi", kind = "INSTANCE_CHAT" } }, sent)
    with_globals({
      SendChatMessage = send,
      C_ChatInfo = {
        InChatMessagingLockdown = function()
          return true
        end,
      },
    }, function()
      assert.is_false(load_platform().SendChatLine("GUILD", "hi"))
    end)
    assert.are.equal(2, #sent)
    with_globals({ SendChatMessage = false }, function()
      assert.is_false(load_platform().SendChatLine("GUILD", "hi"))
    end)
  end)

  it("finds the Local Defense channel by its name, in English or Spanish", function()
    local sent = {}
    local function send(text, kind, language, target)
      sent[#sent + 1] = { text = text, kind = kind, language = language, target = target }
    end
    with_globals({
      SendChatMessage = send,
      GetChannelList = function()
        return 1, "General - Elwynn", false, 4, "DefensaLocal - Elwynn", false
      end,
    }, function()
      assert.is_true(load_platform().SendChatLine("LOCALDEFENSE", "hi"))
    end)
    with_globals({
      SendChatMessage = send,
      GetChannelList = function()
        return 2, "LocalDefense - Elwynn", false
      end,
    }, function()
      assert.is_true(load_platform().SendChatLine("LOCALDEFENSE", "hi"))
    end)
    assert.are.same({ text = "hi", kind = "CHANNEL", target = 4 }, sent[1])
    assert.are.equal(2, sent[2].target)
    with_globals({
      SendChatMessage = send,
      GetChannelList = function()
        return 1, "General - Elwynn", false, "x", 5, true
      end,
    }, function()
      assert.is_false(load_platform().SendChatLine("LOCALDEFENSE", "hi"))
    end)
    with_globals({ SendChatMessage = send, GetChannelList = false }, function()
      assert.is_false(load_platform().SendChatLine("LOCALDEFENSE", "hi"))
    end)
    assert.are.equal(2, #sent)
  end)

  it("names the killer of the death recap, the newest event first", function()
    with_globals({
      DeathRecap_GetEvents = function()
        return {
          { sourceName = "Old-Realm", timestamp = 1 },
          { sourceName = "Newest", timestamp = 9 },
          { sourceName = 5, timestamp = 10 },
          { sourceName = "", timestamp = 11 },
          "junk",
        }
      end,
    }, function()
      assert.are.equal("Newest", load_platform().GetDeathKiller())
    end)
    with_globals({
      DeathRecap_GetEvents = false,
      C_DeathRecap = {
        GetRecapEvents = function()
          return { { sourceName = "First" }, { sourceName = "Second" } }
        end,
      },
    }, function()
      assert.are.equal("Second", load_platform().GetDeathKiller())
    end)
  end)

  it("gives no killer when the recap is missing, empty, wrong or raises", function()
    with_globals({ DeathRecap_GetEvents = false, C_DeathRecap = false }, function()
      assert.is_nil(load_platform().GetDeathKiller())
    end)
    for _, value in ipairs({ "no table", {}, { { sourceName = secret() } } }) do
      with_globals({
        DeathRecap_GetEvents = function()
          return value
        end,
      }, function()
        assert.is_nil(load_platform().GetDeathKiller())
      end)
    end
    with_globals({
      DeathRecap_GetEvents = function()
        error("restricted")
      end,
    }, function()
      assert.is_nil(load_platform().GetDeathKiller())
    end)
  end)

  it("reads the name of a map", function()
    with_globals({
      C_Map = {
        GetMapInfo = function(id)
          return id == 1411 and { name = "Durotar" } or { name = 5 }
        end,
      },
    }, function()
      assert.are.equal("Durotar", load_platform().GetMapName(1411))
      assert.is_nil(load_platform().GetMapName(1))
      assert.is_nil(load_platform().GetMapName("x"))
    end)
    with_globals({ C_Map = false }, function()
      assert.is_nil(load_platform().GetMapName(1411))
    end)
  end)
end)

describe("Platform modifier keys", function()
  it("reads the modifier keys, and false for a key the client cannot read", function()
    with_globals({
      IsShiftKeyDown = function()
        return true
      end,
      IsControlKeyDown = function()
        return false
      end,
      IsAltKeyDown = function()
        error("restricted")
      end,
    }, function()
      assert.are.same({ true, false, false }, { load_platform().ModifierKeys() })
    end)
    with_globals({ IsShiftKeyDown = false, IsControlKeyDown = false, IsAltKeyDown = false }, function()
      assert.are.same({ false, false, false }, { load_platform().ModifierKeys() })
    end)
  end)
end)

describe("Platform world map", function()
  it("knows whether the world map is open", function()
    local platform = load_platform()
    with_globals({
      WorldMapFrame = {
        IsShown = function()
          return true
        end,
      },
    }, function()
      assert.is_true(platform.WorldMapOpen())
    end)
    with_globals({
      WorldMapFrame = {
        IsShown = function()
          return false
        end,
      },
    }, function()
      assert.is_false(platform.WorldMapOpen())
    end)
    with_globals({ WorldMapFrame = false }, function()
      assert.is_false(platform.WorldMapOpen())
    end)
    with_globals({
      WorldMapFrame = {
        IsShown = function()
          error("restricted")
        end,
      },
    }, function()
      assert.is_false(platform.WorldMapOpen())
    end)
  end)

  it("shows a map on the world map only when it is open and the id is a map", function()
    local platform = load_platform()
    local shown = {}
    local frame = {
      open = true,
      current = 1,
      IsShown = function(self)
        return self.open
      end,
      GetMapID = function(self)
        return self.current
      end,
      SetMapID = function(_, id)
        shown[#shown + 1] = id
      end,
    }
    with_globals({ WorldMapFrame = frame }, function()
      assert.is_true(platform.ShowWorldMap(1411))
      assert.are.same({ 1411 }, shown)
      frame.current = 1411
      assert.is_true(platform.ShowWorldMap(1411))
      assert.are.same({ 1411 }, shown)
      assert.is_false(platform.ShowWorldMap("1411"))
      frame.open = false
      assert.is_false(platform.ShowWorldMap(1412))
      assert.are.same({ 1411 }, shown)
      frame.open = true
      frame.SetMapID = function()
        error("busy")
      end
      assert.is_false(platform.ShowWorldMap(1413))
    end)
  end)
end)
