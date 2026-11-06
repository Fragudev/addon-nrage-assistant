local _, ns = ...

-- Home (plan 3.1): who you are, your two specs and your layer, top to bottom, and nothing else. The identity and the
-- specs are the cards Profile draws too (UI/Cards.lua); the layers are the Layers tab's sections (UI.DrawLayers).
local UI = ns.UI
local Kit = ns.Kit
local L = ns.L

UI.Register("home", function(page)
  Kit.PageHeader(page, {
    title = L("Home"),
    description = L("Who you are, your specs and your layer."),
  })
  local character = ns.character
  UI.IdentityCard(page, character.profile)
  UI.SpecsCard(page, character.profile.fields or {})
  UI.DrawLayers(page)
  -- The open groups of the guild, with a way to the board.
  if ns.lfgBoard then
    local card = Kit.Card(page, { title = L("Groups"), gap = 8 })
    local row = Kit.Row(card, { gap = 12, align = "center" })
    Kit.Label(row, { text = ns.ViewModel.GroupsSummary(ns.lfgBoard:OpenCount()), layout = { weight = 1 } })
    Kit.Button(row, {
      text = L("Open Groups"),
      layout = { width = "auto" },
      onClick = function()
        UI.OpenTab("groups")
      end,
    })
  end
end)
