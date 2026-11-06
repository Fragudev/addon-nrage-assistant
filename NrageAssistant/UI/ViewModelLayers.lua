local _, ns = ...

-- Rows for the Layers tab and the text of the swap popup (docs/LAYER_SWAP_PLAN.md, section 4): the own layer, the
-- layers of the continent with the guildmates on each, and the swap that is running.
local ViewModel = ns.ViewModel
local L = ns.L

-- Layers. The reasons a swap cannot be asked for or done now, as shown next to a disabled button or after a click.
ViewModel.LAYER_REASONS = ns.Locale.Table(function()
  return {
    busy = L("a swap is already running."),
    locked = L("an encounter is in progress."),
    in_group = L("you are in a group."),
    in_instance = L("you are in an instance."),
    in_combat = L("you are in combat."),
    same_layer = L("you are already on that layer."),
    unknown_layer = L("your layer is not known yet."),
    other_layer = L("you are no longer on that layer."),
    in_raid = L("you are in a raid."),
    not_leader = L("you are in a group you do not lead."),
    group_full = L("your group is full."),
    lfg = L("you are looking for a group or have posted one."),
    unavailable = L("this client cannot do that."),
    unsupported = L("this client cannot do that."),
    no_swap = L("there is no swap to act on."),
    bad_target = L("that is not a valid layer."),
    error = L("the client refused the action."),
  }
end)

function ViewModel.LayerReason(reason)
  return ViewModel.LAYER_REASONS[reason] or tostring(reason)
end

local function layerLabel(map, layer)
  return ns.LayerModel.Describe(map, layer)
end

-- The popup and the Layers tab show one swap the same way. `status` is LayerSwap:Status(). Returns
-- { title, text, buttons = { { id, text } }, countdown = text or nil, alert = boolean } where the button ids are
-- help | ignore | invite | decline | cancel | leave | close, or nil when there is nothing to show.
local BUTTON_TEXT = ns.Locale.Table(function()
  return {
    help = L("Help"),
    ignore = L("Ignore"),
    invite = L("Invite"),
    decline = L("Decline"),
    cancel = L("Cancel"),
    leave = L("Leave group"),
    close = L("Close"),
  }
end)

local function buttons(...)
  local list = {}
  for _, id in ipairs({ ... }) do
    list[#list + 1] = { id = id, text = BUTTON_TEXT[id] }
  end
  return list
end

local function requesterView(status, target)
  local stage = status.stage
  if stage == "request" then
    return L("Looking for someone on %s..."):format(target), buttons("cancel")
  elseif stage == "assign" then
    return L("%s will invite you."):format(ViewModel.Escape(status.helper or "?")), buttons("cancel")
  elseif stage == "joined" then
    return L("Target or mouse over any NPC to confirm the move."), buttons("leave", "cancel")
  elseif stage == "done" then
    return L("Layer changed."), buttons("leave")
  end
  local outcome = status.outcome
  local text
  if outcome == "expired" then
    text = status.helper and L("The helper did not invite you in time.") or L("Nobody on that layer answered.")
  elseif outcome == "declined" then
    text = L("%s cannot help right now. You can ask again."):format(ViewModel.Escape(status.helper or "?"))
  elseif outcome == "unconfirmed" then
    text = L("Could not confirm the move.")
  else
    text = L("Swap cancelled.")
  end
  if status.joined then
    return text, buttons("leave", "close")
  end
  return text, buttons("close")
end

local function helperView(status)
  local name = ViewModel.Escape(status.requester or "?")
  if status.stage == "request" then
    if status.offered then
      return L("Offer sent. Waiting for %s to choose."):format(name), buttons("ignore")
    end
    return L("%s wants to join your layer."):format(name), buttons("help", "ignore")
  elseif status.stage == "assigned" then
    return L("Invite %s to your group."):format(name), buttons("invite", "decline")
  end
  return L("Waiting for %s to accept the invite."):format(name), buttons("decline")
end

function ViewModel.LayerSwapView(status)
  if type(status) ~= "table" then
    return nil
  end
  local text, list
  if status.role == "requester" then
    text, list = requesterView(status, layerLabel(status.map, status.layer))
  else
    text, list = helperView(status)
  end
  local view = {
    title = L("Layer swap"),
    text = text,
    buttons = list,
    alert = status.role == "helper" and status.stage == "request" and not status.offered,
  }
  if status.left then
    view.countdown = L("%d s left"):format(math.ceil(status.left))
  end
  return view
end

-- The Layers tab. `state` = { own = { map, layer } or nil, inInstance, share, ownName, groups = the layers of the
-- continent (LayerDirectory:Groups), swap = LayerSwap:Status() or nil, canRequest, reason, available }.
-- Returns { yourLayer, share, rows, hint, swapLine, cancelText } where each row is { key, label, count, names, isOwn,
-- map, layer, button = boolean, enabled, reason }.
function ViewModel.LayersView(state)
  local own = state.own
  local view = { share = state.share == true, rows = {} }
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
      button = not group.isOwn,
    }
    if row.button then
      row.enabled = state.canRequest == true
      row.reason = not row.enabled and ViewModel.LayerReason(state.reason) or nil
    end
    view.rows[#view.rows + 1] = row
  end
  if #view.rows == 0 then
    view.hint = L("Nobody has shared a layer yet.")
  end

  local swap = ViewModel.LayerSwapView(state.swap)
  if swap then
    view.swapLine = swap.text
    if state.swap.role == "requester" then
      local finished = state.swap.stage == "done" or state.swap.stage == "closed"
      view.cancelText = finished and BUTTON_TEXT.close or BUTTON_TEXT.cancel
    end
  end
  return view
end
