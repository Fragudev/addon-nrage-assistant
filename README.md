# Nrage Assistant

Private World of Warcraft: Forever addon for guild coordination and raid readiness, built exclusively for the **Nrage** guild (Alliance, PvP ruleset).

> **Status:** early development. The addon currently loads, initializes its saved data and answers `/nrage`.

## Access

This addon is for Nrage members only:

- It is distributed privately through this repository's releases; it is not published on CurseForge, Wago or any other public site.
- Do not share the addon files or release zips outside the guild.
- Planned: the addon disables itself for characters outside Nrage (Alliance, PvP ruleset), and guild data is only synchronized with verified guild members.

## Installation

1. Open the repository's **Releases** page and download the latest `NrageAssistant-<version>.zip`.
2. Extract it into your addons folder so the result is:
   ```text
   World of Warcraft/<forever client folder>/Interface/AddOns/NrageAssistant/NrageAssistant.toc
   ```
3. Restart the game or run `/reload`, and make sure **Nrage Assistant** is enabled in the AddOns list.

## Usage

| Command | Description |
|---|---|
| `/nrage` | Show the installed version |

## Repository layout

```text
NrageAssistant/          Addon files (the only folder shipped in release zips)
.github/workflows/       Release automation
```

## Releasing

Push a tag starting with `v`; the **Release** workflow stamps the version into the TOC, zips `NrageAssistant/` and publishes a GitHub release.

```bash
git tag v0.1.0 && git push origin v0.1.0
```

Tags containing a hyphen (for example `v0.2.0-alpha.1`) are published as pre-releases.

## License

Proprietary. All rights reserved. See [LICENSE](LICENSE).
