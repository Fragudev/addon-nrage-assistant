# Groups minimap icon — plan

Objective: a small icon on the edge of the minimap, like the unread mail icon, shown while another member has an
open group. Branch `feat/groups-minimap-icon`. Test runner: busted on Lua 5.1 (LuaJIT), luacheck, stylua.

## Specs

- **S1. When it shows.** The icon is visible only when all of these hold: the Groups module is enabled
  (`ns.modules:IsEnabled("groups")`, or no `ns.modules`), the board exists (`ns.lfgBoard`), and at least one open post
  on the board (`ns.lfgBoard:Query()`) belongs to someone other than the player (`ns.Platform.GetIdentityKey()`,
  compared with `ns.Validate.NameKey`). The player's own post never counts. Otherwise it is hidden. User decision
  (default chosen in the session, L3): any open group of another member counts, not only the ones the player can join.
- **S2. Look.** Mail-icon style: a 31x31 button on the minimap edge with the dark disc
  (`Interface\Minimap\UI-Minimap-Background`), the icon `Interface\Icons\INV_Misc_GroupNeedMore` (20x20, cropped with
  `SetTexCoord(0.08, 0.92, 0.08, 0.92)`) and the gold ring (`Interface\Minimap\MiniMap-TrackingBorder`), the same
  layout as `UI/MinimapButton.lua`. A small count of open groups (font `NumberFontNormalSmall`, bottom right) when
  there are 2 or more.
- **S3. Position.** It can be dragged around the minimap edge like the addon button. Its angle is saved account-wide
  in `db.global.settings.minimapGroups = { angle = degrees }` (new key, nothing existing changes). Default angle
  `Constants.MINIMAP_GROUPS_DEFAULT_ANGLE = 160`. Reuse `MinimapButton.NormalizeAngle`, `MinimapButton.Position` and
  `MinimapButton.AngleFromCursor`; do not copy them. An invalid saved angle falls back to the groups default, not to
  the addon button default.
- **S4. Tooltip.** On hover, `GameTooltip` shows, in the addon language:
  - title: `Open groups (%d)`
  - one line per post of another member, newest first, at most 5: `%s: %s - %s` (kind label, title, leader), with the
    needed roles after it as ` (Tank, Heal, DPS)` listing only roles with need > 0; a post the player can apply to
    right now (`ns.lfgService:CanApply(pid)` with no role returns true — see S5) is drawn green
    (0.25, 1, 0.25), the others white
  - when there are more than 5: `and %d more`
  - last line, grey: `Click to open Groups`
  All texts from the guild (title, leader) are escaped with `ViewModel.Escape`.
- **S5. Can apply.** A post counts as joinable when `canApply(pid)` is true. The view model receives `canApply` as a
  function and never calls the service directly; the frame passes
  `function(pid) return ns.lfgService and ns.lfgService:CanApply(pid) end` wrapped in `pcall` (false on error).
- **S6. Click.** Left click opens the window on the Groups tab: `ns.UI.OpenTab("groups")`.
- **S7. Refresh.** The icon is updated whenever the board changes (`UI.LfgChanged`, which `LfgService` calls on every
  post, close and sweep), when a module is switched on or off (`UI.ModulesChanged`), and once after it is created.
  Refreshing is cheap and never errors when the board or the service is missing.
- **S8. Docs.** USER_GUIDE "Groups" section and the README Groups bullet mention the icon. English only.

## Interface between the units (fixed — both units code against it)

`ViewModel.GroupsMinimapView(state)` in `UI/ViewModelGroups.lua`:

```lua
-- state = { enabled = boolean (module on and board present), posts = LfgBoard:Query() result (may be nil),
--           ownName = string or nil, canApply = function(pid) -> boolean (may be nil: nothing is joinable) }
-- returns {
--   shown = boolean,            -- S1
--   count = number,             -- posts of others
--   countText = string or nil,  -- tostring(count) when count >= 2, "9+" above 9, else nil
--   title = string,             -- "Open groups (%d)"
--   lines = { { text = string, joinable = boolean } },  -- S4, at most 5
--   more = string or nil,       -- "and %d more"
--   hint = string,              -- "Click to open Groups"
-- }
```

## Tasks

| ID | Specs | Route | Owner | Edit surface |
|----|-------|-------|-------|--------------|
| T1 | S1, S4, S5 | delegated (parallel unit) | Haiku | `NrageAssistant/UI/ViewModelGroups.lua`, `NrageAssistant/Locales/esES.lua`, `tests/view_model_groups_spec.lua` |
| T2 | S2, S3, S6, S7, S8 | delegated (parallel unit) | Sonnet | `NrageAssistant/UI/GroupsMinimapIcon.lua` (new), `NrageAssistant/NrageAssistant.toc`, `NrageAssistant/Core/Constants.lua`, `NrageAssistant/Core/Init.lua`, `NrageAssistant/UI/Main.lua`, `tests/groups_minimap_icon_spec.lua` (new), `docs/USER_GUIDE.md`, `README.md` |
| T3 | all | inline | parent | review, full suite, PR, release |

Writer trigger: two independent units with disjoint edit surfaces, launched together (parallelism).

## Log

- L1 (2026-11-11, user): "Para cuando haya grupos disponibles en el addon, quiero que haya un icono en el minimapa,
  estilo a cuando tienes un correo sin leer, es posible?"
- L2 (2026-11-11, user): "Me gusta la idea del icono propio, planéala, mándala a haiku y sonnet que la implementen,
  revisa el resultado, abre pr, mergea en verde y publica versión"
- L3 (2026-11-11): the open question (any open group vs only joinable ones) was not answered; default: any open group
  of another member shows the icon, joinable ones are highlighted in the tooltip.
- L4 (2026-11-11): T1 (Haiku) and T2 (Sonnet) done; parent review found no blockers. Full suite 3824 successes,
  luacheck 0/0, stylua clean. The frame, drag, tooltip and click are not verified in game.
- L5 (2026-11-11, user): "no veo nada en el minimapa, podriamos hacer que no depende del minimapa por la gente que
  utiliza uis completas como el ellesmere ui, podriamos hacer que salga anclado a algún sitio". S2 and S3 change: the
  icon is now `UI/GroupsIcon.lua`, a child of UIParent anchored by its top right corner to the top right of the screen
  (default offsets -250, -30), draggable anywhere and clamped to the screen; offsets saved in
  `db.global.settings.groupsIcon = { x, y }`. The old `minimapGroups` key is ignored.
