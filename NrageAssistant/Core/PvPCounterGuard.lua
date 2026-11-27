local _, ns = ...

-- Shared by the live world-kill route and the developer probe. Lifetime HKs never establish a lower baseline.
local Guard = {}
function Guard.New(initial, context)
  local guard = {
    epoch = 0,
    previous = initial,
    context = context,
    lifetimeFloor = type(initial.lifetimeHK) == "number" and initial.lifetimeHK or 0,
  }
  function guard:Reset(reason, at)
    self.epoch = self.epoch + 1
    self.reason, self.since, self.samples = reason, at, 0
  end
  function guard:Observe(snapshot, currentContext, at)
    if currentContext ~= self.context then
      self.context = currentContext
      self:Reset("instance_or_map_changed", at)
    end
    snapshot.epoch = self.epoch
    if snapshot.error then
      return snapshot
    end
    local session, lifetime = snapshot.sessionHK, snapshot.lifetimeHK
    if type(session) ~= "number" or type(lifetime) ~= "number" then
      return snapshot
    end
    local decreased = (type(self.previous.sessionHK) == "number" and session < self.previous.sessionHK)
      or lifetime < self.lifetimeFloor
    if decreased and not self.reason then
      self:Reset("counter_decreased", at)
    end
    snapshot.epoch = self.epoch
    if self.reason then
      snapshot.guardReason = self.reason
      if lifetime < self.lifetimeFloor then
        self.samples = 0
      else
        self.samples = self.samples + 1
        if self.samples >= 2 and at - self.since >= 2 then
          self.reason = nil
          self.previous = snapshot
          self.lifetimeFloor = math.max(self.lifetimeFloor, lifetime)
        end
      end
      return snapshot
    end
    self.previous = snapshot
    self.lifetimeFloor = math.max(self.lifetimeFloor, lifetime)
    return snapshot
  end
  initial.epoch = 0
  return guard
end
ns.PvPCounterGuard = Guard
