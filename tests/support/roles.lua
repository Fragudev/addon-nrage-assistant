-- Test helper: the way a spec says "this player is a raid leader / an officer / the guild master" without repeating
-- how roles are worked out. The role is the guild rank, matched by name; the guild master is the rank index 0.
--   Roles.ranking("RL")            -> function for a platform fake's GetOwnGuildRank: rank name and rank index
--   Roles.assignments("RL", key)   -> members, rosters tables: `key` is in roster "r1" (gm and cogm have no roster)
--   Roles.RANK_NAMES               -> the in-game rank name of each role, in order of authority
-- Labels a spec may pass: GM, CoGM, Officer, RL, Roster, Member, Alter. "officer" and "Council" are the Officer rank,
-- "rl" is RL and "member" is Member. nil is a player who is not in a guild.
local Roles = {}

-- The seven in-game rank names (docs/NAV_PERMISSIONS_PLAN.md 1.1), best first. The index in this list minus one is
-- the rank index of the game.
Roles.RANK_NAMES = {
  gm = "GM",
  cogm = "CoGM",
  officer = "Oficial",
  rl = "RL",
  roster = "Roster",
  member = "Miembro",
  alter = "Alter",
}
Roles.ORDER = { "gm", "cogm", "officer", "rl", "roster", "member", "alter" }

local LABELS = {
  GM = "gm",
  gm = "gm",
  CoGM = "cogm",
  cogm = "cogm",
  Officer = "officer",
  officer = "officer",
  Council = "officer",
  council = "officer",
  RL = "rl",
  rl = "rl",
  Roster = "roster",
  roster = "roster",
  Member = "member",
  member = "member",
  Alter = "alter",
  alter = "alter",
}

-- The role id a label stands for (nil for nil or an unknown label, which counts as a plain member).
function Roles.roleOf(label)
  return label ~= nil and (LABELS[label] or "member") or nil
end

function Roles.indexOf(role)
  for index, id in ipairs(Roles.ORDER) do
    if id == role then
      return index - 1
    end
  end
  return nil
end

function Roles.ranking(label)
  return function()
    local role = Roles.roleOf(label)
    if role == nil then
      return nil
    end
    return Roles.RANK_NAMES[role], Roles.indexOf(role)
  end
end

function Roles.assignments(label, key)
  local members = {}
  local rosters = { r1 = { id = "r1", name = "Main", rev = 1, updatedAt = 1 } }
  local role = Roles.roleOf(label)
  if role ~= nil and role ~= "gm" and role ~= "cogm" then
    members[key] = { rosterId = "r1", rev = 1, updatedAt = 1 }
  end
  return members, rosters
end

return Roles
