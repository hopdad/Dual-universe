local outbox = require("autoconf/custom/dufleet/outbox")
local frames = require("frames")

local function sent(box, n, maxline)
    return frames.messages(box:drain(n or 100, "b1", maxline or 400))
end

local function kinds(messages)
    local out = {}
    for _, m in ipairs(messages) do out[#out + 1] = m.kind .. m.seq end
    return table.concat(out, " ")
end

describe("outbox", function()
    it("sends by priority, then in queue order, numbering at send time", function()
        local box = outbox.new()
        box:push("D", '{"msg":"d"}')
        box:push("T", '{"v":1}')
        box:push("E", '{"ev":"e1"}')
        box:push("A", '{"ref":1,"e":1}')
        box:push("H", '{"boot":"k3f9","v":"0.1.0","epoch":0,"cseq":0}')
        box:push("N", '{"ref":2,"e":1,"err":"E_BUSY"}')
        assert.are.equal("A1 N2 E3 H4 T5 D6", kinds(sent(box)))
        assert.are.equal(0, box:size())
    end)

    it("keeps only the newest telemetry", function()
        local box = outbox.new()
        box:push("T", '{"v":1}')
        box:push("T", '{"v":2}')
        local m = sent(box)
        assert.are.equal(1, #m)
        assert.are.equal(2, m[1].body.v)
    end)

    it("hands out at most n lines per drain and finishes a chunked frame first", function()
        local box = outbox.new()
        box:push("E", '{"ev":"long","data":{"text":"' .. string.rep("x", 200) .. '"}}')
        box:push("A", '{"ref":1,"e":1}')
        local first = box:drain(2, "b1", 80)
        assert.are.equal(2, #first)
        assert.truthy(first[1]:find("|A|1|1/1|", 1, true))
        assert.truthy(first[2]:find("|E|2|1/", 1, true))
        local rest = {}
        for _ = 1, 10 do
            for _, l in ipairs(box:drain(2, "b1", 80)) do rest[#rest + 1] = l end
        end
        local m = frames.messages({ first[2], table.unpack(rest) })
        assert.are.equal(1, #m)
        assert.are.equal("long", m[1].body.ev)
        assert.is_true(m[1].chunks > 2)
    end)

    it("replays sent A, N, E and R frames with their original seq", function()
        local box = outbox.new()
        box:push("A", '{"ref":1,"e":1}')
        box:push("T", '{"v":1}')
        box:push("E", '{"ev":"e1"}')
        box:push("D", '{"msg":"d"}')
        assert.are.equal("A1 E2 T3 D4", kinds(sent(box)))
        assert.are.equal(1, box:resend(2))
        box:push("R", '{"job":"j_1","skill":"goto","ok":true}')
        assert.are.equal("E2 R5", kinds(sent(box)))
        assert.are.equal(3, box:resend(0))
        assert.are.equal("A1 E2 R5", kinds(sent(box)))
    end)

    it("keeps a bounded ring", function()
        local box = outbox.new({ ringSize = 3 })
        for i = 1, 5 do box:push("E", '{"ev":"e' .. i .. '"}') end
        sent(box)
        assert.are.equal(3, box:resend(0))
        assert.are.equal("E3 E4 E5", kinds(sent(box)))
    end)

    it("drops low-priority frames first when full", function()
        local box = outbox.new({ maxQueue = 3 })
        assert.is_true(box:push("D", '{"msg":"1"}'))
        assert.is_true(box:push("E", '{"ev":"e1"}'))
        assert.is_true(box:push("D", '{"msg":"2"}'))
        assert.is_true(box:push("A", '{"ref":1,"e":1}')) -- drops D "2", the newest of the lowest priority
        assert.is_false(box:push("D", '{"msg":"3"}')) -- nothing ranks below it
        assert.are.equal(2, box.dropped)
        local m = sent(box)
        assert.are.equal("A1 E2 D3", kinds(m))
        assert.are.equal("1", m[3].body.msg)
    end)

    it("counts frames that cannot be encoded and moves on", function()
        local box = outbox.new()
        box:push("D", '{"msg":"' .. string.rep("x", 5000) .. '"}')
        box:push("A", '{"ref":1,"e":1}')
        local m = frames.messages(box:drain(10, "b1", 64))
        assert.are.equal(1, #m)
        assert.are.equal("A", m[1].kind)
        assert.are.equal(1, box.failed)
        assert.are.equal("D: body too long", box.lastError)
    end)
end)
