-- One queue for command lines from every source: chat now, the inbox (Transport F) and
-- receivers (Phase 3) later. Each line is parsed, checked against the watermark, and,
-- if new, run through its handler (docs/protocol.md, "Delivery, dedupe and epochs").
--
-- A handler returns "A" or "N", the reply fields (the dispatcher adds ref and e), and
-- optionally a function to run after the reply is queued. The watermark and the reply
-- are persisted before the reply is queued, so a retry after a restart is answered from
-- the databank instead of running the command again.

local command = require("autoconf/custom/dufleet/command")
local dedupe = require("autoconf/custom/dufleet/dedupe")
local jsonenc = require("autoconf/custom/dufleet/jsonenc")

local M = {}
local Dispatcher = {}
Dispatcher.__index = Dispatcher

-- ctx needs: store (persist), outbox, handlers (verb -> function), and optionally log(msg).
function M.new(ctx, opts)
    opts = opts or {}
    local d = setmetatable({ ctx = ctx, lines = {}, maxLines = opts.maxLines or 8, dropped = 0,
        epoch = 0, cseq = 0, replyKind = nil, replyBody = nil }, Dispatcher)
    local e, c, kind, body, problem = ctx.store:last()
    d.epoch, d.cseq, d.replyKind, d.replyBody = e, c, kind, body
    if problem then d:log(problem) end
    return d
end

function Dispatcher:log(msg)
    if self.ctx.log then self.ctx.log(msg) end
end

-- Queues a line; false if the queue is full (the companion will retry).
function Dispatcher:submit(line)
    if #self.lines >= self.maxLines then
        self.dropped = self.dropped + 1
        return false
    end
    self.lines[#self.lines + 1] = line
    return true
end

-- Handles up to n queued lines.
function Dispatcher:step(n)
    for _ = 1, n or 1 do
        local line = table.remove(self.lines, 1)
        if not line then return end
        self:handle(line)
    end
end

local function refuse(self, ref, epoch, code, msg)
    self.ctx.outbox:push("N", jsonenc.encode({ ref = ref, e = epoch, err = code, msg = jsonenc.clip(msg, 120) }))
end

-- Stored replies are objects written by jsonenc and always hold ref and e.
local function withDup(body)
    return '{"dup":true,' .. body:sub(2)
end

-- Returns the outcome: "error" (refused by the parser) or one of dedupe's outcomes.
function Dispatcher:handle(line)
    local cmd, err = command.parse(line)
    if not cmd then
        refuse(self, err.ref, err.epoch, err.code, err.msg)
        return "error"
    end
    local outcome = dedupe.decide(self.epoch, self.cseq, cmd.epoch, cmd.cseq)
    if outcome == "stale" then
        refuse(self, cmd.cseq, cmd.epoch, "E_EPOCH", "current epoch is " .. self.epoch)
    elseif outcome == "superseded" then
        refuse(self, cmd.cseq, cmd.epoch, "E_STATE", "superseded by cseq " .. self.cseq)
    elseif outcome == "replay" then
        if self.replyBody then
            self.ctx.outbox:push(self.replyKind, withDup(self.replyBody))
        else
            refuse(self, cmd.cseq, cmd.epoch, "E_STATE", "no stored reply")
        end
    else
        self:execute(cmd)
    end
    return outcome
end

function Dispatcher:execute(cmd)
    local handler = self.ctx.handlers[cmd.verb]
    local kind, fields, after
    if handler then
        local ok, k, f, a = pcall(handler, cmd, self.ctx)
        if ok and (k == "A" or k == "N") and type(f) == "table" then
            kind, fields, after = k, f, a
        else
            kind, fields = "N", { err = "E_INTERNAL", msg = ok and "handler returned no reply" or tostring(k) }
        end
    else
        kind, fields = "N", { err = "E_INTERNAL", msg = "no handler for " .. cmd.verb }
    end
    if fields.msg then fields.msg = jsonenc.clip(fields.msg, 120) end
    fields.ref, fields.e = cmd.cseq, cmd.epoch
    local body = jsonenc.encode(fields)
    self.ctx.store:setLast(cmd.epoch, cmd.cseq, kind, body)
    self.epoch, self.cseq, self.replyKind, self.replyBody = cmd.epoch, cmd.cseq, kind, body
    self.ctx.outbox:push(kind, body)
    if after then
        local ok, e = pcall(after)
        if not ok then self:log(cmd.verb .. " follow-up failed: " .. tostring(e)) end
    end
end

return M
