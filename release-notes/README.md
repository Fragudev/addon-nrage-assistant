# Release notes

Each release tag needs a file named after it, for example `v0.1.0-beta.8.md`. The release
workflow publishes it as the changelog on GitHub and CurseForge (Markdown), and stops before
publishing anything when the file is missing.

Follow the style of the existing notes:

- `# Nrage Assistant — <title> (<version>)` heading, then a short intro.
- `## ✨ Features` with one `###` group per area (Profile, Raid events, PvP, ...).
- Short, player-facing bullets. Leave out tooling, CI and refactors.
