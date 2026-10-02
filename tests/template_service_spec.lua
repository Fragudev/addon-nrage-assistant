local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/EventModel",
    "Domain/EventService",
    "Domain/TemplateService",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local Service, EventService, Constants = ns.TemplateService, ns.EventService, ns.Constants

local function build_ctx(role)
  local ctx = { events = {}, tombstones = {}, role = role or "rl", actor = "Leader-Realm", clock = 1000 }
  local counter = 0
  ctx.now = function()
    return ctx.clock
  end
  ctx.newId = function()
    counter = counter + 1
    return "id" .. counter
  end
  return ctx
end

-- An event with three assignments.
local function event_with_assignments(ctx, title)
  local event = assert(EventService.Create(ctx, { title = title or "Raid" }))
  assert(EventService.AddAssignment(ctx, event.eventId, {
    encounter = "Ragnaros",
    characterKey = "Zed-Realm",
    group = 2,
    task = "Healer",
    note = "watch fire",
  }))
  assert(EventService.AddAssignment(ctx, event.eventId, { encounter = "Garr", characterKey = "Bob-Realm" }))
  assert(EventService.AddAssignment(ctx, event.eventId, {
    encounter = "Ragnaros",
    characterKey = "Ann-Realm",
    task = "Main tank",
  }))
  return event
end

describe("TemplateService.Save", function()
  it("saves the assignments of an event as sorted slots without ids or revisions", function()
    local ctx, templates = build_ctx(), {}
    local event = event_with_assignments(ctx)
    local template = assert(Service.Save(templates, event, "  Ragnaros week  ", 2000, "Leader-Realm"))

    assert.are.equal("Ragnaros week", template.name)
    assert.are.equal(template, templates["Ragnaros week"])
    assert.are.equal(2000, template.savedAt)
    assert.are.equal("Leader-Realm", template.savedBy)
    assert.are.equal(3, #template.slots)
    assert.are.equal("Garr", template.slots[1].encounter)
    assert.are.equal("Ann-Realm", template.slots[2].characterKey)
    assert.are.same(
      { encounter = "Ragnaros", characterKey = "Zed-Realm", group = 2, task = "Healer", note = "watch fire" },
      template.slots[3]
    )
  end)

  it("replaces a template with the same name", function()
    local ctx, templates = build_ctx(), {}
    local event = event_with_assignments(ctx)
    Service.Save(templates, event, "Boss", 1, "A")
    event.assignments = {}
    EventService.AddAssignment(ctx, event.eventId, { encounter = "Only", characterKey = "One-Realm" })
    Service.Save(templates, event, "Boss", 2, "B")
    assert.are.equal(1, #templates.Boss.slots)
    assert.are.equal("B", templates.Boss.savedBy)
  end)

  it("rejects bad names, an event without assignments and going over the limit", function()
    local ctx, templates = build_ctx(), {}
    local event = event_with_assignments(ctx)
    for _, name in ipairs({ "", "   ", "|cffff0000x", ("n"):rep(Constants.TEMPLATE_NAME_MAX + 1) }) do
      assert.are.equal("invalid:name", select(2, Service.Save(templates, event, name, 1, "A")), name)
    end
    assert.are.equal("invalid:name", select(2, Service.Save(templates, event, nil, 1, "A")))

    local empty = assert(EventService.Create(ctx, { title = "Empty" }))
    assert.are.equal("empty", select(2, Service.Save(templates, empty, "Nothing", 1, "A")))
    assert.is_nil(next(templates))

    for i = 1, Constants.TEMPLATES_MAX do
      templates["T" .. i] = { slots = {} }
    end
    assert.are.equal("limit", select(2, Service.Save(templates, event, "One more", 1, "A")))
    assert.is_truthy(Service.Save(templates, event, "T1", 1, "A"))
  end)
end)

describe("TemplateService.List and Delete", function()
  it("lists names in order and deletes by name", function()
    local templates = { Beta = {}, Alpha = {} }
    assert.are.same({ "Alpha", "Beta" }, Service.List(templates))
    assert.is_true(Service.Delete(templates, "Alpha"))
    assert.are.same({ "Beta" }, Service.List(templates))
    local ok, reason = Service.Delete(templates, "Alpha")
    assert.is_false(ok)
    assert.are.equal("not_found", reason)
  end)
end)

describe("TemplateService.Apply", function()
  local ctx, templates, source, target

  before_each(function()
    ctx, templates = build_ctx(), {}
    source = event_with_assignments(ctx, "Last week")
    target = assert(EventService.Create(ctx, { title = "This week" }))
    Service.Save(templates, source, "Boss", 1, "Leader-Realm")
  end)

  it("adds the template's assignments to another event as ordinary assignments", function()
    local created, skipped = Service.Apply(ctx, templates, "Boss", target.eventId)
    assert.are.equal(3, #created)
    assert.are.same({}, skipped)

    local count = 0
    for _, assignment in pairs(target.assignments) do
      count = count + 1
      assert.are.equal(1, assignment.rev)
      assert.are.equal("Leader-Realm", assignment.updatedBy)
      assert.are.equal("declared", assignment.source)
    end
    assert.are.equal(3, count)
  end)

  it("keeps the details of each slot", function()
    Service.Apply(ctx, templates, "Boss", target.eventId)
    local found
    for _, assignment in pairs(target.assignments) do
      if assignment.characterKey == "Zed-Realm" then
        found = assignment
      end
    end
    assert.are.equal("Ragnaros", found.encounter)
    assert.are.equal(2, found.group)
    assert.are.equal("Healer", found.task)
    assert.are.equal("watch fire", found.note)
  end)

  it("skips assignments the event already has, so applying twice adds nothing", function()
    Service.Apply(ctx, templates, "Boss", target.eventId)
    local created, skipped = Service.Apply(ctx, templates, "Boss", target.eventId)
    assert.are.equal(0, #created)
    assert.are.equal(3, skipped.duplicate)
  end)

  it("is refused for a role that cannot manage assignments, and changes nothing", function()
    local member = build_ctx("member")
    member.events = ctx.events
    local created, reason = Service.Apply(member, templates, "Boss", target.eventId)
    assert.is_nil(created)
    assert.are.equal("forbidden", reason)
    assert.is_nil(next(target.assignments))
  end)

  it("reports a missing template or event", function()
    assert.are.equal("not_found", select(2, Service.Apply(ctx, templates, "Nope", target.eventId)))
    assert.are.equal("not_found", select(2, Service.Apply(ctx, templates, "Boss", "nope")))
  end)

  it("stops at the assignment limit", function()
    for i = 1, Constants.EVENT_ASSIGNMENTS_MAX do
      target.assignments["x" .. i] = { encounter = "E" .. i, characterKey = "P" .. i .. "-Realm" }
    end
    local created, skipped = Service.Apply(ctx, templates, "Boss", target.eventId)
    assert.are.equal(0, #created)
    assert.are.equal(1, skipped.limit)
  end)

  it("does not change the template or the source event", function()
    Service.Apply(ctx, templates, "Boss", target.eventId)
    assert.are.equal(3, #templates.Boss.slots)
    local count = 0
    for _ in pairs(source.assignments) do
      count = count + 1
    end
    assert.are.equal(3, count)
  end)
end)

describe("TemplateService.Describe", function()
  it("summarises what was added and why the rest was skipped", function()
    assert.are.equal("added 2 assignment(s)", Service.Describe({ {}, {} }, {}))
    assert.are.equal(
      "added 1 assignment(s) (skipped - duplicate: 2, limit: 1)",
      Service.Describe({ {} }, { limit = 1, duplicate = 2 })
    )
  end)
end)

describe("TemplateService.Suggest", function()
  local function template(name, ...)
    local slots = {}
    for _, encounter in ipairs({ ... }) do
      slots[#slots + 1] = { encounter = encounter, characterKey = "Ann-Realm" }
    end
    return { name = name, slots = slots }
  end

  local function event(title, instance, assignments)
    return { title = title, instance = instance, assignments = assignments or {} }
  end

  local templates = {
    ["Molten Core"] = template("Molten Core", "Garr"),
    ["Naxx"] = template("Naxx", "Patchwerk"),
    ["Onyxia"] = template("Onyxia", "Onyxia"),
    ["MC"] = template("MC", "Garr"),
  }

  it("suggests templates whose name appears in the title, ignoring case", function()
    assert.are.same({ "Molten Core" }, Service.Suggest(templates, event("molten core night", nil)))
  end)

  it("also matches the instance, and a title that contains the template name or the reverse", function()
    assert.are.same({ "Naxx" }, Service.Suggest(templates, event("Tuesday raid", "Naxx")))
    assert.are.same({ "Molten Core" }, Service.Suggest(templates, event("Molten", nil)))
    local reversed = { ["Molten Core Week 1"] = template("Molten Core Week 1", "Garr") }
    assert.are.same({ "Molten Core Week 1" }, Service.Suggest(reversed, event("Molten Core", nil)))
  end)

  it("suggests nothing for unrelated titles, very short names or an untitled event", function()
    assert.are.same({}, Service.Suggest(templates, event("Karazhan", nil)))
    assert.are.same({}, Service.Suggest(templates, event("MC night", nil)))
    assert.are.same({}, Service.Suggest(templates, event("", nil)))
  end)

  it("leaves out a template the event already has in full", function()
    local has = { a = { encounter = "Garr", characterKey = "Ann-Realm" } }
    assert.are.same({}, Service.Suggest(templates, event("Molten Core night", nil, has)))
    local partial = { ["Molten Core"] = template("Molten Core", "Garr", "Geddon") }
    assert.are.same({ "Molten Core" }, Service.Suggest(partial, event("Molten Core", nil, has)))
  end)

  it("returns the names sorted and changes nothing", function()
    local many = {
      ["Onyxia B"] = template("Onyxia B", "Onyxia"),
      ["Onyxia A"] = template("Onyxia A", "Onyxia"),
    }
    local target = event("Onyxia", nil)
    assert.are.same({ "Onyxia A", "Onyxia B" }, Service.Suggest(many, target))
    assert.is_nil(next(target.assignments))
  end)
end)
