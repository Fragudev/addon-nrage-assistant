local _, ns = ...

-- Rows for the Layers tab: the own layer and the layers of the zone with the guildmates on each.
local ViewModel = ns.ViewModel
local L = ns.L

local function layerLabel(map, layer)
  return ns.LayerModel.Describe(map, layer)
end

-- The Layers tab. `state` = { own = { map, layer, zone } or nil, inInstance, share, ownName, zoneName (or nil),
-- groups = the layers of the zone (LayerDirectory:Groups), available }. Returns { yourLayer, share, listTitle, rows,
-- hint } where each row is { key, label, count, names, isOwn, map, layer }.
function ViewModel.LayersView(state)
  local own = state.own
  local view = { share = state.share == true, rows = {} }
  if state.zoneName then
    view.listTitle = L("Layers in %s"):format(ViewModel.Escape(state.zoneName))
  else
    view.listTitle = L("Layers in this zone")
  end
  if state.inInstance then
    view.yourLayer = L("Your layer: you are in an instance.")
  elseif own then
    view.yourLayer = L("Your layer: %s"):format(layerLabel(own.map, own.layer))
  else
    view.yourLayer = L("Your layer: unknown. Target or mouse over any NPC.")
  end
  if state.available == false then
    view.hint = L("Layers are not available yet.")
    return view
  end

  local groups = {}
  local hasOwn = false
  for _, group in ipairs(state.groups or {}) do
    local isOwn = ns.LayerModel.SameLayer(own, group)
    hasOwn = hasOwn or isOwn
    local names = {}
    for _, name in ipairs(group.members) do
      names[#names + 1] = name
    end
    if isOwn and state.share and state.ownName then
      names[#names + 1] = state.ownName
      table.sort(names)
    end
    groups[#groups + 1] = { map = group.map, layer = group.layer, names = names, isOwn = isOwn }
  end
  if own and not hasOwn and not state.inInstance then
    table.insert(groups, 1, {
      map = own.map,
      layer = own.layer,
      names = state.share and state.ownName and { state.ownName } or {},
      isOwn = true,
    })
  end

  for _, group in ipairs(groups) do
    local label = layerLabel(group.map, group.layer)
    if not own then
      label = L("%s (map %d)"):format(label, group.map)
    elseif group.isOwn then
      label = L("%s (you)"):format(label)
    end
    local escaped = {}
    for index, name in ipairs(group.names) do
      escaped[index] = ViewModel.Escape(name)
    end
    local row = {
      key = ns.LayerModel.Key(group.map, group.layer),
      label = label,
      count = #group.names,
      names = table.concat(escaped, ", "),
      isOwn = group.isOwn,
      map = group.map,
      layer = group.layer,
    }
    view.rows[#view.rows + 1] = row
  end
  if #view.rows == 0 then
    view.hint = L("Nobody has shared a layer yet.")
  end

  return view
end
