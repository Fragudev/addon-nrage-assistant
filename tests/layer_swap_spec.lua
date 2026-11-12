local function load_swap()
  local ns = {}
  for _, path in ipairs({ "Core/Constants", "Core/Validate", "Domain/LayerModel", "Domain/LayerSwap" }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_swap()
local Constants = ns.Constants

local TARGET = { map = 0, layer = 222 }
local OTHER = { map = 0, layer = 111 }

-- A small world with a clock, timers and a guild channel that delivers a message to every other client at once.
-- Each client has a fake platform, so the eligibility rules are the real ones.
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

local function new_client(world, name, layer)
  local c = {
    name = name,
    layer = layer,
    locked = false,
    grouped = false,
    raid = false,
    leader = false,
    size = 0,
    inInstance = false,
    inCombat = false,
    changes = 0,
    invites = {},
    leaves = 0,
    joinedAt = {},
    lose = false,
  }
  local platform = {
    IsInGroup = function()
      return c.grouped
    end,
    IsInRaid = function()
      return c.raid
    end,
    IsInInstance = function()
      return c.inInstance
    end,
    IsInCombat = function()
      return c.inCombat
    end,
    IsGroupLeader = function()
      return c.leader
    end,
    GetGroupSize = function()
      return c.size
    end,
  }
  local function ownLayer()
    return c.layer
  end
  local function isLocked()
    return c.locked
  end
  c.swap = ns.LayerSwap.New({
    now = world.now,
    schedule = world.schedule,
    send = function(payload)
      if c.locked then
        return false, "locked"
      end
      if c.sendFails then
        error("transport")
      end
      world.sent[#world.sent + 1] = { from = name, payload = payload }
      if not world.lose then
        for _, other in ipairs(world.clients) do
          if other ~= c then
            other.swap:OnMessage(name, payload)
          end
        end
      end
      return true
    end,
    isLocked = isLocked,
    ownName = function()
      return name
    end,
    newId = function()
      world.counter = world.counter + 1
      return "rid-" .. world.counter
    end,
    ownLayer = ownLayer,
    -- Only the zone specs give the flow the zone of the player; the others run as an older client.
    ownZone = world.withZones and function()
      return c.zone
    end or nil,
    eligibility = ns.LayerSwap.Eligibility(platform, ownLayer, isLocked),
    invite = function(who)
      c.invites[#c.invites + 1] = who
      return not c.inviteFails, "error"
    end,
    leave = function()
      c.leaves = c.leaves + 1
      return not c.leaveFails, "error"
    end,
    onJoined = function(t)
      c.joinedAt[#c.joinedAt + 1] = t
    end,
    onChange = function()
      c.changes = c.changes + 1
      if c.changeFails then
        error("ui")
      end
    end,
  })
  world.clients[#world.clients + 1] = c
  return c
end

local function kinds(world)
  local list = {}
  for _, entry in ipairs(world.sent) do
    list[#list + 1] = entry.from .. ":" .. entry.payload.s .. (entry.payload.o and ("=" .. entry.payload.o) or "")
  end
  return list
end

describe("LayerSwap happy path", function()
  local world, requester, helper

  before_each(function()
    world = new_world()
    requester = new_client(world, "Req", OTHER)
    helper = new_client(world, "Help", TARGET)
  end)

  it("takes a swap from request to done on both sides", function()
    assert.is_true(requester.swap:Request(TARGET.map, TARGET.layer))
    assert.are.equal("request", requester.swap:Status().stage)
    local seen = helper.swap:Status()
    assert.are.equal("helper", seen.role)
    assert.are.equal("Req", seen.requester)
    assert.are.equal(TARGET.layer, seen.layer)

    assert.is_true(helper.swap:Offer())
    assert.are.equal("assign", requester.swap:Status().stage)
    assert.are.equal("Help", requester.swap:Status().helper)
    assert.are.equal("assigned", helper.swap:Status().stage)

    assert.is_true(helper.swap:Invite())
    assert.are.same({ "Req" }, helper.invites)
    assert.are.equal("invited", helper.swap:Status().stage)

    assert.is_true(requester.swap:OnGroupJoined())
    assert.are.equal("joined", requester.swap:Status().stage)
    assert.are.same({ world.clock }, requester.joinedAt)

    assert.is_true(requester.swap:OnLayerConfirmed({ map = 0, layer = 222 }))
    local done = requester.swap:Status()
    assert.are.equal("done", done.stage)
    assert.are.equal("done", done.outcome)
    assert.is_nil(helper.swap:Status())

    assert.is_true(requester.swap:LeaveGroup())
    assert.are.equal(1, requester.leaves)
    assert.is_nil(requester.swap:Status())
    assert.are.same({ "Req:request", "Help:offer", "Req:assign", "Req:close=done" }, kinds(world))
  end)

  it("sends the target layer in the request and the picked helper in the assign", function()
    requester.swap:Request(TARGET.map, TARGET.layer)
    helper.swap:Offer()
    assert.are.same({ rid = "rid-1", s = "request", map = 0, layer = 222 }, world.sent[1].payload)
    assert.are.same({ rid = "rid-1", s = "assign", helper = "Help" }, world.sent[3].payload)
  end)

  it("is done when the target is confirmed even before the group event is seen", function()
    requester.swap:Request(TARGET.map, TARGET.layer)
    helper.swap:Offer()
    assert.is_true(requester.swap:OnLayerConfirmed(TARGET))
    assert.are.equal("done", requester.swap:Status().stage)
  end)

  it("ignores a confirmed layer that is not the target, and group events at other steps", function()
    assert.is_false(requester.swap:OnGroupJoined())
    assert.is_false(requester.swap:OnLayerConfirmed(TARGET))
    requester.swap:Request(TARGET.map, TARGET.layer)
    helper.swap:Offer()
    requester.swap:OnGroupJoined()
    assert.is_false(requester.swap:OnLayerConfirmed(OTHER))
    assert.is_false(requester.swap:OnGroupJoined())
    assert.are.equal("joined", requester.swap:Status().stage)
  end)

  it("shows how long a step has left", function()
    requester.swap:Request(TARGET.map, TARGET.layer)
    world.advance(20)
    assert.are.equal(Constants.LAYER_REQUEST_TIMEOUT - 20, requester.swap:Status().left)
    assert.is_nil(helper.swap:Status().left)
  end)

  it("tells the UI about each change, and survives a UI that raises", function()
    requester.changeFails = true
    local before = requester.changes
    assert.is_true(requester.swap:Request(TARGET.map, TARGET.layer))
    assert.is_true(requester.changes > before)
  end)
end)

describe("LayerSwap offers", function()
  local world, requester, first, second

  before_each(function()
    world = new_world()
    requester = new_client(world, "Req", OTHER)
    first = new_client(world, "One", TARGET)
    second = new_client(world, "Two", TARGET)
  end)

  it("asks every eligible member on the layer", function()
    requester.swap:Request(TARGET.map, TARGET.layer)
    assert.is_truthy(first.swap:Status())
    assert.is_truthy(second.swap:Status())
  end)

  it("picks the first offer and closes the popup of the others", function()
    requester.swap:Request(TARGET.map, TARGET.layer)
    assert.is_true(first.swap:Offer())
    assert.are.equal("One", requester.swap:Status().helper)
    assert.is_nil(second.swap:Status())
    assert.is_false(second.swap:Offer())
    assert.are.equal("assigned", first.swap:Status().stage)
  end)

  it("ignores a later offer", function()
    requester.swap:Request(TARGET.map, TARGET.layer)
    first.swap:Offer()
    local ok, reason = requester.swap:OnMessage("Two", { rid = "rid-1", s = "offer" })
    assert.is_false(ok)
    assert.are.equal("late", reason)
    assert.are.equal("One", requester.swap:Status().helper)
  end)

  it("ignores an offer for another request", function()
    requester.swap:Request(TARGET.map, TARGET.layer)
    local ok, reason = requester.swap:OnMessage("Two", { rid = "rid-9", s = "offer" })
    assert.is_false(ok)
    assert.are.equal("unknown_swap", reason)
    assert.are.equal("request", requester.swap:Status().stage)
  end)

  it("keeps waiting when the assign cannot be sent", function()
    requester.swap:Request(TARGET.map, TARGET.layer)
    requester.locked = true
    local ok, reason = requester.swap:OnMessage("One", { rid = "rid-1", s = "offer" })
    assert.is_false(ok)
    assert.are.equal("locked", reason)
    assert.are.equal("request", requester.swap:Status().stage)
    requester.locked = false
    requester.sendFails = true
    ok, reason = requester.swap:OnMessage("One", { rid = "rid-1", s = "offer" })
    assert.is_false(ok)
    assert.are.equal("error", reason)
  end)

  it("lets a helper who ignored the request stop seeing it", function()
    requester.swap:Request(TARGET.map, TARGET.layer)
    assert.is_true(second.swap:Ignore())
    assert.is_nil(second.swap:Status())
    -- A helper who already offered stays in the swap, only hidden.
    assert.is_true(first.swap:Offer())
    assert.is_false(first.swap:Offer())
  end)

  it("keeps an offered helper in the swap when they hide the popup", function()
    requester.swap:Request(TARGET.map, TARGET.layer)
    local other = new_client(new_world(), "Solo", TARGET)
    assert.is_false(other.swap:Ignore())
    -- With the offer sent but the requester not choosing them, hiding is not leaving.
    world.lose = true
    second.swap:Offer()
    assert.is_true(second.swap:Ignore())
    assert.is_true(second.swap:Status().hidden)
    world.lose = false
    requester.swap:OnMessage("Two", { rid = "rid-1", s = "offer" })
    assert.is_false(second.swap:Status() == nil)
    assert.is_false(second.swap:Status().hidden)
  end)
end)

describe("LayerSwap authority", function()
  local world, requester, helper

  before_each(function()
    world = new_world()
    requester = new_client(world, "Req", OTHER)
    helper = new_client(world, "Help", TARGET)
    requester.swap:Request(TARGET.map, TARGET.layer)
  end)

  it("takes an assign only from the requester", function()
    local ok, reason = helper.swap:OnMessage("Mallory", { rid = "rid-1", s = "assign", helper = "Help" })
    assert.is_false(ok)
    assert.are.equal("forbidden", reason)
    assert.are.equal("request", helper.swap:Status().stage)
    ok = helper.swap:OnMessage("Mallory", { rid = "rid-1", s = "assign", helper = "Mallory" })
    assert.is_false(ok)
    assert.are.equal("request", helper.swap:Status().stage)
  end)

  it("takes a close only from the requester", function()
    local ok, reason = helper.swap:OnMessage("Mallory", { rid = "rid-1", s = "close", o = "done" })
    assert.is_false(ok)
    assert.are.equal("forbidden", reason)
    assert.is_truthy(helper.swap:Status())
    assert.is_true(helper.swap:OnMessage("Req", { rid = "rid-1", s = "close", o = "expired" }))
    assert.is_nil(helper.swap:Status())
  end)

  it("lets the requester hear a close only from the picked helper, and only a decline", function()
    helper.swap:Offer()
    for _, attempt in ipairs({
      { "Mallory", "declined" },
      { "Help", "done" },
      { "Help", "cancelled" },
    }) do
      local ok, reason = requester.swap:OnMessage(attempt[1], { rid = "rid-1", s = "close", o = attempt[2] })
      assert.is_false(ok)
      assert.are.equal("forbidden", reason)
    end
    assert.are.equal("assign", requester.swap:Status().stage)
  end)

  it("ignores messages about a swap it does not know", function()
    for _, step in ipairs({
      { s = "assign", helper = "Help" },
      { s = "close", o = "done" },
      { s = "offer" },
    }) do
      step.rid = "rid-404"
      local ok, reason = helper.swap:OnMessage("Req", step)
      assert.is_false(ok)
      assert.are.equal("unknown_swap", reason)
    end
    assert.is_false(helper.swap:OnMessage("Req", { rid = "rid-1", s = "other" }))
  end)

  it("does not let an assigned name that was never offered make a helper act", function()
    local ok, reason = helper.swap:OnMessage("Req", { rid = "rid-1", s = "assign", helper = "Help" })
    assert.is_false(ok)
    assert.are.equal("not_offered", reason)
    assert.are.equal("request", helper.swap:Status().stage)
  end)

  it("compares the helper name ignoring case and spaces", function()
    local named = new_world()
    local req2 = new_client(named, "Req", OTHER)
    local help2 = new_client(named, "Yonemon Gg", TARGET)
    req2.swap:Request(TARGET.map, TARGET.layer)
    help2.swap:Offer()
    assert.are.equal("assigned", help2.swap:Status().stage)
    assert.is_true(help2.swap:OnMessage("Req", { rid = "rid-1", s = "assign", helper = "YONEMON gg" }))
  end)
end)

describe("LayerSwap timeouts", function()
  local world, requester, helper

  before_each(function()
    world = new_world()
    requester = new_client(world, "Req", OTHER)
    helper = new_client(world, "Help", TARGET)
    requester.swap:Request(TARGET.map, TARGET.layer)
  end)

  it("expires a request nobody answers", function()
    world.advance(Constants.LAYER_REQUEST_TIMEOUT - 1)
    assert.are.equal("request", requester.swap:Status().stage)
    world.advance(1)
    local status = requester.swap:Status()
    assert.are.equal("closed", status.stage)
    assert.are.equal("expired", status.outcome)
    assert.is_nil(helper.swap:Status())
    assert.are.same({ "Req:request", "Req:close=expired" }, kinds(world))
  end)

  it("expires an assignment when nobody joins a group", function()
    helper.swap:Offer()
    world.advance(Constants.LAYER_ASSIGN_TIMEOUT)
    assert.are.equal("expired", requester.swap:Status().outcome)
    assert.is_nil(helper.swap:Status())
  end)

  it("gives up confirming the move and still offers to leave the group", function()
    helper.swap:Offer()
    requester.swap:OnGroupJoined()
    world.advance(Constants.LAYER_CONFIRM_TIMEOUT)
    local status = requester.swap:Status()
    assert.are.equal("closed", status.stage)
    assert.are.equal("unconfirmed", status.outcome)
    assert.is_true(status.joined)
    assert.is_true(requester.swap:LeaveGroup())
    assert.is_nil(requester.swap:Status())
    assert.are.equal("Req:close=unconfirmed", kinds(world)[#kinds(world)])
  end)

  it("does not run the timeout of a step that already moved on", function()
    helper.swap:Offer()
    world.advance(Constants.LAYER_REQUEST_TIMEOUT + 1)
    assert.are.equal("assign", requester.swap:Status().stage)
  end)

  it("does not run the timeout of a swap that was replaced", function()
    requester.swap:Cancel()
    requester.swap:Dismiss()
    assert.is_true(requester.swap:Request(TARGET.map, TARGET.layer))
    world.advance(Constants.LAYER_REQUEST_TIMEOUT - 5)
    assert.are.equal("request", requester.swap:Status().stage)
  end)

  it("drops a swap whose close was lost after the maximum age", function()
    world.lose = true
    requester.swap:Cancel()
    requester.swap:Dismiss()
    world.lose = false
    world.clock = world.clock + 0
    requester.swap:Request(TARGET.map, TARGET.layer)
    -- A helper that heard the request and then lost every message.
    assert.is_truthy(helper.swap:Status())
    world.lose = true
    world.advance(Constants.LAYER_SWAP_MAX_AGE - 1)
    assert.is_truthy(helper.swap:Status())
    world.advance(1)
    assert.is_nil(helper.swap:Status())
  end)

  it("keeps a swap alive while there is activity", function()
    world.lose = true
    world.advance(Constants.LAYER_SWAP_MAX_AGE - 50)
    helper.swap:Offer()
    world.advance(100)
    assert.is_truthy(helper.swap:Status())
    world.advance(Constants.LAYER_SWAP_MAX_AGE)
    assert.is_nil(helper.swap:Status())
  end)
end)

describe("LayerSwap cancel and decline", function()
  local world, requester, helper

  before_each(function()
    world = new_world()
    requester = new_client(world, "Req", OTHER)
    helper = new_client(world, "Help", TARGET)
    requester.swap:Request(TARGET.map, TARGET.layer)
  end)

  it("lets the requester cancel at any step and tells the helper", function()
    helper.swap:Offer()
    assert.is_true(requester.swap:Cancel())
    assert.are.equal("cancelled", requester.swap:Status().outcome)
    assert.is_nil(helper.swap:Status())
    assert.are.equal("Req:close=cancelled", kinds(world)[#kinds(world)])
  end)

  it("closes a finished swap when cancel is pressed again", function()
    requester.swap:Cancel()
    assert.is_true(requester.swap:Cancel())
    assert.is_nil(requester.swap:Status())
    assert.is_false(requester.swap:Cancel())
  end)

  it("cannot cancel or leave without a swap of its own", function()
    assert.is_false(helper.swap:Cancel())
    assert.is_false(helper.swap:LeaveGroup())
    assert.is_false(requester.swap:LeaveGroup())
    assert.is_false(new_client(world, "Idle", OTHER).swap:Dismiss())
  end)

  it("tells the requester when the picked helper declines, and lets them ask again", function()
    helper.swap:Offer()
    assert.is_true(helper.swap:Decline())
    assert.is_nil(helper.swap:Status())
    local status = requester.swap:Status()
    assert.are.equal("declined", status.outcome)
    assert.are.equal("Help", status.helper)
    assert.is_true(requester.swap:Request(TARGET.map, TARGET.layer))
    assert.are.equal("request", requester.swap:Status().stage)
  end)

  it("cannot decline or invite before being picked", function()
    assert.is_false(helper.swap:Decline())
    assert.is_false(helper.swap:Invite())
  end)

  it("lets the requester leave the group from the joined step, which cancels the swap", function()
    helper.swap:Offer()
    requester.swap:OnGroupJoined()
    assert.is_true(requester.swap:LeaveGroup())
    assert.are.equal(1, requester.leaves)
    assert.is_nil(requester.swap:Status())
    assert.is_nil(helper.swap:Status())
    assert.are.equal("Req:close=cancelled", kinds(world)[#kinds(world)])
  end)

  it("keeps the swap when the client refuses to leave the group", function()
    helper.swap:Offer()
    requester.swap:OnGroupJoined()
    requester.leaveFails = true
    local ok, reason = requester.swap:LeaveGroup()
    assert.is_false(ok)
    assert.are.equal("error", reason)
    assert.are.equal("joined", requester.swap:Status().stage)
  end)

  it("refuses to dismiss a swap that is still running", function()
    local ok, reason = requester.swap:Dismiss()
    assert.is_false(ok)
    assert.are.equal("busy", reason)
  end)

  it("treats dismissing as ignoring for a helper", function()
    assert.is_true(helper.swap:Dismiss())
    assert.is_nil(helper.swap:Status())
  end)
end)

describe("LayerSwap invite", function()
  local world, requester, helper

  before_each(function()
    world = new_world()
    requester = new_client(world, "Req", OTHER)
    helper = new_client(world, "Help", TARGET)
    requester.swap:Request(TARGET.map, TARGET.layer)
    helper.swap:Offer()
  end)

  it("re-checks the rules when the button is clicked", function()
    helper.layer = OTHER
    local ok, reason = helper.swap:Invite()
    assert.is_false(ok)
    assert.are.equal("other_layer", reason)
    assert.are.same({}, helper.invites)
    assert.are.equal("assigned", helper.swap:Status().stage)
  end)

  it("tells why the client refused the invite and allows another try", function()
    helper.inviteFails = true
    local ok, reason = helper.swap:Invite()
    assert.is_false(ok)
    assert.are.equal("error", reason)
    helper.inviteFails = false
    assert.is_true(helper.swap:Invite())
  end)

  it("allows inviting again from the invited step", function()
    assert.is_true(helper.swap:Invite())
    helper.grouped, helper.leader, helper.size = true, true, 2
    assert.is_true(helper.swap:Invite())
    assert.are.same({ "Req", "Req" }, helper.invites)
  end)

  it("lets the picked helper decline after inviting", function()
    helper.swap:Invite()
    assert.is_true(helper.swap:Decline())
    assert.are.equal("declined", requester.swap:Status().outcome)
  end)

  it("waits during the lockdown", function()
    helper.locked = true
    local ok, reason = helper.swap:Invite()
    assert.is_false(ok)
    assert.are.equal("locked", reason)
  end)
end)

describe("LayerSwap lockdown", function()
  local world, requester, helper

  before_each(function()
    world = new_world()
    requester = new_client(world, "Req", OTHER)
    helper = new_client(world, "Help", TARGET)
  end)

  it("does not request during the lockdown", function()
    requester.locked = true
    local ok, reason = requester.swap:Request(TARGET.map, TARGET.layer)
    assert.is_false(ok)
    assert.are.equal("locked", reason)
    assert.is_nil(requester.swap:Status())
    assert.are.equal("locked", select(2, requester.swap:CanRequest()))
  end)

  it("does not offer during the lockdown, and offers afterwards", function()
    requester.swap:Request(TARGET.map, TARGET.layer)
    helper.locked = true
    local ok, reason = helper.swap:Offer()
    assert.is_false(ok)
    assert.are.equal("locked", reason)
    helper.locked = false
    assert.is_true(helper.swap:Offer())
  end)

  it("treats a lockdown check that raises as locked", function()
    local swap = ns.LayerSwap.New({
      isLocked = function()
        error("secret")
      end,
      eligibility = {},
    })
    assert.are.equal("locked", select(2, swap:CanRequest()))
  end)

  it("does not ask a helper who is locked down", function()
    helper.locked = true
    requester.swap:Request(TARGET.map, TARGET.layer)
    assert.is_nil(helper.swap:Status())
  end)
end)

describe("LayerSwap eligibility", function()
  local world, requester, helper

  before_each(function()
    world = new_world()
    requester = new_client(world, "Req", OTHER)
    helper = new_client(world, "Help", TARGET)
  end)

  local function refused(reason)
    local ok, why = requester.swap:Request(TARGET.map, TARGET.layer)
    assert.is_false(ok)
    assert.are.equal(reason, why)
    assert.is_nil(requester.swap:Status())
  end

  it("refuses a request from a requester in a group, an instance or combat", function()
    requester.grouped = true
    refused("in_group")
    requester.grouped = false
    requester.inInstance = true
    refused("in_instance")
    requester.inInstance = false
    requester.inCombat = true
    refused("in_combat")
  end)

  it("refuses a request for the own layer, and allows one from an unknown layer", function()
    requester.layer = TARGET
    refused("same_layer")
    requester.layer = nil
    assert.is_true(requester.swap:Request(TARGET.map, TARGET.layer))
  end)

  it("refuses a target that is not a layer", function()
    for _, target in ipairs({ { "x", 1 }, { 0, 0 }, { 0, -4 }, { 99999, 1 } }) do
      local ok, reason = requester.swap:Request(target[1], target[2])
      assert.is_false(ok)
      assert.are.equal("bad_target", reason)
    end
  end)

  it("refuses a second swap at the same time", function()
    assert.is_true(requester.swap:Request(TARGET.map, TARGET.layer))
    local ok, reason = requester.swap:Request(TARGET.map, TARGET.layer)
    assert.is_false(ok)
    assert.are.equal("busy", reason)
    assert.are.equal("busy", select(2, requester.swap:CanRequest()))
  end)

  it("keeps a helper with a swap out of another one", function()
    local second = new_client(world, "Second", OTHER)
    local third = new_client(world, "Third", OTHER)
    requester.swap:Request(TARGET.map, TARGET.layer)
    -- Help is already in the swap of Req: a request from Second does not reach them.
    assert.is_true(second.swap:Request(TARGET.map, TARGET.layer))
    assert.are.equal("Req", helper.swap:Status().requester)
    local ok, reason = helper.swap:OnMessage("Third", { rid = "rid-x", s = "request", map = 0, layer = 222 })
    assert.is_false(ok)
    assert.are.equal("busy", reason)
    assert.is_true(third.swap:CanRequest())
  end)

  it("lets the same requester replace their request", function()
    requester.swap:Request(TARGET.map, TARGET.layer)
    helper.swap:OnMessage("Req", { rid = "rid-2", s = "request", map = 0, layer = 222 })
    assert.are.equal("rid-2", helper.swap:Status().rid)
  end)

  it("does not ask members who cannot help", function()
    local far = new_client(world, "Far", OTHER)
    local unknown = new_client(world, "Unknown", nil)
    local instance = new_client(world, "Instance", TARGET)
    instance.inInstance = true
    local raid = new_client(world, "Raid", TARGET)
    raid.grouped, raid.raid, raid.leader, raid.size = true, true, true, 10
    local follower = new_client(world, "Follower", TARGET)
    follower.grouped, follower.size = true, 3
    local full = new_client(world, "Full", TARGET)
    full.grouped, full.leader, full.size = true, true, 5
    requester.swap:Request(TARGET.map, TARGET.layer)
    for _, client in ipairs({ far, unknown, instance, raid, follower, full }) do
      assert.is_nil(client.swap:Status(), client.name)
    end
  end)

  it("asks a member in combat, who can only help once combat ends", function()
    helper.inCombat = true
    requester.swap:Request(TARGET.map, TARGET.layer)
    assert.are.equal("request", helper.swap:Status().stage)
    local ok, reason = helper.swap:Offer()
    assert.is_false(ok)
    assert.are.equal("in_combat", reason)
    helper.inCombat = false
    assert.is_true(helper.swap:Offer())
  end)

  it("asks a leader of a party with a free slot", function()
    local leader = new_client(world, "Leader", TARGET)
    leader.grouped, leader.leader, leader.size = true, true, 3
    requester.swap:Request(TARGET.map, TARGET.layer)
    assert.is_truthy(leader.swap:Status())
  end)

  it("reports the reason a rule gave, and treats a rule that raises as a refusal", function()
    local swap = ns.LayerSwap.New({
      isLocked = function()
        return false
      end,
      eligibility = {
        requester = function()
          error("platform")
        end,
      },
    })
    local ok, reason = swap:CanRequest()
    assert.is_false(ok)
    assert.are.equal("error", reason)
  end)

  it("fails quietly when the transport fails", function()
    requester.sendFails = true
    local ok, reason = requester.swap:Request(TARGET.map, TARGET.layer)
    assert.is_false(ok)
    assert.are.equal("error", reason)
    assert.is_nil(requester.swap:Status())
  end)
end)

describe("LayerSwap:IsActive", function()
  it("is true from the request until the swap ends, on both sides", function()
    local world = new_world()
    local requester = new_client(world, "Req", OTHER)
    local helper = new_client(world, "Help", TARGET)
    assert.is_false(requester.swap:IsActive())
    requester.swap:Request(TARGET.map, TARGET.layer)
    assert.is_true(requester.swap:IsActive())
    assert.is_true(helper.swap:IsActive())
    requester.swap:Cancel()
    -- The requester keeps the finished swap on screen, but it no longer holds the flow.
    assert.is_false(requester.swap:IsActive())
    assert.is_false(helper.swap:IsActive())
  end)
end)

describe("LayerSwap zones (layers are per zone; the game only moves a player invited from the same zone)", function()
  local ELWYNN, WESTFALL = 1429, 1436
  local world, requester, helper

  local function on(zone, layer)
    return { map = layer.map, layer = layer.layer, zone = zone }
  end

  before_each(function()
    world = new_world()
    world.withZones = true
    requester = new_client(world, "Req", on(ELWYNN, OTHER))
    requester.zone = ELWYNN
    helper = new_client(world, "Help", on(ELWYNN, TARGET))
    helper.zone = ELWYNN
  end)

  it("sends the zone of the requester in the request and keeps it in the swap of both sides", function()
    assert.is_true(requester.swap:Request(TARGET.map, TARGET.layer))
    assert.are.equal(ELWYNN, world.sent[1].payload.zone)
    assert.are.equal(ELWYNN, requester.swap:Status().zone)
    assert.are.equal(ELWYNN, helper.swap:Status().zone)
    assert.is_true(helper.swap:Offer())
    assert.is_true(helper.swap:Invite())
    assert.are.same({ "Req" }, helper.invites)
  end)

  it("refuses a request while the zone of the requester is not known", function()
    requester.zone = nil
    local ok, why = requester.swap:Request(TARGET.map, TARGET.layer)
    assert.is_false(ok)
    assert.are.equal("unknown_zone", why)
    assert.is_nil(requester.swap:Status())
    assert.are.same({}, world.sent)
  end)

  it("does not ask a member on that layer in another zone", function()
    helper.layer = on(WESTFALL, TARGET)
    helper.zone = WESTFALL
    assert.is_true(requester.swap:Request(TARGET.map, TARGET.layer))
    assert.is_nil(helper.swap:Status())
  end)

  it("refuses an offer or an invite from a helper who left the zone of the request", function()
    assert.is_true(requester.swap:Request(TARGET.map, TARGET.layer))
    helper.layer = on(WESTFALL, TARGET)
    local ok, why = helper.swap:Offer()
    assert.is_false(ok)
    assert.are.equal("other_zone", why)
    helper.layer = on(ELWYNN, TARGET)
    assert.is_true(helper.swap:Offer())
    helper.layer = on(WESTFALL, TARGET)
    ok, why = helper.swap:Invite()
    assert.is_false(ok)
    assert.are.equal("other_zone", why)
    assert.are.same({}, helper.invites)
  end)

  it("still answers a request without a zone from an older requester", function()
    -- A request as an older client sends it: no zone.
    helper.swap:OnMessage("Old", { rid = "r-old", s = "request", map = TARGET.map, layer = TARGET.layer })
    local status = helper.swap:Status()
    assert.are.equal("Old", status.requester)
    assert.is_nil(status.zone)
    assert.is_true(helper.swap:Offer())
  end)
end)

describe("LayerSwap.Eligibility helper zone rule", function()
  local platform = {
    IsInGroup = function()
      return false
    end,
    IsInRaid = function()
      return false
    end,
    IsInInstance = function()
      return false
    end,
    IsInCombat = function()
      return false
    end,
    IsGroupLeader = function()
      return false
    end,
    GetGroupSize = function()
      return 0
    end,
  }

  local function helperRule(own)
    return ns.LayerSwap.Eligibility(platform, function()
      return own
    end, function()
      return false
    end).helper
  end

  it("needs the layer read in the zone of the request, and skips the check for a request without a zone", function()
    assert.is_true(helperRule({ map = 0, layer = 222, zone = 1429 })(0, 222, 1429))
    assert.are.same({ false, "other_zone" }, { helperRule({ map = 0, layer = 222, zone = 1436 })(0, 222, 1429) })
    assert.are.same({ false, "other_zone" }, { helperRule({ map = 0, layer = 222 })(0, 222, 1429) })
    assert.is_true(helperRule({ map = 0, layer = 222, zone = 1436 })(0, 222, nil))
    assert.are.same({ false, "unknown_layer" }, { helperRule(nil)(0, 222, 1429) })
  end)
end)
