-- The skill runtime with a stub skill: one job at a time, phases, results, pause, cancel
-- and recovery after a restart. goto_spec runs the real goto skill through the bus.
local command = require("autoconf/custom/dufleet/command")
local frames = require("frames")
local outbox = require("autoconf/custom/dufleet/outbox")
local persist = require("autoconf/custom/dufleet/persist")
local runtime = require("autoconf/custom/dufleet/runtime")

-- Runs as "patrol", a skill name the schema accepts. Each step returns what `script`
-- says for that step number (after moving to `phase`, if given).
local function stubSkill()
    local s = { phase = "one", steps = 0, stops = 0, script = {} }
    function s.check(params)
        if params.bad then return nil, "E_ARGS", "bad is not allowed" end
        return { n = params.n }
    end
    function s.step(job)
        s.steps = s.steps + 1
        local plan = s.script[s.steps]
        if not plan then return nil end
        if plan.phase then job.phase = plan.phase end
        if plan.error then error(plan.error) end
        return table.unpack(plan.result or {})
    end
    function s.stop()
        s.stops = s.stops + 1
        return true
    end
    return s
end

local function setup()
    local t = { clock = 100, logged = {}, idleStops = 0 }
    t.skill = stubSkill()
    t.store = persist.new(nil)
    t.outbox = outbox.new()
    t.env = { now = function() return t.clock end,
        ah = { stop = function() t.idleStops = t.idleStops + 1; return true end } }
    t.rt = runtime.new({ store = t.store, outbox = t.outbox, env = t.env, skills = { patrol = t.skill },
        log = function(msg) t.logged[#t.logged + 1] = msg end })
    local cseq = 0
    -- Handles a command as the dispatcher does: the reply goes out, then its follow-up runs.
    function t.send(verb, ...)
        cseq = cseq + 1
        local cmd = assert(command.parse(command.build(1, cseq, verb, ...)))
        local kind, fields, after = t.rt[verb](t.rt, cmd)
        t.outbox:push(kind, require("autoconf/custom/dufleet/jsonenc").encode(fields))
        if after then after() end
        return kind, fields
    end
    function t.step(n, dt)
        for _ = 1, n or 1 do
            t.clock = t.clock + (dt or 0.25)
            t.rt:step(t.clock)
        end
    end
    function t.frames(kind)
        return frames.ofKind(frames.messages(t.outbox:drain(1000, "b1", 400)), kind)
    end
    return t
end

describe("runtime", function()
    it("starts a job: A with the job id, a skill_state event, dub.job", function()
        local t = setup()
        local kind, fields = t.send("run", "patrol", "j_1", "n=3", "a=1")
        assert.are.same({ "A", { job = "j_1" } }, { kind, fields })
        assert.are.equal("patrol:one", t.rt:status())
        local e = t.frames("E")[1].body
        assert.are.same({ ev = "skill_state", job = "j_1", skill = "patrol", from = "idle", to = "one" }, e)
        assert.are.equal('{"args":"a=1 n=3","job":"j_1","paused":false,"phase":"one","skill":"patrol"}',
            t.store:get("dub.job"))
    end)

    it("runs one job at a time", function()
        local t = setup()
        t.send("run", "patrol", "j_1")
        local kind, fields = t.send("run", "patrol", "j_2")
        assert.are.same({ "N", { err = "E_BUSY", msg = "skill patrol running" } }, { kind, fields })
    end)

    it("refuses a skill it does not have, and parameters the skill rejects", function()
        local t = setup()
        assert.are.same({ "N", { err = "E_STATE", msg = "skill mine_loop not available yet" } },
            { t.send("run", "mine_loop", "j_1") })
        assert.are.same({ "N", { err = "E_ARGS", msg = "bad is not allowed" } },
            { t.send("run", "patrol", "j_1", "bad=1") })
        assert.are.equal("idle", t.rt:status())
        assert.is_nil(t.store:get("dub.job"))
    end)

    it("reports phase changes and keeps dub.job current", function()
        local t = setup()
        t.skill.script = { {}, { phase = "two" } }
        t.send("run", "patrol", "j_1")
        t.step(2)
        assert.are.equal("patrol:two", t.rt:status())
        assert.truthy(t.store:get("dub.job"):find('"phase":"two"', 1, true))
        local events = t.frames("E")
        assert.are.same({ "one", "two" }, { events[2].body.from, events[2].body.to })
    end)

    it("sends R with the data when the job is done", function()
        local t = setup()
        t.skill.script = { { result = { true, { dist = 1.5 } } } }
        t.send("run", "patrol", "j_1")
        t.step(1)
        assert.are.same({ job = "j_1", skill = "patrol", ok = true, data = { dist = 1.5 } }, t.frames("R")[1].body)
        assert.are.equal("idle", t.rt:status())
        assert.is_nil(t.store:get("dub.job"))
    end)

    it("sends R with the error when the job failed", function()
        local t = setup()
        t.skill.script = { { result = { false, "E_FUEL", "atmo fuel 3%", { fuel = 0.03 } } } }
        t.send("run", "patrol", "j_1")
        t.step(1)
        assert.are.same({ job = "j_1", skill = "patrol", ok = false, err = "E_FUEL", msg = "atmo fuel 3%",
            data = { fuel = 0.03 } }, t.frames("R")[1].body)
    end)

    it("knows the same R error codes as the schema", function()
        local f = assert(io.open("../packages/protocol/protocol.schema.json"))
        local schema = require("dkjson").decode(f:read("a"))
        f:close()
        local codes = {}
        for _, code in ipairs(schema["$defs"].result.properties.err.enum) do codes[code] = true end
        assert.are.same(codes, runtime.RESULT_ERRORS)
    end)

    it("sends only error codes an R frame may carry", function()
        local t = setup()
        t.skill.script = { { result = { false, "E_ARGS", "bad leg" } } }
        t.send("run", "patrol", "j_1")
        t.step(1)
        local r = t.frames("R")[1].body
        assert.are.same({ "E_INTERNAL", "bad leg" }, { r.err, r.msg })
    end)

    it("fails the job when its skill throws, after stopping the ship", function()
        local t = setup()
        t.skill.script = { { error = "boom" } }
        t.send("run", "patrol", "j_1")
        t.step(1)
        local r = t.frames("R")[1].body
        assert.are.same({ false, "E_INTERNAL" }, { r.ok, r.err })
        assert.are.equal(1, t.skill.stops)
        assert.truthy(t.logged[1]:find("boom", 1, true))
    end)

    it("cancels the job it is asked to, and only that one", function()
        local t = setup()
        t.send("run", "patrol", "j_1")
        assert.are.same({ "N", { err = "E_STATE", msg = "no job j_2" } }, { t.send("cancel", "j_2") })
        assert.are.same({ "A", { job = "j_1" } }, { t.send("cancel", "j_1") })
        assert.are.equal(1, t.skill.stops)
        local r = t.frames("R")[1].body
        assert.are.same({ job = "j_1", skill = "patrol", ok = false, err = "E_STATE", msg = "cancelled" }, r)
        assert.are.equal("idle", t.rt:status())
    end)

    it("stops the ship on cancel even with no job", function()
        local t = setup()
        assert.are.same({ "A", { data = { idle = true } } }, { t.send("cancel") })
        assert.are.equal(1, t.idleStops)
        assert.are.same({ "N", { err = "E_STATE", msg = "no job j_1" } }, { t.send("cancel", "j_1") })
    end)

    it("pauses and resumes, without counting the pause as running time", function()
        local t = setup()
        t.send("run", "patrol", "j_1")
        t.step(4) -- 1 s
        assert.are.same({ "A", { job = "j_1" } }, { t.send("pause") })
        assert.are.equal("patrol:paused", t.rt:status())
        assert.are.equal(1, t.skill.stops)
        assert.are.same({ "A", { job = "j_1" } }, { t.send("pause") }) -- again: nothing changes
        assert.are.equal(1, t.skill.stops)
        local steps = t.skill.steps
        t.step(40) -- 10 s paused
        assert.are.equal(steps, t.skill.steps)
        t.send("resume")
        assert.are.equal("patrol:one", t.rt:status())
        t.step(4)
        assert.are.equal(1.5, t.rt.job.active) -- the first step after a start or resume only starts the clock
        local moves = {}
        for _, e in ipairs(t.frames("E")) do moves[#moves + 1] = e.body.from .. ">" .. e.body.to end
        assert.are.same({ "idle>one", "one>paused", "paused>one" }, moves)
    end)

    it("refuses pause and resume with no job", function()
        local t = setup()
        assert.are.same({ "N", { err = "E_STATE", msg = "no job running" } }, { t.send("pause") })
        assert.are.same({ "N", { err = "E_STATE", msg = "no job running" } }, { t.send("resume") })
    end)

    it("reports a job that a restart cut off", function()
        local t = setup()
        t.send("run", "patrol", "j_1")
        local t2 = setup()
        t2.store = t.store
        t2.rt = runtime.new({ store = t.store, outbox = t2.outbox, env = t2.env, skills = { patrol = t2.skill } })
        t2.rt:recover()
        local r = t2.frames("R")[1].body
        assert.are.same({ job = "j_1", skill = "patrol", ok = false, err = "E_STATE",
            msg = "interrupted by a restart" }, r)
        assert.is_nil(t.store:get("dub.job"))
        t2.rt:recover() -- only once
        assert.are.equal(0, #t2.frames("R"))
    end)

    it("drops an unreadable dub.job", function()
        local t = setup()
        t.store:set("dub.job", "garbage")
        t.rt:recover()
        assert.are.equal(0, #t.frames("R"))
        assert.is_nil(t.store:get("dub.job"))
        assert.truthy(t.logged[1]:find("unreadable", 1, true))
    end)
end)
