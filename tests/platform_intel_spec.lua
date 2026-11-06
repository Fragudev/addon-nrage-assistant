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
