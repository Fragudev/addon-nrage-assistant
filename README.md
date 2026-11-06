<h1 align="center">Nrage Assistant</h1>

<p align="center">
  Guild coordination and raid readiness for <b>Nrage</b> (Alliance, PvP ruleset) on <b>World of Warcraft: Forever</b>:
  raid events, loot council, PvP seasons, layers, the guild map and groups, in one window.
</p>

<p align="center">
  <a href="https://www.curseforge.com/wow/addons/nrage-assistant"><b>Get it on CurseForge</b></a> ·
  <a href="https://github.com/Fragudev/addon-nrage-assistant/releases"><b>Download from Releases</b></a> ·
  <a href="docs/USER_GUIDE.md"><b>User guide</b></a>
</p>

<p align="center">
  <a href="LICENSE"><img alt="Licence: proprietary" src="https://img.shields.io/badge/licence-proprietary-e6ba66?style=flat-square&labelColor=1c1a17"></a>
  <img alt="World of Warcraft: Forever, client 1.60.1" src="https://img.shields.io/badge/WoW-Forever_1.60.1-94c9ff?style=flat-square&labelColor=1c1a17">
  <img alt="Guild: Nrage, Alliance" src="https://img.shields.io/badge/guild-Nrage_·_Alliance-3d6fd1?style=flat-square&labelColor=1c1a17">
  <a href="https://www.curseforge.com/wow/addons/nrage-assistant"><img alt="CurseForge: Nrage Assistant" src="https://img.shields.io/badge/CurseForge-Nrage_Assistant-f16436?style=flat-square&logo=curseforge&logoColor=white&labelColor=1c1a17"></a>
</p>

<p align="center">
  <a href="#quick-start">Quick start</a> ·
  <a href="#what-it-is">What it is</a> ·
  <a href="#who-can-use-it">Who can use it</a> ·
  <a href="#features">Features</a> ·
  <a href="#slash-commands">Slash commands</a> ·
  <a href="#documentation">Documentation</a> ·
  <a href="#building-from-source">Building from source</a> ·
  <a href="#releasing">Releasing</a> ·
  <a href="#credits-and-licence">Credits and licence</a>
</p>

<table align="center">
  <tr>
    <td align="center" width="240"><a href="#quick-start"><b>Play</b></a><br>Install the addon and open it with <code>/nrage</code>.</td>
    <td align="center" width="240"><a href="docs/USER_GUIDE.md#what-you-can-do-by-role"><b>Lead</b></a><br>Run events, loot council and PvP seasons.</td>
    <td align="center" width="240"><a href="#building-from-source"><b>Work on it</b></a><br>Build the addon and run the tests.</td>
  </tr>
</table>

## Quick start

1. **Install it with the CurseForge app** (search for
   [Nrage Assistant](https://www.curseforge.com/wow/addons/nrage-assistant)), then skip to step 3.
   **Or download** `NrageAssistant-<version>.zip` from the newest release on the
   [Releases page](https://github.com/Fragudev/addon-nrage-assistant/releases), under *Assets* (not "Source code").
2. **Unzip it into the game's AddOns folder**:
   ```text
   World of Warcraft/<forever client folder>/Interface/AddOns/
   ```
   The zip already contains the `NrageAssistant` folder, so do not create it yourself.
3. **Restart the game** and make sure **Nrage Assistant** is enabled in the AddOns list. Log in with a Nrage
   character: the chat says `Nrage Assistant <version> loaded`.
4. **Click the minimap button, or type `/nrage`**, to open the window. Everything is done from there.

Good to know:

- **Updating:** delete the old `NrageAssistant` folder, then unzip the new release the same way (the CurseForge app
  does this for you).
- **Language:** the interface follows the client: Spanish on `esES` and `esMX`, English otherwise.
- **Data:** your sheet and everything you share go to guildmates running the addon. What is shared and how is in
  [Privacy and data](docs/PRIVACY.md).
- **Something wrong?** Check [Troubleshooting](docs/USER_GUIDE.md#troubleshooting) first, then open an
  [issue](https://github.com/Fragudev/addon-nrage-assistant/issues) with what you did, what you expected and the
  output of `/nrage debug info`.

## What it is

Nrage Assistant is the guild's own addon. It puts in one window what the guild otherwise coordinates by hand in chat
and spreadsheets: who is ready for the raid, who comes, who gets the loot, who leads the PvP ranking and which layer
the guild is on. Data is shared between members through the addon's own messages, with no server and no website:
what one officer changes reaches every member running the addon.

Values are never guessed. Each one says where it comes from: `verified` (read from the game), `declared` (typed by
the player) or `received` (from someone else), and what the game cannot tell is shown as `unknown`.

## Who can use it

The addon is published on CurseForge, but it only works for Nrage:

- It **disables itself** for characters outside Nrage (Alliance, PvP ruleset) and does not register its message prefix
  there; the login message says why.
- Shared data is accepted only from guild members, and edits only from members whose role allows them.
- Your role is your **guild rank**, matched by name (`GM`, `CoGM`, `Oficial`, `RL`, `Roster`, `Miembro`, `Alter`); the
  guild master is recognised by rank index 0, never by a name. Roles are changed in the game, not in the addon, and a
  rank with any other name counts as Alter.

## Features

### Character sheet and readiness

- **Profile:** what the addon knows about your character, each value with its source, plus your declared role, main
  and notes; share your sheet with the guild.
- **Readiness:** a checklist per raid with a score that always shows its denominator (`1/3 met, 2 unknown`); unknown
  is never counted as met.

### Raid events

- Events created by raid leaders and admins, shared with the guild, with a roster and assignments.
- **Attendance**, reusable **templates** and **reports**.
- **Export and import** as text, to move data between characters or back it up.

### Loot council

- Sessions tied to a raid event, opened after the encounter. The roster gets the **Nrage Loot** card to answer, and
  the council decides from the same window.

### PvP and PvP seasons

- **Kill counter** split into open world and battleground, a guild **kill ranking** and a **recent kills** feed.
- **Seasons:** missions approved by the GM and CoGM, a points ranking and end-of-season rewards.

### Intel (enemy players)

- **Nearby enemies** seen through their nameplates in battlegrounds, arenas and world PvP, with level, class, race and
  guild, in a compact window. Turn enemy nameplates on first: stealthed enemies are not seen.
- **Kill on Sight** lists: your own, never shared, and a **guild list** with a category and reason for each player.
- **Sightings** shared with the guild, on by default. A sighting shows where you were, so you can turn it off in the
  Intel settings.
- **Statistics** of the enemies you meet, wins and losses, and **bounties** the GM and CoGM open on guild-listed players.
- Imports from Spy (Forever) and a session or season report.

### Guild tools

- **Professions:** "who can craft this?" with online members first and a one-click whisper.
- **Blacklist:** a guild-wide list of players to be warned about.
- **Layers:** your current layer, the layers guildmates have shared, and layer swap requests.
- **Guild map:** guildmates who share their position, on the minimap and the world map.
- **Groups:** post a party for a dungeon or a quest with the roles you need, or apply to one. The leader invites with a click. Only members with the addon see the board.

### Sync

- Changes made during an encounter, while the game blocks addon messages, wait in a queue and are sent when it ends.
  The *Home* tab and the minimap tooltip show the queue.

The full walkthrough, tab by tab and role by role, is the [user guide](docs/USER_GUIDE.md).

## Slash commands

| Command | Description |
|---|---|
| `/nrage` | open the window |
| `/nrage help` | the list of commands |
| `/nrage intel ...` (or `/nrage spy`) | Intel: the window, Kill on Sight, Ignore, statistics and imports |

<details>
<summary><b>Diagnostics for developers</b></summary>

| Command | Description |
|---|---|
| `/nrage debug ...` | `selftest`, `info`, `identity`, `roster`, `senders`, `sync`, `publish`; development builds only: `lockdown`, `pvp`, `layer` |

</details>

## Documentation

| Document | For |
|---|---|
| [User guide](docs/USER_GUIDE.md) | players and officers |
| [Privacy and data](docs/PRIVACY.md) | what is shared, with whom |
| [Sync protocol](docs/PROTOCOL.md) | the wire format between clients |
| [Client API notes](docs/API_NOTES.md) | what the Forever client does and does not expose |
| [Layer swap plan](docs/LAYER_SWAP_PLAN.md) | design of layer swap requests |
| [PvP missions, seasons and rewards plan](docs/PVP_MISSIONS_PLAN.md) | design of PvP seasons |
| [Guild map plan](docs/GUILD_MAP_PLAN.md) | design of the guild map |

## Building from source

Lua 5.1 with [luacheck](https://github.com/lunarmodules/luacheck), [busted](https://lunarmodules.github.io/busted/),
[luacov](https://lunarmodules.github.io/luacov/) and [StyLua](https://github.com/JohnnyMorganz/StyLua).

```bash
luacheck NrageAssistant tests
busted --coverage && luacov && tools/check_coverage.sh 80
stylua --check NrageAssistant tests
tools/package.sh dev
```

Every pull request runs lint, the tests with a minimum of 80% line coverage, a StyLua format check and a package
build that verifies every file referenced by the TOC, `embeds.xml` and the icon is in the zip. Pull request titles
must follow [Conventional Commits](https://www.conventionalcommits.org/). Dependabot keeps the workflow actions up to
date. Domain logic is tested outside the game against fakes of the client API, which all goes through
`NrageAssistant/Core/Platform.lua`. Work happens on `feature/*` branches with one pull request each.

<details>
<summary><b>Translations</b></summary>

What the player reads goes through `L("English text")` (`NrageAssistant/Core/Locale.lua`): the code writes the English
text and `NrageAssistant/Locales/esES.lua` maps it to Spanish; a text with no entry is shown in English. Spanish is
used when the client is `esES` or `esMX`, English otherwise. Keep placeholders (`%d`, `%s`) in the same order, put one
string literal inside each `L(...)`, and never translate a value that is compared or sent (a status, a role, a command
word). A test fails when the code asks for a text the catalog does not have, when the catalog has one nothing asks
for, or when the placeholders differ.

</details>

### Project layout

```text
NrageAssistant/          Addon files (the only folder shipped in release zips)
  Core/                  Constants, platform seam, access and lockdown guards, store
  Domain/                Profile, readiness, events, loot, permissions, reports, templates, PvP and PvP seasons,
                         layers, diagnostics
  Sync/                  Codec, protocol, inbox and outbound queue, event, loot and PvP season sync, snapshot,
                         import/export
  UI/                    Window (own widget kit in Kit/), tabs and view models
  Commands/              Slash commands
  Locales/               Translations (esES)
  Libs/                  Vendored libraries, see Libs/README.md
  Media/                 Game textures, fonts and icons
assets/                  Source artwork (not shipped), see assets/README.md
tools/                   Development helpers (image conversion, packaging, coverage gate)
tests/                   busted specs and client API stubs
docs/                    Documentation
release-notes/           Hand-written notes published with each release
.github/workflows/       CI and release automation
```

## Releasing

Write the notes in `release-notes/<tag>.md`, then push a tag starting with `v`. The **Release** workflow runs the full
CI first and, only if it passes, stamps the version into the TOC, zips `NrageAssistant/`, publishes a GitHub release
and uploads the zip to CurseForge.

```bash
git tag v0.1.0 && git push origin v0.1.0
```

Tags containing a hyphen (for example `v0.2.0-alpha.1`) are published as pre-releases. Only `NrageAssistant/` is
shipped: `tests/`, `docs/` and the plans stay out of the zip. If the CurseForge upload fails, run the **Release**
workflow by hand with the existing tag to publish it again.

## Credits and licence

- **Cinzel** by The Cinzel Project Authors and **Barlow Condensed** by The Barlow Project Authors, licensed under the SIL
  Open Font License 1.1: `NrageAssistant/Media/Fonts/` (the licences are `OFL-Cinzel.txt` and `OFL-BarlowCondensed.txt`
  in the same folder). `NrageDisplay`, `NrageLabel` and `NrageButton` are modified copies made by `tools/make_fonts.py`.
- The icons in `NrageAssistant/Media/Icons/` are our own simple shapes, drawn by `tools/make_icons.py`.
- The interface is built with the addon's own widget kit (`NrageAssistant/UI/Kit/`). No code, texture or font was
  copied from other addons.

Proprietary. All rights reserved. See [LICENSE](LICENSE).
