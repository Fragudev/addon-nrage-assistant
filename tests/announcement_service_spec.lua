local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/EventModel",
    "Domain/AnnouncementModel",
    "Domain/AnnouncementService",
    "Sync/Protocol",
    "Sync/SyncRules",
    "Sync/AnnouncementSync",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local Service, Sync, Protocol, Constants = ns.AnnouncementService, ns.AnnouncementSync, ns.Protocol, ns.Constants

-- One simulated client with its own data, clock and role. What it sends is delivered to `peers` through the real
-- protocol validation, with the role the receiver knows for the sender.
local function client(name, role, roles)
  local c = {
    name = name,
    clock = 10000,
    store = { items = {}, tombstones = {} },
    seen = {},
    sent = {},
    popups = {},
    changes = 0,
    counter = 0,
    peers = {},
  }
  local function deliver(messageType, payload)
    c.sent[#c.sent + 1] = { t = messageType, p = payload }
    for _, peer in ipairs(c.peers) do
      local message = assert(Protocol.Validate(Protocol.Build(messageType, payload, "id-1")))
      Sync.Apply({
        store = peer.store,
        now = function()
          return peer.clock
        end,
        onApplied = function(announcement)
          peer.service:OnReceived(announcement)
        end,
      }, message, name, roles[name])
    end
  end
  c.service = Service.New({
    store = c.store,
    seen = c.seen,
    now = function()
      return c.clock
    end,
    ownName = function()
      return name
    end,
    ownRole = function()
      return role
    end,
    newId = function()
      c.counter = c.counter + 1
      return name .. "-" .. c.counter
    end,
    send = {
      upsert = function(announcement)
        deliver("ANN", Sync.UpsertPayload(announcement))
      end,
      delete = function(id)
        deliver("ANN_DEL", Sync.DeletePayload(c.store, id))
      end,
    },
    onChange = function()
      c.changes = c.changes + 1
    end,
    onPopup = function(announcement)
      c.popups[#c.popups + 1] = announcement.id
    end,
  })
  return c
end

local ROLES = { Gm = "gm", Co = "cogm", Off = "officer", Mem = "member" }

local function world()
  local gm, co = client("Gm", "gm", ROLES), client("Co", "cogm", ROLES)
  local off, mem = client("Off", "officer", ROLES), client("Mem", "member", ROLES)
  local all = { gm, co, off, mem }
  for _, c in ipairs(all) do
    for _, other in ipairs(all) do
      if other ~= c then
        c.peers[#c.peers + 1] = other
      end
    end
  end
  return gm, co, off, mem
end

describe("AnnouncementService.Publish", function()
  it("lets gm and cogm publish, and stores a stamped announcement", function()
    local gm = world()
    local a = assert(gm.service:Publish({ title = "Raid night", body = "Bring flasks", expiry = "7d" }))
    assert.are.equal(1, a.rev)
    assert.are.equal(1, a.popupRev)
    assert.is_true(a.popup)
    assert.is_false(a.pinned)
    assert.are.equal("Gm", a.author)
    assert.are.equal(10000, a.createdAt)
    assert.are.equal(10000 + 7 * 86400, a.expiresAt)
    assert.are.equal(a, gm.store.items[a.id])
    assert.are.equal(1, gm.changes)
    local _, co = world()
    assert.is_truthy(co.service:Publish({ title = "From the cogm" }))
  end)

  it("refuses an officer and a member, and sends nothing", function()
    local _, _, off, mem = world()
    for _, c in ipairs({ off, mem }) do
      local a, reason = c.service:Publish({ title = "Nope" })
      assert.is_nil(a)
      assert.are.equal("forbidden", reason)
      assert.are.equal(0, #c.sent)
      assert.is_nil(next(c.store.items))
    end
  end)

  it("refuses an invalid announcement with the field", function()
    local gm = world()
    local a, reason = gm.service:Publish({ title = "" })
    assert.is_nil(a)
    assert.are.equal("invalid:title", reason)
    assert.are.equal("invalid:body", select(2, gm.service:Publish({ title = "t", body = ("x"):rep(601) })))
  end)

  it("stops at the cap of live announcements", function()
    local gm = world()
    for index = 1, Constants.ANNOUNCE_MAX do
      assert(gm.service:Publish({ title = "n" .. index }))
    end
    local a, reason = gm.service:Publish({ title = "one too many" })
    assert.is_nil(a)
    assert.are.equal("limit", reason)
  end)

  it("reaches the other clients, and only the managers' announcements are kept", function()
    local gm, co, off, mem = world()
    local a = assert(gm.service:Publish({ title = "Hello" }))
    for _, c in ipairs({ co, off, mem }) do
      assert.are.equal("Hello", c.store.items[a.id].title, c.name)
      assert.are.equal("Gm", c.store.items[a.id].author)
    end
    -- An officer client that forged the send would be dropped by everybody.
    off.store.items["forged"] = {
      id = "forged",
      title = "Forged",
      body = "",
      createdAt = 1,
      updatedAt = 1,
      rev = 1,
      popup = true,
      popupRev = 1,
      pinned = false,
    }
    local payload = Sync.UpsertPayload(off.store.items["forged"])
    local message = assert(Protocol.Validate(Protocol.Build("ANN", payload, "id-2")))
    for _, c in ipairs({ gm, co, mem }) do
      local ok, reason = Sync.Apply({
        store = c.store,
        now = function()
          return 10000
        end,
      }, message, "Off", "officer")
      assert.is_false(ok)
      assert.are.equal("forbidden", reason)
      assert.is_nil(c.store.items["forged"])
    end
  end)
end)

describe("AnnouncementService.Edit, Delete and ResendPopup", function()
  it("edits the fields given and bumps the revision", function()
    local gm, co, _, mem = world()
    local a = assert(gm.service:Publish({ title = "Old", body = "body" }))
    gm.clock = 11000
    assert(gm.service:Edit(a.id, { title = "New", pinned = true }))
    assert.are.equal(2, a.rev)
    assert.are.equal(11000, a.updatedAt)
    assert.are.equal("body", a.body)
    assert.are.equal("New", mem.store.items[a.id].title)
    assert.is_true(co.store.items[a.id].pinned)
  end)

  it("does not show the popup again after an edit", function()
    local gm, _, _, mem = world()
    local a = assert(gm.service:Publish({ title = "t" }))
    mem.service:MarkSeen(a.id)
    mem.popups = {}
    assert(gm.service:Edit(a.id, { title = "t2" }))
    assert.are.same({}, mem.popups)
  end)

  it("lets a cogm edit and delete what the gm published", function()
    local gm, co, _, mem = world()
    local a = assert(gm.service:Publish({ title = "t" }))
    assert(co.service:Edit(a.id, { body = "by the cogm" }))
    assert.are.equal("by the cogm", gm.store.items[a.id].body)
    assert.are.equal("Co", mem.store.items[a.id].author)
    assert(co.service:Delete(a.id))
    assert.is_nil(gm.store.items[a.id])
    assert.is_nil(mem.store.items[a.id])
  end)

  it("refuses what is not allowed or unknown", function()
    local gm, _, off = world()
    local a = assert(gm.service:Publish({ title = "t" }))
    assert.are.equal("forbidden", select(2, off.service:Edit(a.id, { title = "x" })))
    assert.are.equal("forbidden", select(2, off.service:Delete(a.id)))
    assert.are.equal("forbidden", select(2, off.service:ResendPopup(a.id)))
    assert.are.equal("not_found", select(2, gm.service:Edit("nope", { title = "x" })))
    assert.are.equal("not_found", select(2, gm.service:Delete("nope")))
    assert.are.equal("not_found", select(2, gm.service:ResendPopup("nope")))
    assert.are.equal("invalid:title", select(2, gm.service:Edit(a.id, { title = "" })))
  end)

  it("deleting leaves a tombstone above the last revision and tells the others", function()
    local gm, _, _, mem = world()
    local a = assert(gm.service:Publish({ title = "t" }))
    assert(gm.service:Delete(a.id))
    assert.are.equal(2, gm.store.tombstones[a.id].rev)
    assert.is_nil(mem.store.items[a.id])
    assert.are.equal("ANN_DEL", gm.sent[#gm.sent].t)
  end)

  it("sends the popup again by bumping popupRev, so members see it once more", function()
    local gm, _, _, mem = world()
    local a = assert(gm.service:Publish({ title = "t" }))
    assert.are.same({ a.id }, mem.popups)
    mem.service:MarkSeen(a.id)
    mem.popups = {}
    gm.clock = 10100
    assert(gm.service:ResendPopup(a.id))
    assert.are.equal(2, mem.store.items[a.id].popupRev)
    assert.are.same({ a.id }, mem.popups)
  end)

  it("turns the popup on when it was off", function()
    local gm, _, _, mem = world()
    local a = assert(gm.service:Publish({ title = "t", popup = false }))
    assert.are.same({}, mem.popups)
    assert(gm.service:ResendPopup(a.id))
    assert.is_true(mem.store.items[a.id].popup)
    assert.are.same({ a.id }, mem.popups)
  end)
end)

describe("AnnouncementService popups", function()
  it("asks for a popup only when the announcement has one and it was not seen", function()
    local gm, _, _, mem = world()
    assert(gm.service:Publish({ title = "silent", popup = false }))
    assert.are.same({}, mem.popups)
    local loud = assert(gm.service:Publish({ title = "loud" }))
    assert.are.same({ loud.id }, mem.popups)
  end)

  it("does not give the author a popup of their own announcement", function()
    local gm = world()
    local a = assert(gm.service:Publish({ title = "mine" }))
    assert.is_false(ns.AnnouncementModel.NeedsPopup(a, gm.seen, gm.clock))
  end)

  it("skips the popup of an announcement older than a week, which only counts as unread", function()
    local _, _, _, mem = world()
    local old = {
      id = "old",
      title = "Old",
      body = "",
      createdAt = 1,
      updatedAt = mem.clock - Constants.ANNOUNCE_POPUP_MAX_AGE_SECONDS - 1,
      rev = 1,
      popup = true,
      popupRev = 1,
      pinned = false,
    }
    mem.service:OnReceived(old)
    assert.are.same({}, mem.popups)
    old.updatedAt = mem.clock - 100
    mem.service:OnReceived(old)
    assert.are.same({ "old" }, mem.popups)
  end)

  it("marks a popup as seen once per revision", function()
    local gm, _, _, mem = world()
    local a = assert(gm.service:Publish({ title = "t" }))
    mem.service:MarkSeen(a.id)
    assert.are.equal(1, mem.seen[a.id])
    mem.service:OnReceived(mem.store.items[a.id])
    assert.are.same({ a.id }, mem.popups)
  end)
end)

describe("AnnouncementService board", function()
  it("lists pinned first then the newest, and hides the expired ones", function()
    local gm = world()
    local first = assert(gm.service:Publish({ title = "first" }))
    gm.clock = gm.clock + 10
    local second = assert(gm.service:Publish({ title = "second", expiry = "1d" }))
    gm.clock = gm.clock + 10
    local pinned = assert(gm.service:Publish({ title = "pinned", pinned = true }))
    local ids = {}
    for _, a in ipairs(gm.service:List()) do
      ids[#ids + 1] = a.id
    end
    assert.are.same({ pinned.id, second.id, first.id }, ids)
    gm.clock = gm.clock + 2 * 86400
    assert.are.equal(2, #gm.service:List())
    assert.are.equal(3, #gm.service:List(true))
  end)

  it("counts unread since the board was last opened, without the own announcements", function()
    local gm, _, _, mem = world()
    assert(gm.service:Publish({ title = "one" }))
    gm.clock = gm.clock + 10
    mem.clock = gm.clock
    assert(gm.service:Publish({ title = "two" }))
    assert.are.equal(2, mem.service:Unread())
    assert.are.equal(0, gm.service:Unread())
    mem.clock = mem.clock + 5
    mem.service:MarkBoardOpened()
    assert.are.equal(0, mem.service:Unread())
    gm.clock = mem.clock + 5
    mem.clock = gm.clock
    assert(gm.service:Publish({ title = "three" }))
    assert.are.equal(1, mem.service:Unread())
  end)

  it("does not count an expired announcement as unread", function()
    local gm, _, _, mem = world()
    assert(gm.service:Publish({ title = "short", expiry = "1d" }))
    mem.clock = mem.clock + 2 * 86400
    assert.are.equal(0, mem.service:Unread())
  end)
end)

describe("AnnouncementService.PendingPopups", function()
  it("lists the popups still due for what is stored, newest first, without the seen, old or silent ones", function()
    local gm, _, _, mem = world()
    local first = assert(gm.service:Publish({ title = "first" }))
    gm.clock = gm.clock + 10
    mem.clock = gm.clock
    local second = assert(gm.service:Publish({ title = "second" }))
    assert(gm.service:Publish({ title = "silent", popup = false }))
    local seenAlready = assert(gm.service:Publish({ title = "seen" }))
    mem.service:MarkSeen(seenAlready.id)
    mem.store.items[first.id].updatedAt = mem.store.items[first.id].updatedAt - 100
    local ids = {}
    for _, a in ipairs(mem.service:PendingPopups()) do
      ids[#ids + 1] = a.id
    end
    assert.are.same({ second.id, first.id }, ids)
    mem.clock = mem.clock + Constants.ANNOUNCE_POPUP_MAX_AGE_SECONDS + 1
    assert.are.same({}, mem.service:PendingPopups())
  end)
end)

describe("AnnouncementService.Purge", function()
  it("removes expired announcements, old tombstones and the seen marks of what is gone", function()
    local gm = world()
    local keep = assert(gm.service:Publish({ title = "keep" }))
    local expiring = assert(gm.service:Publish({ title = "expiring", expiry = "1d" }))
    local gone = assert(gm.service:Publish({ title = "gone" }))
    assert(gm.service:Delete(gone.id))
    gm.seen["unknown"] = 3
    gm.clock = gm.clock + 2 * 86400
    assert.are.equal(
      1,
      Service.Purge({
        store = gm.store,
        seen = gm.seen,
        now = function()
          return gm.clock
        end,
      })
    )
    assert.is_truthy(gm.store.items[keep.id])
    assert.is_nil(gm.store.items[expiring.id])
    assert.is_truthy(gm.store.tombstones[gone.id])
    assert.is_nil(gm.seen["unknown"])
    assert.is_nil(gm.seen[expiring.id])
    gm.clock = gm.clock + Constants.ANNOUNCE_TOMBSTONE_TTL_SECONDS + 1
    Service.Purge({
      store = gm.store,
      seen = gm.seen,
      now = function()
        return gm.clock
      end,
    })
    assert.is_nil(gm.store.tombstones[gone.id])
  end)
end)
