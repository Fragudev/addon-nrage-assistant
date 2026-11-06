local function load_board()
  local ns = {}
  for _, path in ipairs({ "Core/Constants", "Core/Validate", "Domain/LfgBoard" }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_board()
local Constants = ns.Constants

local function open(overrides)
  local payload = {
    pid = "p-1",
    rev = 1,
    s = "open",
    kind = "dungeon",
    title = "Deadmines",
    needs = { tank = 1, heal = 1, dps = 2 },
    members = 1,
  }
  for k, v in pairs(overrides or {}) do
    payload[k] = v
  end
  return payload
end

local function closed(rev, pid)
  return { pid = pid or "p-1", rev = rev, s = "closed", o = "full" }
end

local function build()
  local env = { clock = 100, left = {} }
  env.board = ns.LfgBoard.New({
    now = function()
      return env.clock
    end,
    isMember = function(name)
      if env.memberFails then
        error("roster")
      end
      return not env.left[name]
    end,
  })
  return env
end

describe("LfgBoard", function()
  local env

  before_each(function()
    env = build()
  end)

  it("keeps a post per sender with the fields of the payload and the receiver's clock", function()
    assert.is_true(env.board:Apply("Ann", open({ minLevel = 15, note = "hi" })))
    local post = env.board:Get("Ann")
    assert.are.equal("Ann", post.owner)
    assert.are.equal("p-1", post.pid)
    assert.are.equal("open", post.state)
    assert.are.equal("Deadmines", post.title)
    assert.are.same({ tank = 1, heal = 1, dps = 2 }, post.needs)
    assert.are.equal(15, post.minLevel)
    assert.are.equal("hi", post.note)
    assert.are.equal(100, post.lastSeen)
    assert.are.equal(0, post.age)
  end)

  it("keys the sender like a name, so a case or space difference is the same member", function()
    env.board:Apply("Yonemon Gg", open())
    assert.is_truthy(env.board:Get("yonemongg"))
    env.board:Apply("YONEMON GG", open({ pid = "p-2" }))
    assert.are.equal(1, env.board.count)
  end)

  it("replaces the post with a higher rev, and the age keeps counting from the first message", function()
    env.board:Apply("Ann", open())
    env.clock = 130
    assert.is_true(env.board:Apply("Ann", open({ rev = 2, title = "Wailing Caverns" })))
    local post = env.board:Get("Ann")
    assert.are.equal("Wailing Caverns", post.title)
    assert.are.equal(2, post.rev)
    assert.are.equal(30, post.age)
  end)

  it("only refreshes lastSeen on an equal rev", function()
    env.board:Apply("Ann", open())
    env.clock = 150
    assert.is_true(env.board:Apply("Ann", open({ title = "Other" })))
    local post = env.board:Get("Ann")
    assert.are.equal("Deadmines", post.title)
    assert.are.equal(150, post.lastSeen)
    assert.are.equal(50, post.age)
  end)

  it("drops a lower rev", function()
    env.board:Apply("Ann", open({ rev = 5 }))
    local ok, reason = env.board:Apply("Ann", open({ rev = 4, title = "Old" }))
    assert.is_false(ok)
    assert.are.equal("stale", reason)
    assert.are.equal("Deadmines", env.board:Get("Ann").title)
  end)

  it("replaces the post with a different pid from the same sender, whatever its rev", function()
    env.board:Apply("Ann", open({ rev = 9 }))
    env.clock = 120
    assert.is_true(env.board:Apply("Ann", open({ pid = "p-2", rev = 1, title = "New" })))
    local post = env.board:Get("Ann")
    assert.are.equal("p-2", post.pid)
    assert.are.equal(0, post.age)
    assert.are.equal(1, env.board.count)
  end)

  it("keeps a closed post as a tombstone: hidden from the list, and a late open cannot revive it", function()
    env.board:Apply("Ann", open({ rev = 2 }))
    assert.is_true(env.board:Apply("Ann", closed(3)))
    assert.are.same({}, env.board:Query())
    assert.are.equal(0, env.board:OpenCount())
    local tomb = env.board:Get("Ann")
    assert.are.equal("closed", tomb.state)
    assert.are.equal("full", tomb.outcome)
    local ok, reason = env.board:Apply("Ann", open({ rev = 2 }))
    assert.is_false(ok)
    assert.are.equal("stale", reason)
    assert.are.same({}, env.board:Query())
  end)

  it("forgets a tombstone after the time to live", function()
    env.board:Apply("Ann", closed(2))
    env.clock = env.clock + Constants.LFG_POST_TTL + 1
    assert.is_nil(env.board:Get("Ann"))
    assert.are.equal(1, env.board:Prune())
    assert.are.equal(0, env.board.count)
  end)

  it("drops a post nobody repeated for the time to live, and a repeat keeps it", function()
    env.board:Apply("Ann", open())
    env.board:Apply("Bob", open())
    env.clock = env.clock + Constants.LFG_POST_TTL - 1
    env.board:Apply("Bob", open())
    env.clock = env.clock + 2
    assert.is_nil(env.board:Get("Ann"))
    assert.are.same({ "Bob" }, { env.board:Query()[1].owner })
    assert.are.equal(1, env.board:Prune())
    assert.are.equal(1, env.board.count)
  end)

  it("is bounded, and evicts stale posts before refusing a new sender", function()
    for index = 1, Constants.LFG_BOARD_MAX do
      assert.is_true(env.board:Apply("M" .. index, open()))
    end
    local ok, reason = env.board:Apply("OneMore", open())
    assert.is_false(ok)
    assert.are.equal("limit", reason)
    -- A sender who already has a post can still change it.
    assert.is_true(env.board:Apply("M1", open({ rev = 2 })))
    env.clock = env.clock + Constants.LFG_POST_TTL + 1
    assert.is_true(env.board:Apply("OneMore", open()))
    assert.are.equal(1, env.board.count)
  end)

  it("refuses a sender the roster does not know, and one whose roster check raises", function()
    env.left.Ann = true
    local ok, reason = env.board:Apply("Ann", open())
    assert.is_false(ok)
    assert.are.equal("not_member", reason)
    env.memberFails = true
    assert.are.equal("not_member", select(2, env.board:Apply("Bob", open())))
    assert.are.equal(0, env.board.count)
  end)

  it("hides the posts of members who left the guild", function()
    env.board:Apply("Ann", open())
    env.left.Ann = true
    assert.are.same({}, env.board:Query())
    assert.is_nil(env.board:Get("Ann"))
    assert.is_nil(env.board:ByPid("p-1"))
  end)

  it("accepts every sender when it has no roster", function()
    local board = ns.LfgBoard.New({
      now = function()
        return 1
      end,
    })
    assert.is_true(board:Apply("Ann", open()))
  end)

  it("refuses what is not a post", function()
    for _, payload in ipairs({ "x", {}, open({ s = "other" }), open({ rev = 0 }), open({ pid = 4 }) }) do
      assert.are.equal("bad_post", select(2, env.board:Apply("Ann", payload)))
    end
    assert.are.equal("bad_post", select(2, env.board:Apply("", open())))
    assert.are.equal("bad_post", select(2, env.board:Apply(nil, open())))
  end)

  it("finds a post by pid", function()
    env.board:Apply("Ann", open({ pid = "p-a" }))
    env.board:Apply("Bob", open({ pid = "p-b" }))
    assert.are.equal("Bob", env.board:ByPid("p-b").owner)
    assert.is_nil(env.board:ByPid("p-z"))
  end)

  it("lists the open posts newest first", function()
    env.board:Apply("Ann", open({ pid = "a" }))
    env.clock = 110
    env.board:Apply("Bob", open({ pid = "b" }))
    env.clock = 120
    env.board:Apply("Cid", open({ pid = "c" }))
    local owners = {}
    for _, post in ipairs(env.board:Query()) do
      owners[#owners + 1] = post.owner
    end
    assert.are.same({ "Cid", "Bob", "Ann" }, owners)
  end)

  it("filters by kind and by a role the post still needs", function()
    env.board:Apply("Ann", open({ pid = "a", kind = "quest", needs = { tank = 0, heal = 0, dps = 2 } }))
    env.board:Apply("Bob", open({ pid = "b", kind = "dungeon", needs = { tank = 1, heal = 0, dps = 0 } }))
    assert.are.same({ "Ann" }, { env.board:Query({ kind = "quest" })[1].owner })
    assert.are.equal(1, #env.board:Query({ kind = "quest" }))
    assert.are.same({ "Bob" }, { env.board:Query({ role = "tank" })[1].owner })
    assert.are.equal(1, #env.board:Query({ role = "tank" }))
    assert.are.equal(0, #env.board:Query({ role = "heal" }))
    assert.are.equal(0, #env.board:Query({ kind = "quest", role = "tank" }))
    assert.are.equal(2, #env.board:Query({}))
  end)

  it("hands out copies, never its own tables", function()
    env.board:Apply("Ann", open())
    env.board:Get("Ann").needs.tank = 0
    env.board:Query()[1].title = "x"
    assert.are.equal(1, env.board:Get("Ann").needs.tank)
    assert.are.equal("Deadmines", env.board:Get("Ann").title)
  end)

  it("removes a post", function()
    env.board:Apply("Ann", open())
    env.board:Remove("ann")
    env.board:Remove("Nobody")
    env.board:Remove(nil)
    assert.are.equal(0, env.board.count)
    assert.is_nil(env.board:Get("Ann"))
  end)
end)
