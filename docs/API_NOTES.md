# Client API notes

What has been measured on the WoW: Forever client, what the addon assumes, and what is still to be checked.
The API reference used is [warcraft.wiki.gg](https://warcraft.wiki.gg/wiki/Api) (Mainline branch); only deviations
from it and measured behaviour belong here.

## Measured

| Item | Value | Where it is used |
|---|---|---|
| Interface number (`select(4, GetBuildInfo())`) | 16001 (beta) | TOC |
| Normalized realm name | `ClassicBetaPvP` (beta), `CAMWOWEU4Realm2PvP` (live, EU) | ruleset check: the PvP ruleset is detected as the substring `PvP` |
| Guild club id (`C_Club.GetGuildClubId()`) | read by a Nrage member on live (the value is in `Constants.lua`); it changed from beta to live because the guild was created again; that it is the same across sessions and members is not confirmed yet | access check |
| Faction | `Alliance` | access check |

| Character names | **can have several words** (`Yonemon Gg`, `Black Coffee`) | everywhere a character is named |
| `UnitName("player")` | only the **first word** (`Yonemon` for `Yonemon Gg`) | must not be used to identify a character |
| `GetGuildRosterInfo` names | the full name, **without** a realm suffix (`Macedonio Macedoniez`) | the authority for names in permission checks |

All of the beta values above must be measured again at launch (tracked as an issue).

### How the addon identifies a character

Because `UnitName` is not the roster's name, the addon finds its own full name in the guild roster by GUID (the
seventeenth value of `GetGuildRosterInfo`) and uses that as its identity in everything shared. Until the roster has
loaded it falls back to the `UnitName`-based key, which is also the stable key of the saved data. Names received
from other clients are compared without a `-<this realm>` suffix. `/nrage debug roster` shows the result and
`/nrage debug senders` shows the last senders exactly as the client delivered them.

## Assumed, not measured yet

- Automatic readiness checks read the equipped enchants from `GetInventoryItemLink("player", slot)` (the second
  field of the `item:` link) and the active buffs from `UnitBuff("player", index)` (name first, spell id tenth).
  Both are untested on Forever. A value that is secret or unreadable leaves the slot or buff out (unknown, never
  met). The Profile tab shows what was read, with its source.

- The layer feature (reading the layer from creature GUIDs, group invites and leaves, nameplate units) is built on
  unmeasured assumptions: see "Layers (assumed, not measured yet)" below.
- The libraries (Ace3 parts, LibSerialize, LibDeflate) load on the Forever build.
- The `sender` of `CHAT_MSG_ADDON` is the full name, with or without the realm suffix. If it turns out to be the
  first word only, like `UnitName`, permission lookups by sender will not work. `/nrage debug senders` (after
  another member's message arrives) shows the raw sender and whether the roster finds it.
- Addon whispers between guild members work and their sender name can be used as a whisper target.
- The behaviour of the encounter lockdown: when it starts and ends, and what happens to queued messages. The probe
  (`/nrage debug lockdown start | send | log | clear`) exists; the two-client test has not been run.
- Whether `CHAT_MSG_LOOT` and item links arrive as secret values during an encounter. Loot sessions currently take
  the item from a link typed after the encounter.

## Layers (assumed, not measured yet)

The whole layer feature (`docs/LAYER_SWAP_PLAN.md`) was built on the assumptions below **without measuring them on
Forever** (decided 2026-10-20). Every client call is guarded, so a wrong assumption turns the feature off quietly
(nil or false means unavailable) instead of raising. **All of this must be verified in game before release**, with
two clients: `/nrage debug layer start`, target and mouse over NPCs, group up, then `/nrage debug layer log` and
`/nrage debug layer status`, and copy the result here.

| # | Question | API | Assumption in the code | Result |
|---|---|---|---|---|
| 1 | Does `UnitGUID` return a readable creature GUID for `target`, `mouseover` and `nameplateN`, outside combat? In combat? | `UnitGUID` | yes; a secret or unreadable value is skipped (`LayerModel.Parse`) | not measured yet |
| 2 | Is the fifth field of `Creature-0-<server>-<instance>-<zoneUid>-<npc>-<spawn>` stable for one layer and different between layers of one continent? | GUID | yes: the layer key is `(instanceId, zoneUid)`, and two readings from different spawns confirm it | not measured yet |
| 3 | Does `zoneUid` change after a realm restart? | GUID | yes, hence a 15 minute time to live and no saved layer | not measured yet |
| 4 | After joining a group led by someone on another layer: is the move automatic, how long does it take, is there a cooldown, what blocks it? | game behaviour | automatic after a short delay, not in combat or an instance; the addon waits 120 s for a confirmed layer, never moves anyone itself | not measured yet |
| 5 | Does `C_PartyInfo.InviteUnit` / `InviteUnit` invite the right character for a multi-word name (`Yonemon Gg`) and for the `sender` of `CHAT_MSG_ADDON`? Does it need a hardware event? | invite | the name as the guild roster gives it works; always called from a button click | not measured yet |
| 6 | Are `C_PartyInfo.LeaveParty` / `LeaveParty` available, and do they need a hardware event? | leave | available; always called from a button click | not measured yet |
| 7 | Are `NAME_PLATE_UNIT_ADDED` and `nameplateN` available and readable? | event, unit | yes; registered with `TryRegisterEvent`, so a refusal only drops that source | not measured yet |
| 8 | `InCombatLockdown`, `UnitIsGroupLeader("player")`, `IsInInstance`, `GetNumGroupMembers`, `IsInRaid` behave as on Mainline | group | yes; each is read through `pcall` and a missing one reads as false/unknown | not measured yet |
| 9 | Does the game ever move a player who is a group *leader* to another layer, or can a leader invite someone from another layer without effect? | game behaviour | the helper (leader) stays on their layer and the invited player moves | not measured yet |

The probe logs every GUID read (raw string and parsed fields), the zone and group events, the confirmed layer and the
result of the invite and leave calls made from the swap popup. `/nrage debug layer status` also prints which of
the invite and leave APIs exist on the client. If question 1 or 2 turns out to be false, the layer cannot be read
and the feature should be removed; if question 5 or 6 fails, the popup buttons will say that the client refused.

## Groups (not measured yet)

The Groups feature (`docs/LFG_PLAN.md`) is built for v1.2.0 without measuring the four P0 questions of its plan
(decided 2026-11-06). It calls the same invite and group APIs as the layer swap, each through `Core/Platform.lua`. Check
these in game before relying on Groups: two clients, one with a multi-word name. Invite from the Groups tab, form and
leave a party, and read the results in `/nrage debug layer status` and the probe log (the invite is logged there too).

| # | Question | API | Assumption in the code | Result |
|---|---|---|---|---|
| G1 | Does `InviteByName` invite the right character for a multi-word name? | `InviteByName` | the name as the guild roster gives it; the same as layer question 5 | not measured yet |
| G2 | Does it work with the `sender` of `CHAT_MSG_ADDON` as delivered? Run `/nrage debug senders`, then invite that exact string | `CHAT_MSG_ADDON`, `InviteByName` | the sender is the full name (see the `sender` assumption above) | not measured yet |
| G3 | Does the invite need a hardware event? Groups calls it only from a button click, and a refused call must show in the Groups tab | invite | a click; the same as layer question 5 | not measured yet |
| G4 | Do `IsGroupLeader`, `GetGroupSize`, `IsGroupMember` and `GROUP_ROSTER_UPDATE` behave as assumed when a party is formed and left? | group, event | yes; the same as layer question 8 | not measured yet |

If G1 or G2 fails, Invite does not work for that name. The fallback in the plan, a prefilled whisper through
`Platform.PrefillChat`, is also unmeasured. Nothing in this section is measured yet, and no result should be written
here until it is.

## Guild map (not measured yet)

The guild map (`docs/GUILD_MAP_PLAN.md`) uses the APIs below, none of them measured on Forever. Each is guarded in
`Core/Platform.lua`, so a wrong assumption leaves the feature quietly unavailable (no position is sent, no pin is
drawn). **All of this must be verified in game before release.** Record the result and remove the marker.

| # | Question | API (through `Platform`) | Assumption in the code | Result |
|---|---|---|---|---|
| 1 | `C_Map.GetBestMapForUnit("player")` and `C_Map.GetPlayerMapPosition(map, "player"):GetXY()`: what do they return in the open world, and nil in instances? | `Platform.PlayerMapPosition` | a map id and `x`, `y` in 0..1; nil in an instance (also checked with `IsInInstance`) | not measured yet |
| 2 | Do `UnitInParty(name)` / `UnitInRaid(name)` find a guildmate by the name the guild roster gives (a multi-word name)? | `Platform.IsGroupMember` | yes; a miss only means the pin is also drawn | not measured yet |
| 3 | Does HereBeDragons 2.18 draw minimap pins correctly on Forever (rotation, zoom, indoors) and place world map pins? | `HereBeDragons-Pins-2.0` in `UI/MapPins.lua` | yes; it has a `WoWForever` branch upstream | not measured yet |
| 4 | Does `ChatThrottleLib` "BULK" traffic on `NRAGEPOS` with 20 or more members delay `NRAGE` messages? | `ChatThrottleLib:SendAddonMessage` | no: BULK is the lowest priority | not measured yet |
| 5 | Do `CLASS_ICON_TCOORDS` and the texture `Interface\GLUES\CHARACTERCREATE\UI-CHARACTERCREATE-CLASSES` exist? | `UI/MapPins.lua` | yes; a grey dot is drawn when not | not measured yet |
| 6 | Are the map ids of `C_Map.GetBestMapForUnit` all in 1..9999 (the wire limit, `LAYER_MAP_MAX`)? | wire format | yes; a position on another map is simply not sent | not measured yet |

HereBeDragons was scanned for divisions that could raise `Division by zero` on this client (see the section above):
there is no literal zero and no `1 / x` operand. Its divisors are map sizes and radii that the code checks
(`data[1] == 0 or data[2] == 0` returns nil before the division) or that come from fixed tables, and the distance
divisor sits behind `dist > 1`. The one divisor that comes from the client is the minimap radius
(`C_Minimap.GetViewRadius()`, `HereBeDragons-Pins-2.0.lua`): it is not checked for zero upstream. If any division
raises in game, report it here.

```text
/dump C_Map.GetBestMapForUnit("player")
/dump C_Map.GetPlayerMapPosition(C_Map.GetBestMapForUnit("player"), "player"):GetXY()   -- 0..1 values; nil/error in an instance
/dump UnitInParty("Name"), UnitInRaid("Name")
/dump CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS.MAGE, RAID_CLASS_COLORS and RAID_CLASS_COLORS.MAGE
/dump LibStub("HereBeDragons-Pins-2.0", true)
```

## PvP (to be measured, issue #92)

Nothing PvP-related has been measured on Forever yet. Run the probe on a PvP realm, in the open world and in a
battleground: `/nrage debug pvp start`, do some honourable kills (also grey targets and repeated kills of the same
target), then `/nrage debug pvp log` and copy the result here. `/nrage debug pvp status | stop | clear` do what
they say. Every value is logged through `pcall`; a secret value shows as `<secret>`.

| # | Question | API | Result |
|---|---|---|---|
| 1 | Do the honour counters exist, and do they increase on an honourable kill, including group credit? | `GetPVPSessionStats()`, `GetPVPLifetimeStats()` | not measured yet |
| 2 | Does `CHAT_MSG_COMBAT_HONOR_GAIN` fire? What text and arguments does it carry (victim name, rank, honour)? Is it a secret value? | event | not measured yet |
| 3 | Can an addon register `COMBAT_LOG_EVENT_UNFILTERED` outside encounters? Does `CombatLogGetCurrentEventInfo()` return readable `PARTY_KILL` data (source GUID = player, destination = hostile player)? | event | Right after login the client showed "NrageAssistant has been blocked from an action only available to the Blizzard UI". The dialog does not name the call; this registration is the suspect (Midnight protects the event, and a `pcall` does not hide the dialog), not a confirmed cause. The addon no longer registers it (`PVP_COMBAT_LOG_ENABLED = false`). `/nrage debug pvp start` still tries it, so the dialog may show when you run the probe. |
| 4 | Does `IsInInstance()` return `instanceType == "pvp"` inside a battleground? | `IsInInstance` | not measured yet |
| 5 | Do kills that give no honour (grey targets, repeated kills of the same target) increase any counter? | counters | not measured yet |
| 6 | Are victim names multi-word and first-word-only, like `UnitName`? | event | not measured yet |
| 7 | Does the global `COMBATLOG_HONORGAIN` (and `COMBATLOG_HONORGAIN_NO_RANK`) exist, and does it match the text of `CHAT_MSG_COMBAT_HONOR_GAIN`? Is `destName` of `PARTY_KILL` readable (not secret)? | globals, event | not measured yet |

The kill feed (phase 6, #97) needs a victim name and takes it from either source, whichever works: the first `%s`
of `COMBATLOG_HONORGAIN` turned into a pattern and matched against the chat text, or `destName` of a `PARTY_KILL` by
the player. Neither is measured (#99). Without a readable name no feed entry is produced, and the tab says the feed
is not available when neither source exists on the client.
Decisions still open: the source of honourable kills (counter delta, chat event, or both) and whether killing
blows are available.

## PvP seasons (to be measured)

The PvP missions (`docs/PVP_MISSIONS_PLAN.md`, sections 2 and 5) read the client in five places that nobody has
measured on Forever yet. Each reader in `Core/Platform.lua` is guarded (a missing API, an error or a secret value gives
nil) and a mission criterion whose source does not work is shown as "Not available on this client" instead of
blocking anything. Run `/nrage debug pvp start` on a PvP realm, play, then `/nrage debug pvp log` and copy the
lines here. The probe logs the map (`GetBestMapForUnit` and `C_Map.GetMapInfo` name) at start, on login and zone
changes, the victim parsed from the honour message next to the names of the target (`victim` lines), each distinct
unit seen on `target`, `mouseover` and nameplates (`unit` lines, with `UnitIsPlayer`, `UnitIsEnemy`, `UnitClass`,
`UnitRace`, `GetUnitName(unit, true)` and `UnitName`), and the battleground winner on every
`UPDATE_BATTLEFIELD_STATUS` (`winner` lines). It also registers the unit events in `pcall`; if the client shows the
"blocked action" dialog at that moment, that is the answer to M4.

| # | Question | API | Result |
|---|---|---|---|
| M1 | Does `C_Map.GetBestMapForUnit("player")` return a stable uiMapId (not secret) in cities and contested zones? Record the ids for Orgrimmar, Stormwind, Ironforge, Darnassus, Thunder Bluff, Undercity, Stranglethorn Vale, Hillsbrad Foothills, Alterac Mountains, Ashenvale, Arathi Highlands | `C_Map.GetBestMapForUnit`, `C_Map.GetMapInfo` | not measured yet. `PVP_MISSION_ZONES` in `Core/Constants.lua` holds the Classic map ids (1454, 1453, 1455, 1457, 1456, 1458, 1434, 1424, 1416, 1440, 1417) as a starting point; fix them there once measured. Without a map id a kill never matches a zone criterion |
| M2 | Does the kill feed produce a victim name for honour kills (issue #92, questions 2, 6, 7)? Multi-word or first word? | `CHAT_MSG_COMBAT_HONOR_GAIN` text, `COMBATLOG_HONORGAIN` | not measured yet. Without a victim name no kill is logged for the missions |
| M3 | Do `UnitClass` / `UnitRace` on `target`, `mouseover` and `nameplateN` return readable file tokens for enemy players? Does `GetUnitName(unit, true)` match the feed's victim name? | `UnitIsPlayer`, `UnitIsEnemy`, `UnitClass`, `UnitRace`, `GetUnitName` | not measured yet. The unit cache (`Domain/PvPUnitCache.lua`) keys by the name as `GetUnitName(unit, true)` gives it (without the own realm suffix), compared without case; if the feed uses another form (first word only) the class and race of its kills stay unknown and the approver decides from the evidence |
| M4 | Do `NAME_PLATE_UNIT_ADDED` and `UPDATE_MOUSEOVER_UNIT` fire for enemy players without triggering the "blocked action" dialog? | events | not measured yet. The events are registered one by one in `pcall`; a refused one only removes its own source, and `distinct = class/race` missions show "Not available on this client" when none of the three could be registered |
| M5 | Does `GetBattlefieldWinner()` return the winner after a battleground, and does `UPDATE_BATTLEFIELD_STATUS` fire then? | `GetBattlefieldWinner`, `UnitFactionGroup`, event | not measured yet. The addon assumes `1` is the Alliance and `0` the Horde (the Classic values) and compares it with `UnitFactionGroup("player")`; any other value, or no winner, logs nothing |
| M6 | Are `UnitLevel` and `GetGuildInfo` readable on enemy players? | `UnitLevel`, `GetGuildInfo` (`Platform.GetEnemyDetails`) | not measured yet. An unreadable value is stored as unknown, and a skull enemy is shown as own level + 10, marked as estimated |
| M7 | Does `/targetexact` from a secure button work, outside and inside combat? | `SecureActionButtonTemplate` with `macrotext1` (`UI/IntelWindow.lua`, `UI/IntelTargetButton.lua`) | not measured yet. The buttons are changed outside combat only; a newcomer in combat cannot be targeted until combat ends |
| M8 | Do the death recap functions name the killer? | `C_DeathRecap.GetRecapEvents`, `DeathRecap_GetEvents` (`Platform.GetDeathKiller`) | not measured yet. Without a named killer, a loss uses the enemy who targeted the player in the last 10 seconds, and the debug output counts that source separately |
| M9 | Does `UNIT_SPELLCAST_SUCCEEDED` fire for enemy nameplates with a readable spell id, and are the stealth spell ids right? | `UNIT_SPELLCAST_SUCCEEDED` (`Platform.ReadSpellEvent`), `INTEL_STEALTH_SPELLS` | not measured yet. The stealth ids are Classic values to confirm on Forever |
| M10 | Does `NRAGEINT` work on `GUILD`, and on the group channel in a battleground? | `C_ChatInfo.RegisterAddonMessagePrefix`, `ChatThrottleLib:SendAddonMessage`, `CHAT_MSG_ADDON` | not measured yet. Sightings go to `GUILD` in the open world and to the group channel in a battleground |
| M11 | Is the minimap tooltip text readable? | the tooltip of the minimap button and its dots (`Domain/IntelMinimapTooltip.lua`) | not measured yet. The tooltip details are optional (the `minimapTooltip` setting) |
| M12 | Does `Menu.ModifyMenu` exist, and does it stay free of taint? | `Menu.ModifyMenu` on `MENU_UNIT_ENEMY_PLAYER` (`Platform.AddEnemyPlayerMenuEntry`) | not measured yet. The entry is added inside `pcall`; without the function it is not added and the rest of Intel works |
| M13 | Does `FromSpy` find the saved data of Spy (Forever) when both addons are loaded? | Spy's saved variables, read through the globals (`Domain/IntelImport.lua`, `FromSpy`) | not measured yet. When nothing is found, `/nrage intel import spy` says so and imports nothing |

Until M3, M4 and M6 pass in game, do not tell the guild that Spy can be removed.

## Group names for the blacklist alert (to be measured)

The blacklist alert compares the members of the party or raid with the blacklist. Nothing about group names has
been measured on Forever yet; the addon assumes the same behaviour as `UnitName`, and handles both possibilities:
a single-word group name that equals the first word of a listed multi-word name is reported as a possible match
("may be ..."). Check in game with a character that has a multi-word name in a party and in a raid:

| # | Question | API | Result |
|---|---|---|---|
| 1 | Does `UnitName("party1")` return only the first word of a multi-word name, like `UnitName("player")`? | `UnitName` | not measured yet |
| 2 | Does `GetRaidRosterInfo(i)` return the full multi-word name or only the first word? Is a realm suffix ever added? | `GetRaidRosterInfo` | not measured yet |
| 3 | Do `IsInGroup`, `IsInRaid`, `GetNumGroupMembers` and the events `GROUP_ROSTER_UPDATE` and `PLAYER_ENTERING_WORLD` exist and fire as on Mainline? | APIs, events | not measured yet |
| 4 | Do `RaidNotice_AddMessage(RaidWarningFrame, ...)` and `PlaySound` work for the warning? | UI | not measured yet |

verify-in-game: record the answers above here, and if the full name is available the first-word fallback can be
removed. Every call is guarded, so a missing API or a secret value leaves a name out instead of raising.

## Redesign APIs (phase P0, to be measured in the game)

The UI redesign (`docs/REDESIGN_PLAN.md`) depends on a few client APIs nobody has measured on Forever yet. Each one is
wrapped in `Core/Platform.lua` behind `pcall` and an availability check, and the feature that needs it ships
**disabled or hidden** when the check says it is missing. Record the result of every row, then update the table and
remove the "not measured yet" marker.

| # | Question | API (through `Platform`) | Feature that depends on it | If unavailable | Result |
|---|---|---|---|---|---|
| 1 | Does `GetGuildInfo("player")` return the rank index (third value), and is 0 the guild master? | `GetGuildInfo` (`Platform.GetOwnGuildRank`) | Admin = the guild master only (plan 3.4.2) | Nobody is admin: fix before shipping | not measured yet |
| 2 | Does `IsGuildLeader()` exist and answer a boolean? | `IsGuildLeader` (`Platform.IsGuildLeader`) | Second source for "I am the guild master" | The rank index alone decides | not measured yet |
| 3 | Does `GetGuildRosterInfo` return `isOnline` as the ninth value? Is it kept up to date without a new request? | `GetGuildRosterInfo` (`Platform.GetGuildRosterEntry`, `online`) | Online crafters first, "Connected only", disabled "Ask" for offline members | Every crafter shows as offline-unknown; "Ask" stays enabled | not measured yet |
| 4 | `IsInRaid`, `GetNumGroupMembers`, `GetRaidRosterInfo`, `UnitName("partyN")`: do they exist, and do they return the full multi-word name or only the first word? | `Platform.GroupApiAvailable`, `Platform.GetFullGroupNames` | "Fill from current group" (Raid, Attendance) | The button is hidden | not measured yet |
| 5 | Does `GetProfessions()` also fill the secondary slots (archaeology, fishing, cooking), and does `GetProfessionInfo` give their skill? | `Platform.GetProfessions` (`secondary`) | Profile line 3 and the Members row detail | Only the primary professions are listed | not measured yet |
| 6 | Does `C_TradeSkillUI.GetBaseProfessionInfo`, `GetAllRecipeIDs` and `GetRecipeInfo(id).learned` work while a profession window is open? Is `professionID` stable between clients? Do secondary professions (cooking, fishing) scan the same way? Do `IsTradeSkillLinked`, `IsTradeSkillGuild` and `IsNPCCrafting` exist? | `Platform.RecipeScanAvailable`, `Platform.ScanKnownRecipes` | Professions tab: scan, sync | The Professions tab shows "not available on this client" and nothing is scanned or sent | not measured yet |
| 7 | Do the events `TRADE_SKILL_SHOW` and `TRADE_SKILL_LIST_UPDATE` fire, and is `TRADE_SKILL_LIST_UPDATE` fired before the recipe list is complete? | events (registered through `Platform.TryRegisterEvent`) | When to scan | Scan on `TRADE_SKILL_SHOW` only | not measured yet |
| 8 | Does a recipe id give a name and icon through `C_TradeSkillUI.GetRecipeInfo(id)` when no window is open, or only through the spell (`C_Spell.GetSpellInfo(id)`)? Does `C_TradeSkillUI.GetRecipeOutputItemData(id)` give a link? | `Platform.GetRecipeInfo` | Recipe names, icons and the item link in the "Ask" text | The recipe shows as `Recipe <id>` without an icon | not measured yet |
| 9 | Does `ChatFrameUtil.OpenChat(text)` or `ChatFrame_OpenChat(text)` exist, and does it fill the edit box without sending? | `Platform.CanPrefillChat`, `Platform.PrefillChat` | The "Ask" whisper | The "Ask" button is hidden | not measured yet |
| 10 | Do `LOOT_OPENED`, `GetNumLootItems`, `GetLootSlotLink`, `GetLootSlotInfo` work on a boss corpse, and are the links readable (not secret values) right after the kill? Does `ENCOUNTER_LOOT_RECEIVED` fire and carry the link? | `Platform.LootWindowAvailable`, `Platform.GetLootWindowItems` | The "Last boss loot" strip in the Loot tab | The strip is not shown | not measured yet |
| 11 | Does `GetPhysicalScreenSize` exist, so a border can be exactly one physical pixel? | `Kit/Pixel.lua` | 1px borders | Borders are one interface unit thick | not measured yet |
| 12 | Does `Frame:SetResizeBounds` exist (else `SetMinResize`)? | `Kit/Shell.lua` | Resizable windows | Fixed size | not measured yet |

### Checklist for the owner (run these in the game, then fill the Result column)

```text
/dump GetGuildInfo("player")                       -- 3rd value is the rank index; the GM should be 0
/dump IsGuildLeader and IsGuildLeader()
/dump select(9, GetGuildRosterInfo(1))             -- isOnline, repeat for a few rows (online and offline)
/dump IsInRaid(), IsInGroup(), GetNumGroupMembers()
/dump GetRaidRosterInfo(1)                         -- in a raid; is the name the full multi-word name?
/dump UnitName("party1")                           -- in a party
/dump GetProfessions()                             -- 5 values: prof1, prof2, archaeology, fishing, cooking
/dump GetProfessionInfo((select(4, GetProfessions())))   -- fishing, when learned
/dump C_TradeSkillUI.GetBaseProfessionInfo()       -- with a profession window open
/dump #C_TradeSkillUI.GetAllRecipeIDs()
/dump C_TradeSkillUI.GetRecipeInfo(C_TradeSkillUI.GetAllRecipeIDs()[1])   -- look at .learned, .name, .icon
/dump C_TradeSkillUI.IsTradeSkillLinked and C_TradeSkillUI.IsTradeSkillLinked()
/dump C_TradeSkillUI.GetRecipeOutputItemData and C_TradeSkillUI.GetRecipeOutputItemData(C_TradeSkillUI.GetAllRecipeIDs()[1])
/dump C_Spell and C_Spell.GetSpellInfo(C_TradeSkillUI.GetAllRecipeIDs()[1])
/dump ChatFrameUtil and ChatFrameUtil.OpenChat, ChatFrame_OpenChat
/run ChatFrameUtil.OpenChat("/w Test hello")       -- the edit box must open with the text and send nothing
/dump GetNumLootItems()                            -- while a boss corpse is open
/dump GetLootSlotLink(1)
/dump GetPhysicalScreenSize and GetPhysicalScreenSize()
/dump CreateFrame("Frame").SetResizeBounds
```

For the two events, log them for a minute while opening professions and a corpse:
`/run local f=CreateFrame("Frame") for _,e in ipairs{"TRADE_SKILL_SHOW","TRADE_SKILL_LIST_UPDATE","LOOT_OPENED","ENCOUNTER_LOOT_RECEIVED"} do pcall(f.RegisterEvent,f,e) end f:SetScript("OnEvent",function(_,e,...) print(e,...) end)`

## APIs the addon uses

`/nrage debug selftest` checks each of these on the running client.

| Area | APIs |
|---|---|
| Identity | `UnitGUID`, `UnitName`, `UnitClass`, `UnitLevel`, `UnitFactionGroup`, `GetNormalizedRealmName` |
| Gear and professions | `GetAverageItemLevel`, `GetProfessions`, `GetProfessionInfo` |
| Guild | `IsInGuild`, `GetGuildInfo`, `C_GuildInfo.GuildRoster`, `GetNumGuildMembers`, `GetGuildRosterInfo`, `C_Club.GetGuildClubId`, event `GUILD_ROSTER_UPDATE` |
| Messaging | `C_ChatInfo.RegisterAddonMessagePrefix`, `C_ChatInfo.SendAddonMessage`, `C_ChatInfo.InChatMessagingLockdown`, event `CHAT_MSG_ADDON` |
| Encounters and combat | events `ENCOUNTER_START`, `ENCOUNTER_END`, `PLAYER_REGEN_DISABLED`, `PLAYER_REGEN_ENABLED` (the lockdown probe) |
| PvP counters (**not measured yet**, #99) | `GetPVPSessionStats`, `IsInInstance`, `CombatLogGetCurrentEventInfo` (also the destination name, for the kill feed), the globals `COMBATLOG_HONORGAIN` and `COMBATLOG_HONORGAIN_NO_RANK`, events `CHAT_MSG_COMBAT_HONOR_GAIN`, `PLAYER_PVP_KILLS_CHANGED`, `COMBAT_LOG_EVENT_UNFILTERED`. Each is guarded and registered in `pcall`, so a missing or restricted one disables only that counter; they are not in the self test on purpose, because a missing one would show a permanent warning on the minimap button |
| PvP probe | the above plus `GetPVPLifetimeStats` (`/nrage debug pvp`, to answer #99) |
| Guild map (**not measured yet**) | `C_Map.GetBestMapForUnit`, `C_Map.GetPlayerMapPosition`, `UnitInParty`, `UnitInRaid`, `IsInInstance`, `ChatThrottleLib`, the globals `RAID_CLASS_COLORS`, `CLASS_ICON_TCOORDS`, `HBD_PINS_WORLDMAP_SHOW_CONTINENT`, events `CHAT_MSG_ADDON` (prefix `NRAGEPOS`), `GROUP_ROSTER_UPDATE`. Each is guarded; not in the self test on purpose |
| PvP probe | the above plus `GetPVPLifetimeStats`, `C_Map`, the unit functions and `GetBattlefieldWinner` (`/nrage debug pvp`, to answer #99 and the PvP seasons questions M1 to M5) |
| PvP missions (**not measured yet**) | `C_Map.GetBestMapForUnit`, `UnitIsPlayer`, `UnitIsEnemy`, `UnitClass`, `UnitRace`, `GetUnitName`, `GetBattlefieldWinner`, `UnitFactionGroup`, events `PLAYER_TARGET_CHANGED`, `UPDATE_MOUSEOVER_UNIT`, `NAME_PLATE_UNIT_ADDED`, `UPDATE_BATTLEFIELD_STATUS`. Each reader is guarded and each event registered in `pcall`; not in the self test, for the same reason as the PvP counters |
| Group and warning (**not measured yet**) | `IsInGroup`, `IsInRaid`, `GetNumGroupMembers`, `GetRaidRosterInfo`, `UnitName("party1".."party4")`, `RaidNotice_AddMessage`, `RaidWarningFrame`, `PlaySound`, events `GROUP_ROSTER_UPDATE`, `PLAYER_ENTERING_WORLD`. Each is guarded and registered in `pcall`; not in the self test on purpose |
| Intel (**not measured yet**) | `C_CVar.GetCVar` and `SetCVar` (`nameplateShowEnemies`), `UnitIsPlayer`, `UnitIsEnemy`, `UnitClass`, `UnitRace`, `UnitLevel`, `GetGuildInfo`, `UnitFactionGroup`, `IsInInstance`, `GetPVPSessionStats`, `C_DeathRecap.GetRecapEvents`, `Menu.ModifyMenu`, `ChatThrottleLib`, events `NAME_PLATE_UNIT_ADDED`, `NAME_PLATE_UNIT_REMOVED`, `PLAYER_TARGET_CHANGED`, `UPDATE_MOUSEOVER_UNIT`, `PLAYER_DEAD`, `UNIT_SPELLCAST_SUCCEEDED`, `CHAT_MSG_COMBAT_HONOR_GAIN`, `PLAYER_PVP_KILLS_CHANGED`, `CHAT_MSG_ADDON` (prefix `NRAGEINT`). Each is guarded and registered in `pcall`; not in the self test on purpose |
| Time | `GetServerTime`, `GetTime`, `date`, `time` |
| UI | `CreateFrame`, `C_Timer.After`, `C_Timer.NewTicker`, `C_AddOns.GetAddOnMetadata` |
| Load | events `ADDON_LOADED`, `PLAYER_LOGIN`, `PLAYER_GUILD_UPDATE`, `## SavedVariables` |

All access goes through `NrageAssistant/Core/Platform.lua`, so a change in the client API is fixed in one place,
and the domain code is tested against fakes.

## Restrictions to keep in mind

Forever adopts the Midnight addon restrictions: during an encounter `C_ChatInfo.InChatMessagingLockdown()` is true
and sending addon or chat messages is blocked, and some combat data and chat arrive as secret values that cannot
be inspected, compared or saved. The addon is therefore a coordination tool for outside combat: nothing is sent
during the lockdown, and anything raising on a secret value is dropped. Re-read the restriction notes after every
Forever or Mainline patch, because they may reach Forever in the following one.

## Division by zero raises an error on the Forever client

Found in game on the Forever client: `LibSerialize` failed to encode any message with `Division by zero`
(`LibSerialize.lua:1562`, `1 / num < 0`, its test for negative zero). Every message carries a `0` (the protocol
minor), so nothing was ever sent. Standard Lua gives `inf` for `1 / 0`; this client raises.

Also, `LibStub` returns one instance per library name, and other addons (DBM ships `LibSerialize` too) load first,
so asking for `LibSerialize` returned DBM's copy. The vendored copy is therefore patched and registered as
`NrageAssistant-LibSerialize` (see `Libs/README.md`). Never divide by a value that can be zero in addon code
either.
