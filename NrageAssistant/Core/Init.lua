local addonName, ns = ...

local Constants = ns.Constants
local PREFIX = "|cff33ff99Nrage Assistant|r"

local NOTICES = {
  not_in_guild = "disabled: you are not in a guild.",
  wrong_guild = "disabled: this addon is only for the Nrage guild.",
  wrong_faction = "disabled: this addon is only for the Alliance.",
  wrong_ruleset = "disabled: this addon is only for the PvP ruleset.",
  incompatible_data = "disabled: saved data comes from a newer version of the addon. "
    .. "Update the addon; your data was left untouched.",
}

function ns.GetVersion()
  local version = C_AddOns.GetAddOnMetadata(addonName, "Version")
  if not version or version == "@project-version@" then
    return "dev"
  end
  return version
end

local function InitDatabase()
  local db, err = ns.Store.Load(NrageAssistantDB)
  if db then
    NrageAssistantDB = db
    ns.db = db
  else
    -- Leave NrageAssistantDB as it is so nothing is lost on a downgrade.
    ns.dbError = err
  end
end

-- Runs the self test once, a few seconds after login, and prints nothing. A failure only shows on the minimap
-- button (warning mark and tooltip); /nrage debug selftest still prints the full result.
local SELFTEST_DELAY_SECONDS = 10

local function ScheduleSelfTest()
  C_Timer.After(SELFTEST_DELAY_SECONDS, function()
    local results = ns.Diagnostics.SelfTest(_G, ns)
    ns.selfTestFailures = ns.Diagnostics.Failures(results)
    ns.MinimapButton.Refresh()
  end)
end

local function Activate()
  ns.active = true
  -- The saved data of this character keeps the key it always had; the shared name is resolved later.
  ns.character = ns.Store.GetChar(ns.db, ns.Platform.GetLegacyIdentityKey())
  ns.ProfileService.Refresh(ns.Platform, ns.character.profile)
  ns.EventService.Purge({
    events = ns.db.global.events,
    tombstones = ns.db.global.sync.tombstones,
    now = ns.Platform.ServerTime,
  })
  ns.Comm.Start()
  ns.MinimapButton.Create()
  ns.guildRoster = ns.GuildRoster.New({
    platform = ns.Platform,
    schedule = C_Timer.After,
    now = ns.Platform.Now,
    ownGuid = ns.Platform.GetGUID,
    onOwnName = ns.Platform.SetCanonicalName,
  })
  ns.guildRoster:Request()
  ns.guildRoster:Rebuild()
  ns.LootPopup.Start()
  ScheduleSelfTest()
  print(("%s %s loaded. Type /nrage for help."):format(PREFIX, ns.GetVersion()))
end

local noticeShown = false

-- Re-evaluated on login and on guild changes; shows at most one notice per session.
local function EvaluateAccess()
  local ok, reason = ns.AccessGuard.Evaluate(ns.Platform, Constants)
  if ok and ns.dbError then
    ok, reason = false, "incompatible_data"
  end

  if ok then
    if not ns.active then
      Activate()
    end
    return
  end

  ns.active = false
  ns.MinimapButton.Refresh()
  if not noticeShown then
    noticeShown = true
    print(("%s %s"):format(PREFIX, NOTICES[reason]))
  end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_GUILD_UPDATE")
frame:RegisterEvent("GUILD_ROSTER_UPDATE")
frame:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 == addonName then
      InitDatabase()
      frame:UnregisterEvent("ADDON_LOADED")
    end
  elseif event == "GUILD_ROSTER_UPDATE" then
    if ns.active and ns.guildRoster then
      ns.guildRoster:OnUpdate()
    end
  else
    EvaluateAccess()
  end
end)
