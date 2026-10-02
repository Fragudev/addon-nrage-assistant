-- Minimal WoW API stubs so domain logic can run under busted outside the client.
-- Extend only with the APIs a spec actually needs.

_G.C_AddOns = {
  GetAddOnMetadata = function()
    return "@project-version@"
  end,
}

_G.CreateFrame = function()
  return {
    RegisterEvent = function() end,
    UnregisterEvent = function() end,
    SetScript = function() end,
  }
end

_G.SlashCmdList = {}

-- The client's `time` and `date` are the standard library ones.
_G.time = os.time
_G.date = os.date

-- PvP: a session with no kills, outside any instance, and an empty combat log.
_G.GetPVPSessionStats = function()
  return 0, 0
end

_G.IsInInstance = function()
  return false, "none"
end

_G.CombatLogGetCurrentEventInfo = function() end
