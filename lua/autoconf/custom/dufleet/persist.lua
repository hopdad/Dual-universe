-- The bus's keys in ArchHUD's databank (dbHud_1), all prefixed "dub.". ArchHUD writes
-- only its own keys there and never clears it. Without a linked databank, values live
-- in memory until the unit stops.
--
-- The watermark and last reply share one key, written in a single call:
--   dub.last = "<epoch>|<cseq>|<A or N>|<reply body JSON>"

local M = {}
local Store = {}
Store.__index = Store

function M.new(db)
    return setmetatable({ db = db, mem = {} }, Store)
end

function Store:persistent()
    return self.db ~= nil
end

-- A missing key reads as nil. The databank itself returns "" for it, so ask hasKey,
-- which answers 1 or 0 (true or false in older builds).
function Store:get(key)
    if not self.db then return self.mem[key] end
    local has = self.db.hasKey(key)
    if has == 1 or has == true then return self.db.getStringValue(key) end
    return nil
end

function Store:set(key, value)
    value = tostring(value)
    if self.db then
        self.db.setStringValue(key, value)
    else
        self.mem[key] = value
    end
end

function Store:del(key)
    if self.db then
        self.db.clearValue(key)
    else
        self.mem[key] = nil
    end
end

-- epoch, cseq, reply kind, reply body; plus a problem string if the key was unreadable.
function Store:last()
    local s = self:get("dub.last")
    if not s then return 0, 0, nil, nil end
    local es, cs, kind, body = s:match("^(%d+)|(%d+)|([AN])|({.*})$")
    local e = es and math.tointeger(tonumber(es))
    local c = cs and math.tointeger(tonumber(cs))
    if not (e and c) then return 0, 0, nil, nil, "dub.last unreadable, starting from epoch 0" end
    return e, c, kind, body
end

function Store:setLast(epoch, cseq, kind, body)
    self:set("dub.last", string.format("%d|%d|%s|%s", epoch, cseq, kind, body))
end

return M
