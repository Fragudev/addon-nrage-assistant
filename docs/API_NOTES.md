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

- The libraries (Ace3 parts, LibSerialize, LibDeflate) load on the Forever build.
- The `sender` of `CHAT_MSG_ADDON` is the full name, with or without the realm suffix. If it turns out to be the
  first word only, like `UnitName`, permission lookups by sender will not work. `/nrage debug senders` (after
  another member's message arrives) shows the raw sender and whether the roster finds it.
- Addon whispers between guild members work and their sender name can be used as a whisper target.
- The behaviour of the encounter lockdown: when it starts and ends, and what happens to queued messages. The probe
  (`/nrage debug lockdown start | send | log | clear`) exists; the two-client test has not been run.
- Whether `CHAT_MSG_LOOT` and item links arrive as secret values during an encounter. Loot sessions currently take
  the item from a link typed after the encounter.

## APIs the addon uses

`/nrage debug selftest` checks each of these on the running client.

| Area | APIs |
|---|---|
| Identity | `UnitGUID`, `UnitName`, `UnitClass`, `UnitLevel`, `UnitFactionGroup`, `GetNormalizedRealmName` |
| Gear and professions | `GetAverageItemLevel`, `GetProfessions`, `GetProfessionInfo` |
| Guild | `IsInGuild`, `GetGuildInfo`, `C_GuildInfo.GuildRoster`, `GetNumGuildMembers`, `GetGuildRosterInfo`, `C_Club.GetGuildClubId`, event `GUILD_ROSTER_UPDATE` |
| Messaging | `C_ChatInfo.RegisterAddonMessagePrefix`, `C_ChatInfo.SendAddonMessage`, `C_ChatInfo.InChatMessagingLockdown`, event `CHAT_MSG_ADDON` |
| Encounters and combat | events `ENCOUNTER_START`, `ENCOUNTER_END`, `PLAYER_REGEN_DISABLED`, `PLAYER_REGEN_ENABLED` (the lockdown probe) |
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
