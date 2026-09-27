-- Inbound commands (docs/protocol.md):  /b <epoch>.<cseq> <verb> [args...] #<crc16>
--
-- parse() never throws. It applies the checks in the documented order, so a line gets
-- the same error code, ref and epoch here as in the Python codec (vectors.json):
--   E_PARSE (ref 0), then E_CRC, then E_VERB, then E_ARGS.

local P = require("autoconf/custom/dufleet/protocol_gen")
local crc16 = require("autoconf/custom/dufleet/crc16")

local M = {}

local function fail(code, msg, ref, epoch)
    return nil, { code = code, msg = msg, ref = ref or 0, epoch = epoch or 0 }
end

-- Printable ASCII except space, '"', '#' and '\', between lo and hi bytes long.
local function plain(s, lo, hi)
    return #s >= lo and #s <= hi and not s:find("[^!-~]") and not s:find('["#\\]')
end

-- A decimal integer without leading zeros and with at most maxDigits digits.
local function digits(s, maxDigits)
    return s == "0" or (#s <= maxDigits and s:find("^[1-9]%d*$") ~= nil)
end

local CHECK = {
    uint = function(v) return digits(v, 10) end,
    bot = function(v) return #v >= 1 and #v <= 16 and not v:find("[^A-Za-z0-9_%-]") end,
    job = function(v) return #v <= 18 and v:find("^j_[A-Za-z0-9]+$") ~= nil end,
    dbkey = function(v) return #v <= 44 and v:find("^dub%.[a-z0-9_.]+$") ~= nil end,
    kv = function(v)
        local key, value = v:match("^([a-z][a-z0-9_]*)=(.*)$")
        return key ~= nil and #key <= 16 and plain(value, 1, 120)
    end,
    text = function(v) return plain(v, 1, 200) end,
    chan = function(v) return plain(v, 1, 64) end,
    b64 = function(v) return v:find("^[A-Za-z0-9+/]+=?=?$") ~= nil end,
}

local function checkArg(value, spec)
    if spec.type == "enum" then
        for _, allowed in ipairs(spec.values) do
            if value == allowed then return true end
        end
        return false
    elseif spec.type == "skill" then
        return P.SKILLS[value] == true
    end
    local check = CHECK[spec.type]
    return check ~= nil and check(value)
end

local function split(core)
    local tokens, pos = {}, 1
    while true do
        local s = core:find(" ", pos, true)
        if not s then
            tokens[#tokens + 1] = core:sub(pos)
            return tokens
        end
        tokens[#tokens + 1] = core:sub(pos, s - 1)
        pos = s + 1
    end
end

-- Returns a command table {epoch, cseq, verb, args, named, params}, or nil and an
-- error table {code, msg, ref, epoch}.
function M.parse(line)
    if type(line) ~= "string" or line:sub(1, #P.COMMAND_PREFIX) ~= P.COMMAND_PREFIX then
        return fail("E_PARSE", "missing /b prefix")
    end
    if #line > P.COMMAND_MAX then return fail("E_PARSE", "line too long") end
    if line:find("[^ -~]") or line:find('["\\]') then return fail("E_PARSE", "character not allowed") end
    local core, crc = line:sub(#P.COMMAND_PREFIX + 1):match("^(.*) #([0-9A-F][0-9A-F][0-9A-F][0-9A-F])$")
    if not core then return fail("E_PARSE", "missing CRC") end
    if core:find("#", 1, true) then return fail("E_PARSE", "'#' inside the command") end
    if line:find("::pos", 1, true) then return fail("E_PARSE", "contains ::pos") end
    local tokens = split(core)
    if #tokens < 2 then return fail("E_PARSE", "bad spacing") end
    for _, t in ipairs(tokens) do
        if t == "" then return fail("E_PARSE", "bad spacing") end
    end
    local es, cs = tokens[1]:match("^(%d+)%.(%d+)$")
    if not es or not digits(es, 5) or not digits(cs, 10) then return fail("E_PARSE", "bad header") end
    local epoch, cseq = math.tointeger(tonumber(es)), math.tointeger(tonumber(cs))
    if epoch < 1 or epoch > P.EPOCH_MAX or cseq < 1 or cseq > P.CSEQ_MAX then
        return fail("E_PARSE", "header out of range")
    end
    if crc16.of(core) ~= tonumber(crc, 16) then return fail("E_CRC", "CRC mismatch", cseq, epoch) end
    local verb = tokens[2]
    local spec = verb:find("^[a-z]+$") and P.VERBS[verb]
    if not spec then return fail("E_VERB", "unknown verb " .. verb:sub(1, 20), cseq, epoch) end

    local args, named, params = {}, {}, {}
    for i = 3, #tokens do args[#args + 1] = tokens[i] end
    local pos = 1
    for _, arg in ipairs(spec.args) do
        if arg.variadic then
            while pos <= #args do
                local value = args[pos]
                if not checkArg(value, arg) then return fail("E_ARGS", "bad " .. arg.name, cseq, epoch) end
                local key, val = value:match("^([^=]*)=(.*)$")
                if params[key] ~= nil then return fail("E_ARGS", "duplicate " .. key, cseq, epoch) end
                params[key] = val
                pos = pos + 1
            end
        elseif pos > #args then
            if not arg.optional then return fail("E_ARGS", "missing " .. arg.name, cseq, epoch) end
        else
            local value = args[pos]
            if not checkArg(value, arg) then return fail("E_ARGS", "bad " .. arg.name, cseq, epoch) end
            named[arg.name] = value
            pos = pos + 1
        end
    end
    if pos <= #args then return fail("E_ARGS", "too many arguments", cseq, epoch) end
    if verb == "db" and (named.op == "set") ~= (named.value ~= nil) then
        return fail("E_ARGS", "db set needs a value; get and del take none", cseq, epoch)
    end
    return { epoch = epoch, cseq = cseq, verb = verb, args = args, named = named, params = params }
end

-- Builds a command line (for tests and tools). Raises if the result would not parse.
function M.build(epoch, cseq, verb, ...)
    local parts = { string.format("%d.%d", epoch, cseq), verb, ... }
    local core = table.concat(parts, " ")
    local line = P.COMMAND_PREFIX .. core .. " #" .. crc16.hex(core)
    local ok, err = M.parse(line)
    if not ok then error(err.code .. ": " .. err.msg) end
    return line
end

return M
