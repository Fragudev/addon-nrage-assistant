local _, ns = ...

-- Raid, in the Guild group (docs/NAV_PERMISSIONS_PLAN.md 3.4): the upcoming events the player can see, soonest first.
-- Read-only: events are created and changed in the Raid tab of the Admin group.
local UI = ns.UI
local Kit = ns.Kit
local L = ns.L
local ViewModel = ns.ViewModel

UI.Register("events", function(page)
  local global = ns.db.global
  Kit.PageHeader(page, {
    title = L("Raid"),
    description = L("The upcoming raid events of your roster."),
  })
  local viewer = UI.Viewer()
  local events = ns.RosterService.FilterEvents(global.events, viewer)
  local data = ViewModel.UpcomingEventRows(events, ns.Platform.ServerTime(), global.rosters)
  local rows = {}
  for _, row in ipairs(data) do
    rows[#rows + 1] = {
      cells = {
        date = { text = row.dateText, color = "dim" },
        title = row.title,
        roster = { text = row.rosterText, color = "muted" },
      },
    }
  end
  Kit.Table(page, {
    columns = {
      { key = "date", title = L("Date"), weight = 1.4 },
      { key = "title", title = L("Title"), weight = 2 },
      { key = "roster", title = L("Roster"), weight = 1 },
    },
    fit = true,
    rows = rows,
    emptyText = L("No upcoming events"),
  })
end)
