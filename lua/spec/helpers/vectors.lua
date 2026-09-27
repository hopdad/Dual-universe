-- packages/protocol/vectors.json, the contract shared with the Python codec.
local json = require("dkjson")

local f = assert(io.open("../packages/protocol/vectors.json", "r"))
local text = f:read("a")
f:close()
local vectors, _, err = json.decode(text)
assert(vectors, err)

local function fromHex(hex)
    return (hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
end

return { data = vectors, fromHex = fromHex, json = json }
