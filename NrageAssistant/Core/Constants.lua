local _, ns = ...

ns.Constants = {
  ADDON_PREFIX = "NRAGE",
  SCHEMA_VERSION = 1,

  GUILD_NAME = "Nrage",
  -- Pending phase 0 measurement: run `/nrage debug identity` as a guild member and
  -- set the value of C_Club.GetGuildClubId(). While nil, AccessGuard falls back to GUILD_NAME.
  GUILD_CLUB_ID = nil,
  FACTION = "Alliance",
}
