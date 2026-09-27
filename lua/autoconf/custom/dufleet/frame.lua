-- Outbound frames (docs/protocol.md): one line per chunk,
--   @@DUB|1|<bot>|<kind>|<seq>|<i>/<n>|<crc16>|<body>
-- A body that fits on one line goes as is. A longer one is base64 of its bytes, split
-- into n chunks, where n is the smallest count >= 2 whose lines all fit in maxline
-- bytes, sizing every header as if its index had as many digits as n.

local P = require("autoconf/custom/dufleet/protocol_gen")
local crc16 = require("autoconf/custom/dufleet/crc16")
local base64 = require("autoconf/custom/dufleet/base64")

local format = string.format

local M = {}

function M.validBot(bot)
    return type(bot) == "string" and #bot >= 1 and #bot <= 16 and not bot:find("[^A-Za-z0-9_%-]")
end

local function header(bot, kind, seq, index, total, crc)
    return format("%s|%d|%s|%s|%d|%d/%d|%04X|", P.PREFIX, P.VERSION, bot, kind, seq, index, total, crc)
end

-- Returns the lines, or nil and a reason (the same reasons as the Python codec).
function M.encode(bot, kind, seq, body, maxline)
    if not M.validBot(bot) then return nil, "bad bot id" end
    if not P.KINDS[kind] then return nil, "unknown kind" end
    seq = math.tointeger(seq)
    if not seq or seq < 0 or seq > P.SEQ_MAX then return nil, "seq out of range" end
    maxline = maxline or P.MAXLINE_DEFAULT
    local single = header(bot, kind, seq, 1, 1, crc16.of(body)) .. body
    if #single <= maxline then return { single } end
    local b64 = base64.encode(body)
    local total, size = 2
    while true do
        size = maxline - #header(bot, kind, seq, total, total, 0)
        if size < P.MIN_CHUNK then return nil, "maxline too small" end
        if total * size >= #b64 then break end
        total = total + 1
        if total > P.MAX_CHUNKS then return nil, "body too long" end
    end
    local lines = {}
    for i = 1, total do
        local part = b64:sub((i - 1) * size + 1, i * size)
        lines[i] = header(bot, kind, seq, i, total, crc16.of(part)) .. part
    end
    return lines
end

return M
