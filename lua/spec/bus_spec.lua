-- The bus inside a fake ArchHUD: the userclass shim, the hooks, and a command round trip.
local fake = require("fake_archhud")
local command = require("command_helper")

local function startBus(opts)
    local h = fake.install(opts)
    require("autoconf/custom/archhud/userclass")
    userBase.ExtraOnStart()
    return h
end

describe("userclass shim", function()
    it("defines all four ExtraOn functions ArchHUD calls unconditionally", function()
        fake.install()
        require("autoconf/custom/archhud/userclass")
        for _, name in ipairs({ "ExtraOnStart", "ExtraOnStop", "ExtraOnUpdate", "ExtraOnFlush" }) do
            assert.is_function(userBase[name], name)
        end
        userBase.ExtraOnUpdate()
        userBase.ExtraOnFlush()
    end)
end)

describe("bus", function()
    it("starts its timer and says hello", function()
        local h = startBus()
        assert.are.equal(0.25, h.unitMock.timers.dub)
        h.tick(1)
        local hello = h.ofKind("H")[1]
        assert.are.equal("c4242", hello.bot)
        assert.are.equal(1, hello.seq)
        assert.are.same({ epoch = 0, cseq = 0, id = "", ah = "2.105", tr = "L", ml = 400, v = "0.1.0" },
            { epoch = hello.body.epoch, cseq = hello.body.cseq, id = hello.body.id, ah = hello.body.ah,
                tr = hello.body.tr, ml = hello.body.ml, v = hello.body.v })
        assert.truthy(hello.body.boot:find("^[0-9a-f]+$"))
    end)

    it("takes /b chat lines, even with ::pos, and passes everything else to ArchHUD", function()
        local h = startBus()
        h.type("/b 1.1 run goto j_1 p=::pos{0,2,35.3951,104.1187,285.5413} #0000")
        h.type("/b")
        h.type("::pos{0,2,35.3951,104.1187,285.5413}")
        h.type("/bfoo")
        h.type("/commands")
        assert.are.same({ "::pos{0,2,35.3951,104.1187,285.5413}", "/bfoo", "/commands" }, h.archInputs)
        h.tick(4)
        local nacks = h.ofKind("N")
        assert.are.equal(2, #nacks)
        assert.are.equal("E_PARSE", nacks[1].body.err)
    end)

    it("passes other timers to ArchHUD", function()
        local h = startBus()
        PROGRAM.onTick("apTick")
        PROGRAM.onTick("hudTick")
        assert.are.same({ "apTick", "hudTick" }, h.archTicks)
    end)

    it("acknowledges a ping", function()
        local h = startBus()
        h.type(command.build(1, 1, "ping"))
        h.tick(3)
        local acks = h.ofKind("A")
        assert.are.equal(1, #acks)
        assert.are.same({ ref = 1, e = 1 }, acks[1].body)
    end)

    it("sends at most `lines` lines per tick, 2 by default", function()
        local h = startBus()
        for i = 1, 4 do h.type(command.build(1, i, "ping")) end
        h.tick(1)
        assert.are.equal(2, #h.printed)
    end)

    it("reports telemetry once a second", function()
        local h = startBus()
        _G.Autopilot, _G.AutopilotStatus = true, "Cruising" -- busted runs specs in their own environment
        h.tick(8)
        local t = h.ofKind("T")
        assert.are.equal(2, #t)
        assert.are.same({ w = { -123456.5, 98765.3, 42 }, v = 18, alt = 285.5, st = "idle", ap = "autopilot:Cruising" },
            t[1].body)
    end)

    it("reports the body and latitude and longitude on it", function()
        local h = startBus()
        _G.planet = { id = 2, systemId = 0, center = { x = 1000, y = 2000, z = 3000 }, radius = 100 }
        h.construct.position = { 1000, 2100, 3000 } -- on the equator, 90 degrees east
        h.tick(1)
        local t = h.ofKind("T")[1].body
        assert.are.equal(2, t.b)
        assert.are.same({ 0, 90 }, t.g)
        _G.planet = { id = 0, systemId = 0, center = { 0, 0, 0 }, radius = 0 } -- in space
        h.tick(4)
        t = h.ofKind("T")[2].body
        assert.are.equal(0, t.b)
        assert.is_nil(t.g)
    end)

    it("computes latitude and longitude as ArchHUD does", function()
        local bus = require("autoconf/custom/dufleet/bus")
        local body = { center = { 0, 0, 0 } }
        local lat, lon = bus.latlon({ 0, 0, 150 }, body)
        assert.are.same({ 90, 0 }, { lat, lon })
        lat, lon = bus.latlon({ 0, -10, 0 }, body)
        assert.are.same({ 0, 270 }, { lat, lon })
        lat, lon = bus.latlon({ -10, 0, -10 }, body)
        assert.are.equal(-45, math.floor(lat + 0.5))
        assert.are.equal(180, math.floor(lon + 0.5))
    end)

    it("says hello again every 30 s", function()
        local h = startBus()
        h.tick(30 * 4 + 4)
        assert.are.equal(2, #h.ofKind("H"))
    end)

    it("uses the id from setid", function()
        local h = startBus()
        h.type(command.build(1, 1, "setid", "hauler-1"))
        h.tick(1)
        h.type(command.build(1, 2, "ping"))
        h.tick(4)
        local acks = h.ofKind("A")
        assert.are.equal("hauler-1", acks[#acks].bot)
        assert.are.equal("hauler-1", h.dbMock.data["dub.id"])
    end)

    it("answers a retry after a restart without running the command again", function()
        local h = startBus()
        h.type(command.build(4, 20, "setid", "hauler-1"))
        h.tick(3)
        userBase.ExtraOnStop()
        assert.is_nil(h.unitMock.timers.dub)

        local h2 = startBus({ dbMock = h.dbMock })
        h2.type(command.build(4, 20, "setid", "hauler-2"))
        h2.tick(3)
        local ack = h2.ofKind("A")[1]
        assert.are.same({ ref = 20, e = 4, dup = true }, ack.body)
        assert.are.equal("hauler-1", h2.dbMock.data["dub.id"])
        local hello = h2.ofKind("H")[1]
        assert.are.same({ 4, 20, "hauler-1" }, { hello.body.epoch, hello.body.cseq, hello.body.id })
    end)

    it("reads its settings from dub.cfg keys", function()
        local dbMock = require("dumocks.DatabankUnit"):new(nil, 3)
        dbMock.data["dub.cfg.maxline"] = "120"
        dbMock.data["dub.cfg.lines"] = "5"
        dbMock.data["dub.cfg.tick"] = "-1" -- out of range: ignored
        local h = startBus({ dbMock = dbMock })
        assert.are.equal(0.25, h.unitMock.timers.dub)
        h.tick(1)
        assert.are.equal(3, #h.printed) -- H (2 chunks at 120) and T
        for _, line in ipairs(h.printed) do assert.is_true(#line <= 120) end
        assert.are.equal(120, h.ofKind("H")[1].body.ml)
    end)

    it("works without a databank and says so", function()
        local h = startBus({ databank = false })
        h.type(command.build(1, 1, "ping"))
        h.tick(4)
        assert.are.equal(1, #h.ofKind("A"))
        assert.truthy(h.ofKind("D")[1].body.msg:find("no databank", 1, true))
    end)

    it("turns its own errors into D frames and keeps ArchHUD running", function()
        local h = startBus()
        construct.getWorldPosition = function() error("sensor fault") end
        h.tick(4)
        h.type("hello ArchHUD")
        assert.are.same({ "hello ArchHUD" }, h.archInputs)
        local d = h.ofKind("D")
        assert.are.equal(1, #d)
        assert.truthy(d[1].body.msg:find("sensor fault", 1, true))
        assert.truthy(h.printed[1]:find("dufleet error", 1, true))
    end)

    it("does not hook anything when ArchHUD is missing", function()
        local h = fake.install()
        _G.PROGRAM = nil
        require("autoconf/custom/archhud/userclass")
        userBase.ExtraOnStart()
        assert.is_nil(h.unitMock.timers.dub)
        assert.truthy(h.printed[1]:find("PROGRAM table not found", 1, true))
        userBase.ExtraOnStop()
    end)

    it("restores ArchHUD's entry points on stop", function()
        local h = startBus()
        userBase.ExtraOnStop()
        h.type("/b 1.1 ping #0000")
        assert.are.same({ "/b 1.1 ping #0000" }, h.archInputs)
    end)
end)
