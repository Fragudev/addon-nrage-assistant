local _, ns = ...

ns.Constants = {
  ADDON_PREFIX = "NRAGE",
  SCHEMA_VERSION = 12,

  GUILD_NAME = "Nrage",
  -- Measured on the Forever beta client (build 16001) with /nrage debug identity.
  GUILD_CLUB_ID = 22626971,
  FACTION = "Alliance",
  -- The PvP ruleset shows up in the normalized realm name (beta: "ClassicBetaPvP").
  -- Matched as a plain substring so a rename of the realm prefix does not break it.
  RULESET_REALM_MARKER = "PvP",

  -- Free-text profile fields a player can declare by hand (source = "declared").
  MANUAL_FIELDS = { role = true, role2 = true, main = true, notes = true },
  MAX_FIELD_LENGTH = 200,

  -- Wire protocol. Major mismatches are rejected; minor versions only add optional fields.
  PROTOCOL_MAJOR = 1,
  PROTOCOL_MINOR = 7,
  -- Bounds applied before anything is decoded or deserialized from the wire.
  MAX_ENCODED_BYTES = 4096,
  MAX_DECOMPRESSED_BYTES = 32768,

  -- Inbound guards: per-sender rate limit and a bounded cache of message ids already seen.
  INBOX_SEEN_LIMIT = 200,
  -- Sized for raid operations: an RL recording attendance for a whole raid sends one message per row.
  INBOX_MAX_PER_WINDOW = 60,
  INBOX_WINDOW_SECONDS = 60,
  INBOX_MAX_SENDERS = 200,

  -- Minimum time between two publications of the own profile.
  PUBLISH_COOLDOWN_SECONDS = 30,
  -- How often the profile is read again to see whether it changed and has to be published (a safety net: gear, level
  -- and profession events publish it within PUBLISH_EVENT_DEBOUNCE_SECONDS).
  PUBLISH_CHECK_SECONDS = 300,
  PUBLISH_EVENT_DEBOUNCE_SECONDS = 3,
  -- The readiness views read the character again and redraw at most this often while they are on screen.
  READINESS_REDRAW_SECONDS = 1,

  -- Where the addon role of a player comes from: the guild rank, matched by name through RANK_ROLES. The role is
  -- changed in the game, never in the addon (plan NAV_PERMISSIONS 1.1).
  ROLE_SOURCE = "rank",
  -- The guild master is always rank index 0 in GetGuildRosterInfo / GetGuildInfo (measured? see API_NOTES).
  GUILD_MASTER_RANK_INDEX = 0,

  -- Guild rank name (trimmed, lowercase) -> addon role: "gm" | "cogm" | "officer" | "rl" | "roster" | "member" |
  -- "alter". A rank that is not listed here is treated as "alter" (least privilege), so renaming a rank in the game
  -- demotes its members until this table is updated. The guild master is always "gm", whatever the rank is called.
  RANK_ROLES = {
    gm = "gm",
    cogm = "cogm",
    oficial = "officer",
    rl = "rl",
    roster = "roster",
    miembro = "member",
    alter = "alter",
  },

  -- The beta list of admins by character name is gone: nobody is an admin because of who they are, only because they
  -- hold the guild master rank. The flag stays false so a stale reference cannot turn it on (issue #25).
  BETA_ADMIN_ENABLED = false,

  -- Recipes (the Professions tab, plan 3.10). A profession list is sent in messages of at most RECIPE_CHUNK ids (a
  -- message
  -- is limited to MAX_ENCODED_BYTES); a list has at most RECIPES_MAX_PER_PROFESSION ids and RECIPE_PARTS_MAX parts. A
  -- receiver keeps at most RECIPE_PROFESSIONS_MAX professions for each of RECIPE_MEMBERS_MAX members, and at most
  -- RECIPE_STAGING_MAX half-received lists (in memory). After a profession window changes, it is scanned again
  -- RECIPE_SCAN_DELAY_SECONDS later (the client fires its events several times while the list loads).
  RECIPE_CHUNK = 150,
  RECIPES_MAX_PER_PROFESSION = 3000,
  RECIPE_PARTS_MAX = 20,
  RECIPE_ID_MAX = 10000000,
  RECIPE_PROFESSION_ID_MAX = 1000000,
  RECIPE_PROFESSIONS_MAX = 12,
  RECIPE_MEMBERS_MAX = 500,
  RECIPE_STAGING_MAX = 100,
  RECIPE_SCAN_DELAY_SECONDS = 2,
  -- After login the saved recipe lists are sent once, after a random delay in this range.
  RECIPE_LOGIN_SEND_DELAY_MIN = 30,
  RECIPE_LOGIN_SEND_DELAY_MAX = 60,
  -- The Professions tab shows at most this many recipes, and this many crafters with an "Ask" button each.
  RECIPE_RESULTS_MAX = 100,
  RECIPE_ASK_MAX = 3,

  -- Raid rosters (teams): definitions and the roster and role of each member, both set by the guild master and synced.
  ROSTERS_MAX = 20,
  ROSTER_NAME_MAX = 30,
  MEMBER_ASSIGNMENTS_MAX = 1000,
  -- A snapshot carries at most this many member assignments (scaled down with the events when it is too big).
  MEMBER_SNAPSHOT_MAX = 300,

  -- Guild roster cache: bounded, rebuilt in chunks so a big guild never stalls the UI.
  GUILD_ROSTER_MAX = 1000,
  GUILD_ROSTER_CHUNK = 100,
  GUILD_ROSTER_MIN_INTERVAL_SECONDS = 10,

  -- Snapshot for late joiners: a leader answers a SYNC_REQ by whisper with the most recent events.
  SYNC_MAX_EVENTS = 20,
  SYNC_MAX_ENCODED_BYTES = 32768,
  SYNC_MAX_DECOMPRESSED_BYTES = 262144,
  SYNC_REQUEST_COOLDOWN_SECONDS = 60,
  SYNC_SERVE_COOLDOWN_SECONDS = 60,
  SYNC_SERVED_MAX_ENTRIES = 200,
  SYNC_INBOX_MAX_PER_WINDOW = 4,
  SYNC_LOGIN_REQUEST_DELAY_MIN = 8,
  SYNC_LOGIN_REQUEST_DELAY_MAX = 20,
  SYNC_RESPONSE_DELAY_MIN = 1,
  SYNC_RESPONSE_DELAY_MAX = 10,

  -- Text import/export of raid data. LibDeflate has no output limit, so the encoded input is capped
  -- first (a deflate stream expands at most ~1000x) and the result is capped again afterwards.
  IMPORT_MAX_ENCODED_BYTES = 32768,
  IMPORT_MAX_DECOMPRESSED_BYTES = 262144,
  IMPORT_MAX_ITEMS = 3000,

  -- Raid events, attendance and assignments (bounded so shared data cannot grow without limit).
  EVENT_MAX = 100,
  EVENT_ATTENDANCE_MAX = 60,
  EVENT_ASSIGNMENTS_MAX = 50,
  EVENT_RETENTION_SECONDS = 90 * 24 * 3600,
  TOMBSTONE_MAX = 500,
  TOMBSTONE_TTL_SECONDS = 30 * 24 * 3600,

  -- The guild logo as a game texture (TGA, no extension), and the minimap button around it.
  LOGO_TEXTURE = "Interface\\AddOns\\NrageAssistant\\Media\\nrage_logo",
  MINIMAP_DEFAULT_ANGLE = 225,
  MINIMAP_RADIUS_MARGIN = 5,

  -- Assignment templates, kept on this client only.
  TEMPLATES_MAX = 20,
  TEMPLATE_NAME_MAX = 40,

  -- Loot council sessions, per event (bounded like everything shared).
  LOOT_SESSIONS_MAX = 40,
  LOOT_CANDIDATES_MAX = 40,
  LOOT_VOTES_MAX = 30,
  -- "open": council members see who voted for whom while the session is open. Votes are always
  -- revealed once the session is closed. The guild chose open votes (issue #23). "secret" only hides the counts in
  -- the window until the session closes: the votes still travel over the guild channel, which is not confidential,
  -- so it is not a real secret and would need a different message flow (votes sent only to the leader).
  VOTE_VISIBILITY = "open",
  -- The loot popup passes for you after this long without an answer (local only: nothing is sent).
  LOOT_RESPONSE_TIMEOUT_SECONDS = 60,

  -- PvP counters: how many days of per-day buckets are kept in the saved data of a character.
  PVP_DAILY_DAYS = 30,
  -- The honour counter can update a moment after its event; it is read once more after this delay.
  PVP_RECHECK_SECONDS = 0.5,
  -- Killing blows come from COMBAT_LOG_EVENT_UNFILTERED, which Midnight protects: registering it is the suspected
  -- cause of the "blocked from an action only available to the Blizzard UI" dialog seen at login, and a pcall does
  -- not hide that dialog. So it stays off, and killing blows are not counted, until it is measured that Forever
  -- allows it (issue #99). Honourable kills do not need it.
  PVP_COMBAT_LOG_ENABLED = false,
  -- PvP sync. A counter in a PVP_STATS message is a whole number in 0..PVP_MAX_KILLS. The receiver accepts at most
  -- PVP_MAX_KILLS_PER_HOUR new honourable kills per hour since the previous record of that member (never less than
  -- one hour's worth), which limits a modified client; it cannot prevent one.
  PVP_MAX_KILLS = 1000000,
  PVP_MAX_KILLS_PER_HOUR = 300,
  -- The own counters are sent at most this often (a change waits for the next slot, a burst of kills is one message).
  PVP_SYNC_INTERVAL_SECONDS = 60,
  -- A change is sent no sooner than this, so the two readings of one kill (PVP_RECHECK_SECONDS) become one message.
  PVP_SYNC_MIN_DELAY_SECONDS = 2,
  -- After login the own counters are sent once, after a random delay in this range.
  PVP_LOGIN_SEND_DELAY_MIN = 8,
  PVP_LOGIN_SEND_DELAY_MAX = 20,
  -- A snapshot carries at most this many PvP records (the most recently updated) and this many admin resets.
  PVP_SNAPSHOT_MAX = 100,
  -- The ranking draws at most this many rows (one widget per cell).
  PVP_RANKING_ROWS_MAX = 100,
  -- A redraw of the PvP tab because of a received record waits at least this long after the previous one.
  PVP_REDRAW_SECONDS = 1,
  -- Guild kill feed (PVP_KILL). A kill event within PVP_FEED_MERGE_SECONDS of another one for the same victim
  -- is the same kill (honour credit and killing blow are two events), and an entry waits that long before it
  -- is sent so the second event can still join it. At most PVP_FEED_MAX_PER_MINUTE entries are sent in any
  -- rolling minute (the rest are dropped, never queued); a victim is at most PVP_FEED_VICTIM_MAX bytes of text.
  -- At most PVP_FEED_MAX own entries are kept in memory, never saved.
  PVP_FEED_MERGE_SECONDS = 5,
  PVP_FEED_MAX_PER_MINUTE = 5,
  PVP_FEED_MAX = 50,
  PVP_FEED_VICTIM_MAX = 40,
  -- PvP ranks, lowest first, as in the Classic honour system. `kills` is the total of honourable kills (open
  -- world plus battleground) a rank needs; killing blows do not count. Names and thresholds can be changed
  -- freely, and the list can be longer or shorter, as long as the thresholds keep going up. The rank is worked
  -- out on each client and never sent. PLACEHOLDER thresholds until the guild decides them.
  PVP_RANKS = {
    { name = "Private", kills = 0 },
    { name = "Corporal", kills = 25 },
    { name = "Sergeant", kills = 75 },
    { name = "Master Sergeant", kills = 150 },
    { name = "Sergeant Major", kills = 300 },
    { name = "Knight", kills = 500 },
    { name = "Knight-Lieutenant", kills = 800 },
    { name = "Knight-Captain", kills = 1200 },
    { name = "Knight-Champion", kills = 1700 },
    { name = "Lieutenant Commander", kills = 2300 },
    { name = "Commander", kills = 3000 },
    { name = "Marshal", kills = 3800 },
    { name = "Field Marshal", kills = 4700 },
    { name = "Grand Marshal", kills = 6000 },
  },

  -- PvP seasons (docs/PVP_MISSIONS_PLAN.md). Text and number bounds of the records that travel with PVP_SEASON,
  -- PVP_MISSION, PVP_PRIZES, PVP_OFFICER, PVP_CLAIM, PVP_GRANT, PVP_VOID, PVP_REJECT, PVP_DELIVERY and PVP_FINAL.
  PVP_SEASON_NAME_MAX = 40,
  PVP_MISSION_TITLE_MAX = 40,
  PVP_MISSION_DESC_MAX = 100,
  PVP_MISSION_POINTS_MAX = 1000,
  PVP_MISSION_COUNT_MAX = 500,
  PVP_MISSION_ZONES_MAX = 5,
  PVP_MISSION_PER_PLAYER_MAX = 10,
  PVP_REASON_MAX = 100,
  PVP_NOTE_MAX = 100,
  PVP_PRIZE_ENTRIES_MAX = 5,
  PVP_PRIZE_GOLD_MAX = 100000,
  PVP_PRIZE_ITEM_COUNT_MAX = 200,
  PVP_PRIZE_ITEM_NAME_MAX = 60,
  PVP_OFFICER_INTERVALS_MAX = 10,
  -- A claim carries at most this many evidence rows (it has to fit one guild message), and a claimant announces the
  -- claims still pending again after login and then every PVP_CLAIM_REANNOUNCE_SECONDS.
  PVP_CLAIM_EVIDENCE_MAX = 60,
  PVP_CLAIM_REANNOUNCE_SECONDS = 600,
  PVP_CLAIM_SUMMARY_MAX = 20,
  PVP_FINAL_STANDINGS_MAX = 100,
  -- Receiver side caps. Over one of them a new record is refused; a grant is never evicted to make room.
  PVP_GRANTS_MAX = 3000,
  PVP_VOIDS_MAX = 3000,
  PVP_REJECTS_MAX = 3000,
  PVP_QUEUE_MAX = 300,
  -- One player has at most this many claims waiting in a queue, so a single client cannot fill it.
  PVP_QUEUE_PER_PLAYER_MAX = 20,
  -- Positions 1 to 10 are the only ones that get a prize, so a season has at most this many deliveries.
  PVP_DELIVERIES_MAX = 10,
  PVP_MISSIONS_MAX = 50,
  PVP_SEASONS_MAX = 60,
  PVP_FINALS_MAX = 50,
  PVP_OFFICERS_MAX = 20,
  -- Ledger catch-up (PVP_LEDGER_REQ / PVP_LEDGER_DATA): a client asks after login and when a season becomes active;
  -- a trusted relay answers by whisper, at most once per requester per cooldown, in pages that fit the snapshot
  -- limit and hold at most PVP_LEDGER_PAGE_ITEMS items.
  PVP_LEDGER_REQUEST_COOLDOWN_SECONDS = 60,
  PVP_LEDGER_SERVE_COOLDOWN_SECONDS = 60,
  PVP_LEDGER_PAGE_ITEMS = 400,
  PVP_LEDGER_PAGES_MAX = 100,
  -- Prize tiers, best first: the keys of prizes.tiers and of a delivery. A position 1..10 maps to exactly one tier.
  PVP_PRIZE_TIERS = { "1", "2", "3", "4-6", "7-10" },
  -- Points are never spent; at least this many are needed to be ranked (and to get a prize).
  PVP_MIN_POINTS = 1,

  -- PvP missions: detection (docs/PVP_MISSIONS_PLAN.md, sections 2 and 5).
  -- The own kill log of a character keeps at most PVP_MISSION_KILLS_MAX rows (oldest dropped first). A victim counts at
  -- most PVP_VICTIM_DAILY_CAP times per server day across all missions. A battleground win is logged once per
  -- instance; PVP_BG_WIN_DEDUPE_SECONDS covers a reload inside the same battleground.
  PVP_MISSION_KILLS_MAX = 2000,
  PVP_VICTIM_DAILY_CAP = 3,
  PVP_BG_WIN_DEDUPE_SECONDS = 1800,
  -- The unit cache (victim class and race) lives in memory only: at most PVP_UNIT_CACHE_MAX names, least recently
  -- seen dropped first, and an entry older than PVP_UNIT_CACHE_TTL seconds is ignored.
  PVP_UNIT_CACHE_MAX = 500,
  PVP_UNIT_CACHE_TTL = 3600,
  -- The enemy sets of the distinct = "class" | "race" | "class_race" missions: the Horde side, as upper-case file
  -- tokens (the second return of UnitClass / UnitRace, upper-cased). The guild is Alliance (plan, section 7).
  PVP_ENEMY_CLASSES = { "DRUID", "HUNTER", "MAGE", "PRIEST", "ROGUE", "SHAMAN", "WARLOCK", "WARRIOR" },
  PVP_ENEMY_RACES = { "ORC", "SCOURGE", "TAUREN", "TROLL" },
  -- The zones an admin can pick for a mission: uiMapIds of the capitals and contested zones, with the English name
  -- (a key for L()). The ids are from the Classic map tables and are TO BE MEASURED on Forever (plan, M1); a zone
  -- whose id turns out wrong is fixed here, nothing else depends on the list.
  PVP_MISSION_ZONES = {
    { mapId = 1454, nameKey = "Orgrimmar" },
    { mapId = 1453, nameKey = "Stormwind City" },
    { mapId = 1455, nameKey = "Ironforge" },
    { mapId = 1457, nameKey = "Darnassus" },
    { mapId = 1456, nameKey = "Thunder Bluff" },
    { mapId = 1458, nameKey = "Undercity" },
    { mapId = 1434, nameKey = "Stranglethorn Vale" },
    { mapId = 1424, nameKey = "Hillsbrad Foothills" },
    { mapId = 1416, nameKey = "Alterac Mountains" },
    { mapId = 1440, nameKey = "Ashenvale" },
    { mapId = 1417, nameKey = "Arathi Highlands" },
  },

  -- Guild blacklist: names and short free-text reasons, shared with the guild. A snapshot carries at most
  -- BLACKLIST_SNAPSHOT_MAX entries (the most recently updated) and as many removals (the newest). The tab redraws
  -- because of a received entry at most once per BLACKLIST_REDRAW_SECONDS.
  BLACKLIST_MAX = 200,
  BLACKLIST_NAME_MAX = 40,
  BLACKLIST_REASON_MAX = 100,
  BLACKLIST_SNAPSHOT_MAX = 200,
  BLACKLIST_REDRAW_SECONDS = 1,

  -- Layers. A layer is read from creature GUIDs (LayerModel); a new one is confirmed after LAYER_CONFIRM_READINGS
  -- readings from different spawns, and a reading or a received state is stale after LAYER_STATE_TTL. The own layer
  -- is sent when it changes and every LAYER_REPUBLISH_SECONDS, at most once per LAYER_PUBLISH_MIN_SECONDS.
  -- "Unmeasured" values (plan sections 1.1 and 3.2) are defaults until they are measured in game.
  LAYER_CONFIRM_READINGS = 2,
  LAYER_READINGS_MAX = 12,
  LAYER_STATE_TTL = 900,
  LAYER_REPUBLISH_SECONDS = 300,
  LAYER_PUBLISH_MIN_SECONDS = 30,
  LAYER_MAP_MAX = 9999,
  LAYER_ID_MAX = 2147483647,
  -- Swap flow timeouts (seconds) and the age after which a swap whose close message was lost is dropped.
  LAYER_REQUEST_TIMEOUT = 60,
  LAYER_ASSIGN_TIMEOUT = 90,
  LAYER_CONFIRM_TIMEOUT = 120,
  LAYER_SWAP_MAX_AGE = 300,
  -- A swap popup that cannot be shown during a lockdown tries again after this long.
  LAYER_POPUP_RETRY_SECONDS = 5,
  -- A redraw of the Layers tab because of a received state waits at least this long after the previous one.
  LAYER_REDRAW_SECONDS = 1,
  -- A party holds five players.
  LAYER_PARTY_SIZE = 5,

  -- Guild map. Positions travel on their own addon prefix (not through the NRAGE envelope): a message is
  -- "P1:<map>:<x>:<y>" of at most POSITION_MAX_BYTES bytes, x and y in 0..10000. The own position is checked every
  -- POSITION_TICK_SECONDS and sent when it moved more than POSITION_MIN_MOVE units (0.2 % of the zone), when the map
  -- changed, or after POSITION_HEARTBEAT_SECONDS. A received position is dropped after POSITION_TTL seconds; at most
  -- POSITION_DIRECTORY_MAX members are kept and POSITION_INBOX_MAX_PER_WINDOW messages per sender are read per
  -- INBOX_WINDOW_SECONDS.
  POSITION_PREFIX = "NRAGEPOS",
  POSITION_MAX_BYTES = 32,
  POSITION_TICK_SECONDS = 5,
  POSITION_HEARTBEAT_SECONDS = 20,
  POSITION_MIN_MOVE = 20,
  POSITION_TTL = 60,
  POSITION_DIRECTORY_MAX = 200,
  POSITION_INBOX_MAX_PER_WINDOW = 30,
  POSITION_SCALE = 10000,
  -- The map pins are redrawn at most once per this many seconds.
  POSITION_REDRAW_SECONDS = 1,

  -- Received data kept in memory or SavedVariables.
  ROSTER_MAX_ENTRIES = 500,
  -- A received profile older than this is shown as stale, never as current.
  ROSTER_STALE_SECONDS = 7 * 24 * 3600,
  PEERS_MAX_ENTRIES = 200,

  -- HELLO: sent shortly after login, and once more (jittered, rate limited) when a new peer shows up.
  HELLO_LOGIN_DELAY_MIN = 2,
  HELLO_LOGIN_DELAY_MAX = 10,
  HELLO_REPLY_DELAY_MIN = 1,
  HELLO_REPLY_DELAY_MAX = 8,
  HELLO_REPLY_COOLDOWN_SECONDS = 30,
  QUEUE_FLUSH_SECONDS = 1,

  -- Outbound queue: bounded, expiring, and jittered when it drains after a lockdown.
  QUEUE_MAX_ITEMS = 100,
  QUEUE_TTL_SECONDS = 120,
  QUEUE_MAX_JITTER_SECONDS = 5,

  -- The guild's own readiness rules (admins set them, see ReadinessRules): at most this many in one set.
  READINESS_RULES_MAX = 30,

  -- Starting checklist (guild decision #32). Level 60 is required; the item level minimum is a
  -- placeholder of 1 (nothing is excluded) until the guild sets a real threshold. Profession rules
  -- ({ check = "profession", profession = "...", min = N }) are supported but not yet used.
  DEFAULT_RULES = {
    {
      id = "level",
      label = "Level 60",
      category = "level",
      evidenceMode = "observed",
      check = "level",
      min = 60,
    },
    {
      id = "ilvl",
      label = "Item level",
      category = "gear",
      evidenceMode = "observed",
      check = "ilvl",
      min = 1,
    },
    {
      id = "role",
      label = "Role declared",
      category = "role",
      evidenceMode = "manual",
      check = "field",
      field = "role",
    },
    {
      id = "consumables",
      label = "Consumables ready",
      category = "consumables",
      evidenceMode = "manual",
      check = "confirm",
    },
    {
      id = "enchants",
      label = "Enchants done",
      category = "enchants",
      evidenceMode = "manual",
      check = "confirm",
    },
  },
}
