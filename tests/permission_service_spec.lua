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
    local platform = { GetOwnGuildRank = function() return "RL" end }
    assert.are.equal("rl", Service.OwnRole(platform))
  end)
end)
