-- Compact JSON encoder for frame bodies: sorted object keys, so the same table always
-- gives the same text. The bus never decodes JSON.
--
-- Tables whose keys are exactly 1..n encode as arrays; all others, and empty tables, as
-- objects. NaN and infinities encode as null. Strings must be valid UTF-8 (see clip).

local format, concat, sort = string.format, table.concat, table.sort

local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
    ["\b"] = "\\b", ["\f"] = "\\f" }

local function escape(c)
    return ESCAPES[c] or format("\\u%04x", c:byte())
end

local function isArray(t)
    local n = #t
    if n == 0 then return false end
    local count = 0
    for k in pairs(t) do
        if math.type(k) ~= "integer" or k < 1 or k > n then return false end
        count = count + 1
    end
    return count == n
end

local encode

local function number(n)
    if n ~= n or n == math.huge or n == -math.huge then return "null" end
    if math.type(n) == "integer" then return format("%d", n) end
    if n == math.floor(n) and n > -2 ^ 53 and n < 2 ^ 53 then return format("%d", math.tointeger(n)) end
    return format("%.14g", n)
end

encode = function(v, depth)
    local t = type(v)
    if t == "string" then
        return '"' .. v:gsub('[%c"\\]', escape) .. '"'
    elseif t == "number" then
        return number(v)
    elseif t == "boolean" then
        return v and "true" or "false"
    elseif t == "nil" then
        return "null"
    elseif t == "table" then
        if depth > 16 then error("jsonenc: nesting too deep") end
        local out = {}
        if isArray(v) then
            for i = 1, #v do out[i] = encode(v[i], depth + 1) end
            return "[" .. concat(out, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do
            if type(k) ~= "string" then error("jsonenc: object key is not a string") end
            keys[#keys + 1] = k
        end
        sort(keys)
        for i, k in ipairs(keys) do out[i] = encode(k, depth + 1) .. ":" .. encode(v[k], depth + 1) end
        return "{" .. concat(out, ",") .. "}"
    end
    error("jsonenc: cannot encode a " .. t)
end

local M = {}

function M.encode(v)
    return encode(v, 0)
end

-- At most n bytes of s, cut on a UTF-8 character boundary.
function M.clip(s, n)
    s = tostring(s)
    if #s <= n then return s end
    local cut = n
    while cut > 0 do
        local b = s:byte(cut + 1)
        if b == nil or b < 0x80 or b >= 0xC0 then break end
        cut = cut - 1
    end
    return s:sub(1, cut)
end

return M
