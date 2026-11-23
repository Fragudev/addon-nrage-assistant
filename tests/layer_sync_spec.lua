local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/EventModel",
    "Domain/LayerModel",
    "Domain/LayerDirectory",
    "Sync/Protocol",
    "Sync/SyncRules",
    "Sync/LayerSync",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local LayerSync, Protocol = ns.LayerSync, ns.Protocol

local function message(messageType, payload)
  local clean = Protocol.Validate(Protocol.Build(messageType, payload, "id-1"))
  assert(clean, messageType)
  return clean
end

local function context()
  local ctx = {}
  ctx.directory = ns.LayerDirectory.New({
    now = function()
      return 100
    end,
  })
  return ctx
end

describe("LayerSync", function()
  it("knows its one message type", function()
    assert.is_true(LayerSync.IsLayerMessage("LAYER_STATE"))
    -- Removed: an older client still sends it, and it is no longer a layer message.
    assert.is_false(LayerSync.IsLayerMessage("LAYER_SWAP"))
    assert.is_false(LayerSync.IsLayerMessage("PVP_KILL"))
  end)

  it("keeps the layer of the sender, never of a name in the payload", function()
    local ctx = context()
    local state = message("LAYER_STATE", { map = 0, layer = 50, owner = "Someone-Else" })
    assert.is_true(LayerSync.Apply(ctx, state, "Ann", "member"))
    assert.are.same({ "Ann" }, ctx.directory:MembersOn(0, 50))
    assert.are.same({}, ctx.directory:MembersOn(0, 51))
  end)

  it("forgets the sender on layer 0", function()
    local ctx = context()
    LayerSync.Apply(ctx, message("LAYER_STATE", { map = 0, layer = 50 }), "Ann", "member")
    LayerSync.Apply(ctx, message("LAYER_STATE", { map = 0, layer = 0 }), "Ann", "member")
    assert.are.same({}, ctx.directory:Groups(0))
  end)

  it("needs a sender the roster knows", function()
    local ctx = context()
    local ok, reason = LayerSync.Apply(ctx, message("LAYER_STATE", { map = 0, layer = 5 }), "Stranger", nil)
    assert.is_false(ok)
    assert.are.equal("unknown_sender", reason)
    assert.are.same({}, ctx.directory:Groups(0))
  end)

  it("is unsupported while the directory does not exist", function()
    local ok, reason = LayerSync.Apply({}, message("LAYER_STATE", { map = 0, layer = 5 }), "Ann", "member")
    assert.is_false(ok)
    assert.are.equal("unsupported", reason)
    ok, reason = LayerSync.Apply({}, { t = "PVP_KILL", p = {} }, "Ann", "member")
    assert.is_false(ok)
    assert.are.equal("unsupported", reason)
  end)

  it("builds the payloads of the own layer", function()
    assert.are.same({ map = 1, layer = 7 }, LayerSync.StatePayload({ map = 1, layer = 7, confirmedAt = 5 }))
    assert.is_nil(LayerSync.StatePayload(nil))
    assert.are.same({ map = 0, layer = 0 }, LayerSync.ForgetPayload())
    assert.is_truthy(Protocol.Validate(Protocol.Build("LAYER_STATE", LayerSync.ForgetPayload(), "id-1")))
  end)
end)

describe("Layer permissions", function()
  it("lets every role share", function()
    for _, role in ipairs({ "member", "rl", "officer", "gm" }) do
      assert.is_true(ns.PermissionService.Can(role, "layer_share"), role)
    end
    assert.is_false(ns.PermissionService.Can(nil, "layer_share"))
  end)
end)
