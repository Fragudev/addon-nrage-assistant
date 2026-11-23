-- The Groups tab, form and popup view models (UI/ViewModelGroups.lua). `locale` (optional) is the client locale code
-- to load them for, e.g. "esES".
local function load_view_model(locale)
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Locales/esES",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/ProfileService",
    "Domain/LfgModel",
    "Domain/IntelModel",
    "UI/Kit/Theme",
    "UI/Kit/Util",
    "Domain/Professions",
    "UI/ViewModel",
    "UI/ViewModelHome",
    "UI/ViewModelGroups",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
    if path == "Locales/esES" and locale then
      ns.Locale.Use(locale)
    end
  end
  return ns.ViewModel, ns.Constants, ns
end

local ViewModel, Constants = load_view_model()

local function entry(overrides)
  local e = {
    owner = "Kaelis",
    pid = "p-1",
    state = "open",
    kind = "dungeon",
    title = "Scarlet Monastery",
    needs = { tank = 1, heal = 1, dps = 0 },
    members = 3,
    minLevel = 34,
    note = "Bring potions",
    age = 240,
  }
  for k, v in pairs(overrides or {}) do
    e[k] = v
  end
  return e
end

local function view(overrides)
  local state = {
    available = true,
    locked = false,
    status = {},
    posts = { entry() },
    filter = {},
    ownName = "Me",
    canPost = true,
    canInvite = true,
    canApply = function()
      return true
    end,
  }
  for k, v in pairs(overrides or {}) do
    state[k] = v
  end
  return ViewModel.GroupsView(state)
end

local function own_post(overrides)
  local post = {
    pid = "mine",
    rev = 1,
    kind = "quest",
    title = "Elite quests",
    needs = { tank = 1, heal = 0, dps = 2 },
    members = 2,
    remaining = 3,
    applicants = {},
  }
  for k, v in pairs(overrides or {}) do
    post[k] = v
  end
  return post
end

describe("ViewModel groups board", function()
  it("writes the alert of a new group with its kind, title and leader, escaped", function()
    assert.are.equal(
      "New group (Dungeon): Deadmines - Lead",
      ViewModel.GroupAlertText("Lead", { kind = "dungeon", title = "Deadmines" })
    )
    assert.are.equal(
      "New group (Other): a||b - Lead",
      ViewModel.GroupAlertText("Lead", { kind = "weird", title = "a|b" })
    )
  end)

  it("describes a post: title, kind, leader, level, age, note, roles and members", function()
    local row = view().rows[1]
    assert.are.equal("p-1", row.pid)
    assert.are.equal("Scarlet Monastery", row.title)
    assert.are.equal("Dungeon", row.kindLabel)
    assert.are.equal("Leader: Kaelis · Level 34+ · 4 min ago · Bring potions", row.line)
    assert.are.same({ "1 Tank", "1 Heal" }, row.chips)
    assert.are.same({
      { filled = true },
      { filled = true },
      { filled = true },
      { filled = false, role = "tank" },
      { filled = false, role = "heal" },
    }, row.seats)
    assert.are.equal("3 of 5 members", row.membersLabel)
    assert.are.equal("Apply", row.cta)
    assert.is_true(row.enabled)
    assert.is_nil(row.reason)
  end)

  it("leaves out what a post does not say", function()
    local row =
      view({ posts = { entry({ minLevel = false, note = false, needs = { tank = 0, heal = 0, dps = 2 } }) } }).rows[1]
    assert.are.equal("Leader: Kaelis · 4 min ago", row.line)
    assert.are.same({ "2 DPS" }, row.chips)
  end)

  it("escapes every text that came from the guild", function()
    local row = view({ posts = { entry({ owner = "Ev|cffff0000il", title = "|TX|t", note = "|Hlink|h" }) } }).rows[1]
    assert.are.equal("||TX||t", row.title)
    assert.is_truthy(row.line:find("Ev||cffff0000il", 1, true))
    assert.is_truthy(row.line:find("||Hlink||h", 1, true))
    assert.is_nil(row.line:find("[^|]|[^|]"))
  end)

  it("keeps the own post off the board", function()
    local rows =
      view({ posts = { entry({ owner = "Me" }), entry({ owner = "Ann", pid = "p-2" }) }, ownName = "Me" }).rows
    assert.are.equal(1, #rows)
    assert.are.equal("p-2", rows[1].pid)
  end)

  it("disables the button with the reason the service gives", function()
    local row = view({
      canApply = function()
        return false, "in_group"
      end,
    }).rows[1]
    assert.is_false(row.enabled)
    assert.are.equal("You are already in a group", row.reason)
  end)

  it("marks the post the player applied to", function()
    local rows = view({
      status = {
        application = { pid = "p-1", leader = "Kaelis", title = "x", role = "tank", state = "applied", left = 90 },
      },
      posts = { entry(), entry({ pid = "p-2", owner = "Ann" }) },
      canApply = function()
        return false, "busy"
      end,
    }).rows
    assert.are.equal("Applied", rows[1].cta)
    assert.is_false(rows[1].enabled)
    assert.is_nil(rows[1].reason)
    assert.are.equal("Apply", rows[2].cta)
    assert.are.equal("You already have an application", rows[2].reason)
  end)

  it("says why the board is empty", function()
    assert.are.equal("No groups with these filters. Create yours.", view({ posts = {} }).empty)
    local unavailable = view({ available = false })
    assert.are.equal("Groups are not available yet.", unavailable.empty)
    assert.is_false(unavailable.newGroup.enabled)
  end)

  it("lists the filters with the current ones active", function()
    local v = view({ filter = { kind = "quest", role = "heal" } })
    local active = {}
    for _, f in ipairs(v.kindFilters) do
      if f.active then
        active[#active + 1] = f.value
      end
    end
    for _, f in ipairs(v.roleFilters) do
      if f.active then
        active[#active + 1] = f.value
      end
    end
    assert.are.same({ "quest", "heal" }, active)
    assert.are.equal(4, #v.kindFilters)
    assert.are.equal("Any role", v.roleFilters[1].text)
    assert.is_true(view().kindFilters[1].active)
  end)

  it("never invents a seat outside the party", function()
    local row = view({ posts = { entry({ members = 9 }) } }).rows[1]
    assert.are.equal(5, #row.seats)
    for _, seat in ipairs(row.seats) do
      assert.is_true(seat.filled)
    end
  end)

  it("shows the class and the known role of each member, and lists them in the tooltip", function()
    local party = { { c = "WARRIOR", r = "tank" }, { c = "PRIEST" }, { c = "MAGE", r = "dps" } }
    local row = view({ posts = { entry({ party = party }) } }).rows[1]
    assert.are.same({
      { filled = true, class = "WARRIOR", role = "tank" },
      { filled = true, class = "PRIEST" },
      { filled = true, class = "MAGE", role = "dps" },
      { filled = false, role = "tank" },
      { filled = false, role = "heal" },
    }, row.seats)
    assert.are.equal("3 of 5 members\nWarrior · Tank\nPriest\nMage · DPS", row.membersLabel)
  end)

  it("leaves a free seat without a role when the post asks for fewer than the room left", function()
    local row = view({ posts = { entry({ members = 1, needs = { tank = 1, heal = 0, dps = 1 } }) } }).rows[1]
    assert.are.same({
      { filled = true },
      { filled = false, role = "tank" },
      { filled = false, role = "dps" },
      { filled = false },
      { filled = false },
    }, row.seats)
  end)
end)

describe("ViewModel groups own post", function()
  it("shows the post, the roles still needed and the seats", function()
    local own = view({ status = { post = own_post({ minLevel = 20, note = "Be on time" }) } }).own
    assert.are.equal("Your group · Quest", own.header)
    assert.are.equal("Elite quests", own.title)
    assert.are.same({ "1 Tank", "2 DPS" }, own.chips)
    assert.are.same({
      { filled = true },
      { filled = true },
      { filled = false, role = "tank" },
      { filled = false, role = "dps" },
      { filled = false, role = "dps" },
    }, own.seats)
    assert.are.equal("2 of 5 members", own.membersLabel)
    assert.are.equal("Level 20+", own.levelText)
    assert.are.equal("Be on time", own.note)
    assert.is_true(own.waiting)
  end)

  it("lists applicants with their buttons and escapes them", function()
    local own = view({
      status = {
        post = own_post({
          applicants = {
            { name = "Dre|nna", role = "heal", note = "|cffff0000x", state = "pending", at = 1 },
            { name = "Arthon", role = "tank", state = "invited", left = 40, at = 2 },
            { name = "Mirwen", role = "dps", state = "retry", at = 3 },
          },
        }),
      },
    }).own
    assert.is_false(own.waiting)
    local a, b, c = own.applicants[1], own.applicants[2], own.applicants[3]
    assert.are.equal("Dre||nna", a.name)
    assert.are.equal("Dre|nna", a.key)
    assert.are.equal("Heal", a.roleLabel)
    assert.are.equal("||cffff0000x", a.note)
    assert.is_true(a.pending)
    assert.is_true(a.canInvite)
    assert.is_true(a.inviteEnabled)
    assert.are.equal("", b.note)
    assert.are.equal("Invitation sent...", b.stateText)
    assert.is_false(b.canInvite)
    assert.are.equal("Did not join", c.stateText)
    assert.is_true(c.canInvite)
  end)

  it("disables Invite with the reason of the rules and the buttons during a lockdown", function()
    local status = { post = own_post({ applicants = { { name = "Ann", role = "dps", state = "pending", at = 1 } } }) }
    local v = view({ status = status, canInvite = false, inviteReason = "combat" })
    local row = v.own.applicants[1]
    assert.is_false(row.inviteEnabled)
    assert.are.equal("You are in combat", row.inviteReason)
    assert.is_true(row.declineEnabled)
    v = view({ status = status, locked = true, canInvite = false, inviteReason = "locked" })
    assert.is_false(v.own.applicants[1].declineEnabled)
    assert.is_false(v.own.editEnabled)
    assert.is_false(v.own.closeEnabled)
  end)

  it("says a closed group closed, and why", function()
    for outcome, text in pairs({ full = "Group complete", cancelled = "Group closed", expired = "Group expired" }) do
      local v = view({ status = { closed = { title = "Deadmines", outcome = outcome } } })
      assert.are.equal(text, v.closed.text)
      assert.are.equal("Deadmines", v.closed.title)
      assert.is_nil(v.own)
    end
  end)

  it("keeps the new group button off while a group is open, with the reason", function()
    local v = view({ status = { post = own_post() } })
    assert.is_false(v.newGroup.enabled)
    assert.are.equal("You have an open group", v.newGroup.reason)
    v = view({ canPost = false, postReason = "raid" })
    assert.is_false(v.newGroup.enabled)
    assert.are.equal("You are in a raid", v.newGroup.reason)
    assert.is_true(view().newGroup.enabled)
  end)
end)

describe("ViewModel groups own application", function()
  local function app(overrides)
    local a = { pid = "p-1", leader = "Kaelis", title = "Deadmines", role = "tank", state = "applied", left = 125 }
    for k, v in pairs(overrides or {}) do
      a[k] = v
    end
    return view({ status = { application = a } }).application
  end

  it("shows an application waiting for the leader, with the time left and a way to take it back", function()
    local a = app()
    assert.are.equal("Application sent to Kaelis", a.title)
    assert.are.equal("Deadmines · as Tank · expires in 2:05", a.detail)
    assert.are.equal("withdraw", a.action)
    assert.are.equal("Withdraw", a.actionText)
  end)

  it("tells an invited applicant to accept the game invitation", function()
    local a = app({ state = "invited" })
    assert.are.equal("Kaelis invited you", a.title)
    assert.are.equal("Accept the game invitation to join.", a.detail)
    assert.are.equal("withdraw", a.action)
  end)

  it("shows each finished state with a Close that works during a lockdown", function()
    local cases = {
      { { state = "joined" }, "You are in the group of Kaelis", "success" },
      { { state = "declined" }, "Kaelis declined your application", "danger" },
      { { state = "withdrawn" }, "You withdrew your application", "muted" },
      { { state = "expired", reason = "timeout" }, "Your application expired", "muted" },
      { { state = "expired", reason = "post_closed" }, "Kaelis closed the group", "muted" },
    }
    for _, case in ipairs(cases) do
      local a = view({
        locked = true,
        status = {
          application = {
            pid = "p",
            leader = "Kaelis",
            title = "Deadmines",
            role = "dps",
            state = case[1].state,
            reason = case[1].reason,
          },
        },
      }).application
      assert.are.equal(case[2], a.title, case[2])
      assert.are.equal(case[3], a.status, case[2])
      assert.are.equal("dismiss", a.action)
      assert.is_true(a.enabled)
    end
  end)

  it("disables Withdraw during a lockdown", function()
    local v = view({
      locked = true,
      status = { application = { pid = "p", leader = "K", title = "T", role = "dps", state = "applied" } },
    })
    assert.is_false(v.application.enabled)
  end)

  it("escapes the leader and the title", function()
    local a = app({ leader = "Ev|il", title = "|cffx" })
    assert.are.equal("Application sent to Ev||il", a.title)
    assert.is_truthy(a.detail:find("||cffx", 1, true))
  end)
end)

describe("ViewModel groups form", function()
  it("starts with the roles that fit the party", function()
    assert.are.same({ tank = 1, heal = 1, dps = 1 }, ViewModel.GroupFormNew(1).needs)
    assert.are.same({ tank = 1, heal = 1, dps = 0 }, ViewModel.GroupFormNew(3).needs)
    assert.are.same({ tank = 0, heal = 0, dps = 0 }, ViewModel.GroupFormNew(5).needs)
    assert.are.equal("dungeon", ViewModel.GroupFormNew().kind)
  end)

  it("fills the form of an own post for an edit", function()
    local form = ViewModel.GroupFormFrom(own_post({ minLevel = 30, note = "hi" }))
    assert.are.same(
      { kind = "quest", title = "Elite quests", needs = { tank = 1, heal = 0, dps = 2 }, min = "30", note = "hi" },
      form
    )
    assert.are.equal("", ViewModel.GroupFormFrom(own_post()).min)
    assert.are.equal("", ViewModel.GroupFormFrom(own_post()).note)
  end)

  local function form(overrides)
    local f = { kind = "dungeon", title = "Deadmines", needs = { tank = 1, heal = 1, dps = 1 }, min = "", note = "" }
    for k, v in pairs(overrides or {}) do
      f[k] = v
    end
    return f
  end

  it("builds the fields the service takes", function()
    local v =
      ViewModel.GroupFormView(form({ title = "  Deadmines ", min = " 17 ", note = " bring water " }), { members = 1 })
    assert.is_true(v.canSubmit)
    assert.are.same({
      kind = "dungeon",
      title = "Deadmines",
      needs = { tank = 1, heal = 1, dps = 1 },
      minLevel = 17,
      note = "bring water",
    }, v.fields)
    assert.are.equal("Post", v.submitText)
    assert.are.equal("New group", v.heading)
  end)

  it("clears the level and the note when they are empty (an edit must be able to remove them)", function()
    local v = ViewModel.GroupFormView(form(), { members = 1, edit = true })
    assert.is_false(v.fields.minLevel)
    assert.are.equal("", v.fields.note)
    assert.are.equal("Save", v.submitText)
    assert.are.equal("Edit group", v.heading)
  end)

  it("limits the roles to the free seats and the steppers follow", function()
    local v = ViewModel.GroupFormView(form({ needs = { tank = 1, heal = 1, dps = 1 } }), { members = 2 })
    assert.are.equal(3, v.room)
    for _, s in ipairs(v.steppers) do
      assert.is_false(s.canInc, s.role)
      assert.is_true(s.canDec, s.role)
    end
    v = ViewModel.GroupFormView(form({ needs = { tank = 0, heal = 0, dps = 0 } }), { members = 1 })
    for _, s in ipairs(v.steppers) do
      assert.is_true(s.canInc, s.role)
      assert.is_false(s.canDec, s.role)
    end
    assert.are.same({ "Tank", "Heal", "DPS" }, { v.steppers[1].label, v.steppers[2].label, v.steppers[3].label })
  end)

  it("never lets one role go above the cap of the protocol", function()
    local v =
      ViewModel.GroupFormView(form({ needs = { tank = Constants.LFG_NEED_MAX, heal = 0, dps = 0 } }), { members = 1 })
    assert.is_false(v.steppers[1].canInc)
  end)

  it("refuses to post without a title, without roles, with a bad level or during a lockdown", function()
    assert.are.equal("The title is not valid", ViewModel.GroupFormView(form({ title = "   " }), {}).reason)
    local none = ViewModel.GroupFormView(form({ needs = { tank = 0, heal = 0, dps = 0 } }), {})
    assert.are.equal("Pick at least one role", none.reason)
    assert.is_false(none.canSubmit)
    for _, bad in ipairs({ "abc", "0", "101", "1.5", "-3" }) do
      local v = ViewModel.GroupFormView(form({ min = bad }), {})
      assert.is_false(v.canSubmit, bad)
      assert.are.equal("The minimum level must be a number from 1 to 100", v.minError, bad)
    end
    local locked = ViewModel.GroupFormView(form(), { locked = true })
    assert.is_false(locked.canSubmit)
    assert.are.equal("An encounter is in progress", locked.reason)
  end)

  it("lists the kinds with the chosen one active", function()
    local v = ViewModel.GroupFormView(form({ kind = "quest" }), {})
    local active
    for _, k in ipairs(v.kinds) do
      if k.active then
        active = k.value
      end
    end
    assert.are.equal("quest", active)
    assert.are.equal(3, #v.kinds)
  end)
end)

describe("ViewModel groups reasons", function()
  it("has a text for every reason the service, the rules and the form can give", function()
    for _, reason in ipairs({
      "locked",
      "raid",
      "not_leader",
      "full",
      "no_needs",
      "busy",
      "in_group",
      "own_post",
      "level",
      "role",
      "no_post",
      "combat",
      "unknown_applicant",
      "no_application",
      "bad_kind",
      "bad_title",
      "bad_needs",
      "bad_members",
      "bad_level",
      "bad_note",
      "unavailable",
      "error",
    }) do
      assert.is_truthy(ViewModel.GROUP_REASONS[reason], reason)
    end
  end)

  it("shows an unknown reason as it is, escaped, instead of failing", function()
    assert.are.equal("It could not be done (too_large)", ViewModel.GroupReason("too_large"))
    assert.is_truthy(ViewModel.GroupReason("a|b"):find("a||b", 1, true))
    assert.is_truthy(ViewModel.GroupReason(nil):find("nil", 1, true))
  end)
end)

describe("ViewModel groups summary", function()
  it("says how many groups are open", function()
    assert.are.equal("No open groups", ViewModel.GroupsSummary(0))
    assert.are.equal("No open groups", ViewModel.GroupsSummary(nil))
    assert.are.equal("1 open group", ViewModel.GroupsSummary(1))
    assert.are.equal("4 open groups", ViewModel.GroupsSummary(4))
  end)
end)

describe("ViewModel groups popup", function()
  local function popup(post, app)
    return ViewModel.LfgPopupView({ post = post, application = app })
  end

  it("asks the leader about the oldest waiting applicant", function()
    local v = popup(own_post({
      applicants = {
        { name = "Arthon", role = "tank", state = "invited", at = 1 },
        { name = "Dre|nna", role = "heal", state = "pending", at = 2 },
        { name = "Mirwen", role = "dps", state = "pending", at = 3 },
      },
    }))
    assert.are.equal("Dre||nna wants to go as Heal.", v.text)
    assert.are.equal("Dre|nna", v.target)
    assert.are.equal("New application", v.title)
    assert.are.same({ "invite", "decline" }, { v.buttons[1].id, v.buttons[2].id })
    assert.is_true(v.alert)
  end)

  it("changes its key only when what it says changes", function()
    local post = own_post({ applicants = { { name = "Ann", role = "dps", state = "pending", at = 1 } } })
    local first = popup(post)
    assert.are.equal(first.key, popup(post).key)
    post.applicants[1].role = "heal"
    assert.are_not.equal(first.key, popup(post).key)
  end)

  it("says nothing while nobody is waiting", function()
    assert.is_nil(popup(own_post({ applicants = { { name = "A", role = "dps", state = "invited", at = 1 } } })))
    assert.is_nil(popup(own_post()))
    assert.is_nil(popup(nil, { pid = "p", leader = "K", title = "t", role = "dps", state = "applied" }))
    assert.is_nil(ViewModel.LfgPopupView(nil))
  end)

  it("tells an applicant that the leader accepted or declined", function()
    local accepted = popup(nil, { pid = "p", leader = "Kae|lis", title = "t", role = "dps", state = "invited" })
    assert.are.equal("Application accepted", accepted.title)
    assert.is_truthy(accepted.text:find("Kae||lis invited you", 1, true))
    assert.are.equal("close", accepted.buttons[1].id)
    assert.is_nil(accepted.alert)
    local declined = popup(nil, { pid = "p", leader = "Kaelis", title = "t", role = "dps", state = "declined" })
    assert.are.equal("Application declined", declined.title)
    assert.are_not.equal(accepted.key, declined.key)
  end)
end)

describe("ViewModel groups in Spanish", function()
  it("translates the texts and the reasons", function()
    local es = load_view_model("esES")
    assert.are.equal("Mazmorra", es.GROUP_KINDS.dungeon)
    assert.are.equal("Ya estás en un grupo", es.GROUP_REASONS.in_group)
    assert.are.equal("Nuevo grupo", es.GroupFormView(es.GroupFormNew(1), {}).heading)
  end)
end)

describe("ViewModel groups icon", function()
  local function minimap(overrides)
    local state = {
      enabled = true,
      posts = { entry({ owner = "Kaelis", pid = "a" }) },
      ownName = "Me",
      canApply = function()
        return true
      end,
    }
    for k, v in pairs(overrides or {}) do
      state[k] = v
    end
    return ViewModel.GroupsIconView(state)
  end

  local function posts_of(count)
    local list = {}
    for index = 1, count do
      list[#list + 1] = entry({ owner = "P" .. index, pid = "p" .. index })
    end
    return list
  end

  it("is hidden while the module is disabled", function()
    local icon = minimap({ enabled = false })
    assert.is_false(icon.shown)
    assert.are.equal(1, icon.count)
  end)

  it("shows the player's own open group in the count badge", function()
    local iconView = minimap({
      posts = posts_of(1, "Me-Realm"),
    })

    -- Own posts count towards the badge and keep the icon visible.
    assert.is_true(iconView.shown)
    assert.are.equal(1, iconView.count)
    assert.are.equal("1", iconView.countText)
  end)

  it("shows all open groups, including the player's own, in board order", function()
    local icon = minimap({
      posts = {
        entry({ owner = "Kaelis", pid = "a" }),
        entry({ owner = "Me", pid = "m" }),
        entry({ owner = "Ana", pid = "b" }),
      },
    })

    -- All open groups contribute to the badge, including the player's own post.
    assert.is_true(icon.shown)
    assert.are.equal(3, icon.count)
    assert.are.equal("3", icon.countText)
    assert.are.equal("Open groups (3)", icon.title)
    assert.are.equal("Click to open Groups", icon.hint)
    assert.are.equal("Right click to change the icon", icon.rightClickHint)

    -- Preserve the board order in the tooltip, including the player's own group.
    assert.are.equal(3, #icon.lines)
    assert.is_truthy(icon.lines[1].text:find("Kaelis", 1, true))
    assert.is_truthy(icon.lines[2].text:find("Me", 1, true))
    assert.is_truthy(icon.lines[3].text:find("Ana", 1, true))

    -- The player's own group cannot be joined.
    assert.is_false(icon.lines[2].joinable)

    -- All groups fit within the tooltip limit.
    assert.is_nil(icon.more)
  end)

  it("lists at most five posts and says how many more there are", function()
    local icon = minimap({ posts = posts_of(7) })
    assert.are.equal(7, icon.count)
    assert.are.equal(5, #icon.lines)
    assert.is_truthy(icon.lines[5].text:find("P5", 1, true))
    assert.are.equal("and 2 more", icon.more)
  end)

  it("writes the count badge as nothing, the number, or 9+", function()
    assert.is_nil(minimap({ posts = posts_of(0) }).countText)
    assert.are.equal("1", minimap({ posts = posts_of(1) }).countText)
    assert.are.equal("2", minimap({ posts = posts_of(2) }).countText)
    assert.are.equal("9", minimap({ posts = posts_of(9) }).countText)
    assert.are.equal("9+", minimap({ posts = posts_of(10) }).countText)
    assert.are.equal("Open groups (10)", minimap({ posts = posts_of(10) }).title)
  end)

  it("lists the roles still needed only", function()
    local icon = minimap({ posts = { entry({ owner = "Kaelis", needs = { tank = 1, heal = 0, dps = 2 } }) } })
    assert.are.equal("Dungeon: Scarlet Monastery - Kaelis (Tank, DPS)", icon.lines[1].text)
    local none = minimap({ posts = { entry({ owner = "Kaelis", needs = { tank = 0, heal = 0, dps = 0 } }) } })
    assert.are.equal("Dungeon: Scarlet Monastery - Kaelis", none.lines[1].text)
  end)

  it("uses the Other label for an unknown kind", function()
    local icon =
      minimap({ posts = { entry({ owner = "Kaelis", kind = "raid", needs = { tank = 0, heal = 0, dps = 0 } }) } })
    assert.are.equal("Other: Scarlet Monastery - Kaelis", icon.lines[1].text)
  end)

  it("marks a post joinable only when canApply says yes", function()
    local asked = {}
    local icon = minimap({
      posts = { entry({ owner = "Kaelis", pid = "yes" }), entry({ owner = "Ana", pid = "no" }) },
      canApply = function(pid)
        asked[#asked + 1] = pid
        return pid == "yes"
      end,
    })
    assert.is_true(icon.lines[1].joinable)
    assert.is_false(icon.lines[2].joinable)
    assert.are.same({ "yes", "no" }, asked)
  end)

  it("is not joinable when canApply is missing, fails or returns nothing", function()
    local posts = { entry({ owner = "Kaelis", pid = "a" }) }
    local missing = ViewModel.GroupsIconView({ enabled = true, posts = posts, ownName = "Me" })
    assert.is_false(missing.lines[1].joinable)
    local failing = minimap({
      canApply = function()
        error("boom")
      end,
    })
    assert.is_false(failing.lines[1].joinable)
    local nothing = minimap({
      canApply = function()
        return nil
      end,
    })
    assert.is_false(nothing.lines[1].joinable)
  end)

  it("escapes the title and the leader", function()
    local icon = minimap({ posts = { entry({ owner = "Ka|elis", title = "Fire|Ice" }) } })
    assert.are.equal("Dungeon: Fire||Ice - Ka||elis (Tank, Heal)", icon.lines[1].text)
  end)

  it("never raises on missing posts, own name or canApply", function()
    local bare = ViewModel.GroupsIconView({ enabled = true })
    assert.is_false(bare.shown)
    assert.are.equal(0, bare.count)
    local no_name = ViewModel.GroupsIconView({ enabled = true, posts = { entry({ owner = "Kaelis" }) } })
    assert.is_true(no_name.shown)
    assert.is_false(no_name.lines[1].joinable)
  end)

  it("writes the texts in Spanish", function()
    local es = load_view_model("esES")
    local icon = es.GroupsIconView({
      enabled = true,
      posts = { entry({ owner = "Kaelis", pid = "a" }), entry({ owner = "Ana", pid = "b" }) },
      ownName = "Me",
    })
    assert.are.equal("Grupos abiertos (2)", icon.title)
    assert.are.equal("Clic para abrir Grupos", icon.hint)
    assert.is_truthy(icon.lines[1].text:find("Mazmorra: Scarlet Monastery - Kaelis", 1, true))
    local many = es.GroupsIconView({ enabled = true, posts = posts_of(6), ownName = "Me" })
    assert.are.equal("y 1 más", many.more)
  end)

  it("shows the count for a single open group", function()
    local iconView = ViewModel.GroupsIconView({
      enabled = true,
      ownName = "Me-Realm",
      posts = {
        {
          pid = "test-1",
          owner = "Other-Realm",
          title = "Deadmines",
          kind = "dungeon",
        },
      },
    })

    assert.is_true(iconView.shown)
    assert.are.equal(1, iconView.count)
    assert.are.equal("1", iconView.countText)
  end)

  it("counts the player's own open group without making it joinable", function()
    local iconView = ViewModel.GroupsIconView({
      enabled = true,
      ownName = "Me-Realm",
      posts = {
        {
          pid = "own-1",
          owner = "Me-Realm",
          title = "Deadmines",
          kind = "dungeon",
        },
      },
      canApply = function()
        return true
      end,
    })

    -- Own posts contribute to the badge but cannot be joined.
    assert.is_true(iconView.shown)
    assert.are.equal(1, iconView.count)
    assert.are.equal("1", iconView.countText)
    assert.is_false(iconView.lines[1].joinable)
  end)
end)
