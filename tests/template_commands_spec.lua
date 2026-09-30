local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants", "Core/Validate", "Domain/PermissionService", "Domain/EventModel", "Domain/EventService",
    "Domain/TemplateService", "Commands/TemplateCommands",
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
    GetOwnGuildRank = function() return rank end,
    GetIdentityKey = function() return "Leader-Realm" end,
    ServerTime = function() return 1000 end,
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
  env.commands = ns.TemplateCommands.New({
    events = env.events, templates = env.templates, platform = env.platform, comm = env.comm,
  })
  return env
end

-- Two events: "This week" (number 1, earlier) with three assignments, and "Next week" (number 2, empty).
local function with_events(env)
  local function add(id, title, startAt, assignments)
    env.events[id] = {
      eventId = id, title = title, status = "open", startAt = startAt, rev = 1, updatedAt = 1,
      attendance = {}, assignments = assignments or {}, loot = {},
    }
  end
  add("ev-1", "This week", 1000, {
    a1 = { assignmentId = "a1", encounter = "Ragnaros", characterKey = "Zed-Realm", task = "Healer" },
    a2 = { assignmentId = "a2", encounter = "Garr", characterKey = "Bob-Realm" },
    a3 = { assignmentId = "a3", encounter = "Ragnaros", characterKey = "Ann-Realm", task = "Main tank" },
  })
  add("ev-2", "Next week", 2000)
end

describe("TemplateCommands", function()
  local env

  before_each(function()
    env = build("RL")
    with_events(env)
  end)

  it("explains that there are no templates yet", function()
    assert.is_truthy(text(env.commands:Template("")):find("No templates yet", 1, true))
    assert.is_truthy(text(env.commands:Template("list")):find("No templates yet", 1, true))
  end)

  it("saves the assignments of an event under a name and lists it", function()
    local saved = text(env.commands:Template("save 1 Ragnaros week"))
    assert.is_truthy(saved:find("saved 'Ragnaros week' with 3 slot(s)", 1, true))
    local lines = env.commands:Template("list")
    assert.are.equal("1 template(s):", lines[1])
    assert.are.equal("  Ragnaros week - 3 slot(s)", lines[2])
  end)

  it("shows the slots of a template, and says when it does not exist", function()
    env.commands:Template("save 1 Boss")
    local lines = env.commands:Template("show Boss")
    assert.are.equal("Template 'Boss':", lines[1])
    assert.are.equal("  Garr: Bob-Realm", lines[2])
    assert.are.equal("  Ragnaros: Ann-Realm - Main tank", lines[3])
    assert.are.equal("  Ragnaros: Zed-Realm - Healer", lines[4])
    assert.is_truthy(text(env.commands:Template("show Nope")):find("no template called 'Nope'", 1, true))
  end)

  it("applies a template to another event and sends each assignment to the guild", function()
    env.commands:Template("save 1 Boss")
    local lines = text(env.commands:Template("apply 2 Boss"))
    assert.is_truthy(lines:find("added 3 assignment(s).", 1, true))
    assert.are.equal(3, #env.sent)
    for _, sent in ipairs(env.sent) do
      assert.are.equal("ev-2", sent.eventId)
      assert.are.equal("Leader-Realm", sent.assignment.updatedBy)
    end
  end)

  it("skips what the event already has when applying again", function()
    env.commands:Template("save 1 Boss")
    env.commands:Template("apply 2 Boss")
    env.sent = {}
    local lines = text(env.commands:Template("apply 2 Boss"))
    assert.is_truthy(lines:find("added 0 assignment(s) (skipped - duplicate: 3).", 1, true))
    assert.are.equal(0, #env.sent)
  end)

  it("says when assignments were saved here but could not be sent", function()
    env.commands:Template("save 1 Boss")
    env.sendResult = false
    local lines = text(env.commands:Template("apply 2 Boss"))
    assert.is_truthy(lines:find("3 assignment(s) could not be sent to the guild", 1, true))
  end)

  it("refuses a member, with the reason, and changes nothing", function()
    local member = build("member")
    with_events(member)
    member.commands:Template("save 1 Boss")
    local lines = text(member.commands:Template("apply 2 Boss"))
    assert.is_truthy(lines:find("not allowed", 1, true))
    assert.is_nil(next(member.events["ev-2"].assignments))
    assert.are.equal(0, #member.sent)
  end)

  it("deletes a template", function()
    env.commands:Template("save 1 Boss")
    assert.is_truthy(text(env.commands:Template("delete Boss")):find("deleted 'Boss'", 1, true))
    assert.is_truthy(text(env.commands:Template("delete Boss")):find("not found", 1, true))
    assert.is_nil(next(env.templates))
  end)

  it("gives clear errors and the usage", function()
    assert.is_truthy(text(env.commands:Template("save x Boss")):find("give the event number", 1, true))
    assert.is_truthy(text(env.commands:Template("save 9 Boss")):find("give the event number", 1, true))
    assert.is_truthy(text(env.commands:Template("save 2 Boss")):find("no assignments to save", 1, true))
    assert.is_truthy(text(env.commands:Template("save 1")):find("plain-text name", 1, true))
    assert.is_truthy(text(env.commands:Template("apply 2 Nope")):find("not found", 1, true))
    assert.is_truthy(text(env.commands:Template("apply x Boss")):find("give the event number", 1, true))
    assert.is_truthy(text(env.commands:Template("dance")):find("usage:", 1, true))
    assert.is_nil(next(env.templates))
  end)
end)
