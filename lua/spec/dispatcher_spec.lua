local dispatcher = require("autoconf/custom/dufleet/dispatcher")
local outbox = require("autoconf/custom/dufleet/outbox")
local persist = require("autoconf/custom/dufleet/persist")
local command = require("autoconf/custom/dufleet/command")
local frames = require("frames")
local mockDatabank = require("dumocks.DatabankUnit")

local function setup(dbMock)
    dbMock = dbMock or mockDatabank:new(nil, 1)
    local ctx = { store = persist.new(dbMock:mockGetClosure()), outbox = outbox.new(), logged = {} }
    ctx.runs = 0
    ctx.handlers = {
        ping = function()
            ctx.runs = ctx.runs + 1
            return "A", {}
        end,
        pause = function() return "N", { err = "E_BUSY", msg = "busy" } end,
        resume = function() error("boom") end,
        status = function() return "A", {}, function() ctx.after = true end end,
    }
    ctx.log = function(msg) ctx.logged[#ctx.logged + 1] = msg end
    return dispatcher.new(ctx), ctx, dbMock
end

local function replies(ctx)
    return frames.messages(ctx.outbox:drain(100, "b1", 400))
end

describe("dispatcher", function()
    it("runs a new command once, persists the watermark, then acks", function()
        local d, ctx, dbMock = setup()
        assert.are.equal("execute", d:handle(command.build(1, 5, "ping")))
        local m = replies(ctx)
        assert.are.equal(1, ctx.runs)
        assert.are.equal("A", m[1].kind)
        assert.are.same({ ref = 5, e = 1 }, m[1].body)
        assert.are.equal('1|5|A|{"e":1,"ref":5}', dbMock.data["dub.last"])
    end)

    it("answers a retry from the stored reply without running it again", function()
        local d, ctx = setup()
        d:handle(command.build(1, 5, "ping"))
        assert.are.equal("replay", d:handle(command.build(1, 5, "ping")))
        local m = replies(ctx)
        assert.are.equal(1, ctx.runs)
        assert.are.equal(2, #m)
        assert.are.same({ ref = 5, e = 1, dup = true }, m[2].body)
    end)

    it("replays a refusal as a refusal", function()
        local d, ctx = setup()
        d:handle(command.build(1, 6, "pause"))
        d:handle(command.build(1, 6, "pause"))
        local m = replies(ctx)
        assert.are.same({ ref = 6, e = 1, err = "E_BUSY", msg = "busy" }, m[1].body)
        assert.are.same({ ref = 6, e = 1, err = "E_BUSY", msg = "busy", dup = true }, m[2].body)
    end)

    it("still answers from the databank after a restart", function()
        local d, ctx, dbMock = setup()
        d:handle(command.build(3, 9, "ping"))
        local again, ctx2 = setup(dbMock)
        assert.are.equal(3, again.epoch)
        assert.are.equal(9, again.cseq)
        assert.are.equal("replay", again:handle(command.build(3, 9, "ping")))
        assert.are.equal(1, ctx.runs + ctx2.runs)
        assert.is_true(replies(ctx2)[1].body.dup)
    end)

    it("refuses superseded and stale commands without running them", function()
        local d, ctx = setup()
        d:handle(command.build(2, 10, "ping"))
        assert.are.equal("superseded", d:handle(command.build(2, 9, "ping")))
        assert.are.equal("stale", d:handle(command.build(1, 50, "ping")))
        local m = replies(ctx)
        assert.are.equal(1, ctx.runs)
        assert.are.same({ "E_STATE", 9, 2 }, { m[2].body.err, m[2].body.ref, m[2].body.e })
        assert.are.same({ "E_EPOCH", 50, 1 }, { m[3].body.err, m[3].body.ref, m[3].body.e })
        assert.are.equal(2, d.epoch)
        assert.are.equal(10, d.cseq)
    end)

    it("runs the first command of a newer epoch even with a low cseq", function()
        local d, ctx = setup()
        d:handle(command.build(1, 500, "ping"))
        assert.are.equal("execute", d:handle(command.build(2, 1, "ping")))
        assert.are.equal(2, ctx.runs)
    end)

    it("refuses lines the parser rejects without touching the watermark", function()
        local d, ctx, dbMock = setup()
        assert.are.equal("error", d:handle("/b 1.5 ping #0000"))
        assert.are.equal("error", d:handle("/b garbage"))
        local m = replies(ctx)
        assert.are.same({ ref = 5, e = 1, err = "E_CRC", msg = "CRC mismatch" }, m[1].body)
        assert.are.same({ 0, 0, "E_PARSE" }, { m[2].body.ref, m[2].body.e, m[2].body.err })
        assert.is_nil(dbMock.data["dub.last"])
    end)

    it("turns a handler error into E_INTERNAL and remembers it", function()
        local d, ctx = setup()
        d:handle(command.build(1, 1, "resume"))
        d:handle(command.build(1, 1, "resume"))
        local m = replies(ctx)
        assert.are.equal("E_INTERNAL", m[1].body.err)
        assert.truthy(m[1].body.msg:find("boom", 1, true))
        assert.is_true(m[2].body.dup)
    end)

    it("refuses a verb without a handler as a bus error", function()
        local d, ctx = setup()
        d:handle(command.build(1, 1, "cancel"))
        local body = replies(ctx)[1].body
        assert.are.same({ "E_INTERNAL", "no handler for cancel" }, { body.err, body.msg })
    end)

    it("runs the follow-up after queueing the reply", function()
        local d, ctx = setup()
        d:handle(command.build(1, 1, "status"))
        assert.is_true(ctx.after)
    end)

    it("queues a bounded number of lines and handles them in order", function()
        local d, ctx = setup()
        for i = 1, 10 do d:submit(command.build(1, i, "ping")) end
        assert.are.equal(2, d.dropped)
        d:step(3)
        assert.are.equal(3, ctx.runs)
        d:step(100)
        assert.are.equal(8, ctx.runs)
        assert.are.equal(8, d.cseq)
    end)

    it("starts from epoch 0 and logs an unreadable watermark", function()
        local dbMock = mockDatabank:new(nil, 1)
        dbMock.data["dub.last"] = "bad"
        local d, ctx = setup(dbMock)
        assert.are.same({ 0, 0 }, { d.epoch, d.cseq })
        assert.are.equal(1, #ctx.logged)
    end)
end)
