# Nrage Assistant

Guild coordination and raid readiness for **Nrage** (Alliance, PvP ruleset) on **World of Warcraft: Forever**. Raid
events, raid checks, loot council, PvP seasons, layers and a guild map, in one window.

> **Nrage only.** The addon disables itself for any character outside Nrage, so it does nothing on other guilds or
> realms.

## How it works

Open the window with the minimap button or `/nrage`. Everything you can do lives in two groups:

- **Guild**: what every member uses.
- **Admin**: what the guild's leaders use to run the rosters. You only see it if your rank allows it.

Your permissions come from your **guild rank**, the same one you have in game: GM, CoGM, Oficial, RL, Roster, Miembro
and Alter. Nobody assigns roles inside the addon. Most leaders work on **their own roster**. The GM and the CoGM can
pick any roster.

There is no server and no website. Data travels between guildmates through the addon's own messages, so what a
leader changes reaches everyone running the addon. Values are never guessed: each one says whether it was read from
the game, typed by the player or received from someone else, and what the game cannot tell is shown as unknown.

## Guild

### Home

Your character at a glance: name, class, level and item level, your main and secondary spec, and your **layer**. You
also see the layers your guildmates have shared, and you can ask to swap layers.

### Raid

The upcoming events of your roster and guild-wide events, with date, time and how many have signed up. Answer
**going** or **not going** with one click. Everything else is read-only.

### Raid check

Your checklist against your roster's raid requirements. It shows how many requirements you meet, and unknown is never
counted as met (`1/3 met, 2 unknown`). Available to ranks Roster and above.

### Loot

A loot council per roster. When a session opens, a **popup** asks you to put yourself forward (main spec, off spec or
other) or to pass. Leaders vote and award from the Loot tab, and every closed session keeps its reason as the minutes.
Ranks Roster and above can apply, and a Roster player follows the sessions read-only.

### Professions

"Who can craft this?": search a recipe and see who has it, online members first, with a one-click whisper.

### PvP

A kill counter split into open world and battlegrounds, a guild **kill ranking**, a **recent kills** feed, and **PvP
seasons** with missions, a points ranking and end-of-season rewards.

### Intel

Enemy players you can see through their nameplates in battlegrounds, arenas and world PvP, in a compact window with
their level, class, race and guild. Turn **enemy nameplates** on first: Intel reads what they show, and a stealthed
enemy is not seen. Keep a **Kill on Sight** list of your own, which is never shared, and a **guild list** that every
member sees, with a reason for each player. **Sightings** are shared with the guild by default, and they show where you
were, not where the enemy was; you can turn them off in the Intel settings. The GM and CoGM can open **bounties** on
guild-listed players, which count the kills of them in the season.

### Guild map

See your guildmates on the **minimap** and the **world map**, each one as a pin with their class icon. Hover a pin for
the name, level, layer and how fresh the position is; members on another layer show half transparent. Your own
position is **shared with the guild by default**, and you can turn it off in the settings. Nothing is sent from
instances, battlegrounds or during an encounter.

## Admin

| Section | Who | What |
|---|---|---|
| **Raid** | GM, CoGM, Oficial, RL | Create events, take attendance, set assignments, use templates and see reports. |
| **Roster rules** | GM, CoGM, RL (Oficial reads) | The raid requirements of each roster, the rules Raid check uses. |
| **Members** | GM, CoGM, RL (Oficial reads) | The rosters and who belongs to each. An RL adds and removes players in their own roster. |
| **PvP** | GM, CoGM | Approve missions and claims, run the season, prizes and deliveries. |

## Good to know

- **Language:** Spanish on `esES` and `esMX` clients, English otherwise.
- **Encounters:** changes made while the game blocks addon messages wait in a queue and go out when the fight ends.
- **Privacy:** your character data goes only to guildmates running the addon. Your position and your enemy sightings
  are shared by default; you can turn either off in the settings. Guildmates forget your position after 60 seconds.
- **Problems:** report them on GitHub with the output of `/nrage debug info`.
