local function load_service()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/Constants.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Domain/PermissionService.lua"))("NrageAssistant", ns)
  return ns.PermissionService, ns.Constants
end

local Service, ConstantsTable = load_service()

local function roster_with(entries)
  return {
    Lookup = function(_, name)
      return entries[name]
    end,
  }
end

describe("PermissionService.RoleForRank", function()
  it("maps the placeholder ranks", function()
    assert.are.equal("admin", Service.RoleForRank("GM"))
    assert.are.equal("admin", Service.RoleForRank("Officer"))
    assert.are.equal("rl", Service.RoleForRank("RL"))
    for _, rank in ipairs({ "roster", "member", "alter" }) do
      assert.are.equal("member", Service.RoleForRank(rank))
    end
  end)

  it("ignores case", function()
    assert.are.equal("admin", Service.RoleForRank("oFfIcEr"))
  end)

  it("treats a rank nobody mapped as a plain member", function()
    assert.are.equal("member", Service.RoleForRank("Recruit"))
  end)

  it("gives no role when there is no rank name", function()
    assert.is_nil(Service.RoleForRank(nil))
    assert.is_nil(Service.RoleForRank(""))
    assert.is_nil(Service.RoleForRank(5))
  end)

  it("uses a custom mapping when given one", function()
    assert.are.equal("rl", Service.RoleForRank("Captain", { captain = "rl" }))
  end)
end)

describe("PermissionService.RoleOf", function()
  it("reads the sender's role from the local guild roster", function()
    local roster = roster_with({
      ["Boss-Realm"] = { rankName = "Officer" },
      ["Raider-Realm"] = { rankName = "roster" },
    })
    assert.are.equal("admin", Service.RoleOf(roster, "Boss-Realm"))
    assert.are.equal("member", Service.RoleOf(roster, "Raider-Realm"))
  end)

  it("gives no role to someone the roster does not know", function()
    assert.is_nil(Service.RoleOf(roster_with({}), "Stranger-Realm"))
  end)
end)

describe("PermissionService.Can", function()
  it("lets everyone see data and edit their own profile", function()
    for _, role in ipairs({ "member", "rl", "admin" }) do
      assert.is_true(Service.Can(role, "view"))
      assert.is_true(Service.Can(role, "edit_own_profile"))
    end
  end)

  it("keeps event, attendance and assignment management for RL and admin", function()
    for _, action in ipairs({ "manage_events", "record_attendance", "manage_assignments" }) do
      assert.is_false(Service.Can("member", action))
      assert.is_true(Service.Can("rl", action))
      assert.is_true(Service.Can("admin", action))
    end
  end)

  it("keeps moderation for admins only", function()
    assert.is_false(Service.Can("member", "moderate"))
    assert.is_false(Service.Can("rl", "moderate"))
    assert.is_true(Service.Can("admin", "moderate"))
  end)

  it("lets every role publish its own PvP counters", function()
    for _, role in ipairs({ "member", "rl", "council", "admin" }) do
      assert.is_true(Service.Can(role, "pvp_publish"))
    end
    assert.is_false(Service.Can(nil, "pvp_publish"))
  end)

  it("denies unknown actions and unknown roles", function()
    assert.is_false(Service.Can("admin", "delete_the_guild"))
    assert.is_false(Service.Can(nil, "view"))
    assert.is_false(Service.Can("superuser", "moderate"))
  end)
end)

describe("PermissionService.OwnRole", function()
  it("derives the own role from the own rank", function()
    local platform = {
      GetOwnGuildRank = function()
        return "RL"
      end,
      GetIdentityKey = function()
        return "Someone-Realm"
      end,
    }
    assert.are.equal("rl", Service.OwnRole(platform))
  end)
end)

describe("PermissionService council and loot", function()
  it("maps the council rank to the council role", function()
    assert.are.equal("council", Service.RoleForRank("Council"))
  end)

  it("lets the council and admins open sessions, vote and award", function()
    for _, action in ipairs({ "loot_open", "loot_vote", "loot_award" }) do
      assert.is_true(Service.Can("council", action), action)
      assert.is_true(Service.Can("admin", action), action)
      assert.is_false(Service.Can("member", action), action)
    end
  end)

  it("lets a raid leader vote and award but not open sessions", function()
    assert.is_true(Service.Can("rl", "loot_vote"))
    assert.is_true(Service.Can("rl", "loot_award"))
    assert.is_false(Service.Can("rl", "loot_open"))
  end)

  it("lets every role put themselves forward as a candidate", function()
    for _, role in ipairs({ "member", "rl", "council", "admin" }) do
      assert.is_true(Service.Can(role, "loot_apply"), role)
    end
    assert.is_false(Service.Can(nil, "loot_apply"))
  end)

  it("gives the council no event management rights", function()
    for _, action in ipairs({ "manage_events", "record_attendance", "manage_assignments", "moderate" }) do
      assert.is_false(Service.Can("council", action), action)
    end
    assert.is_true(Service.Can("council", "view"))
    assert.is_true(Service.Can("council", "edit_own_profile"))
  end)
end)

describe("PermissionService beta admin exception", function()
  local Constants = ConstantsTable

  local function roster_of(entries)
    return {
      Lookup = function(_, name)
        return entries[name]
      end,
    }
  end

  local function platform_of(rank, identityKey)
    return {
      GetOwnGuildRank = function()
        return rank
      end,
      GetIdentityKey = function()
        return identityKey
      end,
    }
  end

  it("recognises the listed name, ignoring case, spaces and the realm suffix", function()
    for _, key in ipairs({
      "Yonemon Gg",
      "yonemon gg",
      "YONEMON GG-ClassicBetaPvP",
      "Yonemon Gg-Realm", -- the full name
      "Yonemon-Realm",
      "yonemon",
      "YONEMON-ClassicBetaPvP",
      "Yonemon", -- what UnitName gives
    }) do
      assert.is_true(Service.IsBetaAdmin(key), key)
    end
  end)

  it("does not recognise anyone else", function()
    for _, key in ipairs({
      "Yonemon Gh",
      "Yonemon G",
      "Gg-Realm",
      "Someone-Realm",
      "Yonemo-Realm",
      "Other Yonemon Gg",
      "",
      "-Realm",
    }) do
      assert.is_false(Service.IsBetaAdmin(key), key)
    end
    assert.is_false(Service.IsBetaAdmin(nil))
    assert.is_false(Service.IsBetaAdmin(5))
  end)

  it("can be switched off in one place", function()
    Constants.BETA_ADMIN_ENABLED = false
    local recognised = Service.IsBetaAdmin("Yonemon-Realm")
    local role = Service.RoleOf(roster_of({ ["Yonemon-Realm"] = { rankName = "member" } }), "Yonemon-Realm")
    Constants.BETA_ADMIN_ENABLED = true
    assert.is_false(recognised)
    assert.are.equal("member", role)
  end)

  it("makes a guild member on the list an admin whatever their rank", function()
    local roster = roster_of({
      ["Yonemon-Realm"] = { rankName = "alter" },
      ["Other-Realm"] = { rankName = "alter" },
    })
    assert.are.equal("admin", Service.RoleOf(roster, "Yonemon-Realm"))
    assert.are.equal("member", Service.RoleOf(roster, "Other-Realm"))
    assert.is_true(Service.Can(Service.RoleOf(roster, "Yonemon-Realm"), "moderate"))
    assert.is_true(Service.Can(Service.RoleOf(roster, "Yonemon-Realm"), "loot_award"))
  end)

  it("finds the full name in the roster, as the client writes it, and makes it admin", function()
    local roster = roster_of({
      ["Yonemon Gg"] = { rankName = "Soldado" },
      ["Black Coffee"] = { rankName = "Soldado" },
    })
    assert.are.equal("admin", Service.RoleOf(roster, "Yonemon Gg"))
    assert.are.equal("member", Service.RoleOf(roster, "Black Coffee"))
  end)

  it("gives nothing to a listed name the guild roster does not know", function()
    assert.is_nil(Service.RoleOf(roster_of({}), "Yonemon-Realm"))
  end)

  it("applies to the own role only for someone who is in a guild", function()
    assert.are.equal("admin", Service.OwnRole(platform_of("alter", "Yonemon Gg")))
    assert.are.equal("admin", Service.OwnRole(platform_of("alter", "Yonemon-Realm")))
    assert.are.equal("member", Service.OwnRole(platform_of("alter", "Other-Realm")))
    assert.is_nil(Service.OwnRole(platform_of(nil, "Yonemon-Realm")))
    assert.is_nil(Service.OwnRole(platform_of("", "Yonemon-Realm")))
  end)
end)
