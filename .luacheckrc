std = "lua51"
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
  "C_Timer",
  "CreateFrame",
  "date",
  "GetTime",
  "GetBuildInfo",
  "GetGuildInfo",
  "GetNormalizedRealmName",
  "IsInGuild",
  "UnitFactionGroup",
}

files["tests/"] = {
  std = "+busted",
  globals = { "_G" },
}
