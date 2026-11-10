-- The client APIs of the redesign that are not measured on Forever yet (docs/API_NOTES.md, P0). Every one of them is
-- behind pcall and an availability check, so a missing or restricted API degrades to "not available".
local function load_platform()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/Platform.lua"))("NrageAssistant", ns)
  return ns.Platform
end

-- Runs `fn` with some client globals replaced (false removes one), then puts them back.
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

describe("Platform guild leader and rank index", function()
  it("returns the rank name and the rank index of the own character", function()
    with_globals({
      GetGuildInfo = function()
        return "Nrage", "Guild Master", 0
      end,
    }, function()
      local name, index = load_platform().GetOwnGuildRank()
      assert.are.equal("Guild Master", name)
      assert.are.equal(0, index)
    end)
  end)

  it("gives no index when the client does not return a number", function()
    with_globals({
      GetGuildInfo = function()
        return "Nrage", "Soldado"
      end,
    }, function()
      local name, index = load_platform().GetOwnGuildRank()
      assert.are.equal("Soldado", name)
      assert.is_nil(index)
    end)
  end)

  it("reads IsGuildLeader only when it exists and answers a boolean", function()
    with_globals({ IsGuildLeader = false }, function()
      assert.is_nil(load_platform().IsGuildLeader())
    end)
    with_globals({
      IsGuildLeader = function()
        return true
      end,
    }, function()
      assert.is_true(load_platform().IsGuildLeader())
    end)
    with_globals({
      IsGuildLeader = function()
        return "yes"
      end,
    }, function()
      assert.is_nil(load_platform().IsGuildLeader())
    end)
    with_globals({
      IsGuildLeader = function()
        error("restricted")
      end,
    }, function()
      assert.is_nil(load_platform().IsGuildLeader())
    end)
  end)

  it("leaves the online flag out of a roster row when the client gives no boolean", function()
    with_globals({
      GetGuildRosterInfo = function()
        return "Ann", "Soldado", 3, 60, "Warrior", "Zone", "", "", "yes", 0, "WARRIOR", 0, 0, false, false, 0, "G"
      end,
    }, function()
      assert.is_nil(load_platform().GetGuildRosterEntry(1).online)
    end)
  end)
end)

describe("Platform.GetProfessions", function()
  it("marks the slots after the two primary ones as secondary and survives an error", function()
    with_globals({
      GetProfessions = function()
        return 1, nil, 3, 4
      end,
      GetProfessionInfo = function(index)
        -- Prof3 comes with no icon, Prof4 with an unusable one.
        local icon = ({ [1] = 136240, [4] = {} })[index]
        return "Prof" .. index, icon, index * 10, 300
      end,
    }, function()
      assert.are.same({
        { name = "Prof1", icon = 136240, skill = 10, max = 300 },
        { name = "Prof3", skill = 30, max = 300, secondary = true },
        { name = "Prof4", skill = 40, max = 300, secondary = true },
      }, load_platform().GetProfessions())
    end)
    with_globals({
      GetProfessions = function()
        error("restricted")
      end,
      GetProfessionInfo = function() end,
    }, function()
      assert.are.same({}, load_platform().GetProfessions())
    end)
  end)

  it("remembers the icon by profession name, for a profile received from a member", function()
    with_globals({
      GetProfessions = function()
        return 1
      end,
      GetProfessionInfo = function()
        return "Alchemy", 136240, 10, 300
      end,
    }, function()
      local platform = load_platform()
      assert.is_nil(platform.ProfessionIcon("Alchemy"))
      platform.GetProfessions()
      assert.are.equal(136240, platform.ProfessionIcon("Alchemy"))
      assert.is_nil(platform.ProfessionIcon("Mining"))
    end)
  end)
end)

describe("Platform group names", function()
  it("reports whether the group API exists", function()
    with_globals(
      { IsInGroup = false, IsInRaid = false, GetNumGroupMembers = false, GetRaidRosterInfo = false },
      function()
        assert.is_false(load_platform().GroupApiAvailable())
      end
    )
    assert.is_true(load_platform().GroupApiAvailable())
  end)

  it("lists the player once, with the party", function()
    with_globals({
      IsInGroup = function()
        return true
      end,
      IsInRaid = function()
        return false
      end,
      UnitName = function(unit)
        return unit == "party1" and "Ann" or (unit == "party2" and "Bob" or nil)
      end,
      GetNormalizedRealmName = function()
        return "Realm"
      end,
    }, function()
      local platform = load_platform()
      platform.SetCanonicalName("Me")
      assert.are.same({ "Ann", "Bob", "Me" }, platform.GetFullGroupNames())
    end)
  end)

  it("is empty when not grouped", function()
    assert.are.same({}, load_platform().GetFullGroupNames())
  end)
end)

describe("Platform recipes", function()
  local function api(overrides)
    local tradeskill = {
      GetBaseProfessionInfo = function()
        return { professionID = 171, professionName = "Alchemy" }
      end,
      GetAllRecipeIDs = function()
        return { 10, 11, 12 }
      end,
      GetRecipeInfo = function(id)
        return { learned = id ~= 11, name = "Recipe " .. id, icon = id * 100 }
      end,
    }
    for key, value in pairs(overrides or {}) do
      tradeskill[key] = value
    end
    return tradeskill
  end

  it("is unavailable without the profession API", function()
    with_globals({ C_TradeSkillUI = false }, function()
      local platform = load_platform()
      assert.is_false(platform.RecipeScanAvailable())
      local scanned, reason = platform.ScanKnownRecipes()
      assert.is_nil(scanned)
      assert.are.equal("unavailable", reason)
    end)
  end)

  it("scans only the learned recipes of the open profession", function()
    with_globals({ C_TradeSkillUI = api() }, function()
      local scanned = load_platform().ScanKnownRecipes()
      assert.are.same({ professionId = 171, professionName = "Alchemy", ids = { 10, 12 } }, scanned)
    end)
  end)

  it("never scans a linked profession or an NPC crafter", function()
    for _, check in ipairs({ "IsTradeSkillLinked", "IsTradeSkillGuild", "IsNPCCrafting" }) do
      with_globals({
        C_TradeSkillUI = api({
          [check] = function()
            return true
          end,
        }),
      }, function()
        local scanned, reason = load_platform().ScanKnownRecipes()
        assert.is_nil(scanned)
        assert.are.equal("linked", reason)
      end)
    end
  end)

  it("says the window is not open, or that the data is unreadable", function()
    with_globals({
      C_TradeSkillUI = api({
        GetBaseProfessionInfo = function()
          return { professionID = 0 }
        end,
      }),
    }, function()
      local _, reason = load_platform().ScanKnownRecipes()
      assert.are.equal("not_open", reason)
    end)
    with_globals({
      C_TradeSkillUI = api({
        GetAllRecipeIDs = function()
          error("secret")
        end,
      }),
    }, function()
      local _, reason = load_platform().ScanKnownRecipes()
      assert.are.equal("unreadable", reason)
    end)
  end)

  it("describes a recipe from the profession API, then from the spell", function()
    with_globals({
      C_TradeSkillUI = api({
        GetRecipeOutputItemData = function()
          return { hyperlink = "|Hitem:1|h[Potion]|h" }
        end,
      }),
    }, function()
      assert.are.same(
        { name = "Recipe 10", icon = 1000, link = "|Hitem:1|h[Potion]|h" },
        load_platform().GetRecipeInfo(10)
      )
    end)
    with_globals({
      C_TradeSkillUI = api({
        GetRecipeInfo = function()
          return nil
        end,
      }),
      C_Spell = {
        GetSpellInfo = function(id)
          return { name = "Spell " .. id, iconID = 5 }
        end,
      },
    }, function()
      assert.are.same({ name = "Spell 10", icon = 5 }, load_platform().GetRecipeInfo(10))
    end)
    with_globals({
      C_TradeSkillUI = false,
      C_Spell = false,
      GetSpellInfo = function(id)
        return "Old " .. id, nil, 7
      end,
    }, function()
      assert.are.same({ name = "Old 10", icon = 7 }, load_platform().GetRecipeInfo(10))
    end)
    assert.is_nil(load_platform().GetRecipeInfo("x"))
  end)
end)

describe("Platform chat prefill and loot window", function()
  it("opens the chat box through whichever call exists and never raises", function()
    local typed
    with_globals({
      ChatFrameUtil = false,
      ChatFrame_OpenChat = function(text)
        typed = text
      end,
    }, function()
      local platform = load_platform()
      assert.is_true(platform.CanPrefillChat())
      assert.is_true(platform.PrefillChat("/w Ann hi"))
      assert.are.equal("/w Ann hi", typed)
      assert.is_false(platform.PrefillChat(5))
    end)
    with_globals({
      ChatFrameUtil = {
        OpenChat = function()
          error("restricted")
        end,
      },
    }, function()
      assert.is_false(load_platform().PrefillChat("x"))
    end)
    with_globals({ ChatFrameUtil = false, ChatFrame_OpenChat = false }, function()
      local platform = load_platform()
      assert.is_false(platform.CanPrefillChat())
      assert.is_false(platform.PrefillChat("x"))
    end)
  end)

  it("lists the readable item slots of the loot window", function()
    with_globals({
      GetNumLootItems = function()
        return 3
      end,
      GetLootSlotLink = function(slot)
        return slot == 2 and "gold" or ("|Hitem:" .. slot .. "|h[Item " .. slot .. "]|h")
      end,
      GetLootSlotInfo = function(slot)
        return "icon" .. slot, "Item " .. slot
      end,
    }, function()
      local platform = load_platform()
      assert.is_true(platform.LootWindowAvailable())
      assert.are.same({
        { slot = 1, link = "|Hitem:1|h[Item 1]|h", name = "Item 1", icon = "icon1" },
        { slot = 3, link = "|Hitem:3|h[Item 3]|h", name = "Item 3", icon = "icon3" },
      }, platform.GetLootWindowItems())
    end)
    with_globals({ GetNumLootItems = false, GetLootSlotLink = false }, function()
      local platform = load_platform()
      assert.is_false(platform.LootWindowAvailable())
      assert.is_nil(platform.GetLootWindowItems())
    end)
    with_globals({
      GetNumLootItems = function()
        error("secret")
      end,
      GetLootSlotLink = function() end,
    }, function()
      assert.is_nil(load_platform().GetLootWindowItems())
    end)
  end)
end)

describe("Platform PvP mission readers", function()
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
    })
  end

  it("reads the map id of the player and gives nil for anything else", function()
    with_globals({
      C_Map = {
        GetBestMapForUnit = function()
          return 1411
        end,
      },
    }, function()
      assert.are.equal(1411, load_platform().GetPlayerMapId())
    end)
    for _, value in ipairs({ "x", 0, -3, 1.5 }) do
      with_globals({
        C_Map = {
          GetBestMapForUnit = function()
            return value
          end,
        },
      }, function()
        assert.is_nil(load_platform().GetPlayerMapId())
      end)
    end
    with_globals({
      C_Map = {
        GetBestMapForUnit = function()
          return secret()
        end,
      },
    }, function()
      assert.is_nil(load_platform().GetPlayerMapId())
    end)
    with_globals({
      C_Map = {
        GetBestMapForUnit = function()
          error("restricted")
        end,
      },
    }, function()
      assert.is_nil(load_platform().GetPlayerMapId())
    end)
    with_globals({ C_Map = false }, function()
      assert.is_nil(load_platform().GetPlayerMapId())
    end)
  end)

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
        return "Guerrero", units[unit] and units[unit].class
      end,
      UnitRace = function(unit)
        return "No-muerto", units[unit] and units[unit].race
      end,
    }
  end

  it("reads name, class and race of an enemy player as upper-case file tokens", function()
    with_globals(
      unit_api({
        target = { player = true, enemy = true, name = "Zed Gg", class = "WARRIOR", race = "Scourge" },
      }),
      function()
        local info = load_platform().GetEnemyPlayerInfo("target")
        assert.are.same({ name = "Zed Gg", class = "WARRIOR", race = "SCOURGE" }, info)
      end
    )
  end)

  it("keeps what is readable when only the class or only the race is", function()
    with_globals(
      unit_api({
        target = { player = true, enemy = true, name = "Zed", class = "MAGE", race = secret() },
        mouseover = { player = true, enemy = true, name = "Yan", class = "?1", race = "Orc" },
      }),
      function()
        local platform = load_platform()
        assert.are.same({ name = "Zed", class = "MAGE" }, platform.GetEnemyPlayerInfo("target"))
        assert.are.same({ name = "Yan", race = "ORC" }, platform.GetEnemyPlayerInfo("mouseover"))
      end
    )
  end)

  it("ignores friendly units, non players, unreadable names and secret answers", function()
    with_globals(
      unit_api({
        target = { player = true, enemy = false, name = "Ann", class = "MAGE", race = "Orc" },
        mouseover = { player = false, enemy = true, name = "Boar", class = "MAGE", race = "Orc" },
        nameplate1 = { player = true, enemy = true, name = secret(), class = "MAGE", race = "Orc" },
        nameplate2 = { player = true, enemy = true, name = "Bob", class = secret(), race = secret() },
        nameplate3 = { player = secret(), enemy = true, name = "Cat", class = "MAGE", race = "Orc" },
      }),
      function()
        local platform = load_platform()
        for _, unit in ipairs({ "target", "mouseover", "nameplate1", "nameplate2", "nameplate3", "nameplate9" }) do
          assert.is_nil(platform.GetEnemyPlayerInfo(unit), unit)
        end
        assert.is_nil(platform.GetEnemyPlayerInfo(nil))
      end
    )
  end)

  it("gives nil when the unit API is missing or raises", function()
    with_globals({ UnitIsPlayer = false }, function()
      assert.is_nil(load_platform().GetEnemyPlayerInfo("target"))
    end)
    local api = unit_api({})
    api.UnitIsPlayer = function()
      error("restricted")
    end
    with_globals(api, function()
      assert.is_nil(load_platform().GetEnemyPlayerInfo("target"))
    end)
  end)

  it("falls back to UnitName when GetUnitName does not exist", function()
    local api = unit_api({ target = { player = true, enemy = true, class = "MAGE", race = "Orc" } })
    api.GetUnitName = false
    api.UnitName = function()
      return "Zed"
    end
    with_globals(api, function()
      assert.are.equal("Zed", load_platform().GetEnemyPlayerInfo("target").name)
    end)
  end)

  it("names the winner of a battleground only when it is decided", function()
    local function winner(value)
      local result
      with_globals({
        GetBattlefieldWinner = function()
          return value
        end,
      }, function()
        result = load_platform().GetBattlegroundWinner()
      end)
      return result
    end
    assert.are.equal("Alliance", winner(1))
    assert.are.equal("Horde", winner(0))
    assert.is_nil(winner(nil))
    assert.is_nil(winner(255))
    assert.is_nil(winner(secret()))
    with_globals({ GetBattlefieldWinner = false }, function()
      assert.is_false(load_platform().HasBattlegroundWinner())
      assert.is_nil(load_platform().GetBattlegroundWinner())
    end)
    with_globals({
      GetBattlefieldWinner = function()
        error("restricted")
      end,
    }, function()
      assert.is_true(load_platform().HasBattlegroundWinner())
      assert.is_nil(load_platform().GetBattlegroundWinner())
    end)
  end)

  it("reads the map id of the battleground instance, only inside a battleground", function()
    local function instance(kind, mapId)
      local result
      with_globals({
        IsInInstance = function()
          return true, kind
        end,
        GetInstanceInfo = function()
          return "Warsong Gulch", kind, 1, "", 10, 0, false, mapId
        end,
      }, function()
        result = load_platform().GetBattlegroundInstance()
      end)
      return result
    end
    assert.are.equal(489, instance("pvp", 489))
    assert.is_nil(instance("party", 489))
    assert.is_nil(instance("pvp", nil))
    assert.is_nil(instance("pvp", 0))
    assert.is_nil(instance("pvp", "489"))
    with_globals({ IsInInstance = false }, function()
      assert.is_nil(load_platform().GetBattlegroundInstance())
    end)
    with_globals({
      IsInInstance = function()
        error("restricted")
      end,
      GetInstanceInfo = function() end,
    }, function()
      assert.is_nil(load_platform().GetBattlegroundInstance())
    end)
  end)

  it("requests the battleground score only when the client has the call", function()
    local calls = 0
    with_globals({
      RequestBattlefieldScoreData = function()
        calls = calls + 1
      end,
    }, function()
      assert.is_true(load_platform().RequestBattlegroundScore())
    end)
    assert.are.equal(1, calls)
    with_globals({ RequestBattlefieldScoreData = false }, function()
      assert.is_false(load_platform().RequestBattlegroundScore())
    end)
    with_globals({
      RequestBattlefieldScoreData = function()
        error("restricted")
      end,
    }, function()
      assert.is_false(load_platform().RequestBattlegroundScore())
    end)
  end)

  it("reads the faction of the player", function()
    for faction, expected in pairs({ Alliance = "Alliance", Horde = "Horde", Neutral = false }) do
      with_globals({
        UnitFactionGroup = function()
          return faction
        end,
      }, function()
        assert.are.equal(expected or nil, load_platform().GetPlayerFaction())
      end)
    end
    with_globals({ UnitFactionGroup = false }, function()
      assert.is_nil(load_platform().GetPlayerFaction())
    end)
    with_globals({
      UnitFactionGroup = function()
        return secret()
      end,
    }, function()
      assert.is_nil(load_platform().GetPlayerFaction())
    end)
  end)
end)

describe("Platform.PlayerMapPosition", function()
  local function map_api(map, x, y)
    return {
      GetBestMapForUnit = function()
        return map
      end,
      GetPlayerMapPosition = function()
        return {
          GetXY = function()
            return x, y
          end,
        }
      end,
    }
  end

  it("gives the map and the zone coordinates in the open world", function()
    with_globals({ C_Map = map_api(1411, 0.25, 0.75) }, function()
      assert.are.same({ map = 1411, x = 0.25, y = 0.75 }, load_platform().PlayerMapPosition())
    end)
  end)

  it("gives nothing inside an instance", function()
    with_globals({
      C_Map = map_api(1411, 0.25, 0.75),
      IsInInstance = function()
        return true, "party"
      end,
    }, function()
      assert.is_nil(load_platform().PlayerMapPosition())
    end)
  end)

  it("gives nothing when the API is missing or either call has no usable answer", function()
    with_globals({ C_Map = false }, function()
      assert.is_nil(load_platform().PlayerMapPosition())
    end)
    for _, api in ipairs({
      map_api(nil, 0.5, 0.5),
      map_api(0, 0.5, 0.5),
      map_api("1", 0.5, 0.5),
      map_api(1, nil, 0.5),
      map_api(1, 0.5, "0.5"),
      map_api(1, 1.5, 0.5),
      map_api(1, 0.5, -0.1),
    }) do
      with_globals({ C_Map = api }, function()
        assert.is_nil(load_platform().PlayerMapPosition())
      end)
    end
    with_globals({
      C_Map = {
        GetBestMapForUnit = function()
          return 1
        end,
        GetPlayerMapPosition = function() end,
      },
    }, function()
      assert.is_nil(load_platform().PlayerMapPosition())
    end)
    with_globals({
      C_Map = {
        GetBestMapForUnit = function()
          return 1
        end,
        GetPlayerMapPosition = function()
          return {}
        end,
      },
    }, function()
      assert.is_nil(load_platform().PlayerMapPosition())
    end)
  end)

  it("gives nothing on an error or a secret value", function()
    with_globals({
      C_Map = {
        GetBestMapForUnit = function()
          error("secret value")
        end,
        GetPlayerMapPosition = function() end,
      },
    }, function()
      assert.is_nil(load_platform().PlayerMapPosition())
    end)
  end)
end)

describe("Platform.IsGroupMember", function()
  it("is true for a party member or a raid member", function()
    with_globals({
      UnitInParty = function(name)
        return name == "Ann"
      end,
      UnitInRaid = function(name)
        return name == "Bob" and 3 or nil
      end,
    }, function()
      local platform = load_platform()
      assert.is_true(platform.IsGroupMember("Ann"))
      assert.is_true(platform.IsGroupMember("Bob"))
      assert.is_false(platform.IsGroupMember("Cid"))
    end)
  end)

  it("is false for a bad name, a missing API or an error", function()
    local platform = load_platform()
    assert.is_false(platform.IsGroupMember(nil))
    assert.is_false(platform.IsGroupMember(""))
    with_globals({ UnitInParty = false, UnitInRaid = false }, function()
      assert.is_false(platform.IsGroupMember("Ann"))
    end)
    with_globals({
      UnitInParty = function()
        error("restricted")
      end,
    }, function()
      assert.is_false(platform.IsGroupMember("Ann"))
    end)
  end)
end)
