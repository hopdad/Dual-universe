local P = require("autoconf/custom/dufleet/protocol_gen")
local builtins = require("autoconf/custom/dufleet/builtins")
local command = require("autoconf/custom/dufleet/command")
local outbox = require("autoconf/custom/dufleet/outbox")
local persist = require("autoconf/custom/dufleet/persist")
local runtime = require("autoconf/custom/dufleet/runtime")

-- ArchHUD as it looks before its setup finishes. runtime_spec and goto_spec cover the job verbs.
local STARTING = {
    setupComplete = function() return false end,
    busy = function() return nil end,
    stop = function() return nil, "ArchHUD's AP not found" end,
}

local function setup()
    local bus = { store = persist.new(nil), outbox = outbox.new(), hellos = 0, telemetry = 0 }
    bus.runtime = runtime.new({ store = bus.store, outbox = bus.outbox,
        skills = { ["goto"] = require("autoconf/custom/dufleet/skills/goto") },
        env = { ah = STARTING, now = function() return 0 end } })
    bus.sendHello = function() bus.hellos = bus.hellos + 1 end
    bus.sendTelemetry = function() bus.telemetry = bus.telemetry + 1 end
    bus.setId = function(id) bus.store:set("dub.id", id) end
    return builtins.install({}, bus), bus
end

local function run(handlers, ...)
    local cmd = assert(command.parse(command.build(1, 1, ...)))
    return handlers[cmd.verb](cmd, {})
end

describe("builtins", function()
    it("cover every verb in the schema", function()
        local handlers = setup()
        for verb in pairs(P.VERBS) do
            assert.is_function(handlers[verb], verb)
        end
    end)

    it("refuse only with error codes from the schema", function()
        local handlers = setup()
        local cases = {
            { "pause" }, { "resume" }, { "run", "goto", "j_1" }, { "run", "goto", "j_1", "pos=0,2,1,2,3" },
            { "run", "patrol", "j_1" }, { "cal", "on" }, { "relay", "w1", "eyJ9" }, { "cancel", "j_1" }, { "cancel" },
            { "db", "set", "dub.last", "x" },
        }
        for _, c in ipairs(cases) do
            local kind, fields = run(handlers, table.unpack(c))
            assert.are.equal("N", kind, c[1])
            assert.is_string(P.ERRORS[fields.err], c[1])
        end
    end)

    it("ping and status acknowledge; status then sends H and T", function()
        local handlers, bus = setup()
        assert.are.equal("A", (run(handlers, "ping")))
        local kind, _, after = run(handlers, "status")
        assert.are.equal("A", kind)
        after()
        assert.are.same({ 1, 1 }, { bus.hellos, bus.telemetry })
    end)

    it("setid stores the id", function()
        local handlers, bus = setup()
        run(handlers, "setid", "hauler-1")
        assert.are.equal("hauler-1", bus.store:get("dub.id"))
    end)

    it("db reads, writes and deletes dub. keys, but not the bus's own", function()
        local handlers, bus = setup()
        assert.are.equal("A", (run(handlers, "db", "set", "dub.cfg.maxline", "300")))
        local _, fields = run(handlers, "db", "get", "dub.cfg.maxline")
        assert.are.same({ k = "dub.cfg.maxline", v = "300" }, fields.data)
        run(handlers, "db", "del", "dub.cfg.maxline")
        _, fields = run(handlers, "db", "get", "dub.cfg.maxline")
        assert.are.same({ k = "dub.cfg.maxline" }, fields.data)
        for _, key in ipairs({ "dub.last", "dub.id", "dub.schema", "dub.job" }) do
            assert.are.equal("N", (run(handlers, "db", "del", key)))
        end
        bus.store:setLast(1, 1, "A", "{}")
        _, fields = run(handlers, "db", "get", "dub.last")
        assert.are.equal("1|1|A|{}", fields.data.v)
    end)

    it("resend queues the ring after the ack", function()
        local handlers, bus = setup()
        bus.outbox:push("E", '{"ev":"x"}')
        bus.outbox:drain(10, "b1", 400)
        local kind, _, after = run(handlers, "resend", "0")
        assert.are.equal("A", kind)
        after()
        assert.are.equal(1, bus.outbox:size())
    end)

    it("cal works only with an optical transport", function()
        local handlers, bus = setup()
        assert.are.equal("N", (run(handlers, "cal", "on")))
        bus.calibrate = function(on) bus.cal = on end
        handlers = builtins.install({}, bus)
        assert.are.equal("A", (run(handlers, "cal", "on")))
        assert.is_true(bus.cal)
    end)
end)
