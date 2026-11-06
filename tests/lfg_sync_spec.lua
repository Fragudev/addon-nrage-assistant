local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/EventModel",
    "Sync/Protocol",
    "Sync/SyncRules",
    "Sync/LfgSync",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local LfgSync, Protocol = ns.LfgSync, ns.Protocol

local function message(messageType, payload)
  local clean = Protocol.Validate(Protocol.Build(messageType, payload, "id-1"))
  assert(clean, messageType)
  return clean
end

local POST = {
  pid = "p-1",
  rev = 1,
  s = "open",
  kind = "dungeon",
  title = "Deadmines",
  needs = { tank = 1, heal = 0, dps = 2 },
  members = 1,
}

local function context()
  local ctx = { posts = {}, steps = {} }
  ctx.service = {
    OnPost = function(_, sender, payload)
      ctx.posts[#ctx.posts + 1] = { sender = sender, payload = payload }
      return true
    end,
    OnApply = function(_, sender, payload)
      ctx.steps[#ctx.steps + 1] = { sender = sender, payload = payload }
      return true
    end,
  }
  return ctx
end

describe("LfgSync", function()
  it("knows its two message types", function()
    assert.is_true(LfgSync.IsLfgMessage("LFG_POST"))
    assert.is_true(LfgSync.IsLfgMessage("LFG_APPLY"))
    assert.is_false(ns.LfgSync.IsLfgMessage("LAYER_SWAP"))
  end)

  it("hands a post to the service with the sender as the owner", function()
    local ctx = context()
    assert.is_true(LfgSync.Apply(ctx, message("LFG_POST", POST), "Ann", "member"))
    assert.are.equal("Ann", ctx.posts[1].sender)
    assert.are.equal("Deadmines", ctx.posts[1].payload.title)
  end)

  it("hands a step to the service with the sender as the actor", function()
    local ctx = context()
    assert.is_true(
      LfgSync.Apply(ctx, message("LFG_APPLY", { pid = "p-1", s = "apply", role = "dps" }), "Ann", "member")
    )
    assert.are.same({ { sender = "Ann", payload = { pid = "p-1", s = "apply", role = "dps" } } }, ctx.steps)
  end)

  it("needs a sender the roster knows", function()
    local ctx = context()
    local ok, reason = LfgSync.Apply(ctx, message("LFG_POST", POST), "Stranger", nil)
    assert.is_false(ok)
    assert.are.equal("unknown_sender", reason)
    ok, reason = LfgSync.Apply(ctx, message("LFG_APPLY", { pid = "p-1", s = "withdraw" }), "Stranger", nil)
    assert.is_false(ok)
    assert.are.equal("unknown_sender", reason)
    assert.are.same({}, ctx.posts)
    assert.are.same({}, ctx.steps)
  end)

  it("is unsupported without a service or for another type", function()
    local ok, reason = LfgSync.Apply({}, message("LFG_POST", POST), "Ann", "member")
    assert.is_false(ok)
    assert.are.equal("unsupported", reason)
    ok, reason = LfgSync.Apply({}, message("LFG_APPLY", { pid = "p-1", s = "withdraw" }), "Ann", "member")
    assert.is_false(ok)
    assert.are.equal("unsupported", reason)
    ok, reason = LfgSync.Apply(context(), { t = "PVP_KILL", p = {} }, "Ann", "member")
    assert.is_false(ok)
    assert.are.equal("unsupported", reason)
  end)

  it("passes on the reason the service gave", function()
    local ctx = context()
    ctx.service.OnPost = function()
      return false, "not_member"
    end
    local ok, reason = LfgSync.Apply(ctx, message("LFG_POST", POST), "Ann", "member")
    assert.is_false(ok)
    assert.are.equal("not_member", reason)
  end)

  it("lets every role use Groups", function()
    for _, role in ipairs({ "member", "rl", "officer", "gm" }) do
      assert.is_true(ns.PermissionService.Can(role, "lfg_use"), role)
    end
    assert.is_false(ns.PermissionService.Can(nil, "lfg_use"))
  end)
end)
