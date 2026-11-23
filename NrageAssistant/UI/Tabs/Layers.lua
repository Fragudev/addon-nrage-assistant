local _, ns = ...

-- Layers: the own layer, the "Share my layer" switch and the layers of this zone with the guildmates on each. What to
-- show comes from ViewModel.LayersView. Open to every role: the layer is shared with the guild only.
local UI = ns.UI
local Kit = ns.Kit
local L = ns.L
local ViewModel = ns.ViewModel

local function viewOf()
  local tracker, directory = ns.layerTracker, ns.layerDirectory
  local own = tracker and tracker:Current() or nil
  -- Layers are per zone: the guildmates listed are the ones in this zone.
  local zone = own and own.zone or ns.Platform.GetPlayerZoneId()
  return ViewModel.LayersView({
    own = own,
    inInstance = ns.Platform.IsInInstance() == true,
    share = ns.LayerModel.Settings(ns.db).share,
    ownName = ns.Platform.GetIdentityKey(),
    zoneName = zone and ns.Platform.GetMapName(zone) or nil,
    groups = directory and zone and directory:Groups(own and own.map or nil, zone) or {},
    available = tracker ~= nil,
  })
end

local function layersCard(page, view)
  local card = Kit.Card(page, { title = view.listTitle })
  if #view.rows == 0 then
    Kit.EmptyState(card, { icon = "disc", title = view.hint })
    return
  end
  local rows = {}
  for _, row in ipairs(view.rows) do
    local item = {
      title = row.label,
      subtitle = row.names ~= "" and row.names or nil,
      value = tostring(row.count),
      tooltipWhenCut = true,
    }
    if row.isOwn then
      item.badge = { text = L("You"), color = "info", fixed = true }
    end
    rows[#rows + 1] = item
  end
  Kit.List(card, { rows = rows })
end

-- The sections of the layers, drawn into `parent` (the Layers tab and the Home tab): your layer, the layers of the
-- zone and the note on how the layer is read.
function UI.DrawLayers(parent)
  local view = viewOf()

  local card = Kit.Card(parent, { title = L("Your layer"), gap = 8 })
  Kit.Label(card, { text = view.yourLayer, wrap = true })
  Kit.Switch(card, {
    label = L("Share my layer"),
    description = L("Guildmates see which layer you are on. Turn it off and they forget it."),
    checked = view.share,
    onChange = function(checked)
      ns.SetLayerShare(checked)
      UI.Redraw()
    end,
  })

  layersCard(parent, view)
  Kit.Label(parent, {
    text = L("The layer is read from the creatures you target or mouse over, and shared with the guild only."),
    style = "small",
    color = "muted",
    wrap = true,
  })
end

UI.Register("layers", function(page)
  Kit.PageHeader(page, {
    title = L("Layers"),
    description = L("Your layer and the layers of your guildmates."),
  })
  UI.DrawLayers(page)
end)
