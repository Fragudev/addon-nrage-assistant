-- Test helper: the way a spec says "this player is a raid leader / a council member / the guild master" without
-- repeating how roles are worked out. Roles come from assignments (members), with the guild master as the rank index 0.
--   Roles.ranking("RL")            -> function for a platform fake's GetOwnGuildRank: name and rank index
--   Roles.assignments("RL", key)   -> members, rosters tables: `key` holds the role of that rank in roster "r1"
-- Rank labels: "GM" and "officer" are the guild master (admin); "RL", "Council" and "Member" are assigned roles; nil is
-- a player who is not in a guild.
local Roles = {}

local ADMIN = { GM = true, gm = true, officer = true, Officer = true }
local ASSIGNED = {
  RL = "rl",
  rl = "rl",
  Council = "council",
  council = "council",
  Member = "member",
  member = "member",
}

function Roles.ranking(rank)
  return function()
    if rank == nil then
      return nil
    end
    return rank, ADMIN[rank] and 0 or 3
  end
end

function Roles.assignments(rank, key)
  local members = {}
  local rosters = { r1 = { id = "r1", name = "Main", rev = 1, updatedAt = 1 } }
  if rank ~= nil and not ADMIN[rank] then
    members[key] = { role = ASSIGNED[rank] or "member", rosterId = "r1", rev = 1, updatedAt = 1 }
  end
  return members, rosters
end

return Roles
