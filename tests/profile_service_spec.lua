local function load_service()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/Constants.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Core/Locale.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Domain/ProfileService.lua"))("NrageAssistant", ns)
  return ns.ProfileService, ns.Constants
end

local function fake_platform(overrides)
  local p = {
    ServerTime = function()
      return 1000
    end,
    GetIdentityKey = function()
      return "Nrager-ClassicBetaPvP"
    end,
    GetGUID = function()
      return "Player-1-ABC"
    end,
    GetClass = function()
      return "WARRIOR"
    end,
    GetLevel = function()
      return 60
    end,
    GetAverageItemLevel = function()
      return 200
    end,
    GetProfessions = function()
      return { { name = "Mining", skill = 300, max = 300 } }
    end,
    GetEquippedEnchants = function()
      return { [16] = 100, [5] = 0 }
    end,
    GetActiveBuffs = function()
      return { { name = "Well Fed", spellId = 18125 } }
    end,
  }
  for k, v in pairs(overrides or {}) do
    p[k] = v
  end
  return p
end

describe("ProfileService.Refresh", function()
  it("observes enchants and buffs, and describes them with their source", function()
    local ProfileService = load_service()
    local profile = {}
    ProfileService.Refresh(fake_platform(), profile)
    assert.are.equal(100, profile.enchants[16])
    assert.are.equal("observed", profile.provenance.enchants.source)
    assert.are.equal("Well Fed", profile.buffs[1].name)
    local text = table.concat(ProfileService.Describe(profile), "\n")
    assert.is_truthy(text:find("Enchants: 1 of 2 equipped items [verified]", 1, true))
    assert.is_truthy(text:find("Active buffs: 1 [verified]", 1, true))
  end)

  local ProfileService = load_service()

  it("stores observed values with their provenance", function()
    local profile = {}
    ProfileService.Refresh(fake_platform(), profile)
    assert.are.equal("Nrager-ClassicBetaPvP", profile.identityKey)
    assert.are.equal("WARRIOR", profile.class)
    assert.are.equal(60, profile.level)
    assert.are.equal(200, profile.ilvl)
    assert.are.same({ source = "observed", at = 1000 }, profile.provenance.level)
    assert.are.equal("Mining", profile.professions[1].name)
  end)

  it("keeps a value unknown when the API cannot provide it", function()
    local profile = {}
    ProfileService.Refresh(
      fake_platform({
        GetAverageItemLevel = function()
          return nil
        end,
        GetProfessions = function()
          return {}
        end,
      }),
      profile
    )
    assert.is_nil(profile.ilvl)
    assert.is_nil(profile.provenance.ilvl)
    assert.is_nil(profile.professions)
    assert.is_nil(profile.provenance.professions)
  end)

  it("drops a stale observed value once the API stops providing it", function()
    local profile = {}
    ProfileService.Refresh(fake_platform(), profile)
    ProfileService.Refresh(
      fake_platform({
        GetAverageItemLevel = function()
          return nil
        end,
      }),
      profile
    )
    assert.is_nil(profile.ilvl)
    assert.is_nil(profile.provenance.ilvl)
  end)

  it("does not touch manual fields", function()
    local profile = {}
    ProfileService.Refresh(fake_platform(), profile)
    ProfileService.SetField(fake_platform(), profile, "role", "Tank")
    ProfileService.Refresh(fake_platform(), profile)
    assert.are.equal("Tank", profile.fields.role.value)
  end)
end)

describe("ProfileService.SetField", function()
  local ProfileService, Constants = load_service()

  it("declares a manual field with source and time", function()
    local profile = {}
    assert.is_true(ProfileService.SetField(fake_platform(), profile, "main", "  Alt  "))
    assert.are.same({ value = "Alt", source = "declared", at = 1000 }, profile.fields.main)
  end)

  it("accepts a second spec with the same allowed roles", function()
    local profile = {}
    assert.is_true(ProfileService.SetField(fake_platform(), profile, "role2", "Dps"))
    assert.are.equal("Dps", profile.fields.role2.value)
    assert.is_false(ProfileService.SetField(fake_platform(), profile, "role2", "wizard"))
  end)

  it("accepts only Tank, Dps and Heal as the role", function()
    for _, role in ipairs({ "Tank", "Dps", "Heal" }) do
      local profile = {}
      assert.is_true(ProfileService.SetField(fake_platform(), profile, "role", role))
      assert.are.equal(role, profile.fields.role.value)
    end
    local profile = {}
    local ok, reason = ProfileService.SetField(fake_platform(), profile, "role", "wizard")
    assert.is_false(ok)
    assert.are.equal("invalid_value", reason)
    assert.is_nil(profile.fields)
  end)

  it("maps unambiguous legacy role spellings to the allowed roles", function()
    assert.are.equal("Heal", ProfileService.NormalizeRole("  healer "))
    assert.are.equal("Tank", ProfileService.NormalizeRole("tank"))
    assert.are.equal("Dps", ProfileService.NormalizeRole("DPS"))
    assert.is_nil(ProfileService.NormalizeRole("wizard"))
    assert.is_nil(ProfileService.NormalizeRole(nil))
  end)

  it("clears a field when the value is empty", function()
    local profile = {}
    ProfileService.SetField(fake_platform(), profile, "main", "Other")
    assert.is_true(ProfileService.SetField(fake_platform(), profile, "main", "   "))
    assert.is_nil(profile.fields.main)
  end)

  it("rejects unknown fields, non-strings and oversized values", function()
    local profile = {}
    local ok, reason = ProfileService.SetField(fake_platform(), profile, "level", "80")
    assert.is_false(ok)
    assert.are.equal("unknown_field", reason)

    ok, reason = ProfileService.SetField(fake_platform(), profile, "role", 5)
    assert.is_false(ok)
    assert.are.equal("invalid_value", reason)

    ok, reason = ProfileService.SetField(fake_platform(), profile, "notes", ("x"):rep(Constants.MAX_FIELD_LENGTH + 1))
    assert.is_false(ok)
    assert.are.equal("too_long", reason)
    assert.is_nil(profile.fields)
  end)
end)

describe("ProfileService.Describe", function()
  local ProfileService = load_service()

  it("labels each value with its source", function()
    local profile = {}
    ProfileService.Refresh(fake_platform(), profile)
    ProfileService.SetField(fake_platform(), profile, "role", "Tank")
    local text = table.concat(ProfileService.Describe(profile), "\n")
    assert.is_truthy(text:find("Level: 60 [verified]", 1, true))
    assert.is_truthy(text:find("Professions: Mining (300) [verified]", 1, true))
    assert.is_truthy(text:find("role: Tank [declared]", 1, true))
  end)

  it("shows unknown instead of guessing", function()
    local text = table.concat(ProfileService.Describe({}), "\n")
    assert.is_truthy(text:find("Level: unknown", 1, true))
    assert.is_truthy(text:find("Item level: unknown", 1, true))
    assert.is_truthy(text:find("Professions: unknown", 1, true))
  end)
end)
