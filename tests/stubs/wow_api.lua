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
