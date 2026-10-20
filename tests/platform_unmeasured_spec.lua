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
