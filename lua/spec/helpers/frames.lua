-- Test-only reader for the bus's outbound lines: splits each at most 7 times, checks
-- the CRC, reassembles chunks and decodes the JSON body.
local json = require("dkjson")
local crc16 = require("autoconf/custom/dufleet/crc16")
local base64 = require("autoconf/custom/dufleet/base64")

local M = {}

function M.parseLine(line)
    local start = line:find("@@DUB|", 1, true)
    if not start then return nil end
    local parts, pos = {}, start
    for _ = 1, 7 do
        local s = line:find("|", pos, true)
        if not s then return nil, "too few fields" end
        parts[#parts + 1] = line:sub(pos, s - 1)
        pos = s + 1
    end
    parts[8] = line:sub(pos)
    local i, n = parts[6]:match("^(%d+)/(%d+)$")
    assert(crc16.hex(parts[8]) == parts[7], "crc mismatch in " .. line)
    return { version = parts[2], bot = parts[3], kind = parts[4], seq = math.tointeger(tonumber(parts[5])),
        index = math.tointeger(tonumber(i)), total = math.tointeger(tonumber(n)), body = parts[8] }
end

-- Complete messages from a list of lines: { bot, kind, seq, body (decoded), text, chunks }.
function M.messages(lines)
    local out, pending = {}, {}
    for _, line in ipairs(lines) do
        local c = M.parseLine(line)
        if c then
            local text
            if c.total == 1 then
                text = c.body
            else
                local key = c.bot .. "|" .. c.kind .. "|" .. c.seq .. "|" .. c.total
                pending[key] = pending[key] or {}
                pending[key][c.index] = c.body
                local parts = pending[key]
                local have = 0
                for _ in pairs(parts) do have = have + 1 end
                if have == c.total then
                    text = assert(base64.decode(table.concat(parts)), "bad base64")
                    pending[key] = nil
                end
            end
            if text then
                local body = assert(json.decode(text), "bad json: " .. text)
                out[#out + 1] = { bot = c.bot, kind = c.kind, seq = c.seq, body = body, text = text, chunks = c.total }
            end
        end
    end
    return out
end

function M.ofKind(messages, kind)
    local out = {}
    for _, m in ipairs(messages) do
        if m.kind == kind then out[#out + 1] = m end
    end
    return out
end

return M
