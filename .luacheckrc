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
  "C_Item",
  "GetInventoryItemLink",
  "GetLocale",
  "GetItemIcon",
  "GetItemInfo",
  "GetItemInfoInstant",
  "GetGuildRosterInfo",
  "GetNumGuildMembers",
  "C_Spell",
  "CreateFont",
  "GetPhysicalScreenSize",
  "STANDARD_TEXT_FONT",
  "C_Timer",
  "C_TradeSkillUI",
  "ChatFrameUtil",
  "ChatFrame_OpenChat",
  "GetLootSlotInfo",
  "GetLootSlotLink",
  "GetNumLootItems",
  "GetSpellInfo",
  "IsGuildLeader",
  "ChatTypeInfo",
  "CombatLogGetCurrentEventInfo",
  "GetNumGroupMembers",
  "GetRaidRosterInfo",
  "IsInGroup",
  "IsInRaid",
  "PlaySound",
  "RaidNotice_AddMessage",
  "RaidWarningFrame",
  "SOUNDKIT",
  "GetPVPLifetimeStats",
  "GetPVPSessionStats",
  "IsInInstance",
  "UnitBuff",
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
  "BackdropTemplateMixin",
  "Minimap",
  "LibStub",
  "time",
  "UIParent",
  "UISpecialFrames",
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

-- The translation catalogs hold whole sentences as keys, which do not wrap.
files["NrageAssistant/Locales/**"] = { max_line_length = false }
