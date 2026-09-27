-- Optical test frame for spike S1.
--
-- The layout and the pseudo-random pattern must match
-- spikes/host/src/dufleet_probe/pattern.py exactly; the host tests compare the
-- two. Units are cells; the SVG viewBox scales them to pixels.
--
-- Canvas of W x H cells: a 1-cell black border, four white 2x2 fiducials in the
-- corners, a 1-cell quiet zone, then the COLS x ROWS data grid. Data cell 0 is a
-- mode marker (blue = 2 bits per cell, green = 1 bit). The next cells carry a
-- 32-bit header (seq:16, meta:8, crc8:8), sent most significant symbol first.
-- Every remaining cell comes from xorshift32 seeded by seq, so the decoder can
-- check each cell without knowing anything but the header.

local M = {}

local COLS, ROWS, MARGIN = 48, 24, 4
local W, H = COLS + 2 * MARGIN, ROWS + 2 * MARGIN
M.COLS, M.ROWS, M.MARGIN, M.W, M.H = COLS, ROWS, MARGIN, W, H
M.VERSION = 1

-- Colour indexes: 0 black, 1 red, 2 green, 3 blue. White is reserved for fiducials.
M.PALETTE = { [0] = "#000000", [1] = "#FF0000", [2] = "#00FF00", [3] = "#0000FF" }
local MARKER = { [1] = 2, [2] = 3 }
local ONE_BIT = { [0] = 0, [1] = 2 }
M.FIDUCIALS = { { 1, 1 }, { W - 3, 1 }, { 1, H - 3 }, { W - 3, H - 3 } }

local MASK32 = 0xFFFFFFFF

local function xorshift32(x)
    x = x ~ ((x << 13) & MASK32)
    x = x ~ (x >> 17)
    x = x ~ ((x << 5) & MASK32)
    return x
end

local function seed(seq)
    local x = (seq * 0x9E3779B1 + 0x7F4A7C15) & MASK32
    if x == 0 then x = 1 end
    return x
end

-- CRC-8/SMBUS: polynomial 0x07, initial value 0, no reflection.
local function crc8(bytes)
    local crc = 0
    for i = 1, #bytes do
        crc = crc ~ bytes[i]
        for _ = 1, 8 do
            if (crc & 0x80) ~= 0 then
                crc = ((crc << 1) ~ 0x07) & 0xFF
            else
                crc = (crc << 1) & 0xFF
            end
        end
    end
    return crc
end

local function header(seq, bits)
    local meta = (M.VERSION << 4) | bits
    local hi, lo = (seq >> 8) & 0xFF, seq & 0xFF
    return (hi << 24) | (lo << 16) | (meta << 8) | crc8({ hi, lo, meta })
end

-- Returns the colour index of every data cell, row by row (index 1 = row 0, column 0).
function M.cells(seq, bits)
    assert(bits == 1 or bits == 2, "bits must be 1 or 2")
    seq = seq & 0xFFFF
    local mask = (1 << bits) - 1
    local map = (bits == 1) and ONE_BIT or nil
    local cells = { MARKER[bits] }
    local word = header(seq, bits)
    local headerCells = 32 // bits
    for k = 0, headerCells - 1 do
        local symbol = (word >> (32 - bits * (k + 1))) & mask
        cells[k + 2] = map and map[symbol] or symbol
    end
    local x = seed(seq)
    for i = headerCells + 2, COLS * ROWS do
        x = xorshift32(x)
        local symbol = (x >> 24) & mask
        cells[i] = map and map[symbol] or symbol
    end
    return cells
end

-- Renders the cells as one absolutely positioned SVG. Runs of equal cells along a
-- row are merged into one subpath, one path per colour, to keep the string small.
function M.svg(cells, x, y, cell)
    local out = {
        string.format('<svg xmlns="http://www.w3.org/2000/svg" style="position:absolute;left:%dpx;top:%dpx;z-index:100"'
            .. ' width="%d" height="%d" viewBox="0 0 %d %d" shape-rendering="crispEdges">',
            x, y, W * cell, H * cell, W, H),
        string.format('<rect width="%d" height="%d" fill="#000000"/>', W, H),
    }
    for _, f in ipairs(M.FIDUCIALS) do
        out[#out + 1] = string.format('<rect x="%d" y="%d" width="2" height="2" fill="#FFFFFF"/>', f[1], f[2])
    end
    local runs = { {}, {}, {} }
    for r = 0, ROWS - 1 do
        local base = r * COLS
        local c = 0
        while c < COLS do
            local v = cells[base + c + 1]
            local n = 1
            while c + n < COLS and cells[base + c + n + 1] == v do
                n = n + 1
            end
            if v ~= 0 then
                local t = runs[v]
                t[#t + 1] = "M" .. (MARGIN + c) .. " " .. (MARGIN + r) .. "h" .. n .. "v1h-" .. n .. "z"
            end
            c = c + n
        end
    end
    for v = 1, 3 do
        if #runs[v] > 0 then
            out[#out + 1] = '<path fill="' .. M.PALETTE[v] .. '" stroke="none" d="' .. table.concat(runs[v]) .. '"/>'
        end
    end
    out[#out + 1] = "</svg>"
    return table.concat(out)
end

M._crc8 = crc8
M._xorshift32 = xorshift32
M._seed = seed

return M
