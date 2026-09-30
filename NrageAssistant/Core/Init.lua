local addonName, ns = ...

local Constants = ns.Constants

local function GetVersion()
  local version = C_AddOns.GetAddOnMetadata(addonName, "Version")
  if not version or version == "@project-version@" then
    return "dev"
  end
  return version
end

local function InitDatabase()
  NrageAssistantDB = NrageAssistantDB or {}
  NrageAssistantDB.schemaVersion = NrageAssistantDB.schemaVersion or Constants.SCHEMA_VERSION
  ns.db = NrageAssistantDB
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == addonName then
    InitDatabase()
    frame:UnregisterEvent("ADDON_LOADED")
  elseif event == "PLAYER_LOGIN" then
    print(("|cff33ff99Nrage Assistant|r %s loaded. Type /nrage for help."):format(GetVersion()))
  end
end)

SLASH_NRAGE1 = "/nrage"
SlashCmdList.NRAGE = function()
  print(("|cff33ff99Nrage Assistant|r version %s"):format(GetVersion()))
end
