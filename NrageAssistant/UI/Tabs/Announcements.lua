local _, ns = ...

-- Announcements (Guild group, docs/ANNOUNCEMENTS_MODULES_PVP_PLAN.md B.6): the board of the guild's announcements,
-- read only. Pinned ones come first, then the newest; the expired ones are not shown. Open to every role. Opening it
-- marks everything as read (the count of the sidebar goes away). What to show comes from ViewModel.AnnouncementBoard.
local UI = ns.UI
local Kit = ns.Kit
local L = ns.L
local ViewModel = ns.ViewModel

local function drawCard(page, row)
  local card = Kit.Card(page, { gap = 6, highlight = row.pinned })
  local head = Kit.Row(card, { gap = 8, align = "center" })
  Kit.Label(head, { text = row.title, style = "value", wrap = true, layout = { weight = 1 } })
  if row.pinned then
    Kit.Badge(head, { text = L("Pinned"), color = "accent" })
  end
  local meta = L("%s - %s - %s"):format(row.author, row.date or "", row.age)
  Kit.Label(card, { text = meta, style = "small", color = "muted", wrap = true })
  if row.body ~= "" then
    Kit.Label(card, { text = row.body, wrap = true, layout = { gap = 4 } })
  end
  if row.expires then
    Kit.Label(card, { text = row.expires, style = "small", color = "dim" })
  end
end

UI.Register("announcements", function(page)
  Kit.PageHeader(page, {
    title = L("Notice board"),
    description = L("News from the guild leaders."),
  })
  local service = ns.announcements
  if not service then
    Kit.EmptyState(page, {
      icon = "send",
      title = L("Announcements are not available"),
      hint = L("They start with the addon. Try /reload."),
    })
    return
  end
  local board = ViewModel.AnnouncementBoard(service:List(), ns.Platform.ServerTime())
  -- Drawing the board is reading it.
  service:MarkBoardOpened()
  UI.RefreshAnnouncementsBadge()
  if board.empty then
    Kit.EmptyState(page, {
      icon = "send",
      title = board.emptyText,
      hint = L("The guild leaders post news here."),
    })
    return
  end
  for _, row in ipairs(board.rows) do
    drawCard(page, row)
  end
end)
