-- Raid rosters and assigned roles: the domain rules, and who sees which events.
local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/RosterService",
    "Domain/RecipeService",
    "Domain/EventModel",
    "Domain/EventService",
    "Domain/TemplateService",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local Service, Constants = ns.RosterService, ns.Constants

local function build_ctx(role)
  local ctx = { rosters = {}, members = {}, tombstones = {}, role = role or "gm", actor = "Boss-Realm", clock = 1000 }
  local counter = 0
  ctx.now = function()
    return ctx.clock
  end
  ctx.newId = function()
    counter = counter + 1
    return "r" .. counter
  end
  return ctx
end

describe("RosterService rosters", function()
  it("creates, renames and deletes rosters, for the guild master", function()
    local ctx = build_ctx()
    local main = assert(Service.Create(ctx, "  Main   raid "))
    assert.are.equal("Main raid", main.name)
    assert.are.equal(1, main.rev)
    assert.are.equal("Boss-Realm", main.updatedBy)
    assert.are.equal(main, ctx.rosters[main.id])

    ctx.clock = 2000
    local renamed = assert(Service.Rename(ctx, main.id, "Alts"))
    assert.are.equal("Alts", renamed.name)
    assert.are.equal(2, renamed.rev)
    assert.are.equal(2000, renamed.updatedAt)

    assert.is_true(Service.Delete(ctx, main.id))
    assert.is_nil(ctx.rosters[main.id])
    assert.are.equal(3, ctx.tombstones["R:" .. main.id].rev)
  end)

  it("lets the co-guild master manage rosters too", function()
    local ctx = build_ctx("cogm")
    assert(Service.Create(ctx, "Main"))
    assert(Service.Assign(ctx, "Ann-Realm", {}))
  end)

  it("refuses everybody but gm and cogm, rl and officer included, until the roster scoping exists", function()
    for _, role in ipairs({ "rl", "officer", "roster", "member", "alter" }) do
      local ctx = build_ctx(role)
      assert.are.same({ nil, "forbidden" }, { Service.Create(ctx, "Main") })
      ctx.rosters.r1 = { id = "r1", name = "Main", rev = 1 }
      assert.are.same({ nil, "forbidden" }, { Service.Rename(ctx, "r1", "Other") })
      assert.are.same({ false, "forbidden" }, { Service.Delete(ctx, "r1") })
      assert.are.same({ nil, "forbidden" }, { Service.Assign(ctx, "Ann-Realm", { rosterId = "r1" }) })
      assert.are.same({ false, "forbidden" }, { Service.Unassign(ctx, "Ann-Realm") })
      assert.are.equal("Main", ctx.rosters.r1.name)
    end
    local nobody = build_ctx()
    nobody.role = nil
    assert.are.same({ nil, "forbidden" }, { Service.Create(nobody, "Main") })
  end)

  it("validates the name and refuses duplicates and too many rosters", function()
    local ctx = build_ctx()
    for _, name in ipairs({ "", "   ", "|cffff0000Red", string.rep("x", Constants.ROSTER_NAME_MAX + 1) }) do
      assert.are.equal("invalid:name", select(2, Service.Create(ctx, name)), name)
    end
    assert.are.equal("invalid:name", select(2, Service.Create(ctx, 5)))
    assert(Service.Create(ctx, "Main"))
    assert.are.equal("duplicate", select(2, Service.Create(ctx, "main")))
    local other = assert(Service.Create(ctx, "Alts"))
    assert.are.equal("duplicate", select(2, Service.Rename(ctx, other.id, "MAIN")))
    assert.is_truthy(Service.Rename(ctx, other.id, "ALTS"))
    assert.are.equal("not_found", select(2, Service.Rename(ctx, "nope", "X")))
    assert.are.equal("not_found", select(2, Service.Delete(ctx, "nope")))
    for index = 1, Constants.ROSTERS_MAX do
      ctx.rosters["x" .. index] = { id = "x" .. index, name = "X" .. index, rev = 1 }
    end
    assert.are.equal("limit", select(2, Service.Create(ctx, "One more")))
  end)

  it("lists rosters by name and reads a name", function()
    local rosters = {
      b = { id = "b", name = "beta" },
      a = { id = "a", name = "Alpha" },
      c = { id = "c", name = "alpha" },
    }
    local list = Service.List(rosters)
    assert.are.same({ "a", "c", "b" }, { list[1].id, list[2].id, list[3].id })
    assert.are.equal("beta", Service.NameOf(rosters, "b"))
    assert.is_nil(Service.NameOf(rosters, "zzz"))
    assert.is_nil(Service.NameOf(rosters, nil))
  end)
end)

describe("RosterService assignments", function()
  local ctx

  before_each(function()
    ctx = build_ctx()
    ctx.rosters.r1 = { id = "r1", name = "Main", rev = 1 }
    ctx.rosters.r2 = { id = "r2", name = "Alts", rev = 1 }
  end)

  it("assigns a roster, and keeps one roster per member", function()
    local record = assert(Service.Assign(ctx, "Ann-Realm", { rosterId = "r1" }))
    assert.are.same({ "r1", 1 }, { record.rosterId, record.rev })
    assert.is_nil(record.role)
    assert.are.equal("r1", Service.RosterOf(ctx.members, ctx.rosters, "Ann-Realm"))

    -- Assigning another roster moves them.
    local moved = assert(Service.Assign(ctx, "Ann-Realm", { rosterId = "r2" }))
    assert.are.same({ "r2", 2 }, { moved.rosterId, moved.rev })
    assert.are.equal("r2", Service.RosterOf(ctx.members, ctx.rosters, "Ann-Realm"))

    -- false takes them out of every roster.
    local freed = assert(Service.Assign(ctx, "Ann-Realm", { rosterId = false }))
    assert.is_nil(freed.rosterId)
    assert.is_nil(Service.RosterOf(ctx.members, ctx.rosters, "Ann-Realm"))
  end)

  it("never writes a role: the role is the guild rank", function()
    local record = assert(Service.Assign(ctx, "Bob-Realm", { role = "gm", rosterId = "r1" }))
    assert.is_nil(record.role)
    assert.is_nil(Service.IsAssignableRole)
  end)

  it("refuses a bad key or roster", function()
    for _, key in ipairs({ "", "A:B", "|cff", 5 }) do
      assert.are.equal("invalid:key", select(2, Service.Assign(ctx, key, { rosterId = "r1" })), tostring(key))
    end
    assert.are.equal("invalid:roster", select(2, Service.Assign(ctx, "Ann-Realm", { rosterId = "ghost" })))
    assert.is_nil(ctx.members["Ann-Realm"])
  end)

  it("stops at the assignment limit but still changes one that exists", function()
    for index = 1, Constants.MEMBER_ASSIGNMENTS_MAX do
      ctx.members["M" .. index] = { rev = 1 }
    end
    assert.are.equal("limit", select(2, Service.Assign(ctx, "New-Realm", { rosterId = "r1" })))
    assert.is_truthy(Service.Assign(ctx, "M1", { rosterId = "r1" }))
  end)

  it("takes an assignment away and leaves a tombstone, and a later one needs a higher revision", function()
    assert(Service.Assign(ctx, "Ann-Realm", { rosterId = "r1" }))
    assert.is_true(Service.Unassign(ctx, "Ann-Realm"))
    assert.is_nil(ctx.members["Ann-Realm"])
    assert.are.equal(2, ctx.tombstones["M:Ann-Realm"].rev)
    assert.are.equal("not_found", select(2, Service.Unassign(ctx, "Ann-Realm")))
    local again = assert(Service.Assign(ctx, "Ann-Realm", { rosterId = "r1" }))
    assert.are.equal(3, again.rev)
  end)

  it("counts the guild members of each roster and of none", function()
    assert(Service.Assign(ctx, "Ann-Realm", { rosterId = "r1" }))
    assert(Service.Assign(ctx, "Bob-Realm", { rosterId = "r1" }))
    assert(Service.Assign(ctx, "Cid-Realm", {}))
    local counts = Service.Counts(ctx.rosters, ctx.members, { "Ann-Realm", "Bob-Realm", "Cid-Realm", "Dee-Realm" })
    assert.are.same({ r1 = 2, r2 = 0, none = 2 }, counts)
  end)

  it("counts a member of a deleted roster as in none", function()
    assert(Service.Assign(ctx, "Ann-Realm", { rosterId = "r1" }))
    assert(Service.Delete(ctx, "r1"))
    assert.is_nil(Service.RosterOf(ctx.members, ctx.rosters, "Ann-Realm"))
    assert.are.same({ r2 = 0, none = 1 }, Service.Counts(ctx.rosters, ctx.members, { "Ann-Realm" }))
  end)
end)

describe("RosterService visibility", function()
  local events = {
    mine = { eventId = "mine", rosterId = "r1" },
    theirs = { eventId = "theirs", rosterId = "r2" },
    legacy = { eventId = "legacy" },
  }

  local function ids(filtered)
    local list = {}
    for id in pairs(filtered) do
      list[#list + 1] = id
    end
    table.sort(list)
    return list
  end

  it("shows a member the events of their roster and the legacy ones", function()
    local viewer = Service.Viewer({ role = "member", rosterId = "r1" })
    assert.are.same({ "legacy", "mine" }, ids(Service.FilterEvents(events, viewer)))
    local rl = Service.Viewer({ role = "rl", rosterId = "r2" })
    assert.are.same({ "legacy", "theirs" }, ids(Service.FilterEvents(events, rl)))
    assert.is_false(viewer.canSelect)
  end)

  it("shows a member with no roster nothing", function()
    for _, role in ipairs({ "member", "rl", "officer" }) do
      local viewer = Service.Viewer({ role = role })
      assert.are.equal("blocked", viewer.mode)
      assert.are.same({}, ids(Service.FilterEvents(events, viewer)))
    end
    assert.are.same({}, ids(Service.FilterEvents(events, Service.Viewer({ role = nil }))))
  end)

  it("ignores the selector for anybody but the guild master", function()
    local viewer = Service.Viewer({ role = "rl", rosterId = "r1", selected = "all" })
    assert.are.same({ "legacy", "mine" }, ids(Service.FilterEvents(events, viewer)))
  end)

  it("lets the guild master pick a roster, all rosters, or the events with none", function()
    local own = Service.Viewer({ role = "gm", rosterId = "r1" })
    assert.are.same({ "mine" }, ids(Service.FilterEvents(events, own)))
    assert.is_true(own.canSelect)
    local all = Service.Viewer({ role = "gm", rosterId = "r1", selected = "all" })
    assert.are.same({ "legacy", "mine", "theirs" }, ids(Service.FilterEvents(events, all)))
    local other = Service.Viewer({ role = "gm", selected = "r2" })
    assert.are.same({ "theirs" }, ids(Service.FilterEvents(events, other)))
    local none = Service.Viewer({ role = "gm", selected = "none" })
    assert.are.same({ "legacy" }, ids(Service.FilterEvents(events, none)))
    -- With no roster of their own and nothing picked, they see everything.
    assert.are.same({ "legacy", "mine", "theirs" }, ids(Service.FilterEvents(events, Service.Viewer({ role = "gm" }))))
  end)

  it("builds the viewer of the own character", function()
    local platform = {
      GetOwnGuildRank = function()
        return "RL", 3
      end,
      GetIdentityKey = function()
        return "Me-Realm"
      end,
    }
    local members = { ["Me-Realm"] = { rosterId = "r1" } }
    local rosters = { r1 = { id = "r1", name = "Main" } }
    local viewer, role = Service.OwnViewer(platform, rosters, members)
    assert.are.equal("rl", role)
    assert.are.same({ mode = "roster", rosterId = "r1", legacy = true, canSelect = false }, viewer)
  end)

  it("filters templates the same way", function()
    local mine, theirs, legacy = { rosterId = "r1" }, { rosterId = "r2" }, {}
    local viewer = Service.Viewer({ role = "rl", rosterId = "r1" })
    assert.is_true(Service.TemplateVisible(mine, viewer))
    assert.is_false(Service.TemplateVisible(theirs, viewer))
    assert.is_true(Service.TemplateVisible(legacy, viewer))
    local all = Service.Viewer({ role = "gm", selected = "all" })
    assert.is_true(Service.TemplateVisible(theirs, all))
    assert.is_false(Service.TemplateVisible(legacy, Service.Viewer({ role = "gm", selected = "r1" })) == false)
    assert.is_false(Service.TemplateVisible(mine, Service.Viewer({ role = "member" })))
    assert.is_true(Service.TemplateVisible(legacy, Service.Viewer({ role = "gm", selected = "none" })))
    assert.is_false(Service.TemplateVisible(mine, Service.Viewer({ role = "gm", selected = "none" })))
  end)
end)

describe("RosterService.MayAct", function()
  it("lets gm and cogm act on any event", function()
    for _, role in ipairs({ "gm", "cogm" }) do
      assert.is_true(Service.MayAct(role, nil, "r1"), role)
      assert.is_true(Service.MayAct(role, "r2", nil), role)
      assert.is_true(Service.MayAct(role, "r2", "r1"), role)
    end
  end)

  it("lets the others act on the events of their roster and on the ones no roster owns", function()
    for _, role in ipairs({ "rl", "officer", "roster", "member", "alter" }) do
      assert.is_true(Service.MayAct(role, "r1", "r1"), role)
      assert.is_true(Service.MayAct(role, "r1", nil), role)
      assert.is_false(Service.MayAct(role, "r1", "r2"), role)
      assert.is_false(Service.MayAct(role, nil, "r1"), role)
      assert.is_false(Service.MayAct(role, nil, nil), role)
    end
  end)

  it("reads the roster of a sender from an override, or from the assignments and rosters", function()
    local members = { ["Ann-Realm"] = { rosterId = "r1" }, ["Bob-Realm"] = { rosterId = "gone" } }
    local rosters = { r1 = { id = "r1" } }
    assert.are.equal("r1", Service.SenderRoster({ members = members, rosters = rosters }, "Ann-Realm"))
    assert.is_nil(Service.SenderRoster({ members = members, rosters = rosters }, "Bob-Realm"))
    assert.is_nil(Service.SenderRoster({ members = members, rosters = rosters }, "Nobody"))
    assert.is_nil(Service.SenderRoster({}, "Ann-Realm"))
    local override = {
      rosterOf = function(sender)
        return sender .. "!"
      end,
    }
    assert.are.equal("Ann-Realm!", Service.SenderRoster(override, "Ann-Realm"))
  end)
end)

describe("EventService and rosters", function()
  local function event_ctx(role, rosterId)
    local ctx = { events = {}, tombstones = {}, role = role, actor = "Leader-Realm", rosterId = rosterId }
    ctx.now = function()
      return 1000
    end
    ctx.newId = function()
      return "ev-" .. (next(ctx.events) and "2" or "1")
    end
    return ctx
  end

  it("gives a raid leader's new event their own roster, and refuses another roster or none", function()
    local ctx = event_ctx("rl", "r1")
    local event = assert(ns.EventService.Create(ctx, { title = "Raid" }))
    assert.are.equal("r1", event.rosterId)
    assert.are.equal("other_roster", select(2, ns.EventService.Create(ctx, { title = "Other", rosterId = "r2" })))
    assert.are.equal("other_roster", select(2, ns.EventService.Create(event_ctx("rl", nil), { title = "Lost" })))
  end)

  it("lets the guild master pick the roster of a new event, or none", function()
    local ctx = event_ctx("gm", "r1")
    local picked = assert(ns.EventService.Create(ctx, { title = "A", rosterId = "r2" }))
    assert.are.equal("r2", picked.rosterId)
    ctx.events = {}
    assert.is_nil(assert(ns.EventService.Create(ctx, { title = "B" })).rosterId)
  end)

  it("refuses a raid leader of another roster on every change, and allows the guild master", function()
    local owner = event_ctx("rl", "r1")
    local event = assert(ns.EventService.Create(owner, { title = "Raid" }))
    local other = event_ctx("rl", "r2")
    other.events = owner.events
    assert.are.equal("other_roster", select(2, ns.EventService.Update(other, event.eventId, { title = "X" })))
    assert.are.equal(
      "other_roster",
      select(2, ns.EventService.SetAttendance(other, event.eventId, "A-Realm", "present"))
    )
    assert.are.equal(
      "other_roster",
      select(2, ns.EventService.AddAssignment(other, event.eventId, { encounter = "E", characterKey = "A-Realm" }))
    )
    assert.are.equal("other_roster", select(2, ns.EventService.Delete(other, event.eventId)))
    assert.are.equal("Raid", event.title)

    local boss = event_ctx("gm", nil)
    boss.events = owner.events
    assert.is_truthy(ns.EventService.Update(boss, event.eventId, { title = "By boss" }))
    assert.is_true(ns.EventService.Delete(boss, event.eventId))
  end)

  it("lets only the guild master move an event to another roster", function()
    local owner = event_ctx("rl", "r1")
    local event = assert(ns.EventService.Create(owner, { title = "Raid" }))
    assert.are.equal("forbidden", select(2, ns.EventService.Update(owner, event.eventId, { rosterId = "r2" })))
    local boss = event_ctx("gm", nil)
    boss.events = owner.events
    assert.are.equal("r2", assert(ns.EventService.Update(boss, event.eventId, { rosterId = "r2" })).rosterId)
  end)
end)

describe("TemplateService and rosters", function()
  local function event_of(rosterId)
    return {
      eventId = "ev",
      title = "Molten Core",
      rosterId = rosterId,
      assignments = { a = { assignmentId = "a", encounter = "Garr", characterKey = "Ann-Realm", rev = 1 } },
    }
  end

  it("saves a template with the roster of the event", function()
    local templates = {}
    local template = assert(ns.TemplateService.Save(templates, event_of("r1"), "Molten Core", 1, "Boss"))
    assert.are.equal("r1", template.rosterId)
  end)

  it("does not overwrite the template of another roster", function()
    local templates = {}
    assert(ns.TemplateService.Save(templates, event_of("r1"), "Molten Core", 1, "Boss"))
    assert.are.equal(
      "other_roster",
      select(2, ns.TemplateService.Save(templates, event_of("r2"), "Molten Core", 1, "Boss"))
    )
    assert.is_truthy(ns.TemplateService.Save(templates, event_of("r1"), "Molten Core", 2, "Boss"))
  end)

  it("lists, suggests and applies a template only for its roster, and always for a legacy one", function()
    local templates = {}
    assert(ns.TemplateService.Save(templates, event_of("r1"), "Molten Core", 1, "Boss"))
    assert(ns.TemplateService.Save(templates, event_of(nil), "Molten", 1, "Boss"))
    local fresh = { eventId = "e2", title = "Molten Core night", assignments = {}, rosterId = "r1" }
    assert.are.same({ "Molten", "Molten Core" }, ns.TemplateService.Suggest(templates, fresh))
    fresh.rosterId = "r2"
    assert.are.same({ "Molten" }, ns.TemplateService.Suggest(templates, fresh))

    local viewer = ns.RosterService.Viewer({ role = "rl", rosterId = "r2" })
    assert.are.same({ "Molten" }, ns.TemplateService.List(templates, viewer))
    assert.are.same({ "Molten", "Molten Core" }, ns.TemplateService.List(templates))

    local ctx = { events = { e2 = fresh }, role = "rl", rosterId = "r2", actor = "Lead", now = os.time }
    ctx.newId = function()
      return "new"
    end
    assert.are.equal("other_roster", select(2, ns.TemplateService.Apply(ctx, templates, "Molten Core", "e2")))
  end)

  it("lets a raid leader delete only the templates of their roster", function()
    local templates = {}
    assert(ns.TemplateService.Save(templates, event_of("r1"), "Mine", 1, "Boss"))
    assert(ns.TemplateService.Save(templates, event_of("r2"), "Theirs", 1, "Boss"))
    assert(ns.TemplateService.Save(templates, event_of(nil), "Old", 1, "Boss"))
    local rl = { role = "rl", rosterId = "r1" }
    assert.are.equal("other_roster", select(2, ns.TemplateService.Delete(templates, "Theirs", rl)))
    assert.is_true(ns.TemplateService.Delete(templates, "Mine", rl))
    assert.is_true(ns.TemplateService.Delete(templates, "Old", rl))
    assert.is_true(ns.TemplateService.Delete(templates, "Theirs", { role = "gm" }))
    assert.are.equal("not_found", select(2, ns.TemplateService.Delete(templates, "Nope", rl)))
  end)
end)
