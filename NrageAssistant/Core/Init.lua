local addonName, ns = ...

local Constants = ns.Constants
local L = ns.L
local PREFIX = "|cff33ff99Nrage Assistant|r"

local NOTICES = ns.Locale.Table(function()
  return {
    not_in_guild = L("disabled: you are not in a guild."),
    wrong_guild = L("disabled: this addon is only for the Nrage guild."),
    wrong_faction = L("disabled: this addon is only for the Alliance."),
    wrong_ruleset = L("disabled: this addon is only for the PvP ruleset."),
    incompatible_data = L(
      "disabled: saved data comes from a newer version of the addon. Update the addon; your data was left untouched."
    ),
  }
end)

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
    -- The saved language is applied before anything is drawn, so every text is read in it.
    ns.Locale.UsePreference(ns.Settings.Language(db), ns.Platform.GetLocale())
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
-- them still loads and keeps the other. The combat log is optional and off (Constants.PVP_COMBAT_LOG_ENABLED).
local PVP_HONOR_EVENTS = { "CHAT_MSG_COMBAT_HONOR_GAIN", "PLAYER_PVP_KILLS_CHANGED" }
local PVP_HONOR_TEXT_EVENT = PVP_HONOR_EVENTS[1]
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

  -- The own kill feed, shared with the guild. Its victim names come from the text of the honour message and from
  -- the killing blow in the combat log; with neither, it stays empty and the tab says so.
  local feed = ns.PvPFeed.New({
    now = ns.Platform.Now,
    serverTime = ns.Platform.ServerTime,
    send = function(payload)
      return ns.comm:SendPvPKill(payload)
    end,
    isLocked = function()
      return not ns.lockdown:CanSend()
    end,
    schedule = C_Timer.After,
    ownName = ns.Platform.GetIdentityKey,
    onChange = ns.UI.PvPChanged,
  })
  feed.honorNames = ns.Platform.HasHonorVictimSource()
  ns.pvpFeed = feed

  local pvpFrame = CreateFrame("Frame")
  for _, event in ipairs(PVP_HONOR_EVENTS) do
    ns.Platform.TryRegisterEvent(pvpFrame, event)
  end
  -- A protected event: even inside a pcall, registering it shows the client's "blocked action" dialog.
  tracker.blowsAvailable = Constants.PVP_COMBAT_LOG_ENABLED
      and ns.Platform.TryRegisterEvent(pvpFrame, PVP_COMBAT_LOG_EVENT)
    or false
  feed.blowNames = tracker.blowsAvailable
  pvpFrame:SetScript("OnEvent", function(_, event, text)
    if not ns.active then
      return
    end
    if event == PVP_COMBAT_LOG_EVENT then
      local info = ns.Platform.GetCombatLogInfo()
      if info and tracker:OnCombatLog(info) and info.destName then
        feed:OnKillingBlow(info.destName, tracker:Where())
      end
    else
      tracker:OnHonorEvent()
      if event == PVP_HONOR_TEXT_EVENT then
        local victim = ns.Platform.ParseHonorVictim(text)
        if victim then
          feed:OnHonorKill(victim, tracker:Where())
        end
      end
    end
  end)
end

-- The events the blacklist watcher listens to: the group changed, and a new world (login, a loading screen)
-- with a group already formed. Each is registered on its own, so a client that does not know one keeps the other.
local BLACKLIST_EVENTS = { "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD" }

local blacklistStarted = false

-- A blacklist entry changed here or arrived from the guild: the tab is redrawn and the group is looked at again,
-- because the entry may be about someone who is already in it.
function ns.BlacklistChanged()
  ns.UI.BlacklistChanged()
  if ns.blacklistWatcher then
    pcall(ns.blacklistWatcher.Check, ns.blacklistWatcher)
  end
end

-- Own frame. Runs once: access can be lost and regained.
local function StartBlacklist()
  if blacklistStarted then
    return
  end
  blacklistStarted = true
  local watcher = ns.BlacklistWatcher.New({
    blacklist = ns.db.global.blacklist,
    isGrouped = ns.Platform.IsInGroup,
    members = ns.Platform.GetGroupMemberNames,
    ownNames = function()
      return { ns.Platform.GetIdentityKey(), ns.Platform.GetPlayerName() }
    end,
    -- Each part is guarded inside Platform: a warning that cannot be shown must not hide the chat line.
    alert = function(match)
      local line = ns.ViewModel.BlacklistAlertLine(match)
      print(("%s: %s"):format(PREFIX, line))
      ns.Platform.ShowRaidNotice(line)
      -- The chat line and the warning always show; only the sound can be switched off (settings).
      if ns.Settings.BlacklistSound(ns.db) then
        ns.Platform.PlayAlertSound()
      end
    end,
  })
  ns.blacklistWatcher = watcher

  local blacklistFrame = CreateFrame("Frame")
  for _, event in ipairs(BLACKLIST_EVENTS) do
    ns.Platform.TryRegisterEvent(blacklistFrame, event)
  end
  blacklistFrame:SetScript("OnEvent", function()
    if ns.active then
      pcall(watcher.Check, watcher)
    end
  end)
  -- A group that already exists when the addon starts.
  pcall(watcher.Check, watcher)
end

-- The profile is shared with the guild without a switch (issue #36): once after login, when the roster has had time
-- to load, and again whenever what would be shared differs from what was last sent.
local function StartAutoPublish()
  local function check()
    if ns.active and ns.character and ns.comm then
      ns.ProfileService.Refresh(ns.Platform, ns.character.profile)
      ns.PublishService.PublishIfChanged(ns.comm, ns.character, ns.Platform)
    end
  end
  C_Timer.After(math.random(Constants.SYNC_LOGIN_REQUEST_DELAY_MIN, Constants.SYNC_LOGIN_REQUEST_DELAY_MAX) + 1, check)
  C_Timer.NewTicker(Constants.PUBLISH_CHECK_SECONDS, check)
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
  StartBlacklist()
  StartAutoPublish()
  ScheduleSelfTest()
  print(L("%s %s loaded. Click the minimap button or type /nrage to open the window."):format(PREFIX, ns.GetVersion()))
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
