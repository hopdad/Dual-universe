-- Outbound queue (docs/protocol.md, "Outbox rules").
--
-- push() queues a frame body. drain() hands out up to n lines per call: lower priority
-- numbers first, then in the order frames were queued. A frame's seq is assigned when
-- it starts to go out, so seqs follow send order. A chunked frame finishes before the
-- next one starts. Only the newest T waits in the queue. Sent A, N, E and R frames go
-- into a ring, and resend() queues them again with their original seq.

local P = require("autoconf/custom/dufleet/protocol_gen")
local frame = require("autoconf/custom/dufleet/frame")

local PRIORITY = P.PRIORITY

local M = {}
local Outbox = {}
Outbox.__index = Outbox

function M.new(opts)
    opts = opts or {}
    return setmetatable({
        queue = {}, -- { kind, body, order, seq (only for resent frames) }
        ring = {}, -- sent replayable frames, oldest first: { seq, kind, body }
        ringSize = opts.ringSize or P.REPLAY_RING,
        maxQueue = opts.maxQueue or 64,
        seq = 0, -- the last seq assigned
        order = 0,
        current = nil, -- lines of the frame going out
        currentPos = 1,
        dropped = 0, -- frames dropped because the queue was full
        failed = 0, -- frames that could not be encoded
        lastError = nil,
    }, Outbox)
end

-- Frames waiting, counting a partly sent one.
function Outbox:size()
    return #self.queue + (self.current and 1 or 0)
end

local function add(self, entry)
    self.order = self.order + 1
    entry.order = self.order
    self.queue[#self.queue + 1] = entry
end

function Outbox:push(kind, body)
    if kind == "T" then
        for _, e in ipairs(self.queue) do
            if e.kind == "T" then
                e.body = body
                return true
            end
        end
    end
    if #self.queue >= self.maxQueue then
        -- Make room by dropping the newest frame of the lowest priority, if it ranks below this one.
        local victim
        for i, e in ipairs(self.queue) do
            local v = victim and self.queue[victim]
            if not v or PRIORITY[e.kind] > PRIORITY[v.kind]
                or (PRIORITY[e.kind] == PRIORITY[v.kind] and e.order > v.order) then
                victim = i
            end
        end
        self.dropped = self.dropped + 1
        if PRIORITY[self.queue[victim].kind] <= PRIORITY[kind] then return false end
        table.remove(self.queue, victim)
    end
    add(self, { kind = kind, body = body })
    return true
end

-- Queues the ring frames with seq >= from again. Returns how many.
function Outbox:resend(from)
    local n = 0
    for _, r in ipairs(self.ring) do
        if r.seq >= from then
            add(self, { kind = r.kind, body = r.body, seq = r.seq })
            n = n + 1
        end
    end
    return n
end

local function nextIndex(queue)
    local best
    for i, e in ipairs(queue) do
        local b = best and queue[best]
        if not b or PRIORITY[e.kind] < PRIORITY[b.kind]
            or (PRIORITY[e.kind] == PRIORITY[b.kind] and e.order < b.order) then
            best = i
        end
    end
    return best
end

-- Up to n lines for the transport.
function Outbox:drain(n, bot, maxline)
    local out = {}
    while #out < n do
        if self.current then
            out[#out + 1] = self.current[self.currentPos]
            self.currentPos = self.currentPos + 1
            if self.currentPos > #self.current then self.current = nil end
        else
            local i = nextIndex(self.queue)
            if not i then break end
            local e = table.remove(self.queue, i)
            local seq = e.seq
            if not seq then
                self.seq = self.seq + 1
                seq = self.seq
            end
            local lines, reason = frame.encode(bot, e.kind, seq, e.body, maxline)
            if lines then
                if not e.seq and P.REPLAYABLE[e.kind] then
                    self.ring[#self.ring + 1] = { seq = seq, kind = e.kind, body = e.body }
                    if #self.ring > self.ringSize then table.remove(self.ring, 1) end
                end
                self.current, self.currentPos = lines, 1
            else
                self.failed = self.failed + 1
                self.lastError = e.kind .. ": " .. reason
            end
        end
    end
    return out
end

return M
