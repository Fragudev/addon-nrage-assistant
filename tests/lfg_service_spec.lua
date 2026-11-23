local function load_service()
  local ns = {}
  local files = {
    "Core/Constants",
    "Core/Validate",
    "Core/Locale",
    "Domain/ProfileService",
    "Domain/LfgModel",
    "Domain/LfgBoard",
    "Domain/LfgService",
  }
  for _, path in ipairs(files) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_service()
local Constants = ns.Constants

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local clone = {}
  for k, v in pairs(value) do
    clone[k] = copy(v)
  end
  return clone
end

-- A small world with a clock, timers and a guild channel that delivers a message to every other client at once.
-- Each client has a real board and the real eligibility rules over a fake platform.
local function new_world()
  local world = { clock = 1000, timers = {}, clients = {}, sent = {}, counter = 0 }
  function world.now()
    return world.clock
  end
  function world.schedule(delay, fn)
    world.timers[#world.timers + 1] = { at = world.clock + delay, fn = fn }
  end
  -- Moves the clock and runs the timers that are due, in time order.
  function world.advance(seconds)
    local target = world.clock + seconds
    while true do
      local next_index
      for index, timer in ipairs(world.timers) do
        if timer.at <= target and (not next_index or timer.at < world.timers[next_index].at) then
          next_index = index
        end
      end
      if not next_index then
        break
      end
      local timer = table.remove(world.timers, next_index)
      world.clock = math.max(world.clock, timer.at)
      timer.fn()
    end
    world.clock = target
  end
  return world
end

local function new_client(world, name)
  local c = {
    name = name,
    locked = false,
    size = 1,
    leader = true,
    raid = false,
    combat = false,
    level = 60,
    group = {},
    invites = {},
    changes = 0,
  }
  local platform = {
    IsInGroup = function()
      return c.size > 1
    end,
    IsInRaid = function()
      return c.raid
    end,
    IsInCombat = function()
      return c.combat
    end,
    IsGroupLeader = function()
      return c.leader
    end,
    GetGroupSize = function()
      return c.size
    end,
  }
  local function isLocked()
    return c.locked
  end
  c.board = ns.LfgBoard.New({ now = world.now })
  local function channel(kind)
    return function(payload)
      if c.locked then
        return false, "locked"
      end
      if c.sendFails then
        error("transport")
      end
      world.sent[#world.sent + 1] = { from = name, kind = kind, payload = copy(payload) }
      for _, other in ipairs(world.clients) do
        if other ~= c then
          if kind == "post" then
            other.service:OnPost(name, copy(payload))
          else
            other.service:OnApply(name, copy(payload))
          end
        end
      end
      return true
    end
  end
  c.service = ns.LfgService.New({
    now = world.now,
    schedule = world.schedule,
    send = { post = channel("post"), apply = channel("apply") },
    isLocked = isLocked,
    ownName = function()
      return name
    end,
    newId = function()
      world.counter = world.counter + 1
      return "pid-" .. world.counter
    end,
    ownLevel = function()
      if c.levelFails then
        error("level")
      end
      return c.level
    end,
    eligibility = ns.LfgService.Eligibility(platform, isLocked),
    invite = function(who)
      c.invites[#c.invites + 1] = who
      return not c.inviteFails, "invite_failed"
    end,
    isGroupMember = function(who)
      return c.group[who] == true
    end,
    groupSize = function()
      return c.size
    end,
    isLeader = function()
      return c.leader
    end,
    isRaid = function()
      return c.raid
    end,
    board = c.board,
    partyClasses = function()
      if c.seatsFail then
        error("party")
      end
      return c.seats
    end,
    ownRole = function()
      return c.role
    end,
    onChange = function()
      c.changes = c.changes + 1
      if c.changeFails then
        error("ui")
      end
    end,
    onNewPost = function(sender, post)
      c.alerts = c.alerts or {}
      c.alerts[#c.alerts + 1] = sender .. ":" .. post.title
      if c.alertFails then
        error("alert")
      end
    end,
    -- Records successful local group publications for notification tests.
    onOwnPost = function()
      c.ownPostNotifications = (c.ownPostNotifications or 0) + 1
    end,
  })
  world.clients[#world.clients + 1] = c
  return c
end

local function fields(overrides)
  local f = { kind = "dungeon", title = "Deadmines", needs = { tank = 1, heal = 1, dps = 2 } }
  for k, v in pairs(overrides or {}) do
    f[k] = v
  end
  return f
end

-- The applicant is now in the party of the leader, as the game reports it.
local function join(applicant, leader)
  leader.size = leader.size + 1
  leader.group[applicant.name] = true
  applicant.size = leader.size
  applicant.leader = false
  applicant.group[leader.name] = true
  leader.service:OnGroupChanged()
  applicant.service:OnGroupChanged()
end

local function sentKinds(world)
  local list = {}
  for _, entry in ipairs(world.sent) do
    local p = entry.payload
    list[#list + 1] = entry.from .. ":" .. (p.s .. (p.o and ("=" .. p.o) or ""))
  end
  return list
end

describe("LfgService posting", function()
  local world, lead, ann

  before_each(function()
    world = new_world()
    lead = new_client(world, "Lead")
    ann = new_client(world, "Ann")
  end)

  it("publishes an open post to the others and to its own board", function()
    assert.is_true(lead.service:Post(fields({ minLevel = 20, note = "bring water" })))
    local payload = world.sent[1].payload
    assert.are.equal("open", payload.s)
    assert.are.equal(1, payload.rev)
    assert.are.equal(1, payload.members)
    assert.are.same({ tank = 1, heal = 1, dps = 2 }, payload.needs)
    assert.are.equal(20, payload.minLevel)
    local seen = ann.board:Get("Lead")
    assert.are.equal("Deadmines", seen.title)
    assert.are.equal(payload.pid, lead.board:Get("Lead").pid)
    assert.are.equal(1, lead.board:OpenCount())
    assert.are.equal(1, lead.changes)
  end)

  it("counts the party the leader is already in as members", function()
    lead.size = 3
    lead.group = { A = true, B = true }
    assert.is_true(lead.service:Post(fields({ needs = { tank = 0, heal = 1, dps = 1 } })))
    assert.are.equal(3, world.sent[1].payload.members)
    assert.is_false(select(1, lead.service:Post(fields({ needs = { dps = 3 } }))))
  end)

  it("shows the post in the status", function()
    lead.service:Post(fields())
    local status = lead.service:Status()
    assert.are.equal("Deadmines", status.post.title)
    assert.are.equal(4, status.post.remaining)
    assert.are.equal(Constants.LFG_POST_MAX_AGE, status.post.left)
    assert.are.same({}, status.post.applicants)
    assert.is_nil(status.application)
  end)

  it("refuses to post when the client says so, and says why", function()
    lead.locked = true
    assert.are.same({ false, "locked" }, { lead.service:Post(fields()) })
    lead.locked = false
    lead.raid, lead.size = true, 10
    assert.are.same({ false, "raid" }, { lead.service:Post(fields()) })
    lead.raid, lead.size, lead.leader = false, 3, false
    assert.are.same({ false, "not_leader" }, { lead.service:Post(fields()) })
    lead.leader, lead.size = true, 5
    assert.are.same({ false, "full" }, { lead.service:Post(fields()) })
    lead.size = 1
    assert.are.same({ false, "no_needs" }, { lead.service:Post(fields({ needs = { tank = 0, heal = 0, dps = 0 } })) })
    assert.are.equal(0, #world.sent)
    assert.is_nil(lead.service:Status().post)
  end)

  it("refuses a post the model refuses", function()
    assert.are.equal("bad_kind", select(2, lead.service:Post(fields({ kind = "raid" }))))
    assert.are.equal("bad_title", select(2, lead.service:Post(fields({ title = "a|b" }))))
    assert.are.equal("bad_needs", select(2, lead.service:Post(fields({ needs = { dps = 5 } }))))
    assert.are.equal("bad_level", select(2, lead.service:Post(fields({ minLevel = 500 }))))
    assert.are.equal("bad_note", select(2, lead.service:Post(fields({ note = "a|b" }))))
    assert.are.equal("bad_kind", select(2, lead.service:Post(nil)))
  end)

  it("refuses to post while an application is active", function()
    lead.service:Post(fields())
    assert.is_true(ann.service:Apply(lead.board:Get("Lead").pid, "tank"))
    assert.are.same({ false, "busy" }, { ann.service:Post(fields()) })
  end)

  it("does not post when the send fails, and leaves nothing behind", function()
    lead.sendFails = true
    assert.are.same({ false, "error" }, { lead.service:Post(fields()) })
    assert.is_nil(lead.service:Status().post)
    assert.are.equal(0, lead.board:OpenCount())
    lead.sendFails = false
    lead.locked = true
    assert.are.same({ false, "locked" }, { lead.service:Post(fields()) })
  end)

  it("replaces the old post with a new pid", function()
    lead.service:Post(fields())
    local first = world.sent[1].payload.pid
    assert.is_true(lead.service:Post(fields({ title = "Wailing Caverns" })))
    local second = world.sent[2].payload.pid
    assert.are_not.equal(first, second)
    assert.are.equal(1, ann.board.count)
    assert.are.equal("Wailing Caverns", ann.board:Get("Lead").title)
    assert.are.equal(1, world.sent[2].payload.rev)
  end)

  it("changes the post with a higher rev", function()
    lead.service:Post(fields())
    assert.is_true(
      lead.service:Update({ title = "Deadmines hard", needs = { tank = 0, heal = 1, dps = 2 }, minLevel = 22 })
    )
    local payload = world.sent[2].payload
    assert.are.equal(2, payload.rev)
    assert.are.equal("Deadmines hard", payload.title)
    assert.are.equal(22, ann.board:Get("Lead").minLevel)
    -- Fields that are not given stay as they were; false clears the level.
    assert.is_true(lead.service:Update({ minLevel = false }))
    assert.is_nil(ann.board:Get("Lead").minLevel)
    assert.are.equal("Deadmines hard", ann.board:Get("Lead").title)
    assert.are.equal(3, ann.board:Get("Lead").rev)
  end)

  it("keeps the post as it was when an update is refused or cannot be sent", function()
    assert.are.same({ false, "no_post" }, { lead.service:Update({ title = "x" }) })
    lead.service:Post(fields())
    assert.are.equal("bad_title", select(2, lead.service:Update({ title = "" })))
    assert.are.equal("no_needs", select(2, lead.service:Update({ needs = { tank = 0, heal = 0, dps = 0 } })))
    lead.locked = true
    assert.are.same({ false, "locked" }, { lead.service:Update({ title = "x" }) })
    lead.locked = false
    lead.sendFails = true
    assert.are.same({ false, "error" }, { lead.service:Update({ title = "x" }) })
    lead.sendFails = false
    assert.are.equal("Deadmines", lead.service:Status().post.title)
    assert.are.equal(1, lead.service:Status().post.rev)
    assert.are.equal("Deadmines", lead.board:Get("Lead").title)
    assert.are.equal(1, lead.board:Get("Lead").rev)
  end)

  it("closes the post as cancelled, and a late open cannot bring it back", function()
    lead.service:Post(fields())
    assert.is_true(lead.service:Close())
    assert.are.same({ "Lead:open", "Lead:closed=cancelled" }, sentKinds(world))
    assert.are.equal(2, world.sent[2].payload.rev)
    assert.are.equal(0, ann.board:OpenCount())
    assert.are.equal(0, lead.board:OpenCount())
    assert.is_nil(lead.service:Status().post)
    local ok = ann.service:OnPost("Lead", world.sent[1].payload)
    assert.is_false(ok)
    assert.are.equal(0, ann.board:OpenCount())
    assert.are.same({ false, "no_post" }, { lead.service:Close() })
  end)

  it("keeps the post when the close cannot be sent", function()
    lead.service:Post(fields())
    lead.locked = true
    assert.are.same({ false, "locked" }, { lead.service:Close() })
    assert.is_truthy(lead.service:Status().post)
    assert.are.equal(1, ann.board:OpenCount())
  end)

  it("repeats the open post with the same rev", function()
    lead.service:Post(fields())
    world.advance(Constants.LFG_REPUBLISH_SECONDS)
    assert.is_true(lead.service:Republish())
    assert.are.equal(world.sent[1].payload.rev, world.sent[2].payload.rev)
    assert.are.equal(world.sent[1].payload.pid, world.sent[2].payload.pid)
    assert.are.equal(world.clock, ann.board:Get("Lead").lastSeen)
    assert.are.equal(world.clock, lead.board:Get("Lead").lastSeen)
  end)

  it("does not repeat during a lockdown, and says nothing without a post", function()
    assert.are.same({ false, "no_post" }, { lead.service:Republish() })
    lead.service:Post(fields())
    lead.locked = true
    assert.are.same({ false, "locked" }, { lead.service:Republish() })
    assert.are.equal(1, #world.sent)
  end)

  it("closes the post as expired after the maximum age, by its timer", function()
    lead.service:Post(fields())
    world.advance(Constants.LFG_POST_MAX_AGE)
    assert.is_nil(lead.service:Status().post)
    assert.are.equal("Lead:closed=expired", sentKinds(world)[2])
    assert.are.equal(0, ann.board:OpenCount())
  end)

  it("closes an old post as expired when it is repeated", function()
    lead.service:Post(fields())
    world.clock = world.clock + Constants.LFG_POST_MAX_AGE
    assert.is_true(lead.service:Republish())
    assert.are.equal("Lead:closed=expired", sentKinds(world)[2])
    assert.is_nil(lead.service:Status().post)
  end)

  it("does not close a replaced post when its old timer fires", function()
    lead.service:Post(fields())
    world.advance(100)
    lead.service:Post(fields({ title = "Second" }))
    world.advance(Constants.LFG_POST_MAX_AGE - 100)
    assert.is_truthy(lead.service:Status().post)
    assert.are.equal("Second", lead.service:Status().post.title)
  end)

  it("survives a UI that raises", function()
    lead.changeFails = true
    assert.is_true(lead.service:Post(fields()))
  end)

  it("notifies only when the player successfully creates a group", function()
    assert.is_true(lead.service:Post(fields()))
    assert.are.equal(1, lead.ownPostNotifications)

    -- Editing and republishing must not play the creation sound again.
    assert.is_true(lead.service:Update({ title = "Updated group" }))
    assert.is_true(lead.service:Republish())
    assert.are.equal(1, lead.ownPostNotifications)

    -- A failed publication must not trigger another notification.
    lead.sendFails = true
    assert.is_false(lead.service:Post(fields()))
    assert.are.equal(1, lead.ownPostNotifications)
  end)
end)

describe("LfgService applying", function()
  local world, lead, ann, pid

  before_each(function()
    world = new_world()
    lead = new_client(world, "Lead")
    ann = new_client(world, "Ann")
    lead.service:Post(fields({ minLevel = 30 }))
    pid = lead.board:Get("Lead").pid
  end)

  it("sends the application and waits for the leader", function()
    assert.is_true(ann.service:Apply(pid, "tank", " I can tank "))
    local payload = world.sent[#world.sent].payload
    assert.are.same({ pid = pid, s = "apply", role = "tank", note = "I can tank" }, payload)
    local app = ann.service:Status().application
    assert.are.equal("applied", app.state)
    assert.are.equal("Lead", app.leader)
    assert.are.equal("Deadmines", app.title)
    assert.are.equal(Constants.LFG_APPLY_TIMEOUT, app.left)
    local row = lead.service:Status().post.applicants[1]
    assert.are.equal("Ann", row.name)
    assert.are.equal("tank", row.role)
    assert.are.equal("I can tank", row.note)
    assert.are.equal("pending", row.state)
  end)

  it("takes a declared role as well as a wire role", function()
    assert.is_true(ann.service:Apply(pid, "Heal"))
    assert.are.equal("heal", ann.service:Status().application.role)
  end)

  it("refuses every case the plan lists, with its reason", function()
    ann.locked = true
    assert.are.same({ false, "locked" }, { ann.service:Apply(pid, "tank") })
    ann.locked = false
    ann.size = 3
    assert.are.same({ false, "in_group" }, { ann.service:Apply(pid, "tank") })
    ann.size = 1
    ann.level = 29
    assert.are.same({ false, "level" }, { ann.service:Apply(pid, "tank") })
    ann.level = 30
    assert.are.same({ false, "role" }, { ann.service:Apply(pid, "healer-ish") })
    assert.are.same({ false, "no_post" }, { ann.service:Apply("nope", "tank") })
    assert.are.same({ false, "no_post" }, { ann.service:Apply(nil, "tank") })
    assert.are.same({ false, "own_post" }, { lead.service:Apply(pid, "tank") })
    assert.are.equal("Lead", lead.board:Get("Lead").owner)
    assert.is_true(ann.service:Apply(pid, "tank"))
    assert.are.same({ false, "busy" }, { ann.service:Apply(pid, "heal") })
  end)

  it("refuses a role the post does not need any more", function()
    lead.service:Update({ needs = { tank = 0, heal = 1, dps = 1 } })
    assert.are.same({ false, "role" }, { ann.service:Apply(pid, "tank") })
    assert.is_true(ann.service:Apply(pid, "heal"))
  end)

  it("does not refuse an unknown level, or one it cannot read", function()
    ann.level = nil
    assert.is_true(ann.service:Apply(pid, "tank"))
    ann.service:Withdraw()
    ann.level = 1
    ann.levelFails = true
    assert.is_true(ann.service:Apply(pid, "tank"))
  end)

  it("refuses the application of the leader of its own post", function()
    local other = new_client(world, "Other")
    other.service:Post(fields({ title = "Mine" }))
    assert.are.same({ false, "own_post" }, { other.service:Apply(pid, "tank") })
  end)

  it("refuses a note that is not plain text", function()
    assert.are.same({ false, "bad_note" }, { ann.service:Apply(pid, "tank", "a|cffff0000b") })
    assert.are.same({ false, "bad_note" }, { ann.service:Apply(pid, "tank", string.rep("a", 101)) })
    assert.is_true(ann.service:Apply(pid, "tank", "   "))
    assert.is_nil(world.sent[#world.sent].payload.note)
  end)

  it("does not apply when the send fails", function()
    ann.sendFails = true
    assert.are.same({ false, "error" }, { ann.service:Apply(pid, "tank") })
    assert.is_nil(ann.service:Status().application)
    assert.are.equal(0, #lead.service:Status().post.applicants)
  end)

  it("does not apply to a post that closed", function()
    lead.service:Close()
    assert.are.same({ false, "no_post" }, { ann.service:Apply(pid, "tank") })
  end)

  it("withdraws, and tells the leader", function()
    ann.service:Apply(pid, "tank")
    assert.is_true(ann.service:Withdraw())
    assert.are.equal("withdrawn", ann.service:Status().application.state)
    assert.are.equal(0, #lead.service:Status().post.applicants)
    assert.are.same({ false, "no_application" }, { ann.service:Withdraw() })
    -- A new application is possible afterwards.
    assert.is_true(ann.service:Apply(pid, "tank"))
  end)

  it("keeps the application when the withdraw cannot be sent", function()
    ann.service:Apply(pid, "tank")
    ann.locked = true
    assert.are.same({ false, "locked" }, { ann.service:Withdraw() })
    assert.are.equal("applied", ann.service:Status().application.state)
  end)

  it("expires after the leader does not answer, and the member may apply again", function()
    ann.service:Apply(pid, "tank")
    world.advance(Constants.LFG_APPLY_TIMEOUT - 1)
    assert.are.equal("applied", ann.service:Status().application.state)
    world.advance(1)
    local app = ann.service:Status().application
    assert.are.equal("expired", app.state)
    assert.are.equal("timeout", app.reason)
    assert.is_nil(app.left)
    assert.is_true(ann.service:Apply(pid, "tank"))
    assert.are.equal("applied", ann.service:Status().application.state)
  end)

  it("does not let the old timeout end a newer application", function()
    ann.service:Apply(pid, "tank")
    world.advance(60)
    ann.service:Withdraw()
    ann.service:Apply(pid, "tank")
    world.advance(Constants.LFG_APPLY_TIMEOUT - 60)
    assert.are.equal("applied", ann.service:Status().application.state)
  end)
end)

describe("LfgService applicants of the leader", function()
  local world, lead, ann, bob, pid

  before_each(function()
    world = new_world()
    lead = new_client(world, "Lead")
    ann = new_client(world, "Ann")
    bob = new_client(world, "Bob")
    lead.service:Post(fields())
    pid = lead.board:Get("Lead").pid
  end)

  it("lists the applicants oldest first", function()
    ann.service:Apply(pid, "tank")
    world.advance(5)
    bob.service:Apply(pid, "heal")
    local rows = lead.service:Status().post.applicants
    assert.are.same({ "Ann", "Bob" }, { rows[1].name, rows[2].name })
  end)

  it("refreshes a repeated apply instead of adding a row", function()
    local forged = { pid = pid, s = "apply", role = "tank", note = "one" }
    assert.is_true(lead.service:OnApply("Ann", forged))
    assert.is_true(lead.service:OnApply("Ann", { pid = pid, s = "apply", role = "dps", note = "two" }))
    local rows = lead.service:Status().post.applicants
    assert.are.equal(1, #rows)
    assert.are.equal("dps", rows[1].role)
    assert.are.equal("two", rows[1].note)
  end)

  it("keys an applicant like a name", function()
    lead.service:OnApply("Yonemon Gg", { pid = pid, s = "apply", role = "tank" })
    lead.service:OnApply("yonemon gg", { pid = pid, s = "apply", role = "heal" })
    assert.are.equal(1, #lead.service:Status().post.applicants)
  end)

  it("drops the applicants beyond the limit", function()
    for index = 1, Constants.LFG_APPLICANTS_MAX do
      assert.is_true(lead.service:OnApply("M" .. index, { pid = pid, s = "apply", role = "dps" }))
    end
    local ok, reason = lead.service:OnApply("OneMore", { pid = pid, s = "apply", role = "dps" })
    assert.is_false(ok)
    assert.are.equal("limit", reason)
    -- Someone who is already listed can still refresh.
    assert.is_true(lead.service:OnApply("M1", { pid = pid, s = "apply", role = "heal" }))
    assert.are.equal(Constants.LFG_APPLICANTS_MAX, #lead.service:Status().post.applicants)
  end)

  it("ignores an apply for a role the post does not need", function()
    lead.service:Update({ needs = { tank = 0, heal = 0, dps = 2 } })
    assert.are.same({ false, "role" }, { lead.service:OnApply("Ann", { pid = pid, s = "apply", role = "tank" }) })
  end)

  it("ignores an apply on a post this client does not own", function()
    -- Bob has no post: nothing to take the application, whatever pid it names.
    assert.are.same(
      { false, "unknown_post" },
      { bob.service:OnApply("Ann", { pid = pid, s = "apply", role = "tank" }) }
    )
    -- Lead has a post, but with another pid.
    assert.are.same(
      { false, "unknown_post" },
      { lead.service:OnApply("Ann", { pid = "other-pid", s = "apply", role = "tank" }) }
    )
    assert.are.equal(0, #lead.service:Status().post.applicants)
    assert.are.same({ false, "unknown_post" }, { lead.service:OnApply("Ann", { pid = "other-pid", s = "withdraw" }) })
  end)

  it("does not take an application from itself", function()
    assert.are.same({ false, "self" }, { lead.service:OnApply("Lead", { pid = pid, s = "apply", role = "tank" }) })
  end)

  it("ignores a withdraw from someone who never applied", function()
    assert.are.same({ false, "unknown_applicant" }, { lead.service:OnApply("Ann", { pid = pid, s = "withdraw" }) })
  end)

  it("declines an applicant and tells them", function()
    ann.service:Apply(pid, "tank")
    assert.is_true(lead.service:Decline("Ann"))
    assert.are.equal("declined", ann.service:Status().application.state)
    assert.are.equal(0, #lead.service:Status().post.applicants)
    assert.are.same({ false, "unknown_applicant" }, { lead.service:Decline("Ann") })
  end)

  it("keeps the row when the decline cannot be sent", function()
    ann.service:Apply(pid, "tank")
    lead.locked = true
    assert.are.same({ false, "locked" }, { lead.service:Decline("Ann") })
    assert.are.equal(1, #lead.service:Status().post.applicants)
    lead.locked = false
    lead.service:Close()
    assert.are.same({ false, "no_post" }, { lead.service:Decline("Ann") })
  end)

  it("ignores an unknown message step", function()
    assert.are.same({ false, "unsupported" }, { lead.service:OnApply("Ann", { pid = pid, s = "kick" }) })
    assert.are.same({ false, "bad_sender" }, { lead.service:OnApply("", { pid = pid, s = "apply", role = "tank" }) })
  end)
end)

describe("LfgService inviting", function()
  local world, lead, ann, pid

  before_each(function()
    world = new_world()
    lead = new_client(world, "Lead")
    ann = new_client(world, "Ann")
    lead.service:Post(fields())
    pid = lead.board:Get("Lead").pid
    ann.service:Apply(pid, "tank")
  end)

  it("sends the accept and asks the game to invite, and both sides show it", function()
    assert.is_true(lead.service:Invite("Ann"))
    assert.are.same({ pid = pid, s = "accept", to = "Ann" }, world.sent[#world.sent].payload)
    assert.are.same({ "Ann" }, lead.invites)
    local row = lead.service:Status().post.applicants[1]
    assert.are.equal("invited", row.state)
    assert.are.equal(Constants.LFG_INVITE_TIMEOUT, row.left)
    local app = ann.service:Status().application
    assert.are.equal("invited", app.state)
    assert.are.equal(Constants.LFG_INVITE_TIMEOUT, app.left)
  end)

  it("refuses with the reason of the rules", function()
    lead.locked = true
    assert.are.same({ false, "locked" }, { lead.service:Invite("Ann") })
    lead.locked = false
    lead.size, lead.leader = 3, false
    assert.are.same({ false, "not_leader" }, { lead.service:Invite("Ann") })
    lead.leader = true
    lead.combat = true
    assert.are.same({ false, "combat" }, { lead.service:Invite("Ann") })
    lead.combat = false
    lead.size = 5
    assert.are.same({ false, "full" }, { lead.service:Invite("Ann") })
    assert.are.same({}, lead.invites)
    assert.are.equal("applied", ann.service:Status().application.state)
    assert.are.same({ false, "unknown_applicant" }, { lead.service:Invite("Nobody") })
    assert.are.same({ false, "unknown_applicant" }, { lead.service:Invite(nil) })
  end)

  it("refuses a party that is full even when the rules say yes", function()
    lead.service.deps.eligibility.invite = function()
      return true
    end
    lead.size = 5
    assert.are.same({ false, "full" }, { lead.service:Invite("Ann") })
  end)

  it("says nothing without a post", function()
    lead.service:Close()
    assert.are.same({ false, "no_post" }, { lead.service:Invite("Ann") })
  end)

  it("keeps the invite when the accept cannot be sent after the game took it", function()
    lead.sendFails = true
    assert.is_true(lead.service:Invite("Ann"))
    assert.are.same({ "Ann" }, lead.invites)
    assert.are.equal("invited", lead.service:Status().post.applicants[1].state)
    assert.are.equal("applied", ann.service:Status().application.state)
  end)

  it("keeps the row as it was and sends nothing when the game refuses the invite", function()
    local sent = #world.sent
    lead.inviteFails = true
    assert.are.same({ false, "invite_failed" }, { lead.service:Invite("Ann") })
    assert.are.equal("pending", lead.service:Status().post.applicants[1].state)
    assert.are.equal(sent, #world.sent)
    assert.are.equal("applied", ann.service:Status().application.state)
  end)

  it("refuses when a rule raises", function()
    lead.service.deps.eligibility.invite = function()
      error("boom")
    end
    assert.are.same({ false, "error" }, { lead.service:Invite("Ann") })
  end)

  it("returns the row to a retry state when the join never comes, and the leader may invite again", function()
    lead.service:Invite("Ann")
    world.advance(Constants.LFG_INVITE_TIMEOUT)
    local row = lead.service:Status().post.applicants[1]
    assert.are.equal("retry", row.state)
    assert.is_nil(row.left)
    assert.are.equal("expired", ann.service:Status().application.state)
    -- The applicant applies again: the row goes back to pending, and the invite works again.
    assert.is_true(ann.service:Apply(pid, "tank"))
    assert.are.equal("pending", lead.service:Status().post.applicants[1].state)
    assert.is_true(lead.service:Invite("Ann"))
    assert.are.equal("invited", ann.service:Status().application.state)
    assert.are.same({ "Ann", "Ann" }, lead.invites)
  end)

  it("lets the leader invite again from the retry state", function()
    lead.service:Invite("Ann")
    world.advance(Constants.LFG_INVITE_TIMEOUT)
    assert.is_true(lead.service:Invite("Ann"))
    assert.are.equal("invited", lead.service:Status().post.applicants[1].state)
    -- The first invitation's timer does not end the second.
    world.advance(Constants.LFG_INVITE_TIMEOUT - 1)
    assert.are.equal("invited", lead.service:Status().post.applicants[1].state)
  end)

  it("expires the invitation of the applicant after the timeout", function()
    lead.service:Invite("Ann")
    world.advance(Constants.LFG_INVITE_TIMEOUT)
    local app = ann.service:Status().application
    assert.are.equal("expired", app.state)
    assert.are.equal("timeout", app.reason)
  end)

  it("keeps an invited row when the same applicant sends a repeated apply", function()
    lead.service:Invite("Ann")
    lead.service:OnApply("Ann", { pid = pid, s = "apply", role = "tank" })
    assert.are.equal("invited", lead.service:Status().post.applicants[1].state)
  end)

  it("drops an invited row when the applicant withdraws", function()
    lead.service:Invite("Ann")
    assert.is_true(ann.service:Withdraw())
    assert.are.equal(0, #lead.service:Status().post.applicants)
  end)
end)

describe("LfgService authority", function()
  local world, lead, ann, eve, pid

  before_each(function()
    world = new_world()
    lead = new_client(world, "Lead")
    ann = new_client(world, "Ann")
    eve = new_client(world, "Eve")
    lead.service:Post(fields())
    pid = lead.board:Get("Lead").pid
    ann.service:Apply(pid, "tank")
  end)

  it("ignores an accept forged by someone who does not own the post", function()
    local ok, reason = ann.service:OnApply("Eve", { pid = pid, s = "accept", to = "Ann" })
    assert.is_false(ok)
    assert.are.equal("forbidden", reason)
    assert.are.equal("applied", ann.service:Status().application.state)
    -- The same for a decline.
    assert.are.equal("forbidden", select(2, ann.service:OnApply("Eve", { pid = pid, s = "decline", to = "Ann" })))
    assert.are.equal("applied", ann.service:Status().application.state)
  end)

  it("ignores an accept from a poster of another pid", function()
    eve.service:Post(fields({ title = "Eve's" }))
    ann.board:Apply("Eve", world.sent[#world.sent].payload)
    assert.are.equal("forbidden", select(2, ann.service:OnApply("Eve", { pid = pid, s = "accept", to = "Ann" })))
    assert.are.equal("applied", ann.service:Status().application.state)
  end)

  it("ignores an accept addressed to another client", function()
    local ok, reason = ann.service:OnApply("Lead", { pid = pid, s = "accept", to = "Eve" })
    assert.is_false(ok)
    assert.are.equal("not_for_me", reason)
    assert.are.equal("applied", ann.service:Status().application.state)
    assert.are.equal("not_for_me", select(2, ann.service:OnApply("Lead", { pid = pid, s = "decline", to = "Eve" })))
    assert.are.equal("applied", ann.service:Status().application.state)
  end)

  it("takes an accept only for the pid of its application", function()
    assert.are.equal(
      "unknown_application",
      select(2, ann.service:OnApply("Lead", { pid = "other", s = "accept", to = "Ann" }))
    )
    assert.are.equal(
      "unknown_application",
      select(2, eve.service:OnApply("Lead", { pid = pid, s = "accept", to = "Eve" }))
    )
  end)

  it("takes an accept whose target is written in another case", function()
    assert.is_true(ann.service:OnApply("lead", { pid = pid, s = "accept", to = "ann" }))
    assert.are.equal("invited", ann.service:Status().application.state)
  end)

  it("takes an accept only while the application is active", function()
    world.advance(Constants.LFG_APPLY_TIMEOUT)
    assert.are.equal(
      "unknown_application",
      select(2, ann.service:OnApply("Lead", { pid = pid, s = "accept", to = "Ann" }))
    )
    assert.are.equal("expired", ann.service:Status().application.state)
  end)

  it("does not take an accept from a sender the board does not know", function()
    ann.board:Remove("Lead")
    assert.are.equal("forbidden", select(2, ann.service:OnApply("Lead", { pid = pid, s = "accept", to = "Ann" })))
  end)

  it("does not let a stranger close or change the post of the leader", function()
    -- A post is only ever the post of its sender: Eve cannot touch the one of Lead.
    eve.service:OnPost("Eve", { pid = pid, rev = 9, s = "closed", o = "full" })
    assert.are.equal("open", ann.board:Get("Lead").state)
    ann.service:OnPost("Eve", { pid = pid, rev = 9, s = "closed", o = "full" })
    assert.are.equal("open", ann.board:Get("Lead").state)
    assert.are.equal("applied", ann.service:Status().application.state)
  end)

  it("does not take a post from itself", function()
    assert.are.same(
      { false, "self" },
      { lead.service:OnPost("Lead", { pid = "x", rev = 1, s = "closed", o = "full" }) }
    )
  end)
end)

describe("LfgService joining", function()
  local world, lead, ann, bob, pid

  before_each(function()
    world = new_world()
    lead = new_client(world, "Lead")
    ann = new_client(world, "Ann")
    bob = new_client(world, "Bob")
    lead.service:Post(fields({ needs = { tank = 1, heal = 1, dps = 0 } }))
    pid = lead.board:Get("Lead").pid
    ann.service:Apply(pid, "tank")
    lead.service:Invite("Ann")
  end)

  it("marks the application as joined when the applicant is in the leader's group", function()
    ann.group.Lead = true
    ann.service:OnGroupChanged()
    local app = ann.service:Status().application
    assert.are.equal("joined", app.state)
    assert.is_nil(app.left)
    world.advance(Constants.LFG_INVITE_TIMEOUT * 2)
    assert.are.equal("joined", ann.service:Status().application.state)
  end)

  it("lowers the need of the joined role and republishes with a higher rev", function()
    join(ann, lead)
    local status = lead.service:Status().post
    assert.are.same({ tank = 0, heal = 1, dps = 0 }, status.needs)
    assert.are.equal(2, status.members)
    assert.are.equal(2, status.rev)
    assert.are.equal(0, #status.applicants)
    local last = world.sent[#world.sent].payload
    assert.are.equal("open", last.s)
    assert.are.equal(2, last.rev)
    assert.are.equal(2, bob.board:Get("Lead").members)
    assert.are.equal("joined", ann.service:Status().application.state)
  end)

  it("closes the post as full when no need is left", function()
    join(ann, lead)
    bob.service:Apply(pid, "heal")
    lead.service:Invite("Bob")
    join(bob, lead)
    assert.is_nil(lead.service:Status().post)
    assert.are.equal("Lead:closed=full", sentKinds(world)[#world.sent])
    assert.are.equal(0, bob.board:OpenCount())
    assert.are.equal("closed", ann.board:Get("Lead").state)
  end)

  it("closes the post as full when the party reaches five", function()
    lead.service:Update({ needs = { tank = 1, heal = 1, dps = 2 } })
    lead.size = 5
    lead.group = { A = true, B = true, C = true, D = true }
    lead.service:OnGroupChanged()
    assert.is_nil(lead.service:Status().post)
    assert.are.equal("Lead:closed=full", sentKinds(world)[#world.sent])
  end)

  it("fits the needs in the room left when the party grew some other way", function()
    lead.service:Update({ needs = { tank = 1, heal = 1, dps = 2 } })
    lead.size = 3
    lead.group = { A = true, B = true }
    lead.service:OnGroupChanged()
    local status = lead.service:Status().post
    assert.are.equal(3, status.members)
    assert.are.same({ tank = 1, heal = 1, dps = 0 }, status.needs)
  end)

  it("takes a joined applicant who was never invited from the board", function()
    bob.service:Apply(pid, "heal")
    join(bob, lead)
    assert.are.same({ tank = 1, heal = 0, dps = 0 }, lead.service:Status().post.needs)
    assert.are.same({ "Ann" }, { lead.service:Status().post.applicants[1].name })
  end)

  it("does not republish when nothing changed", function()
    local before = #world.sent
    lead.service:OnGroupChanged()
    assert.are.equal(before, #world.sent)
  end)

  it("keeps the new rev for the next republish when the send is refused", function()
    lead.locked = true
    join(ann, lead)
    assert.are.equal(2, lead.service:Status().post.rev)
    assert.are.equal(2, lead.board:Get("Lead").rev)
    lead.locked = false
    assert.is_true(lead.service:Republish())
    assert.are.equal(2, world.sent[#world.sent].payload.rev)
  end)

  it("ends an application whose post closed while applied", function()
    bob.service:Apply(pid, "heal")
    lead.service:Close()
    local app = bob.service:Status().application
    assert.are.equal("expired", app.state)
    assert.are.equal("post_closed", app.reason)
    assert.is_nil(app.left)
    -- The one that was invited, too.
    assert.are.equal("expired", ann.service:Status().application.state)
    assert.are.equal("post_closed", ann.service:Status().application.reason)
  end)

  it("ends an application whose post was replaced by a new one", function()
    lead.service:Post(fields({ title = "Second" }))
    assert.are.equal("expired", ann.service:Status().application.state)
    assert.are.equal("post_closed", ann.service:Status().application.reason)
  end)

  it("reads a close as a join when the applicant is already in the group", function()
    ann.group.Lead = true
    lead.service:Close()
    assert.are.equal("joined", ann.service:Status().application.state)
  end)

  it("ignores a repeat of the open post for the application", function()
    lead.service:Republish()
    assert.are.equal("invited", ann.service:Status().application.state)
  end)

  it("does not end the application of another leader when an unrelated post closes", function()
    local eve = new_client(world, "Eve")
    eve.service:Post(fields({ title = "Eve's" }))
    eve.service:Close()
    assert.are.equal("invited", ann.service:Status().application.state)
  end)

  it("drops the application when its post disappears from the board, on the sweep", function()
    world.advance(Constants.LFG_POST_TTL + 1)
    ann.service:Sweep()
    local app = ann.service:Status().application
    assert.are.equal("expired", app.state)
  end)

  it("keeps the application on the sweep while its post is on the board", function()
    ann.service:Sweep()
    assert.are.equal("invited", ann.service:Status().application.state)
    assert.are.equal(1, ann.board.count)
  end)

  it("prunes the board on the sweep", function()
    bob.board:Apply("Lead", world.sent[1].payload)
    world.advance(Constants.LFG_POST_TTL + 1)
    bob.service:Sweep()
    assert.are.equal(0, bob.board.count)
  end)
end)

describe("LfgService party seats", function()
  local world, lead, ann

  before_each(function()
    world = new_world()
    lead = new_client(world, "Lead")
    ann = new_client(world, "Ann")
    lead.seats = { { name = "Lead", class = "WARRIOR" } }
    lead.role = "tank"
  end)

  local function lastParty()
    return world.sent[#world.sent].payload.party
  end

  it("posts the leader's class and declared role, and the board of the others shows it", function()
    assert.is_true(lead.service:Post(fields()))
    assert.are.same({ { c = "WARRIOR", r = "tank" } }, lastParty())
    assert.are.same({ { c = "WARRIOR", r = "tank" } }, ann.board:Get("Lead").party)
    assert.are.same({ { c = "WARRIOR", r = "tank" } }, lead.service:Status().post.party)
  end)

  it("gives a joined applicant the role they applied as, and none to who was there before", function()
    lead.size = 2
    lead.group = { Old = true }
    lead.seats = { { name = "Lead", class = "WARRIOR" }, { name = "Old", class = "MAGE" } }
    lead.service:Post(fields({ needs = { tank = 0, heal = 1, dps = 2 } }))
    assert.are.same({ { c = "WARRIOR", r = "tank" }, { c = "MAGE" } }, lastParty())
    local pid = lead.board:Get("Lead").pid
    ann.service:Apply(pid, "heal")
    lead.service:Invite("Ann")
    lead.seats[3] = { name = "Ann", class = "PRIEST" }
    join(ann, lead)
    assert.are.same({ { c = "WARRIOR", r = "tank" }, { c = "MAGE" }, { c = "PRIEST", r = "heal" } }, lastParty())
  end)

  it("matches a joined applicant whose name carries a realm", function()
    local post = lead.service
    post:Post(fields())
    local pid = lead.board:Get("Lead").pid
    post:OnApply("Ann-Realm", { pid = pid, s = "apply", role = "dps" })
    lead.group["Ann-Realm"] = true
    lead.size = 2
    lead.seats = { { name = "Lead", class = "WARRIOR" }, { name = "Ann", class = "ROGUE" } }
    post:OnGroupChanged()
    assert.are.same({ { c = "WARRIOR", r = "tank" }, { c = "ROGUE", r = "dps" } }, lastParty())
  end)

  it("republishes when only the seats changed", function()
    lead.seats = nil
    lead.service:Post(fields())
    assert.is_nil(lastParty())
    local before = #world.sent
    lead.seats = { { name = "Lead", class = "WARRIOR" } }
    lead.service:OnGroupChanged()
    assert.are.equal(before + 1, #world.sent)
    assert.are.same({ { c = "WARRIOR", r = "tank" } }, lastParty())
    lead.service:OnGroupChanged()
    assert.are.equal(before + 1, #world.sent)
  end)

  it("leaves the party out when the client cannot read all of it, and still posts", function()
    lead.size = 2
    lead.group = { Old = true }
    lead.seats = { { name = "Lead", class = "WARRIOR" } }
    assert.is_true(lead.service:Post(fields({ needs = { tank = 0, heal = 1, dps = 2 } })))
    assert.is_nil(lastParty())
    lead.seats = { { name = "Lead", class = "WARRIOR" }, { name = "Old" } }
    lead.service:OnGroupChanged()
    assert.is_nil(lastParty())
    lead.seatsFail = true
    assert.is_true(lead.service:Update({ title = "Stockade" }))
    assert.is_nil(lastParty())
  end)

  it("posts a seat without a role when the leader declared none", function()
    lead.role = nil
    lead.service:Post(fields())
    assert.are.same({ { c = "WARRIOR" } }, lastParty())
  end)
end)

describe("LfgService asking before acting", function()
  local world, lead, ann, pid

  before_each(function()
    world = new_world()
    lead = new_client(world, "Lead")
    ann = new_client(world, "Ann")
    lead.service:Post(fields())
    pid = lead.board:Get("Lead").pid
  end)

  it("says whether a group can be posted, with the reason", function()
    assert.is_true(ann.service:CanPost())
    ann.locked = true
    assert.are.same({ false, "locked" }, { ann.service:CanPost() })
    ann.locked = false
    ann.size, ann.leader = 3, false
    assert.are.same({ false, "not_leader" }, { ann.service:CanPost() })
    ann.size, ann.leader = 1, true
    ann.service:Apply(pid, "tank")
    assert.are.same({ false, "busy" }, { ann.service:CanPost() })
  end)

  it("says whether a post can be applied to, with the reason Apply gives", function()
    assert.is_true(ann.service:CanApply(pid))
    assert.is_true(ann.service:CanApply(pid, "tank"))
    assert.are.same({ false, "role" }, { ann.service:CanApply(pid, "nonsense") })
    assert.are.same({ false, "no_post" }, { ann.service:CanApply("nope") })
    assert.are.same({ false, "own_post" }, { lead.service:CanApply(pid) })
    ann.level = 5
    lead.service:Update({ minLevel = 50 })
    assert.are.same({ false, "level" }, { ann.service:CanApply(pid) })
    ann.level = 60
    ann.size = 2
    assert.are.same({ false, "in_group" }, { ann.service:CanApply(pid) })
    ann.size = 1
    ann.service:Apply(pid, "tank")
    assert.are.same({ false, "busy" }, { ann.service:CanApply(pid) })
  end)

  it("sends nothing when it only asks", function()
    local sent = #world.sent
    ann.service:CanApply(pid)
    ann.service:CanPost()
    assert.are.equal(sent, #world.sent)
  end)
end)

describe("LfgService what stays after it ended", function()
  local world, lead, ann, pid

  before_each(function()
    world = new_world()
    lead = new_client(world, "Lead")
    ann = new_client(world, "Ann")
    lead.service:Post(fields({ needs = { tank = 1, heal = 0, dps = 0 } }))
    pid = lead.board:Get("Lead").pid
    ann.service:Apply(pid, "tank")
  end)

  it("remembers an own post that closed by itself, and why", function()
    lead.service:Invite("Ann")
    join(ann, lead)
    local closed = lead.service:Status().closed
    assert.are.same({ title = "Deadmines", outcome = "full" }, closed)
    assert.is_nil(lead.service:Status().post)
  end)

  it("does not remember a post the leader closed", function()
    lead.service:Close()
    assert.is_nil(lead.service:Status().closed)
  end)

  it("forgets it with Dismiss and with a new post", function()
    lead.size, lead.raid = 4, true
    lead.service:OnGroupChanged()
    assert.are.equal("cancelled", lead.service:Status().closed.outcome)
    assert.is_true(lead.service:Dismiss())
    assert.is_nil(lead.service:Status().closed)
    lead.service:OnGroupChanged()
    lead.size, lead.raid = 1, false
    lead.service:Post(fields())
    lead.size, lead.raid = 4, true
    lead.service:OnGroupChanged()
    assert.is_truthy(lead.service:Status().closed)
    lead.size, lead.raid = 1, false
    lead.service:Post(fields())
    assert.is_nil(lead.service:Status().closed)
  end)

  it("clears a finished application but never an active one", function()
    local changes = ann.changes
    ann.service:Dismiss()
    assert.are.equal("applied", ann.service:Status().application.state)
    assert.is_true(ann.changes > changes)
    ann.service:Withdraw()
    assert.are.equal("withdrawn", ann.service:Status().application.state)
    ann.service:Dismiss()
    assert.is_nil(ann.service:Status().application)
  end)

  it("keeps an open post on Dismiss", function()
    lead.service:Dismiss()
    assert.is_truthy(lead.service:Status().post)
  end)
end)

describe("LfgService sweeping stale applicants", function()
  local world, lead, ann, bob

  before_each(function()
    world = new_world()
    lead = new_client(world, "Lead")
    ann = new_client(world, "Ann")
    bob = new_client(world, "Bob")
    lead.service:Post(fields())
    ann.service:Apply(lead.board:Get("Lead").pid, "tank")
  end)

  it("drops a pending row older than the apply timeout and says so", function()
    world.advance(Constants.LFG_APPLY_TIMEOUT + 1)
    local before = lead.changes
    lead.service:Sweep()
    assert.are.equal(0, #lead.service:Status().post.applicants)
    assert.is_true(lead.changes > before)
  end)

  it("keeps a recent pending row and stays quiet", function()
    world.advance(Constants.LFG_APPLY_TIMEOUT - 1)
    local before = lead.changes
    lead.service:Sweep()
    assert.are.equal(1, #lead.service:Status().post.applicants)
    assert.are.equal(before, lead.changes)
  end)

  it("tells the screen when the board lost a post", function()
    local watcher = new_client(world, "Watcher")
    watcher.board:Apply("Lead", world.sent[1].payload)
    local before = watcher.changes
    watcher.service:Sweep()
    assert.are.equal(before, watcher.changes)
    world.advance(Constants.LFG_POST_TTL + 1)
    watcher.service:Sweep()
    assert.is_true(watcher.changes > before)
  end)

  it("keeps invited and retry rows", function()
    bob.service:Apply(lead.board:Get("Lead").pid, "dps")
    lead.service:Invite("Ann")
    world.advance(Constants.LFG_APPLY_TIMEOUT - 20)
    lead.service:Invite("Bob")
    world.advance(21)
    lead.service:Sweep()
    local states = {}
    for _, row in ipairs(lead.service:Status().post.applicants) do
      states[row.name] = row.state
    end
    assert.are.same({ Ann = "retry", Bob = "invited" }, states)
  end)
end)

describe("LfgService closing with the party", function()
  local world, lead, ann

  before_each(function()
    world = new_world()
    lead = new_client(world, "Lead")
    ann = new_client(world, "Ann")
    lead.service:Post(fields())
  end)

  it("closes as cancelled when the poster stops being the leader", function()
    lead.size, lead.leader = 3, false
    lead.service:OnGroupChanged()
    assert.is_nil(lead.service:Status().post)
    assert.are.equal("Lead:closed=cancelled", sentKinds(world)[#world.sent])
    assert.are.equal(0, ann.board:OpenCount())
  end)

  it("closes as cancelled when the party becomes a raid", function()
    lead.size, lead.raid = 8, true
    lead.service:OnGroupChanged()
    assert.is_nil(lead.service:Status().post)
    assert.are.equal("Lead:closed=cancelled", sentKinds(world)[#world.sent])
  end)

  it("closes as cancelled when a raid of five or fewer forms", function()
    lead.size, lead.raid = 4, true
    lead.service:OnGroupChanged()
    assert.is_nil(lead.service:Status().post)
    assert.are.equal("Lead:closed=cancelled", sentKinds(world)[#world.sent])
  end)

  it("keeps the post when the raid check raises or answers something else than true", function()
    lead.size = 1
    lead.service.deps.isRaid = function()
      error("api")
    end
    lead.service:OnGroupChanged()
    lead.service.deps.isRaid = function()
      return 1
    end
    lead.service:OnGroupChanged()
    assert.is_truthy(lead.service:Status().post)
  end)

  it("closes as cancelled when the party disbands after someone joined", function()
    join(ann, lead)
    assert.is_truthy(lead.service:Status().post)
    lead.size, lead.group = 1, {}
    lead.service:OnGroupChanged()
    assert.is_nil(lead.service:Status().post)
    assert.are.equal("Lead:closed=cancelled", sentKinds(world)[#world.sent])
  end)

  it("closes as cancelled when a party that was posted disbands", function()
    lead.size, lead.group = 2, { A = true }
    lead.service:Post(fields({ needs = { tank = 1, heal = 1, dps = 1 } }))
    lead.size, lead.group = 1, {}
    lead.service:OnGroupChanged()
    assert.is_nil(lead.service:Status().post)
  end)

  it("keeps a post of a leader who is still alone", function()
    lead.service:OnGroupChanged()
    assert.is_truthy(lead.service:Status().post)
    assert.are.equal(1, #world.sent)
  end)

  it("does not close when the client cannot say who leads or how big the group is", function()
    lead.size = 3
    lead.service.deps.isLeader = function()
      error("api")
    end
    lead.service:OnGroupChanged()
    assert.is_truthy(lead.service:Status().post)
    lead.service.deps.groupSize = function()
      return nil
    end
    lead.service:OnGroupChanged()
    assert.is_truthy(lead.service:Status().post)
  end)

  it("does nothing without a post or an application", function()
    ann.service:OnGroupChanged()
    assert.is_nil(ann.service:Status().post)
    assert.is_nil(ann.service:Status().application)
  end)
end)

describe("LfgService.Eligibility", function()
  local function rules(overrides)
    local state = { locked = false, group = false, raid = false, leader = true, size = 1, combat = false }
    for k, v in pairs(overrides or {}) do
      state[k] = v
    end
    local platform = {
      IsInGroup = function()
        return state.group
      end,
      IsInRaid = function()
        return state.raid
      end,
      IsInCombat = function()
        return state.combat
      end,
      IsGroupLeader = function()
        return state.leader
      end,
      GetGroupSize = function()
        return state.size
      end,
    }
    return ns.LfgService.Eligibility(platform, function()
      return state.locked
    end)
  end

  it("lets a free player post, apply and invite", function()
    local r = rules()
    assert.is_true(r.post())
    assert.is_true(r.apply())
    assert.is_true(r.invite())
  end)

  it("lets the leader of a party with room post and invite", function()
    local r = rules({ group = true, size = 3 })
    assert.is_true(r.post())
    assert.is_true(r.invite())
  end)

  it("refuses with a reason", function()
    assert.are.same({ false, "locked" }, { rules({ locked = true }).post() })
    assert.are.same({ false, "locked" }, { rules({ locked = true }).apply() })
    assert.are.same({ false, "locked" }, { rules({ locked = true }).invite() })
    assert.are.same({ false, "raid" }, { rules({ group = true, raid = true, size = 8 }).post() })
    assert.are.same({ false, "not_leader" }, { rules({ group = true, leader = false, size = 3 }).post() })
    assert.are.same({ false, "not_leader" }, { rules({ group = true, leader = false, size = 3 }).invite() })
    assert.are.same({ false, "full" }, { rules({ group = true, size = 5 }).post() })
    assert.are.same({ false, "full" }, { rules({ group = true, size = 5 }).invite() })
    assert.are.same({ false, "in_group" }, { rules({ group = true, size = 2 }).apply() })
    assert.are.same({ false, "combat" }, { rules({ combat = true }).invite() })
  end)
end)

describe("LfgService new group alert", function()
  local world, lead, ann

  before_each(function()
    world = new_world()
    lead = new_client(world, "Lead")
    ann = new_client(world, "Ann")
    -- Past the warm-up: every post that was open at login has been repeated by now.
    world.advance(ns.Constants.LFG_ALERT_WARMUP)
  end)

  it("tells the others once when a new group is posted, never the leader", function()
    lead.service:Post(fields())
    assert.are.same({ "Lead:Deadmines" }, ann.alerts)
    assert.is_nil(lead.alerts)
    -- A repeat, an update and the close of the same post do not alert again.
    lead.service:Republish()
    lead.service:Update({ title = "Deadmines run" })
    lead.service:Close()
    assert.are.same({ "Lead:Deadmines" }, ann.alerts)
  end)

  it("alerts again for a new post of the same leader", function()
    lead.service:Post(fields())
    lead.service:Close()
    lead.service:Post(fields({ title = "Stockade" }))
    assert.are.same({ "Lead:Deadmines", "Lead:Stockade" }, ann.alerts)
  end)

  it("stays quiet during the warm-up after login, when old posts arrive as new", function()
    local late = new_client(world, "Late")
    lead.service:Post(fields())
    assert.is_nil(late.alerts)
    assert.are.equal(1, late.board:OpenCount())
    world.advance(ns.Constants.LFG_ALERT_WARMUP)
    lead.service:Close()
    lead.service:Post(fields({ title = "Stockade" }))
    assert.are.same({ "Lead:Stockade" }, late.alerts)
  end)

  it("keeps the post on the board when the alert fails", function()
    ann.alertFails = true
    lead.service:Post(fields())
    assert.are.equal(1, ann.board:OpenCount())
  end)
end)
