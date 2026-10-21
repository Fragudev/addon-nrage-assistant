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

-- Group: the player is alone. Specs that need a party or a raid replace these.
_G.IsInGroup = function()
  return false
end

_G.IsInRaid = function()
  return false
end

_G.GetNumGroupMembers = function()
  return 0
end

_G.GetRaidRosterInfo = function() end

_G.RaidNotice_AddMessage = function() end

_G.PlaySound = function() end

-- Map position: the player is in the open world on map 1 at the middle. Specs that need another answer replace these.
_G.C_Map = {
  GetBestMapForUnit = function()
    return 1
  end,
  GetPlayerMapPosition = function()
    return {
      GetXY = function()
        return 0.5, 0.5
      end,
    }
  end,
}

_G.UnitInParty = function()
  return false
end

_G.UnitInRaid = function() end
