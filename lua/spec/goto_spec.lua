-- goto through the whole bus, flying the fake ArchHUD autopilot (spec/helpers/fake_archhud.lua).
local fake = require("fake_archhud")
local command = require("command_helper")

local POS = "pos=0,2,10,20,300" -- on Alioth, in its atmosphere

-- A databank that lets the bus send 20 lines per tick, so replies and results go out in the tick that makes them.
local function databank()
    local db = require("dumocks.DatabankUnit"):new(nil, 3)
    db.data["dub.cfg.lines"] = "20"
    return db
end

local function near(a, b)
    return math.abs(a - b) < 1e-6
end

local function startBus(opts)
    opts = opts or {}
    opts.dbMock = opts.dbMock or databank()
    local h = fake.install(opts)
    h.start()
    h.flySpeed = 100000
    h.cseq = 0
    -- Types a command and runs one tick; returns the reply's kind and body.
    function h.send(verb, ...)
        h.cseq = h.cseq + 1
        local before = #h.messages()
        h.type(command.build(1, h.cseq, verb, ...))
        h.tick(1)
        for i = before + 1, #h.messages() do
            local m = h.messages()[i]
            if (m.kind == "A" or m.kind == "N") and m.body.ref == h.cseq then return m.kind, m.body end
        end
        error("no reply to " .. verb)
    end
    function h.result()
        local r = h.ofKind("R")
        return r[#r] and r[#r].body
    end
    function h.moves()
        local out = {}
        for _, e in ipairs(h.ofKind("E")) do out[#out + 1] = e.body.from .. ">" .. e.body.to end
        return out
    end
    return h
end

describe("goto", function()
    it("flies to the position and reports the distance and time", function()
        local h = startBus()
        local kind, body = h.send("run", "goto", "j_1", POS)
        assert.are.same({ "A", { ref = 1, e = 1, job = "j_1" } }, { kind, body })
        assert.are.equal(1, #h.toggles)
        assert.is_true(_G.VectorToTarget)
        local t = h.ofKind("T")[#h.ofKind("T")].body
        assert.are.same({ "goto:travel", "j_1" }, { t.st, t.job })
        h.tick(12)
        assert.are.equal("goto:settle", h.ofKind("T")[#h.ofKind("T")].body.st)
        assert.is_nil(h.result())
        h.tick(20)
        local r = h.result()
        assert.are.same({ "j_1", "goto", true }, { r.job, r.skill, r.ok })
        assert.are.equal(2.8, r.data.dist) -- the fake lands 3 m east and 4 m north: 2.8 m of it horizontal
        assert.is_true(r.data.t >= 5)
        assert.are.same({ "idle>engage", "engage>travel", "travel>settle" }, h.moves())
        assert.is_nil(h.dbMock.data["dub.job"])
        h.tick(4)
        local last = h.ofKind("T")[#h.ofKind("T")].body
        assert.are.same({ "idle" }, { last.st, last.job })
    end)

    it("takes off from the ground as a pilot would: throttle up, brake off", function()
        local h = startBus()
        h.flySpeed = 0 -- keep the ship on the ground to look at the takeoff
        h.send("run", "goto", "j_1", POS)
        assert.is_true(_G.AutoTakeoff) -- ArchHUD's auto takeoff is on
        assert.is_false(_G.BrakeIsOn) -- its brake hold is released
        assert.are.equal(1, h.throttle) -- with the throttle up
    end)

    it("selects its own location, which is not the one ArchHUD selects", function()
        local h = startBus()
        h.flySpeed = 0
        h.send("run", "goto", "j_1", POS)
        assert.are.same({ "dub-j_1" }, h.added)
        assert.are.equal("dub-j_1", _G.CustomTarget.name)
        assert.are.equal("dub-j_1", _G.AtlasOrdered[_G.AutopilotTargetIndex].name)
        assert.are.not_equal(1, _G.AutopilotTargetIndex) -- "Alioth" sorts first
        assert.are.equal(0, h.replaced)
        assert.are.same({ "idle>engage", "engage>travel" }, h.moves())
    end)

    it("converts the position as ArchHUD converts ::pos", function()
        local h = startBus()
        h.flySpeed = 0
        h.send("run", "goto", "j_1", "pos=0,2,0,90,1000")
        local p, c = _G.CustomTarget.position, fake.ALIOTH.center
        local r = fake.ALIOTH.radius + 1000
        assert.is_true(near(c.x, p.x) and near(c.y + r, p.y) and near(c.z, p.z))
    end)

    it("refuses what it cannot fly, without touching ArchHUD", function()
        local h = startBus()
        local cases = {
            { { "tol=5" }, "E_ARGS", "missing pos" },
            { { "pos=0,2,1,2" }, "E_ARGS", "pos needs systemId,bodyId,lat,lon,alt" },
            { { "pos=0,2,x,2,3" }, "E_ARGS", "pos needs 5 finite numbers" },
            { { "pos=0,2.5,1,2,3" }, "E_ARGS", "pos needs whole systemId and bodyId" },
            { { "pos=0,2,95,0,0" }, "E_ARGS", "pos latitude is out of range" },
            { { POS, "tol=0" }, "E_ARGS", "tol must be a number from 1 to 100000" },
            { { POS, "timeout=5" }, "E_ARGS", "timeout must be a number from 10 to 86400" },
            { { POS, "speed=3" }, "E_ARGS", "unknown parameter speed" },
            { { "pos=0,7,1,2,3" }, "E_STATE", "body 7 in system 0 is not in ArchHUD's atlas" },
            { { "pos=3,2,1,2,3" }, "E_STATE", "body 2 in system 3 is not in ArchHUD's atlas" },
        }
        for i, case in ipairs(cases) do
            local kind, body = h.send("run", "goto", "j_" .. i, table.unpack(case[1]))
            assert.are.same({ "N", case[2], case[3] }, { kind, body.err, body.msg })
        end
        assert.are.same({}, h.added)
        assert.are.same({}, h.toggles)
    end)

    it("refuses while ArchHUD is starting, flying, or has a route loaded", function()
        local h = startBus()
        _G.SetupComplete = false
        local kind, body = h.send("run", "goto", "j_1", POS)
        assert.are.same({ "N", "E_STATE", "ArchHUD is still starting" }, { kind, body.err, body.msg })
        _G.SetupComplete, _G.Autopilot = true, true
        kind, body = h.send("run", "goto", "j_2", POS)
        assert.are.same({ "N", "ArchHUD is busy: Autopilot" }, { kind, body.msg })
        _G.Autopilot, _G.apRoute = false, { "Home" }
        kind, body = h.send("run", "goto", "j_3", POS)
        assert.are.same({ "N", "an ArchHUD route is loaded" }, { kind, body.msg })
        assert.are.same({}, h.toggles)
    end)

    it("does not start with too little of the fuel the trip needs", function()
        local h = startBus()
        _G.atmoTanks, _G.spaceTanks = { { 101, "a", 1000, 50 } }, { { 201, "s", 1000, 50 } }
        h.coreMock.elements[101], h.coreMock.elements[201] = { mass = 80 }, { mass = 1050 }
        local kind, body = h.send("run", "goto", "j_1", POS)
        assert.are.same({ "N", "E_FUEL", "atmo fuel 3%, under the 10% minimum" }, { kind, body.err, body.msg })
        h.coreMock.elements[101], h.coreMock.elements[201] = { mass = 1050 }, { mass = 80 }
        assert.are.equal("A", (h.send("run", "goto", "j_2", POS))) -- on this planet: no space fuel needed
        h.send("cancel")
        kind, body = h.send("run", "goto", "j_3", "pos=0,0,1,2,3") -- deep space
        assert.are.same({ "N", "E_FUEL", "space fuel 3%, under the 10% minimum" }, { kind, body.err, body.msg })
        assert.are.same({ "dub-j_2" }, h.added)
    end)

    it("skips the fuel check when dub.cfg.minfuel is 0", function()
        local db = databank()
        db.data["dub.cfg.minfuel"] = "0"
        local h = startBus({ dbMock = db })
        _G.atmoTanks = { { 101, "a", 1000, 50 } }
        h.coreMock.elements[101] = { mass = 50 }
        assert.are.equal("A", (h.send("run", "goto", "j_1", POS)))
    end)

    it("runs one job at a time", function()
        local h = startBus()
        h.flySpeed = 0
        h.send("run", "goto", "j_1", POS)
        local kind, body = h.send("run", "goto", "j_2", POS)
        assert.are.same({ "N", "E_BUSY", "skill goto running" }, { kind, body.err, body.msg })
    end)

    it("cancel stops the autopilot, cuts the throttle and sets the brake", function()
        local h = startBus()
        h.flySpeed = 0
        h.send("run", "goto", "j_1", POS)
        local kind, body = h.send("cancel", "j_1")
        assert.are.same({ "A", "j_1" }, { kind, body.job })
        assert.is_false(_G.VectorToTarget)
        assert.are.same({ true, 0 }, { _G.BrakeIsOn, h.throttle })
        local r = h.result()
        assert.are.same({ false, "E_STATE", "cancelled" }, { r.ok, r.err, r.msg })
    end)

    it("pauses and resumes without an orbital hop or a second location", function()
        local h = startBus()
        h.flySpeed = 0
        h.send("run", "goto", "j_1", POS)
        assert.are.equal("A", (h.send("pause")))
        assert.is_false(_G.VectorToTarget)
        assert.is_true(_G.BrakeIsOn)
        assert.are.equal("A", (h.send("resume")))
        h.tick(12)
        assert.are.equal(2, #h.toggles)
        assert.is_true(h.toggles[2] - h.toggles[1] >= 2)
        assert.are.equal(0, h.hops)
        assert.are.same({ "dub-j_1" }, h.added)
        assert.is_true(_G.VectorToTarget)
        h.flySpeed = 100000
        h.tick(40)
        assert.is_true(h.result().ok)
        assert.are.same({ "idle>engage", "engage>travel", "travel>paused", "paused>engage", "engage>travel",
            "travel>settle" }, h.moves())
    end)

    it("fails and brakes when the ship stops outside the tolerance", function()
        local h = startBus()
        h.miss = { 300, 400, 0 }
        h.send("run", "goto", "j_1", POS)
        h.tick(40)
        local r = h.result()
        assert.are.same({ false, "E_STATE" }, { r.ok, r.err })
        assert.truthy(r.msg:find("^stopped 28%d m from the target$"))
        assert.is_true(r.data.dist > 280 and r.data.dist < 290)
        assert.are.equal(0, h.throttle)
    end)

    it("takes a wider tolerance as tol", function()
        local h = startBus()
        h.miss = { 300, 400, 0 }
        h.send("run", "goto", "j_1", POS, "tol=500")
        h.tick(40)
        assert.is_true(h.result().ok)
    end)

    it("measures in straight lines in space, with a wider default tolerance", function()
        local h = startBus()
        _G.inAtmo, h.flySpeed, h.miss = false, 5000000, { 600, 0, 0 }
        h.send("run", "goto", "j_1", "pos=0,0,2000000,3000000,-4000000")
        assert.are.equal("Space", _G.CustomTarget.planetname)
        assert.is_true(_G.Autopilot)
        h.tick(40)
        local r = h.result()
        assert.are.same({ true, 600 }, { r.ok, r.data.dist })
    end)

    it("fails when the autopilot goes off and the ship keeps moving", function()
        local h = startBus()
        h.flySpeed = 0
        h.send("run", "goto", "j_1", POS)
        _G.VectorToTarget, _G.AltitudeHold, _G.AutoTakeoff = false, false, false -- the construct still moves at 5 m/s
        h.tick(4 * 29)
        assert.is_nil(h.result())
        h.tick(8)
        local r = h.result()
        assert.are.equal(false, r.ok)
        assert.truthy(r.msg:find("^autopilot off and still moving"))
        assert.is_true(_G.BrakeIsOn)
    end)

    it("gives up after its timeout", function()
        local h = startBus()
        h.flySpeed = 0
        h.send("run", "goto", "j_1", POS, "timeout=10")
        h.tick(4 * 9)
        assert.is_nil(h.result())
        h.tick(8)
        assert.are.same({ false, "timed out after 10 s" }, { h.result().ok, h.result().msg })
        assert.is_false(_G.VectorToTarget)
    end)

    it("waits 2 s between its own toggles", function()
        local h = startBus()
        h.flySpeed = 0
        h.send("run", "goto", "j_1", POS)
        h.send("cancel")
        h.send("run", "goto", "j_2", "pos=0,2,11,20,300")
        assert.are.equal(1, #h.toggles)
        h.tick(8)
        assert.are.equal(2, #h.toggles)
        assert.is_true(h.toggles[2] - h.toggles[1] >= 2)
        assert.are.equal(0, h.hops)
    end)

    it("reports a job cut off by a restart", function()
        local h = startBus()
        h.flySpeed = 0
        h.send("run", "goto", "j_1", POS)
        userBase.ExtraOnStop()
        local h2 = startBus({ dbMock = h.dbMock, clock = h.clock })
        h2.tick(1)
        local msgs = h2.messages()
        assert.are.same({ "H", "R" }, { msgs[1].kind, msgs[2].kind })
        assert.are.same({ job = "j_1", skill = "goto", ok = false, err = "E_STATE", msg = "interrupted by a restart" },
            msgs[2].body)
        assert.is_nil(h2.dbMock.data["dub.job"])
    end)
end)
