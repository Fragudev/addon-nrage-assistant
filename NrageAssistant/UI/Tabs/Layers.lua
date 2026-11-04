local _, ns = ...

-- Layers (docs/LAYER_SWAP_PLAN.md, section 4.1): the own layer, the "Share my layer" switch, the layers of this
-- continent with the guildmates on each and a button to ask for a swap, and the swap that is running. What to show
-- (and the reason behind a disabled button) comes from ViewModel.LayersView; the request itself is LayerSwap:Request,
-- which checks the rules again. Open to every role: the layer is shared with the guild only.
local UI = ns.UI
local Kit = ns.Kit
local L = ns.L
local ViewModel = ns.ViewModel

local function viewOf()
  local tracker, directory, swap = ns.layerTracker, ns.layerDirectory, ns.layerSwap
  local own = tracker and tracker:Current() or nil
  local canRequest, reason
  if swap then
    canRequest, reason = swap:CanRequest()
  end
  return ViewModel.LayersView({
    own = own,
    inInstance = ns.Platform.IsInInstance() == true,
    share = ns.LayerModel.Settings(ns.db).share,
    ownName = ns.Platform.GetIdentityKey(),
    groups = directory and directory:Groups(own and own.map or nil) or {},
    swap = swap and swap:Status() or nil,
    canRequest = canRequest,
    reason = reason,
    available = swap ~= nil,
  }),
    swap
end

local function request(row)
  local ok, why = ns.layerSwap:Request(row.map, row.layer)
  if not ok then
    UI.Notify("warning", L("Not done: ") .. ViewModel.LayerReason(why))
    return
  end
  UI.Redraw()
end

local function layersCard(page, view)
  local card = Kit.Card(page, { title = L("Layers on this continent") })
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
    elseif row.button then
      item.right = {
        widget = "button",
        opts = {
          text = L("Request swap"),
          disabled = not row.enabled,
          tooltip = row.reason,
          layout = { width = "auto" },
          onClick = function()
            request(row)
          end,
        },
      }
    end
    rows[#rows + 1] = item
  end
  Kit.List(card, { rows = rows })
  for _, row in ipairs(view.rows) do
    if row.reason then
      Kit.Label(card, {
        text = L("You cannot ask for a swap now: %s"):format(row.reason),
        style = "small",
        color = "muted",
        wrap = true,
      })
      break
    end
  end
end

local function swapCard(page, view, swap)
  if not view.swapLine then
    return
  end
  local card = Kit.Card(page, { title = L("Current swap"), gap = 8 })
  Kit.Label(card, { text = view.swapLine, wrap = true })
  if view.cancelText then
    Kit.Button(card, {
      text = view.cancelText,
      layout = { width = "auto" },
      onClick = function()
        swap:Cancel()
        UI.Redraw()
      end,
    })
  end
end

-- The sections of the layers, drawn into `parent` (the Layers tab and the Home tab): your layer, the layers of the
-- continent, the running swap and the note on how the layer is read.
function UI.DrawLayers(parent)
  local view, swap = viewOf()

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
  swapCard(parent, view, swap)
  Kit.Label(parent, {
    text = L("The layer is read from the creatures you target or mouse over, and shared with the guild only.")
      .. " "
      .. L("A swap needs a guildmate on that layer to invite you; leaving the group afterwards is your choice."),
    style = "small",
    color = "muted",
    wrap = true,
  })
end

UI.Register("layers", function(page)
  Kit.PageHeader(page, {
    title = L("Layers"),
    description = L("Your layer, the layers of your guildmates and a swap when you want to change."),
  })
  UI.DrawLayers(page)
end)
