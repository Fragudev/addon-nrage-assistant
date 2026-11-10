-- The Announcements tabs, form and popup view models (UI/ViewModelAnnouncements.lua). `locale` (optional) is the client
-- locale code to load them for, e.g. "esES".
local function load_view_model(locale)
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Locales/esES",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/EventModel",
    "Domain/AnnouncementModel",
    "UI/Kit/Theme",
    "UI/Kit/Util",
    "UI/Kit/Calendar",
    "UI/ViewModel",
    "UI/ViewModelHome",
    "UI/ViewModelAnnouncements",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
    if path == "Locales/esES" and locale then
      ns.Locale.Use(locale)
    end
  end
  return ns.ViewModel, ns.Constants
end

local ViewModel, Constants = load_view_model()

local NOW = 100000

local function record(id, overrides)
  local a = {
    id = id,
    title = "Title " .. id,
    body = "Body " .. id,
    author = "Gm-Realm",
    createdAt = NOW - 120,
    updatedAt = NOW - 120,
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

describe("ViewModel.AnnouncementBoard", function()
  it("keeps the order it is given and says when and by whom", function()
    local board = ViewModel.AnnouncementBoard({ record("a", { pinned = true }), record("b") }, NOW)
    assert.is_false(board.empty)
    assert.are.same({ "a", "b" }, { board.rows[1].id, board.rows[2].id })
    assert.is_true(board.rows[1].pinned)
    assert.is_false(board.rows[2].pinned)
    assert.are.equal("Gm-Realm", board.rows[1].author)
    assert.are.equal("2 min ago", board.rows[1].age)
    assert.is_string(board.rows[1].date)
    assert.is_nil(board.rows[1].expires)
  end)

  it("says it is empty, with the text for the empty state", function()
    local board = ViewModel.AnnouncementBoard({}, NOW)
    assert.is_true(board.empty)
    assert.are.equal("No announcements yet", board.emptyText)
  end)

  it("escapes everything that was received", function()
    local board =
      ViewModel.AnnouncementBoard({ record("a", { title = "T|cffff0000", body = "B|r", author = "A|n" }) }, NOW)
    assert.are.equal("T||cffff0000", board.rows[1].title)
    assert.are.equal("B||r", board.rows[1].body)
    assert.are.equal("A||n", board.rows[1].author)
  end)

  it("tells when an announcement expires", function()
    local rows = ViewModel.AnnouncementBoard({
      record("days", { expiresAt = NOW + 3 * 86400 + 5 }),
      record("hours", { expiresAt = NOW + 5 * 3600 + 5 }),
      record("minutes", { expiresAt = NOW + 600 }),
      record("gone", { expiresAt = NOW - 1 }),
    }, NOW).rows
    assert.are.equal("Expires in 3 d", rows[1].expires)
    assert.are.equal("Expires in 5 h", rows[2].expires)
    assert.are.equal("Expires in 10 min", rows[3].expires)
    assert.are.equal("Expired", rows[4].expires)
    assert.is_true(rows[4].expired)
    assert.is_false(rows[1].expired)
  end)
end)

describe("ViewModel.AnnouncementAdminList", function()
  it("counts N of 30 and knows when the board is full", function()
    local list = ViewModel.AnnouncementAdminList({ record("a"), record("b") }, NOW)
    assert.are.equal("2 of 30", list.counter)
    assert.is_false(list.full)
    local many = {}
    for index = 1, Constants.ANNOUNCE_MAX do
      many[index] = record("n" .. index)
    end
    local full = ViewModel.AnnouncementAdminList(many, NOW)
    assert.are.equal("30 of 30", full.counter)
    assert.is_true(full.full)
  end)

  it("marks the ones with no popup and the expired ones", function()
    local rows = ViewModel.AnnouncementAdminList(
      { record("a", { popup = false }), record("b", { expiresAt = NOW - 5 }) },
      NOW
    ).rows
    assert.is_false(rows[1].popup)
    assert.is_true(rows[2].expired)
  end)
end)

describe("ViewModel announcement form", function()
  it("starts empty with the popup on and nothing pinned", function()
    assert.are.same(
      { title = "", body = "", popup = true, pinned = false, expiry = "never" },
      ViewModel.AnnouncementFormNew()
    )
  end)

  it("cannot be published without a title, and says why", function()
    local view = ViewModel.AnnouncementFormView(ViewModel.AnnouncementFormNew(), false)
    assert.is_false(view.canSubmit)
    assert.are.equal("The title is not valid", view.reason)
    assert.are.equal("Publish", view.submitText)
    assert.are.equal("New announcement", view.heading)
  end)

  it("can be published with a title, and the text is optional", function()
    local form = ViewModel.AnnouncementFormNew()
    form.title = "Raid night"
    local view = ViewModel.AnnouncementFormView(form, false)
    assert.is_true(view.canSubmit)
    assert.is_nil(view.reason)
  end)

  it("cannot be published when the board is full, but an edit can be saved", function()
    local form = ViewModel.AnnouncementFormNew()
    form.title = "Raid night"
    local view = ViewModel.AnnouncementFormView(form, true)
    assert.is_false(view.canSubmit)
    assert.are.equal("The board is full: delete an announcement first", view.reason)
    form.editing = "a"
    view = ViewModel.AnnouncementFormView(form, true)
    assert.is_true(view.canSubmit)
    assert.are.equal("Save changes", view.submitText)
    assert.are.equal("Edit the announcement", view.heading)
  end)

  it("refuses a text that is too long or has an escape", function()
    local form = ViewModel.AnnouncementFormNew()
    form.title = "t"
    form.body = ("x"):rep(Constants.ANNOUNCE_BODY_MAX + 1)
    local view = ViewModel.AnnouncementFormView(form, false)
    assert.is_false(view.canSubmit)
    assert.are.equal("The text is not valid", view.reason)
    form.body = "has |c"
    assert.is_false(ViewModel.AnnouncementFormView(form, false).canSubmit)
  end)

  it("counts characters and colours the counter near and over the limit", function()
    local form = ViewModel.AnnouncementFormNew()
    form.title = "abc"
    local view = ViewModel.AnnouncementFormView(form, false)
    assert.are.same({ text = "3/60", token = "muted", over = false }, view.titleCounter)
    assert.are.equal("0/600", view.bodyCounter.text)
    form.title = ("x"):rep(55)
    assert.are.equal("warning", ViewModel.AnnouncementFormView(form, false).titleCounter.token)
    form.title = ("x"):rep(61)
    local over = ViewModel.AnnouncementFormView(form, false).titleCounter
    assert.are.equal("danger", over.token)
    assert.is_true(over.over)
    form.title = ("\195\177"):rep(60)
    assert.are.equal("60/60", ViewModel.AnnouncementFormView(form, false).titleCounter.text)
  end)

  it("offers the four expiry choices in order", function()
    local items = ViewModel.AnnouncementFormView(ViewModel.AnnouncementFormNew(), false).expiryItems
    local values = {}
    for _, item in ipairs(items) do
      values[#values + 1] = item.value
      assert.is_string(item.text)
    end
    assert.are.same({ "never", "1d", "7d", "30d" }, values)
    assert.are.equal("Never expires", items[1].text)
  end)

  it("is filled from an announcement, with the closest expiry choice", function()
    local form =
      ViewModel.AnnouncementFormFrom(record("a", { pinned = true, popup = false, expiresAt = NOW + 6 * 86400 }), NOW)
    assert.are.same({
      editing = "a",
      title = "Title a",
      body = "Body a",
      popup = false,
      pinned = true,
      expiry = "7d",
      originalExpiry = "7d",
    }, form)
  end)
end)

describe("ViewModel announcement popup", function()
  it("describes the card of one announcement", function()
    local view = ViewModel.AnnouncementPopupView(record("a"), 1, 1, NOW)
    assert.are.equal("Title a", view.title)
    assert.are.equal("Gm-Realm - 2 min ago", view.meta)
    assert.are.equal("Body a", view.body)
    assert.is_nil(view.counter)
    assert.is_false(view.long)
    assert.is_false(view.canPrev)
    assert.is_false(view.canNext)
  end)

  it("says which one of how many and where the arrows can go", function()
    local view = ViewModel.AnnouncementPopupView(record("a"), 2, 3, NOW)
    assert.are.equal("2 of 3", view.counter)
    assert.is_true(view.canPrev)
    assert.is_true(view.canNext)
    assert.is_false(ViewModel.AnnouncementPopupView(record("a"), 3, 3, NOW).canNext)
  end)

  it("scrolls a text past ten lines", function()
    assert.is_false(ViewModel.AnnouncementPopupView(record("a", { body = ("l\n"):rep(9) .. "l" }), 1, 1, NOW).long)
    assert.is_true(ViewModel.AnnouncementPopupView(record("a", { body = ("l\n"):rep(10) .. "l" }), 1, 1, NOW).long)
  end)
end)

describe("ViewModel announcements in the sidebar and on Home", function()
  it("shows the unread count on the Announcements item and on no other", function()
    local function badges(count)
      local found = {}
      for _, group in ipairs(ViewModel.NavGroups("gm", "r1", 0, count)) do
        for _, item in ipairs(group.items) do
          found[item.value] = item.badge
        end
      end
      return found
    end
    assert.are.equal("3", badges(3).announcements)
    assert.are.equal("99+", badges(120).announcements)
    assert.is_nil(badges(0).announcements)
    assert.is_nil(badges(nil).announcements)
    assert.is_nil(badges(3).announceadmin)
    assert.is_nil(badges(3).groups)
    assert.is_nil(badges(3).home)
  end)

  it("gives the editor to gm and cogm only, and the board to everyone", function()
    for _, role in ipairs({ "gm", "cogm" }) do
      assert.is_true(ViewModel.TabVisible("announceadmin", role, nil), role)
    end
    for _, role in ipairs({ "officer", "rl", "roster", "member", "alter" }) do
      assert.is_false(ViewModel.TabVisible("announceadmin", role, "r1"), role)
    end
    for _, role in ipairs({ "gm", "cogm", "officer", "rl", "roster", "member", "alter" }) do
      assert.is_true(ViewModel.TabVisible("announcements", role, "r1"), role)
    end
  end)

  it("takes the pinned announcement at the top for the Home banner", function()
    assert.is_nil(ViewModel.AnnouncementBanner({}))
    assert.is_nil(ViewModel.AnnouncementBanner({ record("a") }))
    assert.are.same(
      { id = "p", text = "Title p" },
      ViewModel.AnnouncementBanner({ record("p", { pinned = true }), record("a") })
    )
    assert.are.equal("T||c", ViewModel.AnnouncementBanner({ record("p", { pinned = true, title = "T|c" }) }).text)
  end)
end)

describe("ViewModel announcement reasons", function()
  it("explains every reason of the service", function()
    for _, reason in ipairs({
      "forbidden",
      "not_found",
      "limit",
      "invalid:title",
      "invalid:body",
      "invalid:popup",
      "invalid:pinned",
      "invalid:expiry",
    }) do
      assert.is_nil(ViewModel.AnnouncementReason(reason):find("could not be done", 1, true), reason)
    end
    assert.are.equal("It could not be done (weird)", ViewModel.AnnouncementReason("weird"))
  end)

  it("reads in Spanish for a Spanish client", function()
    local spanish = load_view_model("esES")
    assert.are.equal("Ese anuncio ya no existe", spanish.AnnouncementReason("not_found"))
    assert.are.equal("Aún no hay anuncios", spanish.AnnouncementBoard({}, NOW).emptyText)
    local items = spanish.AnnouncementFormView(spanish.AnnouncementFormNew(), false).expiryItems
    assert.are.equal("Caduca en 1 día", items[2].text)
  end)
end)
