local _, ns = ...

-- Gate: the addon only activates for Nrage members on the Alliance side.
-- Ruleset (PvP) is not checked yet; the identifier is still to be measured in phase 0.
local AccessGuard = {}

-- Returns true, or false plus a reason code:
-- "not_in_guild" | "wrong_guild" | "wrong_faction"
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

  return true
end

ns.AccessGuard = AccessGuard
