local _, ns = ...

-- Gate: the addon only activates for Nrage members on the Alliance side of the PvP ruleset.
local AccessGuard = {}

-- Returns true, or false plus a reason code:
-- "not_in_guild" | "wrong_guild" | "wrong_faction" | "wrong_ruleset"
function AccessGuard.Evaluate(platform, constants)
  if not platform.IsInGuild() then
    return false, "not_in_guild"
  end

  if constants.GUILD_CLUB_ID then
    if platform.GetGuildClubId() ~= constants.GUILD_CLUB_ID then
      return false, "wrong_guild"
    end
  elseif platform.GetGuildName() ~= constants.GUILD_NAME then
    return false, "wrong_guild"
  end

  if platform.GetFaction() ~= constants.FACTION then
    return false, "wrong_faction"
  end

  local realm = platform.GetRealmName()
  if not realm or not realm:find(constants.RULESET_REALM_MARKER, 1, true) then
    return false, "wrong_ruleset"
  end

  return true
end

ns.AccessGuard = AccessGuard
