local _, ns = ...

ns.Constants = {
  ADDON_PREFIX = "NRAGE",
  SCHEMA_VERSION = 2,

  GUILD_NAME = "Nrage",
  -- Measured on the Forever beta client (build 16001) with /nrage debug identity.
  GUILD_CLUB_ID = 22626971,
  FACTION = "Alliance",
  -- The PvP ruleset shows up in the normalized realm name (beta: "ClassicBetaPvP").
  -- Matched as a plain substring so a rename of the realm prefix does not break it.
  RULESET_REALM_MARKER = "PvP",

  -- Free-text profile fields a player can declare by hand (source = "declared").
  MANUAL_FIELDS = { role = true, main = true, notes = true },
  MAX_FIELD_LENGTH = 200,

  -- Wire protocol. Major mismatches are rejected; minor versions only add optional fields.
  PROTOCOL_MAJOR = 1,
  PROTOCOL_MINOR = 0,
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

  -- Guild rank name (lowercase) -> addon role: "member" | "rl" | "admin". Placeholder ranks until
  -- Nrage defines its own; a rank that is not listed here is treated as "member".
  RANK_ROLES = {
    gm = "admin",
    officer = "admin",
    rl = "rl",
    roster = "member",
    member = "member",
    alter = "member",
  },

  -- Guild roster cache: bounded, rebuilt in chunks so a big guild never stalls the UI.
  GUILD_ROSTER_MAX = 1000,
  GUILD_ROSTER_CHUNK = 100,
  GUILD_ROSTER_MIN_INTERVAL_SECONDS = 10,

  -- Raid events, attendance and assignments (bounded so shared data cannot grow without limit).
  EVENT_MAX = 100,
  EVENT_ATTENDANCE_MAX = 60,
  EVENT_ASSIGNMENTS_MAX = 50,
  EVENT_RETENTION_SECONDS = 90 * 24 * 3600,
  TOMBSTONE_MAX = 500,
  TOMBSTONE_TTL_SECONDS = 30 * 24 * 3600,

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

  -- Starting checklist. It only holds items that need no guild-specific numbers: level, item level
  -- and profession rules ({ check = "level" | "ilvl", min = N } / { check = "profession", ... })
  -- are supported by ReadinessService but wait for the guild to decide their thresholds.
  DEFAULT_RULES = {
    {
      id = "role", label = "Role declared", category = "role",
      evidenceMode = "manual", check = "field", field = "role",
    },
    {
      id = "consumables", label = "Consumables ready", category = "consumables",
      evidenceMode = "manual", check = "confirm",
    },
    {
      id = "enchants", label = "Enchants done", category = "enchants",
      evidenceMode = "manual", check = "confirm",
    },
  },
}
