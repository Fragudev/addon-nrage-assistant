local function load_service()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/Constants.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Core/Validate.lua"))("NrageAssistant", ns)
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

describe("PermissionService.RoleOf with the rank as the source", function()
  local options = { source = "rank" }

  it("reads the sender's role from the rank in the local guild roster", function()
    local roster = roster_with({
      ["Boss-Realm"] = { rankName = "Officer" },
      ["Raider-Realm"] = { rankName = "roster" },
    })
    assert.are.equal("admin", Service.RoleOf(roster, "Boss-Realm", options))
    assert.are.equal("member", Service.RoleOf(roster, "Raider-Realm", options))
  end)

  it("gives no role to someone the roster does not know", function()
    assert.is_nil(Service.RoleOf(roster_with({}), "Stranger-Realm", options))
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

  it("lets every role add to the blacklist but only an admin remove from it", function()
    for _, role in ipairs({ "member", "rl", "council", "admin" }) do
      assert.is_true(Service.Can(role, "blacklist_add"), role)
    end
    assert.is_false(Service.Can(nil, "blacklist_add"))
    assert.is_true(Service.Can("admin", "blacklist_remove"))
    for _, role in ipairs({ "member", "rl", "council" }) do
      assert.is_false(Service.Can(role, "blacklist_remove"), role)
    end
    assert.is_false(Service.Can(nil, "blacklist_remove"))
  end)

  it("denies unknown actions and unknown roles", function()
    assert.is_false(Service.Can("admin", "delete_the_guild"))
    assert.is_false(Service.Can(nil, "view"))
    assert.is_false(Service.Can("superuser", "moderate"))
  end)
end)

describe("PermissionService.OwnRole with the rank as the source", function()
  it("derives the own role from the own rank", function()
    local platform = {
      GetOwnGuildRank = function()
        return "RL"
      end,
      GetIdentityKey = function()
        return "Someone-Realm"
      end,
    }
    assert.are.equal("rl", Service.OwnRole(platform, { source = "rank" }))
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

describe("PermissionService with assigned roles (the default)", function()
  local function platform_of(rank, index, key, leader)
    return {
      GetOwnGuildRank = function()
        return rank, index
      end,
      GetIdentityKey = function()
        return key
      end,
      IsGuildLeader = leader and function()
        return leader == true
      end or nil,
    }
  end

  it("is the default, with the beta admin list gone", function()
    assert.are.equal("assigned", ConstantsTable.ROLE_SOURCE)
    assert.is_false(ConstantsTable.BETA_ADMIN_ENABLED)
    assert.is_nil(ConstantsTable.BETA_ADMIN_NAMES)
    assert.is_nil(Service.IsBetaAdmin)
  end)

  describe("RoleOf", function()
    local roster = roster_with({
      ["Boss-Realm"] = { rankName = "Maestro", rankIndex = 0 },
      ["Officer-Realm"] = { rankName = "officer", rankIndex = 1 },
      ["Leader-Realm"] = { rankName = "Raider", rankIndex = 4 },
      ["Plain-Realm"] = { rankName = "Raider", rankIndex = 4 },
      ["Yonemon Gg"] = { rankName = "Raider", rankIndex = 4 },
    })
    local members = {
      ["Leader-Realm"] = { role = "rl", rosterId = "r1" },
      ["Officer-Realm"] = { role = "council" },
      ["Boss-Realm"] = { role = "member" },
    }

    it("makes the guild master, by rank index 0, the admin whatever the rank is called", function()
      assert.are.equal("admin", Service.RoleOf(roster, "Boss-Realm", { members = members }))
    end)

    it("does not let an assignment take the guild master's admin away", function()
      assert.are.equal(
        "admin",
        Service.RoleOf(roster, "Boss-Realm", { members = { ["Boss-Realm"] = { role = "rl" } } })
      )
    end)

    it("gives every other rank the assigned role, or member: an officer is not an admin", function()
      assert.are.equal("rl", Service.RoleOf(roster, "Leader-Realm", { members = members }))
      assert.are.equal("council", Service.RoleOf(roster, "Officer-Realm", { members = members }))
      assert.are.equal("member", Service.RoleOf(roster, "Plain-Realm", { members = members }))
      assert.are.equal("member", Service.RoleOf(roster, "Plain-Realm", { members = {} }))
    end)

    it("ignores the rank name for everybody but the guild master", function()
      local ranked = roster_with({
        ["A-Realm"] = { rankName = "GM", rankIndex = 2 },
        ["B-Realm"] = { rankName = "rl", rankIndex = 3 },
      })
      assert.are.equal("member", Service.RoleOf(ranked, "A-Realm", { members = {} }))
      assert.are.equal("member", Service.RoleOf(ranked, "B-Realm", { members = {} }))
    end)

    it("never turns an assignment into admin, nor accepts a role it does not know", function()
      for _, role in ipairs({ "admin", "root", 5 }) do
        local forged = { ["Plain-Realm"] = { role = role } }
        assert.are.equal("member", Service.RoleOf(roster, "Plain-Realm", { members = forged }), tostring(role))
      end
      assert.is_nil(Service.AssignedRole({ x = { role = "admin" } }, "x"))
      assert.are.equal("rl", Service.AssignedRole({ x = { role = "rl" } }, "x"))
      assert.is_nil(Service.AssignedRole(nil, "x"))
    end)

    it("is not fooled by a name: a multi-word name is just a member unless assigned", function()
      assert.are.equal("member", Service.RoleOf(roster, "Yonemon Gg", { members = members }))
    end)

    it("gives no role to someone the roster does not know, even with an assignment", function()
      assert.is_nil(Service.RoleOf(roster, "Ghost-Realm", { members = { ["Ghost-Realm"] = { role = "rl" } } }))
    end)

    it("reads the configured assignments when none are passed", function()
      Service.Configure({ members = members })
      assert.are.equal("rl", Service.RoleOf(roster, "Leader-Realm"))
      Service.Configure({ members = {} })
      assert.are.equal("member", Service.RoleOf(roster, "Leader-Realm"))
    end)
  end)

  describe("OwnRole", function()
    it("is admin for rank index 0, or when the client says the player is the guild master", function()
      assert.are.equal("admin", Service.OwnRole(platform_of("Whatever", 0, "Me-Realm"), { members = {} }))
      assert.are.equal("admin", Service.OwnRole(platform_of("Whatever", nil, "Me-Realm", true), { members = {} }))
      assert.are.equal("member", Service.OwnRole(platform_of("GM", 2, "Me-Realm", false), { members = {} }))
    end)

    it("is the assigned role, or member, for everybody else", function()
      local members = { ["Me-Realm"] = { role = "council", rosterId = "r1" } }
      assert.are.equal("council", Service.OwnRole(platform_of("Raider", 3, "Me-Realm"), { members = members }))
      assert.are.equal("member", Service.OwnRole(platform_of("Officer", 1, "Other-Realm"), { members = members }))
    end)

    it("is nothing for somebody who is not in a guild", function()
      assert.is_nil(Service.OwnRole(platform_of(nil, nil, "Me-Realm"), { members = {} }))
      assert.is_nil(Service.OwnRole(platform_of("", 0, "Me-Realm"), { members = {} }))
    end)

    it("is not changed by the name of the character", function()
      for _, key in ipairs({ "Yonemon Gg", "Yonemon", "Yonemon-Realm" }) do
        assert.are.equal("member", Service.OwnRole(platform_of("alter", 7, key), { members = {} }), key)
      end
    end)
  end)

  describe("roster actions", function()
    it("keeps managing rosters and seeing all of them for the admin", function()
      for _, action in ipairs({ "roster_manage", "roster_view_all" }) do
        assert.is_true(Service.Can("admin", action), action)
        for _, role in ipairs({ "rl", "council", "member" }) do
          assert.is_false(Service.Can(role, action), role .. " " .. action)
        end
      end
    end)

    it("lets everybody publish their recipes", function()
      for _, role in ipairs({ "member", "rl", "council", "admin" }) do
        assert.is_true(Service.Can(role, "recipes_publish"), role)
      end
    end)
  end)
end)
