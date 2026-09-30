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
