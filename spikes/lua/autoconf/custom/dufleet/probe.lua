-- dufleet probe for the Phase 0 spikes A2, S0, S1, S3, S10 and S11 (see spikes/README.md).
--
-- Runs inside ArchHUD's control unit, loaded by archhud/userclass.lua. At start it
-- wraps two ArchHUD entry points:
--   PROGRAM.controlInput  so "/b" chat lines reach the probe and never ArchHUD
--                         (ArchHUD would treat a line containing "::pos" as a waypoint);
--   PROGRAM.onTick        so the probe gets its own "dub" timer.
-- Every entry point runs under pcall: a probe bug prints an error and leaves
-- flight alone.

local optical = require("autoconf/custom/dufleet/optical")

local VERSION = "0.1.0"
local TIMER = "dub"
local INBOX = "autoconf/custom/dufleet/inbox"
local PREFIX = "@@DUB|probe|"
local SWEEP = { 100, 200, 400, 800, 1600, 3200, 6400, 12800 }

local DEFAULTS = {
    tick = 0.25,
    print_every = 2, print_for = 300,
    inbox_every = 0.5,
    frame = false, frame_fps = 2, frame_bits = 2, frame_cell = 6, frame_x = 20, frame_y = 200,
    panel = true, panel_x = 20, panel_y = 420,
}

local cfg = {}
do
    for k, v in pairs(DEFAULTS) do cfg[k] = v end
    local ok, user = pcall(require, "autoconf/custom/dufleet/probe_config")
    if ok and type(user) == "table" then
        for k, v in pairs(user) do
            if type(v) == type(DEFAULTS[k]) then cfg[k] = v end
        end
    end
    -- A bad value here would break the panel on every tick, so fall back to defaults.
    if cfg.frame_fps ~= 1 and cfg.frame_fps ~= 2 and cfg.frame_fps ~= 4 then cfg.frame_fps = DEFAULTS.frame_fps end
    if cfg.frame_bits ~= 1 and cfg.frame_bits ~= 2 then cfg.frame_bits = DEFAULTS.frame_bits end
    if cfg.tick <= 0 then cfg.tick = DEFAULTS.tick end
    cfg.frame_cell = math.max(2, math.min(40, math.floor(cfg.frame_cell)))
end

local st = {
    started = false, t0 = 0, nonce = "000000", ticks = 0, errors = 0, last_error = "",
    -- A2 and S3
    b_seen = 0, b_last = "-", passthru = 0, last_input_len = 0,
    -- S0
    prints = 0, beat_n = 0, next_beat = 0, beat_until = 0, sweep = {}, env = "",
    -- S11
    inbox_on = false, inbox_next = 0, inbox_reads = 0, inbox_changes = 0, inbox_seq = nil,
    inbox_lag = nil, inbox_cost = 0, inbox_state = "not read yet", inbox_cleared = false,
    -- S1
    frame_on = false, frame_seq = 0, frame_next = 0, frame_svg = "", frame_cost = 0, frame_cost_max = 0,
    -- S10
    limit = -1, tick_cost_max = 0, tick_entry_max = 0, upd_max = 0, flush_max = 0, flush_ok = true,
}

local P = {}

local function now()
    return system.getUtcTime()
end

local function icount()
    return system.getInstructionCount()
end

local function esc(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function short(s, n)
    s = tostring(s)
    if #s > n then return s:sub(1, n - 3) .. "..." end
    return s
end

local function emit(kind, ...)
    local parts = { PREFIX .. kind, st.nonce }
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring((select(i, ...)))
    end
    system.print(table.concat(parts, "|"))
    st.prints = st.prints + 1
end

local function guard(name, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        st.errors = st.errors + 1
        st.last_error = name .. ": " .. tostring(err)
        if st.errors <= 5 then
            system.print("dufleet probe error (" .. name .. "): " .. tostring(err))
        end
    end
    return ok
end

-- S11: which loading functions does the sandbox expose?
local function envReport()
    local pk = package
    local isTable = type(pk) == "table"
    return table.concat({
        "lua=" .. tostring(_VERSION),
        "io=" .. type(io), "os=" .. type(os),
        "package=" .. type(pk),
        "loaded=" .. type(isTable and pk.loaded or nil),
        "preload=" .. type(isTable and pk.preload or nil),
        "require=" .. type(require), "load=" .. type(load), "loadfile=" .. type(loadfile),
        "dofile=" .. type(dofile), "loadstring=" .. type(loadstring), "debug=" .. type(debug),
    }, " ")
end

-- S11: re-read the inbox file. Clearing package.loaded forces require to load the
-- file again; whether the game then sees the companion's latest write is the question.
local function inboxPoll()
    local pk = package
    local cleared = false
    if type(pk) == "table" and type(pk.loaded) == "table" then
        pk.loaded[INBOX] = nil
        cleared = true
    end
    st.inbox_cleared = cleared
    local c0 = icount()
    local ok, data = pcall(require, INBOX)
    st.inbox_cost = icount() - c0
    st.inbox_reads = st.inbox_reads + 1
    if not ok then
        st.inbox_state = "error: " .. short(data, 60)
        return
    end
    if type(data) ~= "table" then
        st.inbox_state = "not a table (" .. type(data) .. ")"
        return
    end
    st.inbox_state = "ok"
    if data.seq ~= st.inbox_seq then
        st.inbox_changes = st.inbox_changes + 1
        st.inbox_seq = data.seq
        st.inbox_lag = (type(data.t) == "number") and (now() - data.t) or nil
        emit("inbox", tostring(data.seq), st.inbox_lag and string.format("%.3f", st.inbox_lag) or "?",
            "cost=" .. tostring(st.inbox_cost), "cleared=" .. tostring(cleared))
    end
end

-- S1: build the next optical frame.
local function frameBuild()
    st.frame_seq = (st.frame_seq + 1) & 0xFFFF
    local c0 = icount()
    local cells = optical.cells(st.frame_seq, cfg.frame_bits)
    st.frame_svg = optical.svg(cells, math.floor(cfg.frame_x), math.floor(cfg.frame_y), math.floor(cfg.frame_cell))
    st.frame_cost = icount() - c0
    if st.frame_cost > st.frame_cost_max then st.frame_cost_max = st.frame_cost end
end

local function panelSvg()
    local beat = (st.beat_until > 0 and now() <= st.beat_until) and "on" or "off"
    local lag = st.inbox_lag and string.format("%.2fs", st.inbox_lag) or "-"
    local lines = {
        string.format("dufleet probe %s   up %ds   ticks %d   errors %d",
            VERSION, math.floor(now() - st.t0), st.ticks, st.errors),
        string.format("A2  /b lines %d (last: %s)   passed to ArchHUD %d   last input %d chars",
            st.b_seen, short(st.b_last, 16), st.passthru, st.last_input_len),
        string.format("S0  prints %d   heartbeat %s (every %ss)   nonce %s",
            st.prints, beat, tostring(cfg.print_every), st.nonce),
        string.format("S11 %s   cleared %s   seq %s   lag %s   changes %d   cost %s",
            short(st.inbox_state, 28), tostring(st.inbox_cleared), tostring(st.inbox_seq), lag,
            st.inbox_changes, tostring(st.inbox_cost)),
        string.format("S1  frame %s #%d   %d fps   %d bit   cell %d at %d,%d   build %s (max %s)",
            st.frame_on and "on" or "off", st.frame_seq, cfg.frame_fps, cfg.frame_bits,
            math.floor(cfg.frame_cell), math.floor(cfg.frame_x), math.floor(cfg.frame_y),
            tostring(st.frame_cost), tostring(st.frame_cost_max)),
        string.format("S10 limit %s   tick max %s (own %s)   update max %s   flush max %s",
            tostring(st.limit), tostring(st.tick_entry_max), tostring(st.tick_cost_max),
            tostring(st.upd_max), st.flush_ok and tostring(st.flush_max) or "n/a"),
    }
    if st.errors > 0 then
        lines[#lines + 1] = "last error: " .. short(st.last_error, 70)
    end
    local lh, w = 16, 620
    local h = lh * #lines + 8
    local out = {
        string.format('<svg xmlns="http://www.w3.org/2000/svg" style="position:absolute;left:%dpx;top:%dpx;z-index:100"'
            .. ' width="%d" height="%d">', math.floor(cfg.panel_x), math.floor(cfg.panel_y), w, h),
        string.format('<rect width="%d" height="%d" fill="#000000" fill-opacity="0.65"/>', w, h),
    }
    for i, line in ipairs(lines) do
        out[#out + 1] = string.format('<text x="6" y="%d" fill="#7CFC00"'
            .. ' style="font-family:monospace;font-size:13px;stroke:none">%s</text>', i * lh, esc(line))
    end
    out[#out + 1] = "</svg>"
    return table.concat(out)
end

-- ArchHUD adds the global userScreen to its HUD content on its next redraw.
local function render()
    local parts = {}
    if st.frame_on and st.frame_svg ~= "" then parts[#parts + 1] = st.frame_svg end
    if cfg.panel then parts[#parts + 1] = panelSvg() end
    local s = table.concat(parts)
    userScreen = (s ~= "") and s or nil
end

local function queueSweep()
    for _, len in ipairs(SWEEP) do
        local head = PREFIX .. "len|" .. st.nonce .. "|" .. len .. "|"
        local tail = "|END"
        local fill = math.max(0, len - #head - #tail)
        st.sweep[#st.sweep + 1] = head .. string.rep("x", fill) .. tail
    end
end

local function onTick()
    local entry = icount()
    if entry > st.tick_entry_max then st.tick_entry_max = entry end
    st.ticks = st.ticks + 1
    local t = now()

    if cfg.print_every > 0 and t <= st.beat_until and t >= st.next_beat then
        st.beat_n = st.beat_n + 1
        emit("tick", st.beat_n, string.format("%.3f", t))
        st.next_beat = t + cfg.print_every
    end
    if #st.sweep > 0 then
        system.print(table.remove(st.sweep, 1)) -- one sweep line per tick
        st.prints = st.prints + 1
    end
    if st.inbox_on and t >= st.inbox_next then
        st.inbox_next = t + cfg.inbox_every
        guard("inbox", inboxPoll)
    end
    if st.frame_on and t >= st.frame_next then
        st.frame_next = t + 1 / cfg.frame_fps
        guard("frame", frameBuild)
    end
    render()

    local own = icount() - entry
    if own > st.tick_cost_max then st.tick_cost_max = own end
end

local HELP = {
    "/b ping [text]     reply with pong (A2)",
    "/b len             print test lines of 100 to 12800 characters (S0)",
    "/b esc             print a line with special characters (S0)",
    "/b beat on|off     heartbeat lines on or off (S0)",
    "/b inbox on|off    inbox reads on or off (S11)",
    "/b frame on|off    optical frame on or off (S1)",
    "/b fps 1|2|4       frames per second (S1)",
    "/b bits 1|2        bits per cell (S1)",
    "/b cell N          cell size in pixels, 2 to 40 (S1)",
    "/b at X Y          move the frame (S1)",
    "/b panel X Y|off   move or hide the status panel",
    "/b stats           print instruction statistics (S10)",
    "/b echo TEXT       report the length of TEXT (S3)",
}

local function handleCommand(text)
    st.b_seen = st.b_seen + 1
    st.last_input_len = #text
    local args = {}
    for word in text:gmatch("%S+") do args[#args + 1] = word end
    local verb = args[2] or "help"
    st.b_last = verb
    local n3, n4 = tonumber(args[3]), tonumber(args[4])

    if verb == "ping" then
        emit("pong", st.b_seen, string.format("%.3f", now()), short(text, 80))
    elseif verb == "len" then
        queueSweep()
        emit("len-start", #SWEEP)
    elseif verb == "esc" then
        emit("esc", '<>&"\'\t' .. "é€✓", "END")
    elseif verb == "beat" then
        if args[3] == "off" then
            st.beat_until = 0
        else
            st.beat_until, st.next_beat = now() + cfg.print_for, 0
        end
    elseif verb == "inbox" then
        st.inbox_on = args[3] ~= "off"
        if cfg.inbox_every <= 0 then cfg.inbox_every = DEFAULTS.inbox_every end
    elseif verb == "frame" then
        st.frame_on, st.frame_next = args[3] ~= "off", 0
    elseif verb == "fps" then
        if n3 == 1 or n3 == 2 or n3 == 4 then cfg.frame_fps = n3 end
    elseif verb == "bits" then
        if n3 == 1 or n3 == 2 then cfg.frame_bits, st.frame_next = n3, 0 end
    elseif verb == "cell" then
        if n3 and n3 >= 2 and n3 <= 40 then cfg.frame_cell, st.frame_next = math.floor(n3), 0 end
    elseif verb == "at" then
        if n3 and n4 then cfg.frame_x, cfg.frame_y, st.frame_next = n3, n4, 0 end
    elseif verb == "panel" then
        if args[3] == "off" then
            cfg.panel = false
        else
            cfg.panel = true
            if n3 and n4 then cfg.panel_x, cfg.panel_y = n3, n4 end
        end
    elseif verb == "stats" then
        emit("stats", "limit=" .. tostring(st.limit), "tick_entry_max=" .. tostring(st.tick_entry_max),
            "tick_own_max=" .. tostring(st.tick_cost_max), "update_max=" .. tostring(st.upd_max),
            "flush_max=" .. (st.flush_ok and tostring(st.flush_max) or "n/a"),
            "frame_max=" .. tostring(st.frame_cost_max), "inbox_cost=" .. tostring(st.inbox_cost))
    elseif verb == "echo" then
        emit("echo", #text, short(text, 60))
    else
        for _, line in ipairs(HELP) do system.print(line) end
    end
    render()
end

function P.start()
    guard("start", function()
        st.t0 = now()
        st.nonce = string.format("%06x", math.floor(st.t0 * 1000) % 0xFFFFFF)
        st.beat_until = (cfg.print_every > 0) and (st.t0 + cfg.print_for) or 0
        st.inbox_on = cfg.inbox_every > 0
        st.frame_on = cfg.frame and true or false
        local okLimit, limit = pcall(system.getInstructionLimit)
        st.limit = okLimit and limit or -1
        st.env = envReport()

        local prog = PROGRAM
        if type(prog) ~= "table" then error("ArchHUD's PROGRAM table not found") end
        local origInput, origTick = prog.controlInput, prog.onTick
        if type(origInput) ~= "function" or type(origTick) ~= "function" then
            error("ArchHUD's controlInput or onTick not found")
        end
        prog.controlInput = function(text)
            if type(text) == "string" and (text == "/b" or text:sub(1, 3) == "/b ") then
                guard("input", handleCommand, text)
                return
            end
            st.passthru = st.passthru + 1
            return origInput(text)
        end
        prog.onTick = function(timerId)
            if timerId == TIMER then
                guard("tick", onTick)
                return
            end
            return origTick(timerId)
        end
        unit.setTimer(TIMER, cfg.tick)
        st.started = true
        emit("hello", "v=" .. VERSION, "limit=" .. tostring(st.limit), st.env)
        render()
    end)
end

function P.stop()
    guard("stop", function()
        if st.started then
            emit("bye", st.ticks, st.b_seen, st.inbox_changes, st.frame_seq)
            unit.stopTimer(TIMER)
        end
        userScreen = nil
    end)
end

-- Runs at the end of every ArchHUD update, so it only records the instruction
-- count ArchHUD reached; S10 compares it with the limit.
function P.onUpdate()
    local ok, c = pcall(icount)
    if ok and type(c) == "number" and c > st.upd_max then st.upd_max = c end
end

-- Most API calls are disabled in flush; stop trying after the first failure.
function P.onFlush()
    if not st.flush_ok then return end
    local ok, c = pcall(icount)
    if not ok or type(c) ~= "number" then
        st.flush_ok = false
    elseif c > st.flush_max then
        st.flush_max = c
    end
end

-- For the offline tests.
P._state, P._cfg, P._handle, P._tick = st, cfg, handleCommand, onTick

return P
