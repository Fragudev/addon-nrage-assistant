# Nrage Assistant

Private World of Warcraft: Forever addon for guild coordination and raid readiness, built exclusively for the **Nrage** guild (Alliance, PvP ruleset).

> **Status:** beta. Character sheet, readiness, raid events with attendance and assignments, loot council, reports and text import/export are implemented and covered by automated tests. Most of it has not been verified on the game client yet; see the issues labelled `verify-in-game`.

## Access

This addon is for Nrage members only:

- It is distributed privately through this repository's releases; it is not published on CurseForge, Wago or any other public site.
- Do not share the addon files or release zips outside the guild.
- The addon disables itself for characters outside Nrage (Alliance, PvP ruleset) and does not register its message prefix there. Shared data is accepted only from guild members, and edits only from members whose guild rank allows them.

## Installation

1. Open the repository's **Releases** page and download the latest `NrageAssistant-<version>.zip`.
2. Extract the zip into your addons folder:
   ```text
   World of Warcraft/<forever client folder>/Interface/AddOns/
   ```
   The zip already contains the `NrageAssistant` folder, so do not create it yourself.
3. Restart the game or run `/reload`, and make sure **Nrage Assistant** is enabled in the AddOns list.

## Usage

Type `/nrage` to open the window and `/nrage help` for the commands. The full guide is [docs/USER_GUIDE.md](docs/USER_GUIDE.md).

| Command | Description |
|---|---|
| `/nrage` | open the window |
| `/nrage profile`, `publish` | your sheet and what is shared with the guild (automatically) |
| `/nrage ready` | readiness checklist |
| `/nrage event`, `attendance`, `assign`, `template` | raid events, attendance, assignments and templates |
| `/nrage loot` | loot council |
| `/nrage report` | attendance and loot reports |
| `/nrage export`, `import` | move raid data as text |
| `/nrage minimap` | show, hide or reset the minimap button |
| `/nrage sync`, `role` | sync state, your role |
| `/nrage debug selftest`, `debug info` | diagnostics |

## Documentation

- [User guide](docs/USER_GUIDE.md)
- [Sync protocol](docs/PROTOCOL.md)
- [Privacy and data](docs/PRIVACY.md)
- [Client API notes](docs/API_NOTES.md)

## Repository layout

```text
NrageAssistant/          Addon files (the only folder shipped in release zips)
  Core/                  Constants, platform seam, access and lockdown guards, store
  Domain/                Profile, readiness, events, loot, permissions, reports, templates, diagnostics
  Sync/                  Codec, protocol, inbox and outbound queue, event and loot sync, snapshot, import/export
  UI/                    Window (AceGUI) and its view model
  Commands/              Slash commands
  Libs/                  Vendored libraries, see Libs/README.md
  Media/                 Game textures (the guild logo)
assets/                  Source artwork (not shipped), see assets/README.md
tools/                   Development helpers (image conversion, packaging, coverage gate)
tests/                   busted specs and client API stubs
docs/                    Documentation
.github/workflows/       CI and release automation
```

## Development

Lua 5.1 with [luacheck](https://github.com/lunarmodules/luacheck), [busted](https://lunarmodules.github.io/busted/), [luacov](https://lunarmodules.github.io/luacov/) and [StyLua](https://github.com/JohnnyMorganz/StyLua).

```bash
luacheck NrageAssistant tests
busted --coverage && luacov && tools/check_coverage.sh 80
stylua --check NrageAssistant tests
tools/package.sh dev
```

Every pull request runs lint, the tests with a minimum of 80% line coverage, a StyLua format check and a package build that verifies every file referenced by the TOC, `embeds.xml` and the icon is in the zip. Pull request titles must follow [Conventional Commits](https://www.conventionalcommits.org/). Dependabot keeps the workflow actions up to date. Domain logic is tested outside the game against fakes of the client API, which all goes through `NrageAssistant/Core/Platform.lua`. Work happens on `feature/*` branches with one pull request each.

### Translations

What the player reads goes through `L("English text")` (`NrageAssistant/Core/Locale.lua`): the code writes the English
text and `NrageAssistant/Locales/esES.lua` maps it to Spanish; a text with no entry is shown in English. Spanish is used when
the client is `esES` or `esMX`, English otherwise. Keep placeholders (`%d`, `%s`) in the same order, put one string literal
inside each `L(...)`, and never translate a value that is compared or sent (a status, a role, a command word). A test
fails when the code asks for a text the catalog does not have, when the catalog has one nothing asks for, or when
the placeholders differ.

## Releasing

Push a tag starting with `v`; the **Release** workflow runs the full CI first and, only if it passes, stamps the version into the TOC, zips `NrageAssistant/` and publishes a GitHub release.

```bash
git tag v0.1.0 && git push origin v0.1.0
```

Tags containing a hyphen (for example `v0.2.0-alpha.1`) are published as pre-releases. Only `NrageAssistant/` is shipped: `tests/`, `docs/` and the plan stay out of the zip.

## License

Proprietary. All rights reserved. See [LICENSE](LICENSE).
