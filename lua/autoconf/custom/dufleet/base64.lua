-- Base64 with the standard alphabet and padding (RFC 4648), over bytes.

local byte, char, concat = string.byte, string.char, table.concat

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local ENC, DEC = {}, {}
for i = 1, 64 do
    local c = ALPHABET:sub(i, i)
    ENC[i - 1] = c
    DEC[byte(c)] = i - 1
end

local M = {}

function M.encode(s)
    local out, n = {}, #s
    for i = 1, n - 2, 3 do
        local a, b, c = byte(s, i, i + 2)
        local v = (a << 16) | (b << 8) | c
        out[#out + 1] = ENC[v >> 18] .. ENC[(v >> 12) & 63] .. ENC[(v >> 6) & 63] .. ENC[v & 63]
    end
    local rest = n % 3
    if rest == 1 then
        local v = byte(s, n) << 16
        out[#out + 1] = ENC[v >> 18] .. ENC[(v >> 12) & 63] .. "=="
    elseif rest == 2 then
        local a, b = byte(s, n - 1, n)
        local v = (a << 16) | (b << 8)
        out[#out + 1] = ENC[v >> 18] .. ENC[(v >> 12) & 63] .. ENC[(v >> 6) & 63] .. "="
    end
    return concat(out)
end

-- Returns nil for anything that is not canonical padded base64.
function M.decode(s)
    local n = #s
    if n % 4 ~= 0 then return nil end
    local out = {}
    for i = 1, n, 4 do
        local a, b, c, d = byte(s, i, i + 3)
        local last = i + 3 == n
        local va, vb = DEC[a], DEC[b]
        local vc = DEC[c] or (last and c == 61 and d == 61 and 0) or nil
        local vd = DEC[d] or (last and d == 61 and 0) or nil
        if not (va and vb and vc and vd) then return nil end
        local v = (va << 18) | (vb << 12) | (vc << 6) | vd
        if last and d == 61 then
            if c == 61 then
                if v & 0xFFFF ~= 0 then return nil end
                out[#out + 1] = char(v >> 16)
            else
                if v & 0xFF ~= 0 then return nil end
                out[#out + 1] = char(v >> 16, (v >> 8) & 0xFF)
            end
        else
            out[#out + 1] = char(v >> 16, (v >> 8) & 0xFF, v & 0xFF)
        end
    end
    return concat(out)
end

return M
