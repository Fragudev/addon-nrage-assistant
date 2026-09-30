std = "lua51"

-- Third-party code, vendored unmodified.
exclude_files = { "NrageAssistant/Libs/**" }
max_line_length = 120

-- Addon entry files receive (addonName, ns) via varargs and write SavedVariables.
globals = {
  "NrageAssistantDB",
  "SLASH_NRAGE1",
  "SlashCmdList",
}

-- WoW client API used by the addon. Extend as new APIs are adopted.
read_globals = {
  "C_AddOns",
  "C_ChatInfo",
  "C_Club",
  "C_GuildInfo",
  "GetGuildRosterInfo",
  "GetNumGuildMembers",
  "C_Timer",
  "CreateFrame",
  "date",
  "GetTime",
  "GetAverageItemLevel",
  "GameFontNormalLarge",
  "GameTooltip",
  "GetBuildInfo",
  "GetCursorPosition",
  "GetGuildInfo",
  "GetNormalizedRealmName",
  "GetProfessionInfo",
  "GetProfessions",
  "GetServerTime",
  "IsInGuild",
  "Minimap",
  "LibStub",
  "time",
  "UnitClass",
  "UnitFactionGroup",
  "UnitGUID",
  "UnitLevel",
  "UnitName",
}

files["tests/"] = {
  std = "+busted",
  globals = { "_G" },
}
