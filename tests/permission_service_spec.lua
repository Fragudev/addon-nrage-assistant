local function load_service()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/Constants.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Domain/PermissionService.lua"))("NrageAssistant", ns)
  return ns.PermissionService
end

local Service = load_service()

local function roster_with(entries)
  return {
    Lookup = function(_, name) return entries[name] end,
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

  it("denies unknown actions and unknown roles", function()
    assert.is_false(Service.Can("admin", "delete_the_guild"))
    assert.is_false(Service.Can(nil, "view"))
    assert.is_false(Service.Can("superuser", "moderate"))
  end)
end)

describe("PermissionService.OwnRole", function()
  it("derives the own role from the own rank", function()
    local platform = {
      GetOwnGuildRank = function() return "RL" end,
      GetIdentityKey = function() return "Someone-Realm" end,
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
      assert.is_false(Service.Can("rl", action), action)
      assert.is_false(Service.Can("member", action), action)
    end
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
  local Constants = ns.Constants

  local function roster_of(entries)
    return { Lookup = function(_, name) return entries[name] end }
  end

  local function platform_of(rank, identityKey)
    return {
      GetOwnGuildRank = function() return rank end,
      GetIdentityKey = function() return identityKey end,
    }
  end

  it("recognises the listed name, ignoring case, spaces and the realm suffix", function()
    for _, key in ipairs({ "Yonemongg-Realm", "yonemongg", "YONEMONGG-ClassicBetaPvP", "Yonemongg" }) do
      assert.is_true(Service.IsBetaAdmin(key), key)
    end
  end)

  it("does not recognise anyone else", function()
    for _, key in ipairs({ "Yonemon-Realm", "Gg-Realm", "Someone-Realm", "Yonemonggg-Realm", "", "-Realm" }) do
      assert.is_false(Service.IsBetaAdmin(key), key)
    end
    assert.is_false(Service.IsBetaAdmin(nil))
    assert.is_false(Service.IsBetaAdmin(5))
  end)

  it("can be switched off in one place", function()
    Constants.BETA_ADMIN_ENABLED = false
    local recognised = Service.IsBetaAdmin("Yonemongg-Realm")
    local role = Service.RoleOf(roster_of({ ["Yonemongg-Realm"] = { rankName = "member" } }), "Yonemongg-Realm")
    Constants.BETA_ADMIN_ENABLED = true
    assert.is_false(recognised)
    assert.are.equal("member", role)
  end)

  it("makes a guild member on the list an admin whatever their rank", function()
    local roster = roster_of({
      ["Yonemongg-Realm"] = { rankName = "alter" },
      ["Other-Realm"] = { rankName = "alter" },
    })
    assert.are.equal("admin", Service.RoleOf(roster, "Yonemongg-Realm"))
    assert.are.equal("member", Service.RoleOf(roster, "Other-Realm"))
    assert.is_true(Service.Can(Service.RoleOf(roster, "Yonemongg-Realm"), "moderate"))
    assert.is_true(Service.Can(Service.RoleOf(roster, "Yonemongg-Realm"), "loot_award"))
  end)

  it("gives nothing to a listed name the guild roster does not know", function()
    assert.is_nil(Service.RoleOf(roster_of({}), "Yonemongg-Realm"))
  end)

  it("applies to the own role only for someone who is in a guild", function()
    assert.are.equal("admin", Service.OwnRole(platform_of("alter", "Yonemongg-Realm")))
    assert.are.equal("member", Service.OwnRole(platform_of("alter", "Other-Realm")))
    assert.is_nil(Service.OwnRole(platform_of(nil, "Yonemongg-Realm")))
    assert.is_nil(Service.OwnRole(platform_of("", "Yonemongg-Realm")))
  end)
end)
