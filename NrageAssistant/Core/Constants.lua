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
}
