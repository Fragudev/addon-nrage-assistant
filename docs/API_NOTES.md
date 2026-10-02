# Client API notes

What has been measured on the WoW: Forever client, what the addon assumes, and what is still to be checked.
The API reference used is [warcraft.wiki.gg](https://warcraft.wiki.gg/wiki/Api) (Mainline branch); only deviations
from it and measured behaviour belong here.

## Measured

| Item | Value | Where it is used |
|---|---|---|
| Interface number (`select(4, GetBuildInfo())`) | 16001 (beta) | TOC |
| Normalized realm name | `ClassicBetaPvP` (beta) | ruleset check: the PvP ruleset is detected as the substring `PvP` |
| Guild club id (`C_Club.GetGuildClubId()`) | read once by a Nrage member (the value is in `Constants.lua`); that it is the same across sessions and members is not confirmed yet | access check |
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

- The libraries (Ace3 parts, LibSerialize, LibDeflate) load on the Forever build.
- The `sender` of `CHAT_MSG_ADDON` is the full name, with or without the realm suffix. If it turns out to be the
  first word only, like `UnitName`, permission lookups by sender will not work. `/nrage debug senders` (after
  another member's message arrives) shows the raw sender and whether the roster finds it.
- Addon whispers between guild members work and their sender name can be used as a whisper target.
- The behaviour of the encounter lockdown: when it starts and ends, and what happens to queued messages. The probe
  (`/nrage debug lockdown start | send | log | clear`) exists; the two-client test has not been run.
- Whether `CHAT_MSG_LOOT` and item links arrive as secret values during an encounter. Loot sessions currently take
  the item from a link typed after the encounter.

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
| Group and warning (**not measured yet**) | `IsInGroup`, `IsInRaid`, `GetNumGroupMembers`, `GetRaidRosterInfo`, `UnitName("party1".."party4")`, `RaidNotice_AddMessage`, `RaidWarningFrame`, `PlaySound`, events `GROUP_ROSTER_UPDATE`, `PLAYER_ENTERING_WORLD`. Each is guarded and registered in `pcall`; not in the self test on purpose |
| Time | `GetServerTime`, `GetTime`, `date`, `time` |
| UI | `CreateFrame`, `C_Timer.After`, `C_Timer.NewTicker`, `C_AddOns.GetAddOnMetadata`, AceGUI |
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
