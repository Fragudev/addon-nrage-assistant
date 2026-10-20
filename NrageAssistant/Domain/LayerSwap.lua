local _, ns = ...

-- The layer swap flow, one state machine per client that runs both sides. A client takes part in at most one swap
-- at a time. Nothing here touches the client: the clock, the timers, the transport, the eligibility rules and the
-- game actions (invite, leave) are injected, so the rules are tested with fakes.
--
--   Requester: Request(map, layer) -> "request" (waiting for an offer) -> "assign" (the first offer won; waiting
--     for the invite and the group join) -> "joined" (waiting for the layer to be confirmed) -> "done". A swap that
--     ends otherwise is "closed" with an outcome: expired | cancelled | declined | unconfirmed.
--   Helper: an eligible member on the requested layer gets a "request" swap, answers with Offer(), is "assigned"
--     when the requester picks them, and Invite() asks the game to invite the requester ("invited").
--   The requester is the only arbiter: only the requester of a rid may send `assign` and `close` (the one
--     exception is `close declined` from the assigned helper), checked against the sender, never against a name in
--     the payload. A swap whose `close` was lost is dropped after Constants.LAYER_SWAP_MAX_AGE without activity.
--   Every action that invites or leaves a group is a method for a button the user clicks.
--
-- deps = { now = function() -> seconds (monotonic), schedule = function(delay, fn),
--          send = function(payload) -> ok, reason (live only: refuses during the lockdown),
--          isLocked = function() -> boolean, ownName = function() -> string, newId = function() -> rid,
--          ownLayer = function() -> { map, layer } or nil,
--          eligibility = { requester = function() -> ok, reason, helper = function(map, layer) -> ok, reason },
--          invite = function(name) -> ok, reason, leave = function() -> ok, reason,
--          onJoined = function(t) (the requester joined a group at time t), onChange = function() (optional) }
local LayerSwap = {}
LayerSwap.__index = LayerSwap

local FINAL = { done = true, closed = true }

function LayerSwap.New(deps)
  return setmetatable({ deps = deps, swap = nil }, LayerSwap)
end

local function changed(self)
  if self.deps.onChange then
    pcall(self.deps.onChange)
  end
end

local function locked(self)
  local ok, isLocked = pcall(self.deps.isLocked)
  return not ok or isLocked == true
end

local function transmit(self, payload)
  local ok, sent, reason = pcall(self.deps.send, payload)
  if not ok then
    return false, "error"
  end
  return sent == true, reason
end

-- Asks an eligibility rule; a rule that raises refuses.
local function eligible(rule, ...)
  local ok, allowed, reason = pcall(rule, ...)
  if not ok then
    return false, "error"
  end
  return allowed == true, reason
end

local function sameName(a, b)
  return type(a) == "string" and type(b) == "string" and ns.Validate.NameKey(a) == ns.Validate.NameKey(b)
end

-- Runs `fn` after `delay` seconds, but only if `swap` is still the swap of this client.
local function after(self, swap, delay, fn)
  swap.deadline = self.deps.now() + delay
  self.deps.schedule(delay, function()
    if self.swap == swap then
      fn()
    end
  end)
end

local function touch(self, swap)
  swap.lastAt = self.deps.now()
end

-- Drops a swap that has had no activity for LAYER_SWAP_MAX_AGE (a lost `close`). A finished swap of the requester
-- stays until it is dismissed.
local function watchAge(self, swap)
  local maxAge = ns.Constants.LAYER_SWAP_MAX_AGE
  local function check()
    if self.swap ~= swap or FINAL[swap.stage] then
      return
    end
    local left = maxAge - (self.deps.now() - swap.lastAt)
    if left <= 0 then
      self.swap = nil
      changed(self)
    else
      self.deps.schedule(left, check)
    end
  end
  self.deps.schedule(maxAge, check)
end

local function begin(self, swap)
  local now = self.deps.now()
  swap.startedAt, swap.lastAt = now, now
  self.swap = swap
  watchAge(self, swap)
end

-- Ends the swap of the requester. `silent` skips the `close` message (the other side ended it).
local function finish(self, swap, outcome, silent)
  swap.stage = outcome == "done" and "done" or "closed"
  swap.outcome = outcome
  swap.deadline = nil
  touch(self, swap)
  if not silent then
    transmit(self, { rid = swap.rid, s = "close", o = outcome })
  end
  changed(self)
end

local function drop(self)
  self.swap = nil
  changed(self)
end

-- The swap as the popup and the tab show it, or nil: { rid, role, stage, outcome, requester, helper, map, layer,
-- joined, offered, hidden, left }. `left` is the seconds until the current step times out, when it does.
function LayerSwap:Status()
  local swap = self.swap
  if not swap then
    return nil
  end
  local left
  if swap.deadline then
    left = math.max(0, swap.deadline - self.deps.now())
  end
  return {
    rid = swap.rid,
    role = swap.role,
    stage = swap.stage,
    outcome = swap.outcome,
    requester = swap.requester,
    helper = swap.helper,
    map = swap.map,
    layer = swap.layer,
    joined = swap.joined == true,
    offered = swap.offered == true,
    hidden = swap.hidden == true,
    left = left,
  }
end

-- Can this client ask for a swap now? Returns true, or false plus "busy" | "locked" | a reason of the eligibility.
function LayerSwap:CanRequest()
  local swap = self.swap
  if swap and not FINAL[swap.stage] then
    return false, "busy"
  end
  if locked(self) then
    return false, "locked"
  end
  return eligible(self.deps.eligibility.requester)
end

-- Requester: asks for the layer (map, layer). Returns true, or false plus the reason.
function LayerSwap:Request(map, layer)
  local constants = ns.Constants
  if not (ns.Validate.Int(map, 0, constants.LAYER_MAP_MAX) and ns.Validate.Int(layer, 1, constants.LAYER_ID_MAX)) then
    return false, "bad_target"
  end
  local ok, reason = self:CanRequest()
  if not ok then
    return false, reason
  end
  if ns.LayerModel.SameLayer(self.deps.ownLayer(), { map = map, layer = layer }) then
    return false, "same_layer"
  end

  local rid = self.deps.newId()
  local sent, why = transmit(self, { rid = rid, s = "request", map = map, layer = layer })
  if not sent then
    return false, why or "error"
  end
  local swap = { rid = rid, role = "requester", stage = "request", map = map, layer = layer }
  begin(self, swap)
  after(self, swap, constants.LAYER_REQUEST_TIMEOUT, function()
    if swap.stage == "request" then
      finish(self, swap, "expired")
    end
  end)
  changed(self)
  return true
end

-- Requester: cancels at any step; on a finished swap it just closes the popup.
function LayerSwap:Cancel()
  local swap = self.swap
  if not (swap and swap.role == "requester") then
    return false, "no_swap"
  end
  if FINAL[swap.stage] then
    return self:Dismiss()
  end
  finish(self, swap, "cancelled")
  return true
end

-- Closes the popup of a finished swap (requester) or of one the helper does not want to see.
function LayerSwap:Dismiss()
  local swap = self.swap
  if not swap then
    return false, "no_swap"
  end
  if swap.role == "helper" then
    return self:Ignore()
  end
  if not FINAL[swap.stage] then
    return false, "busy"
  end
  drop(self)
  return true
end

-- Requester: leaves the group (a button, never automatic). From the "joined" step this also cancels the swap.
function LayerSwap:LeaveGroup()
  local swap = self.swap
  local joined = swap and swap.role == "requester" and (swap.stage == "joined" or swap.stage == "done")
  if not (joined or (swap and swap.role == "requester" and swap.stage == "closed" and swap.joined)) then
    return false, "no_swap"
  end
  local ok, reason = eligible(self.deps.leave)
  if not ok then
    return false, reason or "error"
  end
  if not FINAL[swap.stage] then
    finish(self, swap, "cancelled")
  end
  drop(self)
  return true
end

-- Requester: the player joined a group. In the assign step this is the expected move; the layer readings from
-- before it are forgotten, so only what is read after the move can confirm it.
function LayerSwap:OnGroupJoined()
  local swap = self.swap
  if not (swap and swap.role == "requester" and swap.stage == "assign") then
    return false
  end
  local now = self.deps.now()
  swap.stage = "joined"
  swap.joined = true
  touch(self, swap)
  pcall(self.deps.onJoined, now)
  after(self, swap, ns.Constants.LAYER_CONFIRM_TIMEOUT, function()
    if swap.stage == "joined" then
      finish(self, swap, "unconfirmed")
    end
  end)
  changed(self)
  return true
end

-- Requester: the tracker confirmed a layer. The swap is done when it is the target.
function LayerSwap:OnLayerConfirmed(current)
  local swap = self.swap
  if not (swap and swap.role == "requester" and (swap.stage == "assign" or swap.stage == "joined")) then
    return false
  end
  if not ns.LayerModel.SameLayer(current, swap) then
    return false
  end
  finish(self, swap, "done")
  return true
end

-- Helper: answers the request. The requester takes the first offer.
function LayerSwap:Offer()
  local swap = self.swap
  if not (swap and swap.role == "helper" and swap.stage == "request") or swap.offered then
    return false, "no_swap"
  end
  if locked(self) then
    return false, "locked"
  end
  local ok, reason = eligible(self.deps.eligibility.helper, swap.map, swap.layer)
  if not ok then
    return false, reason
  end
  -- Marked before sending: the answer can come back before the send returns.
  swap.offered = true
  local sent, why = transmit(self, { rid = swap.rid, s = "offer" })
  if not sent then
    swap.offered = false
    return false, why or "error"
  end
  touch(self, swap)
  changed(self)
  return true
end

-- Helper: stops showing the request. A helper who already offered stays in the swap (they may still be picked).
function LayerSwap:Ignore()
  local swap = self.swap
  if not (swap and swap.role == "helper") then
    return false, "no_swap"
  end
  if swap.offered and swap.stage == "request" then
    swap.hidden = true
    changed(self)
  else
    drop(self)
  end
  return true
end

-- Helper (assigned): invites the requester through the game. Re-checks the rules first.
function LayerSwap:Invite()
  local swap = self.swap
  if not (swap and swap.role == "helper" and (swap.stage == "assigned" or swap.stage == "invited")) then
    return false, "no_swap"
  end
  if locked(self) then
    return false, "locked"
  end
  local ok, reason = eligible(self.deps.eligibility.helper, swap.map, swap.layer)
  if not ok then
    return false, reason
  end
  ok, reason = eligible(self.deps.invite, swap.requester)
  if not ok then
    return false, reason or "error"
  end
  swap.stage = "invited"
  touch(self, swap)
  changed(self)
  return true
end

-- Helper (assigned): backs out; the requester is told and may ask again.
function LayerSwap:Decline()
  local swap = self.swap
  if not (swap and swap.role == "helper" and (swap.stage == "assigned" or swap.stage == "invited")) then
    return false, "no_swap"
  end
  transmit(self, { rid = swap.rid, s = "close", o = "declined" })
  drop(self)
  return true
end

local function onRequest(self, sender, payload)
  local current = self.swap
  if current then
    if current.role == "helper" and current.requester == sender then
      -- A new request from the same requester replaces the old one.
      self.swap = nil
    elseif not FINAL[current.stage] and current.stage ~= nil then
      return false, "busy"
    end
  end
  if locked(self) then
    return false, "locked"
  end
  local ok, reason = eligible(self.deps.eligibility.helper, payload.map, payload.layer)
  if not ok then
    return false, reason
  end
  begin(self, {
    rid = payload.rid,
    role = "helper",
    stage = "request",
    requester = sender,
    map = payload.map,
    layer = payload.layer,
    offered = false,
  })
  changed(self)
  return true
end

local function onOffer(self, sender, payload)
  local swap = self.swap
  if not (swap and swap.role == "requester" and swap.rid == payload.rid) then
    return false, "unknown_swap"
  end
  if swap.stage ~= "request" then
    return false, "late"
  end
  local sent, why = transmit(self, { rid = swap.rid, s = "assign", helper = sender })
  if not sent then
    return false, why or "error"
  end
  swap.helper = sender
  swap.stage = "assign"
  touch(self, swap)
  after(self, swap, ns.Constants.LAYER_ASSIGN_TIMEOUT, function()
    if swap.stage == "assign" then
      finish(self, swap, "expired")
    end
  end)
  changed(self)
  return true
end

local function onAssign(self, sender, payload)
  local swap = self.swap
  if not (swap and swap.role == "helper" and swap.rid == payload.rid) then
    return false, "unknown_swap"
  end
  if sender ~= swap.requester then
    return false, "forbidden"
  end
  if not sameName(payload.helper, self.deps.ownName()) then
    -- Someone else was picked: the popup closes.
    drop(self)
    return true
  end
  if not swap.offered then
    return false, "not_offered"
  end
  swap.stage = "assigned"
  swap.hidden = false
  touch(self, swap)
  changed(self)
  return true
end

local function onClose(self, sender, payload)
  local swap = self.swap
  if not (swap and swap.rid == payload.rid) then
    return false, "unknown_swap"
  end
  if swap.role == "helper" then
    if sender ~= swap.requester then
      return false, "forbidden"
    end
    drop(self)
    return true
  end
  -- The requester only hears a `close` from the helper it picked, and only a decline.
  if payload.o == "declined" and swap.stage == "assign" and sender == swap.helper then
    finish(self, swap, "declined", true)
    return true
  end
  return false, "forbidden"
end

local HANDLERS = { request = onRequest, offer = onOffer, assign = onAssign, close = onClose }

-- A LAYER_SWAP message, already validated by Protocol and authorized by LayerSync. `sender` is the member who sent
-- it, as the client delivered it; the payload never says who anyone is. Returns true, or false plus the reason.
function LayerSwap:OnMessage(sender, payload)
  local handler = HANDLERS[payload.s]
  if not handler then
    return false, "unsupported"
  end
  return handler(self, sender, payload)
end

-- The eligibility rules (plan section 3.3) over a platform-like object.
--   platform: IsInGroup, IsInRaid, IsInInstance, IsInCombat, IsGroupLeader, GetGroupSize
--   ownLayer: function() -> { map, layer } or nil     isLocked: function() -> boolean
-- Each rule returns true, or false plus a reason.
function LayerSwap.Eligibility(platform, ownLayer, isLocked)
  local function common()
    if isLocked() then
      return false, "locked"
    end
    if platform.IsInInstance() then
      return false, "in_instance"
    end
    if platform.IsInCombat() then
      return false, "in_combat"
    end
    return true
  end

  return {
    requester = function()
      if platform.IsInGroup() then
        return false, "in_group"
      end
      return common()
    end,
    helper = function(map, layer)
      local current = ownLayer()
      if not current then
        return false, "unknown_layer"
      end
      if not ns.LayerModel.SameLayer(current, { map = map, layer = layer }) then
        return false, "other_layer"
      end
      local ok, reason = common()
      if not ok then
        return false, reason
      end
      if platform.IsInGroup() then
        if platform.IsInRaid() then
          return false, "in_raid"
        end
        if not platform.IsGroupLeader() then
          return false, "not_leader"
        end
        if platform.GetGroupSize() >= ns.Constants.LAYER_PARTY_SIZE then
          return false, "group_full"
        end
      end
      return true
    end,
  }
end

ns.LayerSwap = LayerSwap
