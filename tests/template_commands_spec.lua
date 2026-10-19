local Roles = dofile("tests/support/roles.lua")

local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/RosterService",
    "Domain/RecipeService",
    "Domain/EventModel",
    "Domain/EventService",
    "Domain/TemplateService",
    "Commands/TemplateCommands",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()

local function text(lines)
  return table.concat(lines, "\n")
end

local function build(rank)
  local env = { events = {}, templates = {}, sent = {}, sendResult = true, counter = 0 }
  env.platform = {
    GetOwnGuildRank = Roles.ranking(rank),
    GetIdentityKey = function()
      return "Leader-Realm"
    end,
    ServerTime = function()
      return 1000
    end,
  }
  env.comm = {}
  function env.comm.NextId()
    env.counter = env.counter + 1
    return "id" .. env.counter
  end
  function env.comm.SendAssignment(_, eventId, assignment)
    env.sent[#env.sent + 1] = { eventId = eventId, assignment = assignment }
    return env.sendResult
  end
  env.members, env.rosters = Roles.assignments(rank, "Leader-Realm")
  ns.PermissionService.Configure({ members = env.members })
  env.commands = ns.TemplateCommands.New({
    events = env.events,
    templates = env.templates,
    platform = env.platform,
    comm = env.comm,
    members = env.members,
    rosters = env.rosters,
  })
  return env
end

-- Two events: "This week" (number 1, earlier) with three assignments, and "Next week" (number 2, empty).
local function with_events(env)
  local function add(id, title, startAt, assignments)
    env.events[id] = {
      eventId = id,
      title = title,
      status = "open",
      startAt = startAt,
      rev = 1,
      updatedAt = 1,
      attendance = {},
      assignments = assignments or {},
      loot = {},
    }
  end
  add("ev-1", "This week", 1000, {
    a1 = { assignmentId = "a1", encounter = "Ragnaros", characterKey = "Zed-Realm", task = "Healer" },
    a2 = { assignmentId = "a2", encounter = "Garr", characterKey = "Bob-Realm" },
    a3 = { assignmentId = "a3", encounter = "Ragnaros", characterKey = "Ann-Realm", task = "Main tank" },
  })
  add("ev-2", "Next week", 2000)
end

describe("TemplateCommands structured operations", function()
  it("saves an event as a template and applies it to another event", function()
    local env = build("RL")
    with_events(env)
    local events = ns.EventService.List({ events = env.events })

    assert.is_truthy(text(env.commands:SaveEvent(events[1], "Boss")):find("saved 'Boss' with 3 slot(s)", 1, true))
    assert.is_truthy(text(env.commands:ApplyToEvent(events[2], "Boss")):find("added 3 assignment(s)", 1, true))
    assert.are.equal(3, #env.sent)
  end)

  it("refuses to apply for a member", function()
    local env = build("member")
    with_events(env)
    env.templates.Boss = { name = "Boss", slots = { { encounter = "Garr", characterKey = "Bob-Realm" } } }
    local events = ns.EventService.List({ events = env.events })
    assert.is_truthy(text(env.commands:ApplyToEvent(events[2], "Boss")):find("not allowed", 1, true))
    assert.are.equal(0, #env.sent)
  end)
end)

describe("TemplateCommands operations", function()
  local env, events

  before_each(function()
    env = build("RL")
    with_events(env)
    events = ns.EventService.List({ events = env.events })
  end)

  it("saves the assignments of an event under a name", function()
    assert.is_truthy(text(env.commands:SaveEvent(events[1], "Ragnaros week")):find("saved 'Ragnaros week'", 1, true))
    assert.is_table(env.templates["Ragnaros week"])
  end)

  it("applies a template to another event and sends each assignment to the guild", function()
    env.commands:SaveEvent(events[1], "Boss")
    local lines = text(env.commands:ApplyToEvent(events[2], "Boss"))
    assert.is_truthy(lines:find("added 3 assignment(s).", 1, true))
    assert.are.equal(3, #env.sent)
    for _, sent in ipairs(env.sent) do
      assert.are.equal("ev-2", sent.eventId)
      assert.are.equal("Leader-Realm", sent.assignment.updatedBy)
    end
  end)

  it("skips what the event already has when applying again", function()
    env.commands:SaveEvent(events[1], "Boss")
    env.commands:ApplyToEvent(events[2], "Boss")
    env.sent = {}
    local lines = text(env.commands:ApplyToEvent(events[2], "Boss"))
    assert.is_truthy(lines:find("added 0 assignment(s) (skipped - duplicate: 3).", 1, true))
    assert.are.equal(0, #env.sent)
  end)

  it("says when assignments were saved here but could not be sent", function()
    env.commands:SaveEvent(events[1], "Boss")
    env.sendResult = false
    local lines = text(env.commands:ApplyToEvent(events[2], "Boss"))
    assert.is_truthy(lines:find("3 assignment(s) could not be sent to the guild", 1, true))
  end)

  it("refuses a member, with the reason, and changes nothing", function()
    local member = build("member")
    with_events(member)
    local member_events = ns.EventService.List({ events = member.events })
    member.templates.Boss = { name = "Boss", slots = { { encounter = "Garr", characterKey = "Bob-Realm" } } }
    local lines = text(member.commands:ApplyToEvent(member_events[2], "Boss"))
    assert.is_truthy(lines:find("not allowed", 1, true))
    assert.is_nil(next(member.events["ev-2"].assignments))
    assert.are.equal(0, #member.sent)
  end)

  it("deletes a template, and says when it is not there", function()
    env.commands:SaveEvent(events[1], "Boss")
    assert.is_truthy(text(env.commands:Delete("Boss")):find("deleted 'Boss'", 1, true))
    assert.is_truthy(text(env.commands:Delete("Boss")):find("not found", 1, true))
    assert.is_nil(next(env.templates))
  end)

  it("gives clear errors", function()
    assert.is_truthy(text(env.commands:SaveEvent(events[2], "Boss")):find("no assignments to save", 1, true))
    assert.is_truthy(text(env.commands:SaveEvent(events[1], "")):find("plain-text name", 1, true))
    assert.is_truthy(text(env.commands:ApplyToEvent(events[2], "Nope")):find("not found", 1, true))
    assert.is_nil(next(env.templates))
  end)
end)
