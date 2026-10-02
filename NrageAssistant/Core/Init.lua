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

-- The events the PvP counters listen to. Both are registered one by one, so a client that does not know one of
-- them still loads and keeps the other; the combat log is optional (it may be restricted on this client).
local PVP_HONOR_EVENTS = { "CHAT_MSG_COMBAT_HONOR_GAIN", "PLAYER_PVP_KILLS_CHANGED" }
local PVP_COMBAT_LOG_EVENT = "COMBAT_LOG_EVENT_UNFILTERED"

local pvpStarted = false

-- Own frame, so the access frame below stays as it is. Runs once: access can be lost and regained.
local function StartPvP()
  if pvpStarted then
    return
  end
  pvpStarted = true
  local pvp = ns.PvPService.Ensure(ns.character.pvp)
  ns.character.pvp = pvp
  ns.PvPService.Prune(pvp, ns.Platform.ServerDay(ns.Platform.ServerTime()), Constants.PVP_DAILY_DAYS)
  local tracker = ns.PvPTracker.New({
    platform = ns.Platform,
    stats = pvp,
    schedule = C_Timer.After,
  })
  tracker:Start()
  ns.pvpTracker = tracker

  -- The own counters go to the guild by themselves: a while after login, and after a change at most once per
  -- interval. Without a transport (or outside the guild) nothing is scheduled.
  local publisher = ns.PvPPublisher.New({
    sync = ns.character.pvpSync,
    stats = pvp,
    send = function(payload)
      return ns.comm:SendPvPStats(payload)
    end,
    now = ns.Platform.Now,
    serverTime = ns.Platform.ServerTime,
    day = function()
      return tracker:Day()
    end,
    blowsAvailable = function()
      return tracker.blowsAvailable
    end,
    schedule = C_Timer.After,
    random = math.random,
  })
  ns.pvpPublisher = publisher
  tracker.onChange = function()
    ns.UI.PvPChanged()
    publisher:Changed()
  end
  -- An admin reset of this character (received, or found in a snapshot): zero the counters, tell the guild.
  ns.comm.onPvPReset = function(rev)
    ns.PvPService.Reset(pvp)
    publisher:OnReset(rev)
    ns.UI.PvPChanged()
  end
  publisher:SendAtLogin()

  local pvpFrame = CreateFrame("Frame")
  for _, event in ipairs(PVP_HONOR_EVENTS) do
    ns.Platform.TryRegisterEvent(pvpFrame, event)
  end
  tracker.blowsAvailable = ns.Platform.TryRegisterEvent(pvpFrame, PVP_COMBAT_LOG_EVENT)
  pvpFrame:SetScript("OnEvent", function(_, event)
    if not ns.active then
      return
    end
    if event == PVP_COMBAT_LOG_EVENT then
      local info = ns.Platform.GetCombatLogInfo()
      if info then
        tracker:OnCombatLog(info)
      end
    else
      tracker:OnHonorEvent()
    end
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
  ns.VotingFrame.Start()
  StartPvP()
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
