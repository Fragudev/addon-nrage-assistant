local function load_service()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/Constants.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Core/Validate.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Domain/PermissionService.lua"))("NrageAssistant", ns)
  return ns.PermissionService, ns.Constants
end

local Service = load_service()
local Roles = require("tests.support.roles")

local ROLES = { "gm", "cogm", "officer", "rl", "roster", "member", "alter" }

local function roster_with(entries)
  return {
    Lookup = function(_, name)
      return entries[name]
    end,
  }
end

local function platform_of(rank, index, leader)
  return {
    GetOwnGuildRank = function()
      return rank, index
    end,
    IsGuildLeader = leader ~= nil and function()
      return leader
    end or nil,
  }
end

describe("PermissionService.RoleForRank", function()
  it("maps the seven guild ranks by name", function()
    for role, rankName in pairs(Roles.RANK_NAMES) do
      assert.are.equal(role, Service.RoleForRank(rankName), rankName)
    end
  end)

  it("ignores case", function()
    assert.are.equal("officer", Service.RoleForRank("oFiCiAl"))
    assert.are.equal("cogm", Service.RoleForRank("COGM"))
  end)

  it("trims the name", function()
    assert.are.equal("rl", Service.RoleForRank("  RL "))
    assert.are.equal("member", Service.RoleForRank("\tMiembro\n"))
  end)

  it("treats a rank nobody mapped as an alter", function()
    assert.are.equal("alter", Service.RoleForRank("Recruit"))
    assert.are.equal("alter", Service.RoleForRank("Officer"))
    assert.are.equal("alter", Service.RoleForRank("   "))
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
  local roster = roster_with({
    ["Boss-Realm"] = { rankName = "Maestro", rankIndex = 0 },
    ["Co-Realm"] = { rankName = "CoGM", rankIndex = 1 },
    ["Officer-Realm"] = { rankName = "Oficial", rankIndex = 2 },
    ["Leader-Realm"] = { rankName = "RL", rankIndex = 3 },
    ["Plain-Realm"] = { rankName = "Miembro", rankIndex = 5 },
    ["Odd-Realm"] = { rankName = "Newbie", rankIndex = 7 },
    ["Fake-Realm"] = { rankName = "GM", rankIndex = 2 },
    ["Yonemon Gg"] = { rankName = "Raider", rankIndex = 4 },
  })

  it("reads the role from the rank in the local guild roster", function()
    assert.are.equal("cogm", Service.RoleOf(roster, "Co-Realm"))
    assert.are.equal("officer", Service.RoleOf(roster, "Officer-Realm"))
    assert.are.equal("rl", Service.RoleOf(roster, "Leader-Realm"))
    assert.are.equal("member", Service.RoleOf(roster, "Plain-Realm"))
  end)

  it("makes the guild master, by rank index 0, gm whatever the rank is called", function()
    assert.are.equal("gm", Service.RoleOf(roster, "Boss-Realm"))
  end)

  it("gives an unknown rank the alter role, and a rank called GM at another index is just a GM rank", function()
    assert.are.equal("alter", Service.RoleOf(roster, "Odd-Realm"))
    assert.are.equal("alter", Service.RoleOf(roster, "Yonemon Gg"))
    assert.are.equal("gm", Service.RoleOf(roster, "Fake-Realm"))
  end)

  it("never reads an assignment: a stored role means nothing", function()
    assert.are.equal(
      "member",
      Service.RoleOf(roster, "Plain-Realm", { members = { ["Plain-Realm"] = { role = "rl" } } })
    )
  end)

  it("gives no role to someone the roster does not know", function()
    assert.is_nil(Service.RoleOf(roster_with({}), "Stranger-Realm"))
  end)

  it("uses a custom mapping when given one", function()
    assert.are.equal("rl", Service.RoleOf(roster, "Plain-Realm", { mapping = { miembro = "rl" } }))
  end)
end)

describe("PermissionService.OwnRole", function()
  it("is gm for rank index 0, or when the client says the player is the guild master", function()
    assert.are.equal("gm", Service.OwnRole(platform_of("Whatever", 0)))
    assert.are.equal("gm", Service.OwnRole(platform_of("Whatever", nil, true)))
    assert.are.equal("gm", Service.OwnRole(platform_of("Alter", 6, true)))
    assert.are.equal("gm", Service.OwnRole(platform_of("GM", 2, false)))
  end)

  it("is the role of the rank name for everybody else", function()
    assert.are.equal("cogm", Service.OwnRole(platform_of("CoGM", 1)))
    assert.are.equal("rl", Service.OwnRole(platform_of(" rl ", 3)))
    assert.are.equal("alter", Service.OwnRole(platform_of("Recruit", 9)))
  end)

  it("is nothing for somebody who is not in a guild", function()
    assert.is_nil(Service.OwnRole(platform_of(nil, nil)))
    assert.is_nil(Service.OwnRole(platform_of("", 0)))
  end)
end)

describe("PermissionService.Rank and IsGlobal", function()
  it("orders the seven roles from gm to alter", function()
    for index, role in ipairs(ROLES) do
      assert.are.equal(index - 1, Service.Rank(role), role)
    end
    assert.is_nil(Service.Rank("admin"))
    assert.is_nil(Service.Rank(nil))
  end)

  it("makes only gm and cogm global", function()
    for _, role in ipairs(ROLES) do
      assert.are.equal(role == "gm" or role == "cogm", Service.IsGlobal(role), role)
    end
    assert.is_false(Service.IsGlobal(nil))
    assert.is_false(Service.IsGlobal("admin"))
  end)
end)

-- The matrix of docs/NAV_PERMISSIONS_PLAN.md 1.3: the scope of each role for each action.
-- "-" is not allowed, "all" every roster, "own" the roster of the player.
local MATRIX = {
  --                    gm     cogm   officer rl     roster member alter
  admin_view = { "all", "all", "all", "all", "-", "-", "-" },
  raidcheck_view = { "all", "all", "own", "own", "own", "-", "-" },
  loot_view = { "all", "all", "own", "own", "own", "-", "-" },
  loot_manage = { "all", "all", "own", "own", "-", "-", "-" },
  loot_apply = { "all", "all", "own", "own", "own", "-", "-" },
  events_view = { "all", "all", "own", "own", "own", "-", "-" },
  event_signup = { "all", "all", "own", "own", "own", "-", "-" },
  raid_manage = { "all", "all", "own", "own", "-", "-", "-" },
  members_view = { "all", "all", "all", "own", "-", "-", "-" },
  members_manage = { "all", "all", "-", "own", "-", "-", "-" },
  rules_view = { "all", "all", "all", "own", "-", "-", "-" },
  rules_edit = { "all", "all", "-", "own", "-", "-", "-" },
  pvp_admin = { "all", "all", "-", "-", "-", "-", "-" },
  -- Open to every rank.
  edit_own_profile = { "all", "all", "all", "all", "all", "all", "all" },
  layer_share = { "all", "all", "all", "all", "all", "all", "all" },
  position_share = { "all", "all", "all", "all", "all", "all", "all" },
  pvp_publish = { "all", "all", "all", "all", "all", "all", "all" },
  pvp_claim = { "all", "all", "all", "all", "all", "all", "all" },
  recipes_publish = { "all", "all", "all", "all", "all", "all", "all" },
  blacklist_add = { "all", "all", "all", "all", "all", "all", "all" },
  -- Admin only actions that stay: gm and cogm.
  moderate = { "all", "all", "-", "-", "-", "-", "-" },
  blacklist_remove = { "all", "all", "-", "-", "-", "-", "-" },
  blacklist_edit_any = { "all", "all", "-", "-", "-", "-", "-" },
  pvp_claim_decide = { "all", "all", "-", "-", "-", "-", "-" },
  pvp_delivery_mark = { "all", "all", "-", "-", "-", "-", "-" },
  pvp_grant_direct = { "all", "all", "-", "-", "-", "-", "-" },
  pvp_grant_void = { "all", "all", "-", "-", "-", "-", "-" },
  pvp_season_manage = { "all", "all", "-", "-", "-", "-", "-" },
  pvp_mission_manage = { "all", "all", "-", "-", "-", "-", "-" },
  pvp_prize_manage = { "all", "all", "-", "-", "-", "-", "-" },
}

local function sorted_keys(map)
  local keys = {}
  for key in pairs(map) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

describe("PermissionService action matrix", function()
  for _, action in ipairs(sorted_keys(MATRIX)) do
    describe(action, function()
      for index, role in ipairs(ROLES) do
        local expected = MATRIX[action][index]
        it(("%s: %s"):format(role, expected), function()
          assert.are.equal(expected ~= "-", Service.Can(role, action))
          -- With a roster, the scope is the one the matrix gives; without one "own" turns into "none".
          assert.are.equal(expected == "-" and "none" or expected, Service.Scope(role, action, "r1"))
          assert.are.equal(expected == "all" and "all" or "none", Service.Scope(role, action, nil))
          assert.are.equal(expected == "all", Service.CanAll(role, action))
        end)
      end
    end)
  end

  it("lists no action the plan does not know", function()
    for _, action in ipairs({ "view", "manage_events", "record_attendance", "manage_assignments" }) do
      assert.is_false(Service.Can("gm", action), action)
    end
    for _, action in ipairs({ "loot_open", "loot_vote", "loot_award", "roster_manage", "roster_view_all" }) do
      assert.is_false(Service.Can("gm", action), action)
    end
    assert.is_false(Service.Can("gm", "pvp_officer_assign"))
    assert.is_nil(Service.CanPvP)
  end)

  it("denies unknown actions, unknown roles and a missing role", function()
    assert.is_false(Service.Can("gm", "delete_the_guild"))
    assert.is_false(Service.Can(nil, "pvp_publish"))
    assert.is_false(Service.Can("admin", "moderate"))
    assert.is_false(Service.Can("council", "loot_manage"))
    assert.are.equal("none", Service.Scope("gm", "delete_the_guild", "r1"))
    assert.are.equal("none", Service.Scope(nil, "pvp_publish", "r1"))
    assert.are.equal("none", Service.Scope("admin", "moderate", "r1"))
  end)

  it("gives a scope of none to a roster-bound rank with no roster, but not to gm and cogm", function()
    assert.are.equal("none", Service.Scope("rl", "raid_manage"))
    assert.are.equal("own", Service.Scope("rl", "raid_manage", "r1"))
    assert.are.equal("all", Service.Scope("cogm", "raid_manage"))
    assert.are.equal("all", Service.Scope("officer", "members_view"))
  end)
end)
