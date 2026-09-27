-- The Lua codec against packages/protocol/vectors.json (the same file the Python tests use).
local V = require("vectors")
local vectors, fromHex = V.data, V.fromHex

local crc16 = require("autoconf/custom/dufleet/crc16")
local base64 = require("autoconf/custom/dufleet/base64")
local frame = require("autoconf/custom/dufleet/frame")
local command = require("autoconf/custom/dufleet/command")
local dedupe = require("autoconf/custom/dufleet/dedupe")

describe("vectors", function()
    it("crc16", function()
        for _, c in ipairs(vectors.crc16) do
            assert.are.equal(c.crc, crc16.hex(fromHex(c.hex)), c.name)
        end
    end)

    it("base64 encodes and decodes", function()
        for _, c in ipairs(vectors.base64) do
            assert.are.equal(c.b64, base64.encode(fromHex(c.hex)))
            assert.are.equal(fromHex(c.hex), base64.decode(c.b64))
        end
    end)

    it("frames encode to the same lines", function()
        for _, c in ipairs(vectors.frames) do
            local lines, reason = frame.encode(c.bot, c.kind, c.seq, c.body, c.maxline)
            assert.is_nil(reason, c.name)
            assert.are.same(c.lines, lines, c.name)
            for _, line in ipairs(lines) do
                assert.is_true(#line <= c.maxline, c.name)
            end
        end
    end)

    it("frame errors give the same reasons", function()
        for _, c in ipairs(vectors.frame_errors) do
            local lines, reason = frame.encode(c.bot, c.kind, c.seq, c.body, c.maxline)
            assert.is_nil(lines, c.name)
            assert.are.equal(c.error, reason, c.name)
        end
    end)

    it("commands parse to the same fields", function()
        for _, c in ipairs(vectors.commands) do
            local cmd, err = command.parse(c.line)
            assert.is_nil(err, c.line)
            assert.are.equal(c.epoch, cmd.epoch)
            assert.are.equal(c.cseq, cmd.cseq)
            assert.are.equal(c.verb, cmd.verb)
            assert.are.same(c.args, cmd.args)
            assert.are.same(c.named, cmd.named)
            assert.are.same(c.params, cmd.params)
            assert.are.equal(c.line, command.build(c.epoch, c.cseq, c.verb, table.unpack(c.args)))
        end
    end)

    it("bad commands give the same code, ref and epoch", function()
        for _, c in ipairs(vectors.command_errors) do
            local cmd, err = command.parse(c.line)
            assert.is_nil(cmd, c.name)
            assert.are.same({ c.code, c.ref, c.epoch }, { err.code, err.ref, err.epoch }, c.name)
        end
    end)

    it("dedupe", function()
        for _, c in ipairs(vectors.dedupe) do
            assert.are.equal(c.outcome, dedupe.decide(c.last[1], c.last[2], c.cmd[1], c.cmd[2]))
        end
    end)
end)

describe("base64.decode", function()
    it("refuses what is not canonical padded base64", function()
        for _, s in ipairs({ "Zg=", "Zg", "Z===", "Zh==", "Zm9=", "Zm9v=", "=Zm9", "Zm9v!A==", "Zm=v" }) do
            assert.is_nil(base64.decode(s), s)
        end
    end)
end)

describe("command.parse", function()
    it("never throws", function()
        local seeds = {}
        for _, c in ipairs(vectors.commands) do seeds[#seeds + 1] = c.line end
        for _, c in ipairs(vectors.command_errors) do seeds[#seeds + 1] = c.line end
        local chars = { "#", " ", ".", "=", "::pos", "\t", "\195\169", "0", "9", "A", "z", "/", "b", "\"" }
        math.randomseed(1)
        for _, seed in ipairs(seeds) do
            for _ = 1, 100 do
                local s = seed
                for _ = 1, math.random(1, 4) do
                    local i = math.random(0, #s)
                    local op = math.random(3)
                    if op == 1 then
                        s = s:sub(1, i) .. chars[math.random(#chars)] .. s:sub(i + 1)
                    elseif op == 2 then
                        s = s:sub(1, i - 1) .. s:sub(i + 1)
                    else
                        s = s:sub(1, i - 1) .. chars[math.random(#chars)] .. s:sub(i + 1)
                    end
                end
                local ok, cmd, err = pcall(command.parse, s)
                assert.is_true(ok, s)
                assert.is_true((cmd ~= nil) ~= (err ~= nil), s)
            end
        end
        for _, v in ipairs({ 42, true, {}, "", "/b", "/b ", "/b  #0000" }) do
            local ok, cmd = pcall(command.parse, v)
            assert.is_true(ok)
            assert.is_nil(cmd)
        end
    end)
end)
