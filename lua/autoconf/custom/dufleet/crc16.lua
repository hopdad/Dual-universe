-- CRC-16/CCITT-FALSE: polynomial 0x1021, initial value 0xFFFF, no reflection, no final XOR.
-- Check value: crc16.of("123456789") == 0x29B1.

local byte = string.byte

local TABLE = {}
for b = 0, 255 do
    local crc = b << 8
    for _ = 1, 8 do
        if crc & 0x8000 ~= 0 then
            crc = ((crc << 1) ~ 0x1021) & 0xFFFF
        else
            crc = (crc << 1) & 0xFFFF
        end
    end
    TABLE[b] = crc
end

local M = {}

function M.of(s)
    local crc = 0xFFFF
    for i = 1, #s do
        crc = ((crc << 8) & 0xFFFF) ~ TABLE[(crc >> 8) ~ byte(s, i)]
    end
    return crc
end

function M.hex(s)
    return string.format("%04X", M.of(s))
end

return M
