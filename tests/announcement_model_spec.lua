local function load_modules()
  local ns = {}
  for _, path in ipairs({ "Core/Constants", "Core/Validate", "Domain/EventModel", "Domain/AnnouncementModel" }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local Model, Constants = ns.AnnouncementModel, ns.Constants

local function record(overrides)
  local a = {
    id = "a-1",
    title = "Raid night",
    body = "Bring flasks.\nBe on time.",
    author = "Gm-Realm",
    createdAt = 1000,
    updatedAt = 1000,
    rev = 1,
    popup = true,
    popupRev = 1,
    pinned = false,
  }
  for key, value in pairs(overrides or {}) do
    a[key] = value
  end
  return a
end

describe("AnnouncementModel.ValidateFields", function()
  it("accepts a title with an empty body", function()
    local clean = assert(Model.ValidateFields({ title = "  Hello  " }))
    assert.are.equal("Hello", clean.title)
    assert.are.equal("", clean.body)
  end)

  it("limits the title to 60 characters and requires it", function()
    assert.is_truthy(Model.ValidateFields({ title = ("x"):rep(Constants.ANNOUNCE_TITLE_MAX) }))
    local clean, reason = Model.ValidateFields({ title = ("x"):rep(Constants.ANNOUNCE_TITLE_MAX + 1) })
    assert.is_nil(clean)
    assert.are.equal("invalid:title", reason)
    clean, reason = Model.ValidateFields({ title = "   " })
    assert.is_nil(clean)
    assert.are.equal("invalid:title", reason)
    clean, reason = Model.ValidateFields({ body = "no title" })
    assert.is_nil(clean)
    assert.are.equal("invalid:title", reason)
  end)

  it("counts characters, not bytes, so accents do not eat the limit", function()
    assert.is_truthy(Model.ValidateFields({ title = ("\195\177"):rep(Constants.ANNOUNCE_TITLE_MAX) }))
    assert.is_nil(Model.ValidateFields({ title = ("\195\177"):rep(Constants.ANNOUNCE_TITLE_MAX + 1) }))
  end)

  it("allows newlines in the body up to 600 characters, and no other control character", function()
    assert.is_truthy(Model.ValidateFields({ title = "t", body = ("x"):rep(Constants.ANNOUNCE_BODY_MAX) }))
    local clean, reason = Model.ValidateFields({ title = "t", body = ("x"):rep(Constants.ANNOUNCE_BODY_MAX + 1) })
    assert.is_nil(clean)
    assert.are.equal("invalid:body", reason)
    clean, reason = Model.ValidateFields({ title = "t", body = "a\tb" })
    assert.is_nil(clean)
    assert.are.equal("invalid:body", reason)
    assert.are.equal("a\nb", Model.ValidateFields({ title = "t", body = "a\r\nb" }).body)
  end)

  it("rejects the escape character in both texts", function()
    assert.are.equal("invalid:title", select(2, Model.ValidateFields({ title = "|cffff0000red" })))
    assert.are.equal("invalid:body", select(2, Model.ValidateFields({ title = "t", body = "|Hlink|h" })))
  end)

  it("takes only booleans for the switches and a known expiry choice", function()
    assert.are.equal("invalid:popup", select(2, Model.ValidateFields({ title = "t", popup = "yes" })))
    assert.are.equal("invalid:pinned", select(2, Model.ValidateFields({ title = "t", pinned = 1 })))
    assert.are.equal("invalid:expiry", select(2, Model.ValidateFields({ title = "t", expiry = "2d" })))
    local clean = Model.ValidateFields({ title = "t", popup = false, pinned = true, expiry = "7d" })
    assert.is_false(clean.popup)
    assert.is_true(clean.pinned)
    assert.are.equal("7d", clean.expiry)
  end)

  it("in partial mode validates only the fields that are there", function()
    local clean = assert(Model.ValidateFields({ pinned = true }, true))
    assert.is_true(clean.pinned)
    assert.is_nil(clean.title)
    assert.are.equal("invalid:title", select(2, Model.ValidateFields({ title = "" }, true)))
  end)
end)

describe("AnnouncementModel.ExpiresAt", function()
  it("is nil for never and now plus the span for the others", function()
    assert.is_nil(Model.ExpiresAt("never", 100))
    assert.are.equal(100 + 86400, Model.ExpiresAt("1d", 100))
    assert.are.equal(100 + 7 * 86400, Model.ExpiresAt("7d", 100))
    assert.are.equal(100 + 30 * 86400, Model.ExpiresAt("30d", 100))
  end)

  it("tells which choice a stored expiry is closest to", function()
    assert.are.equal("never", Model.ExpiryChoiceOf(nil, 100))
    assert.are.equal("7d", Model.ExpiryChoiceOf(100 + 6 * 86400, 100))
    assert.are.equal("1d", Model.ExpiryChoiceOf(100 + 3600, 100))
  end)
end)

describe("AnnouncementModel.Validate", function()
  it("accepts a whole record and drops unknown fields", function()
    local clean = assert(Model.Validate(record({ junk = 1 })))
    assert.is_nil(clean.junk)
    assert.are.equal("a-1", clean.id)
    local bare = record()
    bare.body = nil
    assert.are.equal("", Model.Validate(bare).body)
  end)

  it("rejects what is out of bounds", function()
    assert.is_nil(Model.Validate(record({ id = "bad id" })))
    assert.is_nil(Model.Validate(record({ rev = 0 })))
    assert.is_nil(Model.Validate(record({ popupRev = 0 })))
    assert.is_nil(Model.Validate(record({ popup = "x" })))
    assert.is_nil(Model.Validate(record({ createdAt = -1 })))
    assert.is_nil(Model.Validate(record({ expiresAt = "soon" })))
    assert.is_nil(Model.Validate(record({ title = "" })))
  end)

  it("checks the author only when it is there", function()
    assert.is_nil(Model.Validate(record({ author = "bad|name" })))
    local anonymous = record()
    anonymous.author = nil
    assert.is_truthy(Model.Validate(anonymous))
  end)
end)

describe("AnnouncementModel.Sort", function()
  it("lists pinned first, then the newest", function()
    local list = {
      record({ id = "old", createdAt = 10 }),
      record({ id = "new", createdAt = 30 }),
      record({ id = "pin", createdAt = 5, pinned = true }),
      record({ id = "mid", createdAt = 20 }),
    }
    Model.Sort(list)
    local ids = {}
    for _, a in ipairs(list) do
      ids[#ids + 1] = a.id
    end
    assert.are.same({ "pin", "new", "mid", "old" }, ids)
  end)
end)

describe("AnnouncementModel.IsExpired and NeedsPopup", function()
  it("expires at the stamp, never when it has none", function()
    assert.is_false(Model.IsExpired(record(), 5000))
    assert.is_false(Model.IsExpired(record({ expiresAt = 6000 }), 5000))
    assert.is_true(Model.IsExpired(record({ expiresAt = 5000 }), 5000))
  end)

  it("asks for a popup once per popupRev", function()
    assert.is_true(Model.NeedsPopup(record(), {}, 2000))
    assert.is_false(Model.NeedsPopup(record(), { ["a-1"] = 1 }, 2000))
    assert.is_true(Model.NeedsPopup(record({ popupRev = 2 }), { ["a-1"] = 1 }, 2000))
  end)

  it("never asks when popup is off or the announcement expired", function()
    assert.is_false(Model.NeedsPopup(record({ popup = false }), {}, 2000))
    assert.is_false(Model.NeedsPopup(record({ expiresAt = 1500 }), {}, 2000))
  end)
end)
