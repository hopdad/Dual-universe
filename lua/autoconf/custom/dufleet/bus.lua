-- The bot bus. Runs inside ArchHUD's control unit, loaded by archhud/userclass.lua.
--
-- At start it wraps ArchHUD's chat input and timer entry points (archhud_adapter),
-- starts its own "dub" timer, and sends H. On each tick it handles one queued command,
-- sends T at the configured rate and H every 30 s, and hands the transport up to
-- `lines` outbound lines. Every entry point runs under pcall, so a bus error becomes a
-- D frame and never stops ArchHUD.
--
-- Outbound transport for now: system.print (Transport L). The optical transport and
-- the inbox wait for ADR-0001.

local P = require("autoconf/custom/dufleet/protocol_gen")
local adapter = require("autoconf/custom/dufleet/archhud_adapter")
local builtins = require("autoconf/custom/dufleet/builtins")
local dispatcher = require("autoconf/custom/dufleet/dispatcher")
local frame = require("autoconf/custom/dufleet/frame")
local game = require("autoconf/custom/dufleet/game")
local jsonenc = require("autoconf/custom/dufleet/jsonenc")
local outbox = require("autoconf/custom/dufleet/outbox")
local persist = require("autoconf/custom/dufleet/persist")

local M = { VERSION = "0.1.0", TIMER = "dub" }

-- Settings, overridable with `db set dub.cfg.<name> <value>`; read at start.
M.DEFAULTS = { tick = 0.25, maxline = P.MAXLINE_DEFAULT, lines = 2, telemetry = 1 }
local LIMITS = { tick = { 0.05, 5 }, maxline = { 64, 12800 }, lines = { 1, 20 }, telemetry = { 0.25, 60 } }
local INTEGERS = { maxline = true, lines = true }

local function round1(x)
    return math.floor(x * 10 + 0.5) / 10
end

local Bus = {}
Bus.__index = Bus

-- opts.sink(line) replaces system.print as the outbound transport.
function M.new(opts)
    opts = opts or {}
    return setmetatable({ sink = opts.sink or game.print, started = false, errors = 0, lastError = nil,
        printedErrors = 0, lastDebug = nil, suppressed = 0, state = "idle" }, Bus)
end

function Bus:guard(name, fn, ...)
    local ok, err = pcall(fn, ...)
    if ok then return true end
    self.errors = self.errors + 1
    self.lastError = name .. ": " .. tostring(err)
    if self.printedErrors < 5 then
        self.printedErrors = self.printedErrors + 1
        pcall(game.print, "dufleet error (" .. self.lastError .. ")")
    end
    if self.outbox then pcall(self.debug, self, self.lastError) end
    return false
end

-- A D frame, at most one per second; the rest are counted.
function Bus:debug(msg)
    local t = game.now()
    if self.lastDebug and t - self.lastDebug < 1 then
        self.suppressed = self.suppressed + 1
        return
    end
    self.lastDebug = t
    self.outbox:push("D", jsonenc.encode({ msg = jsonenc.clip(msg, 300) }))
end

function Bus:config()
    local cfg = {}
    for k, default in pairs(M.DEFAULTS) do
        local n = tonumber(self.store:get("dub.cfg." .. k) or "")
        if n and n >= LIMITS[k][1] and n <= LIMITS[k][2] then
            cfg[k] = INTEGERS[k] and math.floor(n) or n
        else
            cfg[k] = default
        end
    end
    return cfg
end

-- The id in frames: dub.id, else "c" plus the construct id, else "bot".
function Bus:botId()
    local id = self.store:get("dub.id")
    if id and frame.validBot(id) then return id end
    local cid = game.constructId()
    if cid and frame.validBot("c" .. cid) then return "c" .. cid end
    return "bot"
end

function Bus:sendHello()
    local d = self.dispatcher
    self.outbox:push("H", jsonenc.encode({
        boot = self.boot, v = M.VERSION, epoch = d.epoch, cseq = d.cseq,
        id = jsonenc.clip(self.store:get("dub.id") or "", 16), ah = adapter.version(), tr = "L",
        ml = self.cfg.maxline, q = self.outbox:size(),
    }))
end

function Bus:sendTelemetry()
    local t = { st = self.state, ap = adapter.autopilot() }
    local p = game.position()
    if p then t.w = { round1(p[1]), round1(p[2]), round1(p[3]) } end
    local v = game.velocity()
    if v then t.v = round1(math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3]) * 3.6) end
    local alt = game.altitude()
    if alt then t.alt = round1(alt) end
    self.outbox:push("T", jsonenc.encode(t))
end

function Bus:start()
    local problem = adapter.problem()
    if problem then error(problem) end
    self.store = persist.new(adapter.databank())
    if not self.store:get("dub.schema") then self.store:set("dub.schema", "1") end
    self.cfg = self:config()
    self.outbox = outbox.new()
    self.handlers = builtins.install({}, {
        store = self.store,
        outbox = self.outbox,
        sendHello = function() self:sendHello() end,
        sendTelemetry = function() self:sendTelemetry() end,
        setId = function(id)
            self.store:set("dub.id", id)
            self.id = id
        end,
    })
    self.dispatcher = dispatcher.new({ store = self.store, outbox = self.outbox, handlers = self.handlers,
        log = function(msg) self:debug(msg) end })
    self.id = self:botId()
    local t = game.now()
    self.boot = string.format("%08x", math.floor(t * 1000) % 0x100000000)
    self.nextTelemetry, self.nextHello = t, t + P.HELLO_INTERVAL_S
    adapter.hook(M.TIMER,
        function(text) self:guard("input", self.dispatcher.submit, self.dispatcher, text) end,
        function() self:guard("tick", self.tick, self) end)
    game.setTimer(M.TIMER, self.cfg.tick)
    self.started = true
    self:sendHello()
    if not self.store:persistent() then
        self:debug("no databank on ArchHUD's dbHud_1 slot: the watermark will not survive a restart")
    end
end

function Bus:tick()
    local t = game.now()
    self.dispatcher:step(1)
    if t >= self.nextTelemetry then
        self.nextTelemetry = t + self.cfg.telemetry
        self:sendTelemetry()
    end
    if t >= self.nextHello then
        self.nextHello = t + P.HELLO_INTERVAL_S
        self:sendHello()
    end
    for _, line in ipairs(self.outbox:drain(self.cfg.lines, self.id, self.cfg.maxline)) do
        self.sink(line)
    end
end

function Bus:stop()
    if not self.started then return end
    self.started = false
    game.stopTimer(M.TIMER)
    adapter.unhook()
end

-- Entry points for the userclass shim.

function M.start()
    M.instance = M.new()
    M.instance:guard("start", M.instance.start, M.instance)
end

function M.stop()
    if M.instance then M.instance:guard("stop", M.instance.stop, M.instance) end
end

return M
