-- The decisions of the announcement popup (UI/AnnouncementPopup.lua), apart from its frame: when it shows, waits for
-- the end of combat, queues, moves between announcements and marks them seen; and what it draws.
local function load_popup()
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
    "Domain/Professions",
    "UI/ViewModel",
    "UI/ViewModelHome",
    "UI/ViewModelAnnouncements",
    "UI/AnnouncementPopup",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns.AnnouncementPopup.Controller, ns
end

local Controller, ns = load_popup()

local function announcement(id, updatedAt, overrides)
  local a = {
    id = id,
    title = "Title " .. id,
    body = "Body of " .. id,
    author = "Gm-Realm",
    createdAt = updatedAt,
    updatedAt = updatedAt,
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

local function build(overrides)
  local env = {
    items = {},
    seen = {},
    blocked = false,
    shown = {},
    hidden = 0,
    timers = {},
    alerts = 0,
    boards = 0,
    clock = 2000,
  }
  local deps = {
    get = function(id)
      return env.items[id]
    end,
    markSeen = function(id)
      env.seen[#env.seen + 1] = id
    end,
    isBlocked = function()
      return env.blocked
    end,
    after = function(seconds, fn)
      env.timers[#env.timers + 1] = { seconds = seconds, fn = fn }
    end,
    now = function()
      return env.clock
    end,
    show = function(view)
      env.shown[#env.shown + 1] = view
    end,
    hide = function()
      env.hidden = env.hidden + 1
    end,
    openBoard = function()
      env.boards = env.boards + 1
    end,
    alert = function()
      env.alerts = env.alerts + 1
    end,
  }
  for key, value in pairs(overrides or {}) do
    deps[key] = value
  end
  env.controller = Controller.New(deps)
  function env.add(id, updatedAt, extra)
    env.items[id] = announcement(id, updatedAt, extra)
    env.controller:Add(env.items[id])
  end
  function env.last()
    return env.shown[#env.shown]
  end
  return env
end

describe("AnnouncementPopup controller", function()
  it("shows the card with the announcement and alerts once", function()
    local env = build()
    env.add("a", 1000)
    assert.are.equal(1, #env.shown)
    assert.are.equal("Title a", env.last().title)
    assert.is_nil(env.last().counter)
    assert.are.equal(1, env.alerts)
    env.controller:Refresh()
    assert.are.equal(1, env.alerts)
  end)

  it("waits while the player is in combat or in a lockdown, and shows when it is over", function()
    local env = build()
    env.blocked = true
    env.add("a", 1000)
    assert.are.equal(0, #env.shown)
    assert.are.equal(0, env.alerts)
    assert.are.equal(1, #env.timers)
    assert.are.equal(ns.Constants.ANNOUNCE_POPUP_RETRY_SECONDS, env.timers[1].seconds)
    -- Still in combat when the timer fires: it waits again, once.
    env.timers[1].fn()
    assert.are.equal(0, #env.shown)
    assert.are.equal(2, #env.timers)
    env.blocked = false
    env.controller:Refresh()
    assert.are.equal(1, #env.shown)
    assert.are.equal(1, env.alerts)
  end)

  it("does not schedule a second retry while one is waiting", function()
    local env = build()
    env.blocked = true
    env.add("a", 1000)
    env.add("b", 1100)
    env.controller:Refresh()
    assert.are.equal(1, #env.timers)
  end)

  it("queues several, newest first, and says which one of how many", function()
    local env = build()
    env.add("new", 1500)
    env.add("old", 1000)
    assert.are.equal("Title new", env.last().title)
    assert.are.equal("1 of 2", env.last().counter)
    assert.is_false(env.last().canPrev)
    assert.is_true(env.last().canNext)
    env.controller:Next()
    assert.are.equal("Title old", env.last().title)
    assert.are.equal("2 of 2", env.last().counter)
    assert.is_true(env.last().canPrev)
    env.controller:Next()
    assert.are.equal("2 of 2", env.last().counter)
    env.controller:Previous()
    assert.are.equal("Title new", env.last().title)
  end)

  it("stays on the announcement being read when a newer one arrives", function()
    local env = build()
    env.add("old", 1000)
    env.add("new", 1500)
    env.controller:Next()
    env.add("newest", 1800)
    assert.are.equal("Title old", env.last().title)
    assert.are.equal("3 of 3", env.last().counter)
  end)

  it("alerts again when another announcement arrives, but not when moving between them", function()
    local env = build()
    env.add("a", 1000)
    env.add("b", 1100)
    assert.are.equal(2, env.alerts)
    env.controller:Next()
    env.controller:Previous()
    assert.are.equal(2, env.alerts)
  end)

  it("keeps the three newest and marks the older ones as seen", function()
    local env = build()
    for index = 1, 5 do
      env.add("n" .. index, 1000 + index)
    end
    assert.are.equal(ns.Constants.ANNOUNCE_POPUP_QUEUE_MAX, env.controller:Count())
    table.sort(env.seen)
    assert.are.same({ "n1", "n2" }, env.seen)
    assert.is_truthy(env.last().counter)
  end)

  it("'Got it' marks the one on the card as seen and moves on, then closes", function()
    local env = build()
    env.add("a", 1000)
    env.add("b", 1100)
    env.controller:GotIt()
    assert.are.same({ "a" }, env.seen)
    assert.are.equal("Title b", env.last().title)
    assert.is_nil(env.last().counter)
    env.controller:GotIt()
    assert.are.same({ "a", "b" }, env.seen)
    assert.are.equal(1, env.hidden)
    assert.are.equal(0, env.controller:Count())
  end)

  it("'Open board' marks everything waiting as seen, closes the card and opens the board", function()
    local env = build()
    env.add("a", 1000)
    env.add("b", 1100)
    env.controller:OpenBoard()
    table.sort(env.seen)
    assert.are.same({ "a", "b" }, env.seen)
    assert.are.equal(1, env.boards)
    assert.are.equal(1, env.hidden)
    assert.are.equal(0, env.controller:Count())
  end)

  it("the close button counts as having read everything waiting", function()
    local env = build()
    env.add("a", 1000)
    env.controller:DismissAll()
    assert.are.same({ "a" }, env.seen)
    assert.are.equal(1, env.hidden)
  end)

  it("drops an announcement that was deleted while it waited", function()
    local env = build()
    env.add("a", 1000)
    env.add("b", 1100)
    env.items["b"] = nil
    env.controller:Refresh()
    assert.are.equal("Title a", env.last().title)
    assert.is_nil(env.last().counter)
    env.items["a"] = nil
    env.controller:Refresh()
    assert.are.equal(1, env.hidden)
  end)

  it("does not queue the same announcement twice", function()
    local env = build()
    env.add("a", 1000)
    env.controller:Add(env.items["a"])
    assert.are.equal(1, env.controller:Count())
  end)

  it("queues nothing while the module is off", function()
    local env = build({
      enabled = function()
        return false
      end,
    })
    env.add("a", 1000)
    assert.are.equal(0, env.controller:Count())
    assert.are.equal(0, #env.shown)
  end)

  it("shows a long text in a scrolling box", function()
    local env = build()
    env.add("a", 1000, { body = ("line\n"):rep(15) })
    assert.is_true(env.last().long)
    local short = build()
    short.add("a", 1000)
    assert.is_false(short.last().long)
  end)
end)

describe("AnnouncementPopup drawing", function()
  local function draw(view)
    local Kit = { made = {} }
    local function make(kind)
      return function(parent, opts)
        local node = { kind = kind, opts = opts, parent = parent }
        Kit.made[#Kit.made + 1] = node
        return node
      end
    end
    Kit.Label, Kit.Row, Kit.Button, Kit.TextArea = make("Label"), make("Row"), make("Button"), make("TextArea")
    ns.Kit = Kit
    local pressed = {}
    local function press(name)
      return function()
        pressed[#pressed + 1] = name
      end
    end
    ns.AnnouncementPopup.Draw({}, view, {
      gotIt = press("gotIt"),
      openBoard = press("openBoard"),
      next = press("next"),
      previous = press("previous"),
    })
    local function find(kind, text)
      for _, node in ipairs(Kit.made) do
        if node.kind == kind and (text == nil or node.opts.text == text) then
          return node
        end
      end
    end
    return Kit, pressed, find
  end

  local function view(overrides)
    local a = announcement("a", 1000, overrides)
    return ns.ViewModel.AnnouncementPopupView(a, 1, 1, 1200)
  end

  it("draws the title, who and when, the text and the two buttons, the first as the main one", function()
    local _, pressed, find = draw(view())
    assert.are.equal("Title a", find("Label").opts.text)
    assert.is_truthy(find("Label", "Gm-Realm - 3 min ago"))
    assert.is_truthy(find("Label", "Body of a"))
    local gotIt, board = find("Button", "Got it"), find("Button", "Open board")
    assert.are.same({ "primary", "secondary" }, { gotIt.opts.variant, board.opts.variant })
    gotIt.opts.onClick()
    board.opts.onClick()
    assert.are.same({ "gotIt", "openBoard" }, pressed)
    assert.is_nil(find("TextArea"))
    assert.is_nil(find("Button", "<"))
  end)

  it("draws the arrows with their state when several wait", function()
    local a = announcement("a", 1000)
    local _, pressed, find = draw(ns.ViewModel.AnnouncementPopupView(a, 2, 3, 1200))
    assert.is_truthy(find("Label", "2 of 3"))
    find("Button", "<").opts.onClick()
    find("Button", ">").opts.onClick()
    assert.are.same({ "previous", "next" }, pressed)
    local _, _, first = draw(ns.ViewModel.AnnouncementPopupView(a, 1, 3, 1200))
    assert.is_true(first("Button", "<").opts.disabled)
    assert.is_false(first("Button", ">").opts.disabled)
  end)

  it("puts a long text in a read-only box and leaves out an empty one", function()
    local _, _, find = draw(view({ body = ("line\n"):rep(15) }))
    assert.is_true(find("TextArea").opts.readOnly)
    local _, _, none = draw(view({ body = "" }))
    assert.is_nil(none("TextArea"))
    assert.is_nil(none("Label", ""))
  end)

  it("shows the announcement escaped, whatever was received", function()
    local _, _, find = draw(view({ title = "A|cffff0000red" }))
    assert.are.equal("A||cffff0000red", find("Label").opts.text)
  end)
end)

describe("AnnouncementPopup without the frame", function()
  it("does nothing before it is started", function()
    assert.has_no.errors(function()
      ns.AnnouncementPopup.Refresh()
      ns.AnnouncementPopup.Add(announcement("a", 1000))
    end)
  end)
end)
