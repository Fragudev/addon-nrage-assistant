-- The announcements part of the snapshot a gm or cogm answers to a late joiner (Transfer.BuildSnapshot and
-- Transfer.ApplyItems). Real protocol and domain; nothing is faked.
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
    "Domain/AnnouncementModel",
    "Domain/AnnouncementService",
    "Domain/EventService",
    "Domain/LootModel",
    "Domain/LootService",
    "Domain/BlacklistService",
    "Domain/IntelModel",
    "Domain/GuildKosService",
    "Domain/ReadinessRules",
    "Sync/Protocol",
    "Sync/SyncRules",
    "Sync/EventSync",
    "Sync/LootSync",
    "Sync/PvPSync",
    "Sync/BlacklistSync",
    "Sync/GuildKosSync",
    "Sync/ReadinessRulesSync",
    "Sync/RosterSync",
    "Sync/RecipeSync",
    "Sync/AnnouncementSync",
    "Sync/Transfer",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local Transfer = ns.Transfer

local NOW = 10000

local function board()
  local function a(id, createdAt, overrides)
    local record = {
      id = id,
      title = "Title " .. id,
      body = "Body",
      author = "Gm-Realm",
      createdAt = createdAt,
      updatedAt = createdAt,
      rev = 1,
      popup = true,
      popupRev = 1,
      pinned = false,
    }
    for key, value in pairs(overrides or {}) do
      record[key] = value
    end
    return record
  end
  return {
    items = { old = a("old", 100), mid = a("mid", 200, { author = "Co-Realm" }), new = a("new", 300) },
    tombstones = { gone = { at = 250, rev = 2 } },
  }
end

local function receiver(roles)
  local heard = {}
  return {
    announcements = { items = {}, tombstones = {} },
    now = function()
      return NOW
    end,
    roleOf = function(name)
      return roles[name]
    end,
    onAnnouncement = function(announcement)
      heard[#heard + 1] = announcement.id
    end,
  },
    heard
end

local function snapshot(max)
  return Transfer.BuildSnapshot({}, {}, 5, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, board(), max, NOW)
end

describe("Transfer announcements in a snapshot", function()
  it("lists the newest announcements and the removals after everything else", function()
    local ids = {}
    for _, item in ipairs(snapshot(10)) do
      ids[#ids + 1] = item.t .. ":" .. item.p.id
    end
    assert.are.same({ "ANN:new", "ANN:mid", "ANN:old", "ANN_DEL:gone" }, ids)
    assert.are.equal(2, #snapshot(2))
    assert.are.equal(0, #snapshot(0))
  end)

  it("adds none when the sender passes no board", function()
    assert.are.equal(0, #Transfer.BuildSnapshot({}, {}, 5))
  end)

  it("round-trips through the protocol, under the role of the sender", function()
    local ctx, heard = receiver({ ["Co-Realm"] = "cogm", ["Gm-Realm"] = "gm" })
    local summary = Transfer.ApplyItems(snapshot(10), ctx, "Gm-Realm", "gm")
    assert.are.equal(4, summary.applied)
    assert.are.equal(4, summary.announcements)
    assert.are.equal("Title mid", ctx.announcements.items.mid.title)
    assert.are.equal("Co-Realm", ctx.announcements.items.mid.author)
    assert.are.equal("Gm-Realm", ctx.announcements.items.new.author)
    assert.are.equal(2, ctx.announcements.tombstones.gone.rev)
    assert.are.equal(3, #heard)
  end)

  it("applies nothing under a role that cannot manage announcements", function()
    for _, role in ipairs({ "officer", "rl", "member" }) do
      local ctx = receiver({})
      local summary = Transfer.ApplyItems(snapshot(10), ctx, "Lead-Realm", role)
      assert.are.equal(0, summary.announcements, role)
      assert.is_nil(next(ctx.announcements.items), role)
      assert.are.equal(4, summary.skipped.forbidden, role)
    end
  end)

  it("keeps the sender as the author when the named author may not publish", function()
    local ctx = receiver({ ["Co-Realm"] = "officer" })
    Transfer.ApplyItems(snapshot(10), ctx, "Gm-Realm", "gm")
    assert.are.equal("Gm-Realm", ctx.announcements.items.mid.author)
    ctx = receiver({})
    Transfer.ApplyItems(snapshot(10), ctx, "Gm-Realm", "gm")
    assert.are.equal("Gm-Realm", ctx.announcements.items.mid.author)
  end)

  it("skips an announcement that does not pass validation, and the rest still applies", function()
    local items = snapshot(10)
    items[1].p.title = ""
    local ctx = receiver({})
    local summary = Transfer.ApplyItems(items, ctx, "Gm-Realm", "gm")
    assert.are.equal(1, summary.skipped.bad_payload)
    assert.are.equal(3, summary.announcements)
  end)

  it("does not apply them to a context without the board, such as a text import", function()
    local ctx = receiver({})
    ctx.announcements = nil
    local summary = Transfer.ApplyItems(snapshot(10), ctx, "import", "gm")
    assert.are.equal(0, summary.announcements)
    assert.are.equal(4, summary.skipped.unsupported)
  end)

  it("keeps them out of the text export", function()
    for _, item in ipairs(Transfer.BuildItems({}, board().tombstones)) do
      assert.is_false(item.t == "ANN" or item.t == "ANN_DEL")
    end
  end)
end)
