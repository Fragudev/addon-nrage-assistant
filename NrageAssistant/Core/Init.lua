local addonName, ns = ...

local Constants = ns.Constants
local PREFIX = "|cff33ff99Nrage Assistant|r"

local NOTICES = {
  not_in_guild = "disabled: you are not in a guild.",
  wrong_guild = "disabled: this addon is only for the Nrage guild.",
  wrong_faction = "disabled: this addon is only for the Alliance.",
  wrong_ruleset = "disabled: this addon is only for the PvP ruleset.",
}

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

local noticeShown = false

-- Re-evaluated on login and on guild changes; shows at most one notice per session.
local function EvaluateAccess()
  local ok, reason = ns.AccessGuard.Evaluate(ns.Platform, Constants)
  if ok then
    if not ns.active then
      ns.active = true
      print(("%s %s loaded. Type /nrage for help."):format(PREFIX, GetVersion()))
    end
    return
  end

  ns.active = false
  if not noticeShown then
    noticeShown = true
    print(("%s %s"):format(PREFIX, NOTICES[reason]))
  end
end

local function PrintIdentity()
  local P = ns.Platform
  print(PREFIX .. " identity (phase 0 measurement):")
  print("  build: " .. tostring(select(4, GetBuildInfo())))
  print("  realm: " .. tostring(P.GetRealmName()))
  print("  guild: " .. tostring(P.GetGuildName()))
  print("  clubId: " .. tostring(P.GetGuildClubId()))
  print("  faction: " .. tostring(P.GetFaction()))
  print("  lockdown: " .. tostring(P.IsChatMessagingLockedDown()))
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_GUILD_UPDATE")
frame:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 == addonName then
      InitDatabase()
      frame:UnregisterEvent("ADDON_LOADED")
    end
  else
    EvaluateAccess()
  end
end)

SLASH_NRAGE1 = "/nrage"
SlashCmdList.NRAGE = function(msg)
  local command, subcommand, action = msg:match("^(%S*)%s*(%S*)%s*(%S*)")
  if command == "debug" and subcommand == "identity" then
    PrintIdentity()
    return
  end
  if command == "debug" and subcommand == "lockdown" then
    ns.Probe.Handle(action)
    return
  end
  print(("%s version %s"):format(PREFIX, GetVersion()))
end
