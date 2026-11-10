local addonName, ns = ...

local Constants = ns.Constants
local L = ns.L
local PREFIX = "|cffff0019Nrage Assistant|r"

local NOTICES = ns.Locale.Table(function()
  return {
    not_in_guild = L("disabled: you are not in a guild."),
    wrong_guild = L("disabled: this addon is only for the Nrage guild."),
    wrong_faction = L("disabled: this addon is only for the Alliance."),
    wrong_ruleset = L("disabled: this addon is only for the PvP ruleset."),
    pending = L("disabled: the client did not give the guild data. Type /reload to try again."),
    incompatible_data = L(
      "disabled: saved data comes from a newer version of the addon. Update the addon; your data was left untouched."
    ),
    migration_failed = L(
      "disabled: the saved data could not be updated to this version. Please report it before changing anything."
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

-- A release build has its version written into the .toc when it is packaged (tools/package.sh); the token that is
-- still there means the addon runs from a source checkout. The debug probes only work in such a build.
function ns.IsDevBuild()
  local version = C_AddOns.GetAddOnMetadata(addonName, "Version")
  return not version or version == "@project-version@"
end

local function InitDatabase()
  -- A migration that raises must not leave the addon without a database or without a reason: the saved data stays
  -- as it was and the addon turns itself off with a notice.
  local loaded, db, err = pcall(ns.Store.Load, NrageAssistantDB)
  if not loaded then
    db, err = nil, "migration_failed"
  end
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

local selfTestScheduled = false

local function ScheduleSelfTest()
  if selfTestScheduled then
    return
  end
  selfTestScheduled = true
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

-- The events the PvP missions listen to (docs/PVP_MISSIONS_PLAN.md, 2.2 and 2.3), each registered on its own so a
-- client that refuses one keeps the others. The first three fill the unit cache (the unit is the event argument for
-- a nameplate, otherwise the one named here); none of them is measured on Forever yet (M3 to M5).
local PVP_MISSION_UNITS = { PLAYER_TARGET_CHANGED = "target", UPDATE_MOUSEOVER_UNIT = "mouseover" }
local PVP_MISSION_NAMEPLATE_EVENT = "NAME_PLATE_UNIT_ADDED"
local PVP_MISSION_WIN_EVENT = "UPDATE_BATTLEFIELD_STATUS"
local PVP_MISSION_WORLD_EVENT = "PLAYER_ENTERING_WORLD"
-- The score update brings the winner of a battleground too, and the end of a fight is a good moment to ask for it.
local PVP_MISSION_SCORE_EVENT = "UPDATE_BATTLEFIELD_SCORE"
local PVP_MISSION_REGEN_EVENT = "PLAYER_REGEN_ENABLED"

-- Runs a handler of the PvP missions. One that raises never reaches the client: it is listed with the startup errors
-- (ns.ReportStartupError, for /nrage debug) and costs nothing else.
local function GuardedMissionCall(name, handler, ...)
  local ok, err = pcall(handler, ...)
  if not ok and ns.ReportStartupError then
    ns.ReportStartupError(name, err)
  end
  return ok
end

-- Builds ns.pvpMissions (the kill log, progress and claims of the PvP missions) and its events. Returns the service,
-- or nil when it cannot start. A failing handler never raises into the client.
local function StartPvPMissions(feed)
  if not (ns.pvpSeason and ns.PvPMissionService and ns.PvPUnitCache) then
    return nil
  end
  local missions = ns.PvPMissionService.New({
    season = ns.pvpSeason,
    log = function()
      return ns.character and ns.character.pvpLog
    end,
    claims = function()
      return ns.character and ns.character.pvpClaims
    end,
    cache = ns.PvPUnitCache.New({ now = ns.Platform.Now }),
    now = ns.Platform.ServerTime,
    platform = ns.Platform,
    killsAvailable = function()
      return feed:Available()
    end,
    schedule = C_Timer.After,
    random = math.random,
    isActive = function()
      return ns.active == true
    end,
    isGuildKos = function(name)
      local guildKos = ns.db and ns.db.global and ns.db.global.guildKos
      return guildKos ~= nil and ns.GuildKosService.Find(guildKos, name) ~= nil
    end,
    -- The guild members in the party or raid of the player, the player excluded (for the missions that ask for a
    -- group). Names the client gives without the realm are matched with the guild roster.
    guildInGroup = function()
      local roster = ns.guildRoster
      if not (roster and roster:IsReady() and ns.Platform.IsInGroup()) then
        return 0
      end
      local own = ns.Platform.GetPlayerName()
      local count = 0
      for _, name in ipairs(ns.Platform.GetGroupMemberNames()) do
        if name ~= own and roster:Canonical(name) then
          count = count + 1
        end
      end
      return count
    end,
    onAutoClaim = function(mission)
      print(("%s %s"):format(PREFIX, L("Mission claimed automatically: %s"):format(mission.title)))
    end,
    onChange = function()
      if ns.UI and ns.UI.PvPChanged then
        ns.UI.PvPChanged()
      end
      if ns.pvpProgress then
        ns.pvpProgress:Changed()
      end
    end,
  })
  ns.pvpMissions = missions

  -- The own progress goes to the approvers by itself (numbers only), and a gm or cogm coming online gets the claims
  -- that nobody has decided yet.
  if ns.PvPProgressPublisher and ns.comm then
    ns.pvpProgress = ns.PvPProgressPublisher.New({
      missions = missions,
      season = ns.pvpSeason,
      send = function(payload)
        return ns.comm:SendPvPProgress(payload)
      end,
      now = ns.Platform.ServerTime,
      schedule = C_Timer.After,
      random = math.random,
      isActive = function()
        return ns.active == true
      end,
    })
    ns.pvpProgress:SendAtLogin()
    ns.comm.onApproverHello = function()
      GuardedMissionCall("pvpMissions.approverSeen", missions.OnApproverSeen, missions)
    end
  end

  local frame = CreateFrame("Frame")
  for event in pairs(PVP_MISSION_UNITS) do
    missions.unitSource = ns.Platform.TryRegisterEvent(frame, event) or missions.unitSource
  end
  missions.unitSource = ns.Platform.TryRegisterEvent(frame, PVP_MISSION_NAMEPLATE_EVENT) or missions.unitSource
  missions.winSource = ns.Platform.TryRegisterEvent(frame, PVP_MISSION_WIN_EVENT)
  ns.Platform.TryRegisterEvent(frame, PVP_MISSION_WORLD_EVENT)
  ns.Platform.TryRegisterEvent(frame, PVP_MISSION_SCORE_EVENT)
  ns.Platform.TryRegisterEvent(frame, PVP_MISSION_REGEN_EVENT)
  -- For PLAYER_ENTERING_WORLD the two arguments are isInitialLogin and isReloadingUi; for the unit events, the unit.
  frame:SetScript("OnEvent", function(_, event, unit, isReloadingUi)
    if not ns.active then
      return
    end
    if event == PVP_MISSION_WIN_EVENT then
      GuardedMissionCall("pvpMissions.battlegroundStatus", missions.OnBattlegroundStatus, missions)
    elseif event == PVP_MISSION_SCORE_EVENT then
      GuardedMissionCall("pvpMissions.battlegroundScore", missions.OnBattlegroundScore, missions)
    elseif event == PVP_MISSION_REGEN_EVENT then
      GuardedMissionCall("pvpMissions.combatEnded", missions.OnCombatEnded, missions)
    elseif event == PVP_MISSION_WORLD_EVENT then
      GuardedMissionCall("pvpMissions.worldEntered", missions.OnWorldEntered, missions, unit, isReloadingUi)
    else
      pcall(missions.OnUnit, missions, PVP_MISSION_UNITS[event] or unit)
    end
  end)
  missions:StartAnnouncing()
  return missions
end

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
    -- The own honour kills also go to the mission log.
    onHonorKill = function(entry)
      if ns.pvpMissions then
        ns.pvpMissions:OnHonorKill(entry)
      end
    end,
  })
  feed.honorNames = ns.Platform.HasHonorVictimSource()
  ns.pvpFeed = feed
  StartPvPMissions(feed)

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
          -- The same honour kill is a win against that enemy in Intel.
          if ns.intel and ns.intelDetector and ns.intelDetector:Allowed() then
            pcall(ns.intel.OnWin, ns.intel, victim)
          end
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
      -- The Blacklist tab marks the listed players that are in the group: it follows the group.
      ns.UI.BlacklistChanged()
    end
  end)
  -- A group that already exists when the addon starts.
  pcall(watcher.Check, watcher)
end

-- The events the layer tracker listens to: the units whose creature GUID names the layer, and the changes that end
-- or move it. Each is registered on its own, so a client that does not know one keeps the others.
local LAYER_UNIT_EVENTS = { PLAYER_TARGET_CHANGED = "target", UPDATE_MOUSEOVER_UNIT = "mouseover" }
local LAYER_NAMEPLATE_EVENT = "NAME_PLATE_UNIT_ADDED"
local LAYER_WORLD_EVENTS = { "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "GROUP_ROSTER_UPDATE" }

local layerStarted = false

-- The "Share my layer" switch: on publishes the layer at once, off tells the guild to forget it.
function ns.SetLayerShare(share)
  ns.LayerModel.Settings(ns.db).share = share == true
  if ns.layerPublisher then
    if share then
      ns.layerPublisher:Changed()
    else
      ns.layerPublisher:Forget()
    end
  end
  ns.UI.LayersChanged()
end

-- A swap and a Groups post or application exclude each other (docs/LFG_PLAN.md 2.4): the swap rules refuse with "lfg"
-- while the Groups service is busy. The service starts after this and is looked up when asked.
local function ExcludeLfg(rules)
  local function guarded(rule)
    return function(...)
      local ok, reason = rule(...)
      if ok and ns.lfgService and ns.lfgService:IsBusy() then
        return false, "lfg"
      end
      return ok, reason
    end
  end
  return { requester = guarded(rules.requester), helper = guarded(rules.helper) }
end

-- Own frame. Runs once: access can be lost and regained. Everything the client has to say is guarded, so a wrong
-- assumption about layers (docs/API_NOTES.md) leaves the feature quietly unavailable instead of raising.
local function StartLayer()
  if layerStarted then
    return
  end
  layerStarted = true
  local platform = ns.Platform
  local function isLocked()
    return not ns.lockdown:CanSend()
  end

  local swap, publisher
  local tracker = ns.LayerTracker.New({
    now = platform.Now,
    isInInstance = platform.IsInInstance,
    onChange = function(current)
      publisher:Changed()
      swap:OnLayerConfirmed(current)
      ns.UI.LayersChanged()
    end,
  })
  local function ownLayer()
    return tracker:Current()
  end
  local directory = ns.LayerDirectory.New({
    now = platform.Now,
    isMember = function(name)
      local roster = ns.guildRoster
      return roster == nil or not roster:IsReady() or roster:Lookup(name) ~= nil
    end,
  })
  publisher = ns.LayerPublisher.New({
    now = platform.Now,
    schedule = C_Timer.After,
    send = function(payload)
      return ns.comm:SendLayerState(payload)
    end,
    current = ownLayer,
    enabled = function()
      return ns.LayerModel.Settings(ns.db).share
    end,
  })
  swap = ns.LayerSwap.New({
    now = platform.Now,
    schedule = C_Timer.After,
    send = function(payload)
      return ns.comm:SendLayerSwap(payload)
    end,
    isLocked = isLocked,
    ownName = platform.GetIdentityKey,
    newId = function()
      return ns.comm:NextId()
    end,
    ownLayer = ownLayer,
    eligibility = ExcludeLfg(ns.LayerSwap.Eligibility(platform, ownLayer, isLocked)),
    invite = function(name)
      local ok, reason = platform.InviteByName(name)
      ns.LayerProbe.Note(
        "invite",
        ("InviteByName('%s') -> %s %s"):format(tostring(name), tostring(ok), tostring(reason))
      )
      return ok, reason
    end,
    leave = function()
      local ok, reason = platform.LeaveGroup()
      ns.LayerProbe.Note("leave", ("LeaveGroup() -> %s %s"):format(tostring(ok), tostring(reason)))
      return ok, reason
    end,
    onJoined = function(t)
      tracker:ResetSince(t)
    end,
    onChange = function()
      ns.UI.LayersChanged()
      ns.LayerPopup.Refresh()
    end,
  })
  ns.layerTracker, ns.layerDirectory, ns.layerSwap, ns.layerPublisher = tracker, directory, swap, publisher
  ns.comm.layerDirectory, ns.comm.layerSwap = directory, swap
  ns.comm.onLayerChange = ns.UI.LayersChanged
  ns.LayerPopup.Start()

  local layerFrame = CreateFrame("Frame")
  for event in pairs(LAYER_UNIT_EVENTS) do
    platform.TryRegisterEvent(layerFrame, event)
  end
  platform.TryRegisterEvent(layerFrame, LAYER_NAMEPLATE_EVENT)
  for _, event in ipairs(LAYER_WORLD_EVENTS) do
    platform.TryRegisterEvent(layerFrame, event)
  end
  local wasGrouped = platform.IsInGroup()
  layerFrame:SetScript("OnEvent", function(_, event, arg1)
    if not ns.active then
      return
    end
    local unit = LAYER_UNIT_EVENTS[event] or (event == LAYER_NAMEPLATE_EVENT and arg1) or nil
    if unit then
      local guid = platform.GetUnitGUID(unit)
      if guid then
        tracker:Observe(guid)
      end
      return
    end
    tracker:Expire()
    if event == "GROUP_ROSTER_UPDATE" then
      local grouped = platform.IsInGroup()
      if grouped and not wasGrouped then
        swap:OnGroupJoined()
      end
      wasGrouped = grouped
    end
    ns.UI.LayersChanged()
  end)

  -- The layer is sent again now and then, so a member who logs in later learns it.
  C_Timer.NewTicker(Constants.LAYER_REPUBLISH_SECONDS, function()
    if ns.active then
      publisher:Tick()
    end
  end)
end

local lfgStarted = false

-- The own level when the client gives a plain whole number; a secret value (which raises when compared) or anything
-- else is unknown.
local function OwnLevel()
  local ok, level = pcall(ns.Platform.GetLevel)
  if not ok or type(level) ~= "number" then
    return nil
  end
  local readable, valid = pcall(function()
    return level >= 1 and level % 1 == 0
  end)
  return readable and valid and level or nil
end

-- Groups (docs/LFG_PLAN.md). Own frame. Runs once: access can be lost and regained. The board and the service live in
-- memory; the timers and the events do nothing while the addon is inactive.
local function StartLfg()
  if lfgStarted then
    return
  end
  lfgStarted = true
  local platform = ns.Platform
  local function isLocked()
    return not ns.lockdown:CanSend()
  end
  local function swapActive()
    return ns.layerSwap ~= nil and ns.layerSwap:IsActive()
  end

  local board = ns.LfgBoard.New({
    now = platform.Now,
    isMember = function(name)
      local roster = ns.guildRoster
      return roster == nil or not roster:IsReady() or roster:Lookup(name) ~= nil
    end,
  })
  local service = ns.LfgService.New({
    now = platform.Now,
    schedule = C_Timer.After,
    send = {
      post = function(payload)
        return ns.comm:SendLfgPost(payload)
      end,
      apply = function(payload)
        return ns.comm:SendLfgApply(payload)
      end,
    },
    isLocked = isLocked,
    ownName = platform.GetIdentityKey,
    newId = function()
      return ns.comm:NextId()
    end,
    ownLevel = OwnLevel,
    eligibility = ns.LfgService.Eligibility(platform, isLocked, swapActive),
    invite = function(name)
      local ok, reason = platform.InviteByName(name)
      ns.LayerProbe.Note(
        "invite",
        ("InviteByName('%s') -> %s %s"):format(tostring(name), tostring(ok), tostring(reason))
      )
      return ok, reason
    end,
    isGroupMember = platform.IsGroupMember,
    groupSize = platform.GetGroupSize,
    isLeader = platform.IsGroupLeader,
    isRaid = platform.IsInRaid,
    partyClasses = platform.GetPartyClasses,
    ownRole = function()
      local fields = ns.character and ns.character.profile and ns.character.profile.fields or {}
      return fields.role and ns.LfgModel.WireRole(fields.role.value) or nil
    end,
    board = board,
    onChange = function()
      ns.UI.LfgChanged()
      ns.LfgPopup.Refresh()
    end,
  })
  ns.lfgBoard, ns.lfgService = board, service
  ns.comm.lfgService = service
  -- A received post or step changes the board (the count of the sidebar) and may bring an applicant to the popup.
  ns.comm.onLfgChange = function()
    ns.UI.LfgChanged()
    ns.LfgPopup.Refresh()
  end
  ns.LfgPopup.Start()

  local lfgFrame = CreateFrame("Frame")
  platform.TryRegisterEvent(lfgFrame, "GROUP_ROSTER_UPDATE")
  platform.TryRegisterEvent(lfgFrame, "PLAYER_ENTERING_WORLD")
  lfgFrame:SetScript("OnEvent", function()
    if ns.active then
      service:OnGroupChanged()
    end
  end)

  -- An open post is sent again now and then, so a member who logs in later sees it.
  C_Timer.NewTicker(Constants.LFG_REPUBLISH_SECONDS, function()
    if ns.active then
      service:Republish()
    end
  end)
  C_Timer.NewTicker(Constants.LFG_SWEEP_SECONDS, function()
    if ns.active then
      service:Sweep()
    end
  end)
end

local positionStarted = false

-- The "Share my position" switch: on publishes the position at once, off tells the guild to forget it.
function ns.SetPositionShare(share)
  ns.PositionModel.Settings(ns.db).share = share == true
  if ns.positionPublisher then
    if share then
      ns.positionPublisher:Tick()
    else
      ns.positionPublisher:Forget()
    end
  end
end

-- The "Show guildmates on the minimap / world map" switches. `which` is "minimap" or "worldmap".
function ns.SetPositionDisplay(which, on)
  if which ~= "minimap" and which ~= "worldmap" then
    return
  end
  ns.PositionModel.Settings(ns.db)[which] = on == true
  if ns.mapPins then
    ns.mapPins:Request()
  end
  -- The Guild button on the world map shows this same setting.
  if ns.WorldMapToggles then
    pcall(ns.WorldMapToggles.Refresh)
  end
end

-- Guild map. Positions travel on their own prefix, outside the NRAGE envelope (docs/PROTOCOL.md): a short strict text
-- sent through ChatThrottleLib at "BULK" priority, so it never delays real traffic. Runs once, like StartLayer.
local function StartPosition()
  if positionStarted then
    return
  end
  positionStarted = true
  local platform = ns.Platform
  platform.RegisterPrefix(Constants.POSITION_PREFIX)

  local mapPins
  local function redraw()
    if mapPins then
      mapPins:Request()
    end
  end
  local directory = ns.PositionDirectory.New({ now = platform.Now, onChange = redraw })
  local function ownPosition()
    local position = platform.PlayerMapPosition()
    if not position then
      return nil
    end
    local x, y = ns.PositionModel.FromZone(position.x, position.y)
    return x and { map = position.map, x = x, y = y } or nil
  end
  local publisher = ns.PositionPublisher.New({
    now = platform.Now,
    current = ownPosition,
    enabled = function()
      return ns.PositionModel.Settings(ns.db).share
    end,
    canSend = function()
      return ns.lockdown:CanSend()
    end,
    send = function(text)
      if not ChatThrottleLib then
        return false
      end
      ChatThrottleLib:SendAddonMessage("BULK", Constants.POSITION_PREFIX, text, "GUILD")
      return true
    end,
  })
  local sync = ns.PositionSync.New({
    platform = platform,
    inbox = ns.Inbox.New({ maxPerWindow = Constants.POSITION_INBOX_MAX_PER_WINDOW }),
    -- Looked up lazily, like the roles of Comm: the guild roster may not be ready yet.
    roleOf = function(sender)
      if not ns.guildRoster then
        return nil
      end
      return ns.PermissionService.RoleOf(ns.guildRoster, sender)
    end,
    directory = directory,
    now = platform.Now,
  })

  local function pins()
    local roster = ns.guildRoster
    if not roster then
      return {}
    end
    local layers = {}
    if ns.layerDirectory then
      for _, entry in ipairs(ns.layerDirectory:Fresh()) do
        layers[entry.name] = entry
      end
    end
    return ns.PositionPins.Build({
      list = directory:List(),
      now = platform.Now,
      lookup = function(name)
        return roster:Lookup(name)
      end,
      profile = function(name)
        return ns.db.global.roster[name]
      end,
      ownLayer = ns.layerTracker and ns.layerTracker:Current() or nil,
      layerOf = function(name)
        return layers[name]
      end,
      isGroupMember = platform.IsGroupMember,
      settings = ns.PositionModel.Settings(ns.db),
    })
  end
  mapPins = ns.MapPins.Start({
    now = platform.Now,
    after = C_Timer.After,
    pins = pins,
    settings = function()
      return ns.PositionModel.Settings(ns.db)
    end,
  })
  ns.positionDirectory, ns.positionPublisher, ns.positionSync, ns.mapPins = directory, publisher, sync, mapPins

  -- A layer that arrives changes which pins are faded: the pins follow it, after what the Layers tab already does.
  if ns.comm then
    local onLayerChange = ns.comm.onLayerChange
    ns.comm.onLayerChange = function(...)
      if onLayerChange then
        onLayerChange(...)
      end
      redraw()
    end
  end

  local positionFrame = CreateFrame("Frame")
  platform.TryRegisterEvent(positionFrame, "CHAT_MSG_ADDON")
  platform.TryRegisterEvent(positionFrame, "GROUP_ROSTER_UPDATE")
  positionFrame:SetScript("OnEvent", function(_, event, prefix, text, channel, sender)
    if not ns.active then
      return
    end
    if event == "GROUP_ROSTER_UPDATE" then
      redraw()
      return
    end
    -- During an encounter the arguments can be secret values: any error means "drop it silently".
    pcall(function()
      if prefix == Constants.POSITION_PREFIX then
        sync:Handle(text, channel, sender)
      end
    end)
  end)

  -- Nothing is sent on PLAYER_LEAVING_WORLD: the TTL clears the pins of the others.
  C_Timer.NewTicker(Constants.POSITION_TICK_SECONDS, function()
    if ns.active then
      pcall(publisher.Tick, publisher)
      directory:Prune()
    end
  end)
end

-- Intel (docs/PVP_INTEL_PLAN.md). The enemy players in range are read from the nameplates, the target, the focus and
-- the mouseover. Each event is registered on its own, so a client that refuses one keeps the others (the result of
-- each is kept for /nrage intel debug), and a ticker reads everything again every INTEL_RESCAN_SECONDS. The mission
-- unit cache keeps its own listeners.
local INTEL_UNIT_EVENTS = {
  { event = "NAME_PLATE_UNIT_ADDED" },
  { event = "PLAYER_TARGET_CHANGED", unit = "target" },
  { event = "PLAYER_FOCUS_CHANGED", unit = "focus" },
  { event = "UPDATE_MOUSEOVER_UNIT", unit = "mouseover" },
}

local INTEL_OTHER_EVENTS = { "UNIT_SPELLCAST_SUCCEEDED", "PLAYER_DEAD" }

local intelStarted = false

-- Runs once, like StartPosition: access can be lost and regained.
local function StartIntel()
  if intelStarted then
    return
  end
  intelStarted = true
  local platform = ns.Platform
  local service = ns.IntelService.New({
    intel = ns.db.global.intel,
    guildKos = ns.db.global.guildKos,
    settings = function()
      return ns.Settings.Intel(ns.db)
    end,
    now = platform.Now,
    wall = platform.ServerTime,
  })
  service:Prune(platform.ServerTime())

  local function allowed()
    return ns.IntelModel.DetectionAllowed({
      instance = platform.GetInstanceKind(),
      pvpType = platform.GetZonePvPType(),
      mapId = platform.GetPlayerMapId(),
    }, ns.Settings.Intel(ns.db))
  end
  -- The position of the reporter: the client gives no enemy coordinates.
  local function where()
    local position = platform.PlayerMapPosition()
    if position then
      local x, y = ns.PositionModel.FromZone(position.x, position.y)
      return { map = position.map, x = x, y = y }
    end
    return { map = platform.GetPlayerMapId() }
  end
  local detector = ns.IntelDetector.New({
    reader = platform,
    service = service,
    now = platform.Now,
    allowed = allowed,
    where = where,
  })
  ns.intel, ns.intelDetector = service, detector

  -- Sightings: shared with the guild (or the battleground group) on their own prefix, and the ones received kept in
  -- memory (docs/PROTOCOL.md). The receiving side is registered in Comm.Start, which looks ns.intelSync up.
  platform.RegisterPrefix(Constants.INTEL_PREFIX)
  local directory = ns.IntelDirectory.New({
    now = platform.Now,
    onChange = function()
      if ns.UI and ns.UI.IntelChanged then
        ns.UI.IntelChanged()
      end
    end,
  })
  local publisher = ns.IntelPublisher.New({
    now = platform.Now,
    settings = function()
      return ns.Settings.Intel(ns.db)
    end,
    canSend = function()
      return ns.lockdown:CanSend()
    end,
    instanceKind = platform.GetInstanceKind,
    groupChannel = platform.GroupDistribution,
    isIgnored = function(name)
      return service:IsIgnored(name)
    end,
    send = function(text, channel)
      if not ChatThrottleLib then
        return false
      end
      ChatThrottleLib:SendAddonMessage("BULK", Constants.INTEL_PREFIX, text, channel)
      return true
    end,
  })
  ns.intelDirectory, ns.intelPublisher = directory, publisher
  ns.intelSync = ns.IntelSync.New({
    platform = platform,
    inbox = ns.Inbox.New({ maxPerWindow = Constants.INTEL_INBOX_MAX_PER_WINDOW }),
    -- Looked up lazily, like the roles of Comm: the guild roster may not be ready yet.
    roleOf = function(sender)
      if not ns.guildRoster then
        return nil
      end
      return ns.PermissionService.RoleOf(ns.guildRoster, sender)
    end,
    directory = directory,
    now = platform.Now,
  })

  -- Alerts and announcements. The warning goes to the movable window once ns.IntelWindow exists (the interface),
  -- else to the error area at the top of the screen.
  local function settings()
    return ns.Settings.Intel(ns.db)
  end
  local alerts = ns.IntelAlerts.New({
    settings = settings,
    service = service,
    now = platform.Now,
    mapId = platform.GetPlayerMapId,
    window = function(text, alert)
      if ns.IntelWindow and ns.IntelWindow.Warn then
        return ns.IntelWindow.Warn(text, alert.kind, alert.class) ~= false
      end
      return false
    end,
    errorText = function(text)
      return platform.ShowErrorText(text)
    end,
    playSound = function(kind)
      return platform.PlayIntelSound(kind)
    end,
    say = function(text)
      print(("%s %s"):format(PREFIX, text))
    end,
    send = function(channel, text)
      return platform.SendChatLine(channel, text)
    end,
    groupChannel = platform.GroupDistribution,
  })
  ns.intelAlerts = alerts
  directory.deps.onSighting = function(entry)
    alerts:OnReport(entry)
  end
  detector.deps.onContact = function(result, details, spot)
    if not result.ignored then
      pcall(publisher.Offer, publisher, details, spot, result.kos ~= nil)
    end
    alerts:OnContact(result, details)
  end

  ns.intelCommands = ns.IntelCommands.New({
    service = service,
    detector = detector,
    publisher = publisher,
    sync = ns.intelSync,
    alerts = alerts,
    directory = directory,
    platform = platform,
    settings = settings,
    guildKos = ns.db.global.guildKos,
    tombstones = ns.db.global.sync.tombstones,
    comm = function()
      return ns.comm
    end,
    onChange = function()
      if ns.UI and ns.UI.IntelChanged then
        ns.UI.IntelChanged()
      end
    end,
    ui = function()
      return ns.UI
    end,
    events = function()
      return ns.intelEvents
    end,
    zone = function()
      local context = {
        instance = platform.GetInstanceKind(),
        pvpType = platform.GetZonePvPType(),
        mapId = platform.GetPlayerMapId(),
      }
      return context, ns.IntelModel.DetectionAllowed(context, settings())
    end,
    season = function()
      return ns.pvpSeason and ns.pvpSeason:ActiveSeason() or nil
    end,
    zoneName = platform.GetMapName,
    globals = function()
      return _G
    end,
    toggleMinimap = function()
      local hidden = not ns.MinimapButton.Settings(ns.db).hide
      ns.MinimapButton.SetHidden(ns.db, hidden)
      ns.MinimapButton.Refresh()
      return hidden
    end,
  })

  ns.intelEvents = {}
  local intelFrame = CreateFrame("Frame")
  for _, spec in ipairs(INTEL_UNIT_EVENTS) do
    ns.intelEvents[spec.event] = platform.TryRegisterEvent(intelFrame, spec.event)
  end
  for _, event in ipairs(INTEL_OTHER_EVENTS) do
    ns.intelEvents[event] = platform.TryRegisterEvent(intelFrame, event)
  end
  intelFrame:SetScript("OnEvent", function(_, event, ...)
    if not ns.active then
      return
    end
    -- During an encounter the arguments can be secret values: any error means "drop it silently".
    pcall(function(...)
      if event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, spell = platform.ReadSpellEvent(...)
        if unit then
          detector:OnCast(unit, spell)
        end
        return
      elseif event == "PLAYER_DEAD" then
        detector:OnDeath(platform.GetDeathKiller())
        return
      end
      for _, spec in ipairs(INTEL_UNIT_EVENTS) do
        if spec.event == event then
          detector:OnUnit(spec.unit or (...))
          return
        end
      end
    end, ...)
  end)

  -- Every second, after the read: the window, the pins and the sub-tab follow (UI.IntelChanged waits its turn).
  C_Timer.NewTicker(Constants.INTEL_RESCAN_SECONDS, function()
    if ns.active then
      pcall(detector.Rescan, detector)
      if ns.UI and ns.UI.IntelChanged then
        pcall(ns.UI.IntelChanged, true)
      end
    end
  end)
  C_Timer.NewTicker(Constants.INTEL_SHARE_TICK_SECONDS, function()
    if ns.active then
      pcall(publisher.Tick, publisher)
      directory:Prune()
    end
  end)

  -- The compact window starts on its own (pcall), like each part of the interface: one that fails costs only itself.
  pcall(ns.IntelWindow.Start)

  -- The enemy pins on the maps: the ones seen here and the sightings of the guild, by the map mode of the player.
  local function enemyPins()
    local layers = {}
    if ns.layerDirectory then
      for _, entry in ipairs(ns.layerDirectory:Fresh()) do
        layers[entry.name] = entry
      end
    end
    return ns.IntelPins.Build({
      own = service:Nearby(platform.Now()),
      remote = directory:List(),
      now = platform.Now,
      mapMode = settings().mapMode,
      ownMap = platform.GetPlayerMapId(),
      continentOf = platform.GetContinentMapId,
      ownLayer = ns.layerTracker and ns.layerTracker:Current() or nil,
      layerOf = function(reporter)
        return layers[reporter]
      end,
      kosOf = function(key)
        return service:IsKos(key)
      end,
      isIgnored = function(key)
        return service:IsIgnored(key)
      end,
    })
  end
  ns.intelMapPins = ns.MapPins.StartEnemies({
    now = platform.Now,
    after = C_Timer.After,
    pins = enemyPins,
    settings = function()
      -- The minimap pins are always on (mapMode still filters them); the world map ones follow the map button.
      return { minimap = true, worldmap = settings().worldmapPins, follow = settings().mapFollow }
    end,
    follow = platform.ShowWorldMap,
  })

  -- The button by the target frame, and the level and class of the enemies on the tooltip of the minimap.
  pcall(ns.IntelTargetButton.Start)
  pcall(ns.WorldMapToggles.Start)
  pcall(ns.MinimapButton.HookTooltip, {
    service = service,
    settings = settings,
    -- The same rule as the detector: nothing is recorded where detection is off.
    feed = function(details)
      if detector:Allowed() then
        service:OnSeen(details, where())
      end
    end,
  })

  -- Enemy nameplates are what Intel reads: the player is told once per session when they are off.
  C_Timer.After(Constants.INTEL_REMINDER_DELAY_SECONDS, function()
    if not ns.active then
      return
    end
    local notice = ns.ViewModel.IntelNameplateNotice({
      enabled = settings().enabled,
      nameplates = platform.EnemyNameplatesEnabled(),
      inCombat = platform.IsInCombat(),
    })
    if notice then
      print(("%s %s %s"):format(PREFIX, notice.text, L("The Intel settings in the PvP tab have a button for it.")))
    end
  end)
end

-- Who is nearby now: the enemies read here plus the sightings of the guild on the same map.
function ns.IntelNearby()
  if not ns.intel then
    return {}
  end
  local map = ns.Platform.GetPlayerMapId()
  local remote = map and ns.intelDirectory and ns.intelDirectory:List(map) or {}
  return ns.intel:Nearby(ns.Platform.Now(), remote)
end

-- A guild Kill On Sight entry arrived: the Intel views are drawn again.
function ns.GuildKosChanged()
  if ns.UI and ns.UI.IntelChanged then
    ns.UI.IntelChanged()
  end
end

-- The events that change what is shared in the profile: gear, level and professions.
local PROFILE_EVENTS = {
  "PLAYER_EQUIPMENT_CHANGED",
  "PLAYER_LEVEL_UP",
  "SKILL_LINES_CHANGED",
  "PLAYER_AVG_ITEM_LEVEL_UPDATE",
}

-- The profile is shared with the guild without a switch (issue #36, plan 0.1): once after login, when the roster has
-- had time to load; a few seconds after any event that changes it; and every PUBLISH_CHECK_SECONDS as a safety net.
-- A change made inside the publish cooldown is published when it ends (AutoPublisher), and nothing is read or sent
-- during an encounter lockdown.
local autoPublishStarted = false

local function StartAutoPublish()
  if autoPublishStarted then
    return
  end
  autoPublishStarted = true
  local publisher = ns.AutoPublisher.New({
    refresh = function()
      if ns.active and ns.character then
        ns.ProfileService.Refresh(ns.Platform, ns.character.profile)
      end
    end,
    publish = function()
      if ns.active and ns.character and ns.comm then
        return ns.PublishService.PublishIfChanged(ns.comm, ns.character, ns.Platform)
      end
      return false, "inactive"
    end,
    cooldownLeft = function()
      return ns.character and ns.PublishService.CooldownLeft(ns.character, ns.Platform) or 0
    end,
    schedule = C_Timer.After,
    isLocked = ns.Platform.IsChatMessagingLockedDown,
    debounce = Constants.PUBLISH_EVENT_DEBOUNCE_SECONDS,
  })
  ns.autoPublisher = publisher

  local profileFrame = CreateFrame("Frame")
  for _, event in ipairs(PROFILE_EVENTS) do
    ns.Platform.TryRegisterEvent(profileFrame, event)
  end
  profileFrame:SetScript("OnEvent", function()
    if ns.active then
      publisher:Changed()
    end
  end)

  C_Timer.After(
    math.random(Constants.SYNC_LOGIN_REQUEST_DELAY_MIN, Constants.SYNC_LOGIN_REQUEST_DELAY_MAX) + 1,
    function()
      publisher:Run()
    end
  )
  C_Timer.NewTicker(Constants.PUBLISH_CHECK_SECONDS, function()
    publisher:Run()
  end)
end

-- The items of the last corpse looted, for the "Last boss loot" strip of the Loot tab. Kept in memory only, and only
-- when
-- the client lets the addon read the loot window (Platform.LootWindowAvailable): otherwise the strip is not shown.
local bossLootStarted = false

local function StartBossLoot()
  if bossLootStarted or not ns.Platform.LootWindowAvailable() then
    return
  end
  local lootFrame = CreateFrame("Frame")
  if not ns.Platform.TryRegisterEvent(lootFrame, "LOOT_OPENED") then
    return
  end
  bossLootStarted = true
  lootFrame:SetScript("OnEvent", function()
    if ns.active then
      local items = ns.Platform.GetLootWindowItems()
      if items and #items > 0 then
        ns.bossLoot = items
      end
    end
  end)
end

-- Recipes (plan 3.10): the recipes a profession window shows are read when it opens or changes, kept, and published
-- when
-- they differ from the last scan. Only when the client has the profession API (Platform.RecipeScanAvailable); the
-- client
-- fires its events several times while a list loads, so a burst is one scan a moment after the last one.
local RECIPE_EVENTS = { "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE" }
local recipesStarted = false

local function SkillOf(name)
  for _, profession in ipairs(ns.character.profile.professions or {}) do
    if profession.name == name then
      return profession.skill
    end
  end
  return nil
end

local function ScanRecipes()
  if not (ns.active and ns.character) then
    return
  end
  local scan = ns.Platform.ScanKnownRecipes()
  if not scan then
    return
  end
  local record, changed =
    ns.RecipeService.StoreScan(ns.character.recipes, scan, ns.Platform.ServerTime(), SkillOf(scan.professionName))
  if record and changed and ns.comm then
    ns.comm:SendRecipes(scan.professionId, record)
  end
  if record then
    ns.recipesVersion = (ns.recipesVersion or 0) + 1
    ns.UI.RecipesChanged()
  end
end

local function StartRecipes()
  if recipesStarted or not ns.Platform.RecipeScanAvailable() then
    return
  end
  recipesStarted = true
  local throttle = ns.Throttle.New({
    run = ScanRecipes,
    now = ns.Platform.Now,
    schedule = C_Timer.After,
    interval = Constants.RECIPE_SCAN_DELAY_SECONDS,
  })
  local recipeFrame = CreateFrame("Frame")
  for _, event in ipairs(RECIPE_EVENTS) do
    ns.Platform.TryRegisterEvent(recipeFrame, event)
  end
  recipeFrame:SetScript("OnEvent", function()
    if ns.active then
      throttle:Call()
    end
  end)
  -- The saved lists go out once after login, for the members who were not there when they changed.
  C_Timer.After(math.random(Constants.RECIPE_LOGIN_SEND_DELAY_MIN, Constants.RECIPE_LOGIN_SEND_DELAY_MAX), function()
    if ns.active and ns.comm then
      for professionId, record in pairs(ns.character.recipes) do
        if record.ids then
          ns.comm:SendRecipes(professionId, record)
        end
      end
    end
  end)
end

-- A PvP season record changed here or arrived from the guild: the interface follows (the PvP tab, until it has its own
-- sub-tabs, redraws like for any other PvP change).
function ns.PvPSeasonChanged(messageType)
  -- A season record changed (not a summary from another member): the own progress may have changed with it.
  if messageType ~= "PVP_PROGRESS" and ns.pvpProgress then
    ns.pvpProgress:Changed()
  end
  if ns.UI and ns.UI.PvPSeasonChanged then
    ns.UI.PvPSeasonChanged(messageType)
  elseif ns.UI and ns.UI.PvPChanged then
    ns.UI.PvPChanged()
  end
end

-- A season closed: the claims this character kept for it are dropped; only the final standing stays. The PvP log is
-- not tied to a season.
function ns.PvPSeasonClosed(seasonId)
  ns.PvPSeasonService.ClearClaims(ns.character and ns.character.pvpClaims, seasonId)
end

-- The PvP seasons (docs/PVP_MISSIONS_PLAN.md): the service the interface and the interim commands use. Runs once.
local pvpSeasonStarted = false

local function StartPvPSeason()
  if pvpSeasonStarted then
    return
  end
  pvpSeasonStarted = true
  local platform = ns.Platform
  ns.pvpSeason = ns.PvPSeasonService.New({
    ledger = ns.db.global.pvpSeason,
    now = platform.ServerTime,
    newId = function()
      return ns.comm:NextId()
    end,
    ownName = platform.GetIdentityKey,
    ownRole = function()
      return ns.PermissionService.OwnRole(platform)
    end,
    roleOf = function(name)
      return ns.guildRoster and ns.PermissionService.RoleOf(ns.guildRoster, name) or nil
    end,
    rosterReady = function()
      return ns.guildRoster ~= nil and ns.guildRoster:IsReady()
    end,
    canonicalName = function(name)
      return ns.guildRoster and ns.guildRoster:Canonical(name) or nil
    end,
    send = function(messageType, payload, key)
      return ns.comm:Send(messageType, payload, key)
    end,
    onChange = ns.PvPSeasonChanged,
    onSeasonClosed = ns.PvPSeasonClosed,
    fits = function(messageType, payload)
      return ns.comm:Fits(messageType, payload)
    end,
  })
  ns.pvpSeasonCommands = ns.PvPSeasonCommands.New({
    service = ns.pvpSeason,
    formatDate = platform.FormatDate,
    missions = function()
      return ns.pvpMissions
    end,
  })
end

local loadedShown = false
local startupFailureShown = false

-- The popups build their controller on every call: once only, like the other Start functions.
local lootPopupStarted = false
local votingFrameStarted = false

local function StartLootPopup()
  if lootPopupStarted then
    return
  end
  lootPopupStarted = true
  ns.LootPopup.Start()
end

local function StartVotingFrame()
  if votingFrameStarted then
    return
  end
  votingFrameStarted = true
  ns.VotingFrame.Start()
end

-- The guild roster is built once; a later activation only asks the client for fresh data.
local function StartGuildRoster()
  if not ns.guildRoster then
    ns.guildRoster = ns.GuildRoster.New({
      platform = ns.Platform,
      schedule = C_Timer.After,
      now = ns.Platform.Now,
      ownGuid = ns.Platform.GetGUID,
      onOwnName = ns.Platform.SetCanonicalName,
      onReady = function()
        if ns.comm then
          ns.comm:OnGuildRosterReady()
        end
      end,
    })
  end
  ns.guildRoster:Request()
  ns.guildRoster:Rebuild()
end

-- The steps of an activation, in order. Each one runs on its own (pcall), so one that raises costs only its own
-- feature. A `core` step is one the others stand on: the character data and the transport. If it fails, nothing after
-- it runs and the addon stays inactive, so the next guild event tries again; the other steps are safe to repeat
-- because each Start function runs only once. The saved data of this character keeps the key it always had; the
-- shared name is resolved later.
local ACTIVATION_STEPS = {
  {
    name = "character",
    core = true,
    run = function()
      ns.character = ns.Store.GetChar(ns.db, ns.Platform.GetLegacyIdentityKey())
    end,
  },
  {
    name = "profile",
    run = function()
      ns.ProfileService.Refresh(ns.Platform, ns.character.profile)
    end,
  },
  {
    name = "purge",
    run = function()
      ns.EventService.Purge({
        events = ns.db.global.events,
        tombstones = ns.db.global.sync.tombstones,
        now = ns.Platform.ServerTime,
      })
    end,
  },
  {
    name = "comm",
    core = true,
    run = function()
      ns.Comm.Start()
    end,
  },
  {
    name = "minimap",
    run = function()
      ns.MinimapButton.Create()
    end,
  },
  { name = "roster", run = StartGuildRoster },
  { name = "pvpSeason", run = StartPvPSeason },
  { name = "lootPopup", run = StartLootPopup },
  { name = "votingFrame", run = StartVotingFrame },
  { name = "pvp", run = StartPvP },
  { name = "blacklist", run = StartBlacklist },
  { name = "layer", run = StartLayer },
  { name = "position", run = StartPosition },
  { name = "intel", run = StartIntel },
  { name = "lfg", run = StartLfg },
  { name = "bossLoot", run = StartBossLoot },
  { name = "recipes", run = StartRecipes },
  { name = "autoPublish", run = StartAutoPublish },
  { name = "selfTest", run = ScheduleSelfTest },
}

-- The steps that raised in this session ({ step, error }), for /nrage debug and the tests.
ns.startupErrors = {}
local STARTUP_ERRORS_MAX = 20

-- Lists an error of `step` with the startup ones (a handler that runs after the activation, like the PvP missions').
function ns.ReportStartupError(step, err)
  if #ns.startupErrors < STARTUP_ERRORS_MAX then
    ns.startupErrors[#ns.startupErrors + 1] = { step = step, error = tostring(err) }
  end
end

local function ReportStartupFailures(failed)
  if startupFailureShown or #failed == 0 then
    return
  end
  startupFailureShown = true
  print(
    ("%s %s"):format(
      PREFIX,
      L("%s could not start; the rest of the addon works. Type /reload to retry."):format(table.concat(failed, ", "))
    )
  )
end

-- ns.active means the core (character data and transport) is up. A feature that failed to start does not turn it
-- off: it is listed in ns.startupErrors and the rest keeps working.
local function Activate()
  ns.active = true
  local failed = {}
  for _, step in ipairs(ACTIVATION_STEPS) do
    local ok, err = pcall(step.run)
    if not ok then
      -- A core step is tried again on every guild event: the list keeps the first failures only.
      ns.ReportStartupError(step.name, err)
      failed[#failed + 1] = step.name
      if step.core then
        ns.active = false
        break
      end
    end
  end
  ReportStartupFailures(failed)
  if not ns.active then
    return
  end
  if not loadedShown then
    loadedShown = true
    print(
      L("%s %s loaded. Click the minimap button or type /nrage to open the window."):format(PREFIX, ns.GetVersion())
    )
  end
  if ns.PositionModel.TakeShareNotice(ns.db) then
    print(
      ("%s %s"):format(PREFIX, L("your position is now shared with the guild. You can turn it off in the settings."))
    )
  end
  -- The notice waits when Intel did not start, so it never describes a feature that is not running.
  if ns.intel and ns.IntelModel.TakeShareNotice(ns.db) then
    print(
      ("%s %s"):format(
        PREFIX,
        L("the enemy players you meet are now shared with the guild. You can turn it off in the Intel settings.")
      )
    )
  end
end

local noticeShown = false

-- Checked on login and on guild changes; shows at most one notice per session.
local accessMonitor = ns.AccessGuard.NewMonitor({
  evaluate = function()
    local ok, reason = ns.AccessGuard.Evaluate(ns.Platform, Constants)
    if ok and ns.dbError then
      return false, ns.dbError == "migration_failed" and "migration_failed" or "incompatible_data"
    end
    return ok, reason
  end,
  isActive = function()
    return ns.active
  end,
  activate = Activate,
  deactivate = function(reason)
    ns.active = false
    -- The ranks of the guild just left must not answer for anybody in the next one.
    if ns.guildRoster then
      ns.guildRoster:Reset()
    end
    ns.MinimapButton.Refresh()
    if not noticeShown then
      noticeShown = true
      print(("%s %s"):format(PREFIX, NOTICES[reason]))
    end
  end,
  schedule = function(seconds, fn)
    C_Timer.After(seconds, fn)
  end,
  onWait = function()
    ns.Platform.RequestGuildRoster()
  end,
  retrySeconds = Constants.ACCESS_RETRY_SECONDS,
  retryMax = Constants.ACCESS_RETRY_MAX,
})

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
    elseif not ns.active then
      accessMonitor:Check()
    end
  else
    accessMonitor:Check()
  end
end)
