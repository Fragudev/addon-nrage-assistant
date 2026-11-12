local _, ns = ...

-- Raid, in the Guild group (docs/NAV_PERMISSIONS_PLAN.md 3.4): the upcoming events the player can see, soonest first.
-- Read-only except for the player's own sign-up: events are created and changed in the Raid tab of the Admin group.
local UI = ns.UI
local Kit = ns.Kit
local L = ns.L
local ViewModel = ns.ViewModel

-- The own answer is sent through RaidCommands like every other change, so it is validated and queued as usual.
local function signupCommands()
  local global = ns.db.global
  return ns.RaidCommands.New({
    events = global.events,
    tombstones = global.sync.tombstones,
    platform = ns.Platform,
    comm = ns.comm,
    rosters = global.rosters,
    members = global.members,
  })
end

-- One button of the Going / Not going pair: the current answer is highlighted, and nothing happens when the sign-up
-- is closed or the rank cannot answer.
local function answerButton(row, status, text, global)
  local chosen = row.answer == status
  return {
    widget = "button",
    opts = {
      text = text,
      variant = chosen and "primary" or "secondary",
      disabled = not row.canAnswer or not ns.comm,
      tooltip = not row.canAnswer and L("Sign-up is closed for this event.") or nil,
      onClick = function()
        UI.Report(signupCommands():SetSignup(global.events[row.eventId], status))
      end,
    },
  }
end

UI.Register("events", function(page)
  local global = ns.db.global
  Kit.PageHeader(page, {
    title = L("Raid"),
    description = L("The upcoming raid events of your roster."),
  })
  UI.DrawSectionTabs(page, "events")
  local viewer = UI.Viewer()
  local events = ns.RosterService.FilterEvents(global.events, viewer)
  local own = { key = ns.Platform.GetIdentityKey(), role = UI.Role(), rosterId = UI.OwnRosterId() }
  local data = ViewModel.UpcomingEventRows(events, ns.Platform.ServerTime(), global.rosters, own)
  local rows = {}
  for _, row in ipairs(data) do
    rows[#rows + 1] = {
      cells = {
        date = { text = row.dateText, color = "dim" },
        title = row.title,
        roster = { text = row.rosterText, color = "muted" },
        going = { text = row.goingText, color = "dim" },
        yes = answerButton(row, "yes", L("Going"), global),
        no = answerButton(row, "no", L("Not going"), global),
      },
    }
  end
  Kit.Table(page, {
    columns = {
      { key = "date", title = L("Date"), weight = 1.4 },
      { key = "title", title = L("Title"), weight = 2 },
      { key = "roster", title = L("Roster"), weight = 1 },
      { key = "going", title = L("Sign-ups"), weight = 0.8 },
      { key = "yes", title = "", width = 90 },
      { key = "no", title = "", width = 110 },
    },
    fit = true,
    rows = rows,
    emptyText = L("No upcoming events"),
  })
end)
