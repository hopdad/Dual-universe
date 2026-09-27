-- The handler for every verb in the schema. Verbs whose feature is missing still get
-- one, which refuses with E_STATE. The job verbs (run, cancel, pause, resume) go to the
-- skill runtime.
--
-- The bus passes itself as `bus`: store, outbox, runtime, sendHello(), sendTelemetry(),
-- setId(id), and optionally calibrate(on) when an optical transport is active.

local M = {}

-- Keys the bus manages itself; `db` may read them but not change them.
M.RESERVED = { ["dub.last"] = true, ["dub.schema"] = true, ["dub.id"] = true, ["dub.job"] = true }

local function refuse(code, msg)
    return "N", { err = code, msg = msg }
end

function M.install(handlers, bus)
    handlers.ping = function()
        return "A", {}
    end

    handlers.status = function()
        return "A", {}, function()
            bus.sendHello()
            bus.sendTelemetry()
        end
    end

    handlers.setid = function(cmd)
        bus.setId(cmd.named.id)
        return "A", {}
    end

    handlers.resend = function(cmd)
        local from = math.tointeger(tonumber(cmd.named.from))
        return "A", {}, function() bus.outbox:resend(from) end
    end

    handlers.db = function(cmd)
        local op, key = cmd.named.op, cmd.named.key
        if op == "get" then
            return "A", { data = { k = key, v = bus.store:get(key) } }
        end
        if M.RESERVED[key] then return refuse("E_STATE", key .. " is managed by the bus") end
        if op == "set" then
            bus.store:set(key, cmd.named.value)
        else
            bus.store:del(key)
        end
        return "A", {}
    end

    handlers.run = function(cmd) return bus.runtime:run(cmd) end
    handlers.cancel = function(cmd) return bus.runtime:cancel(cmd) end
    handlers.pause = function() return bus.runtime:pause() end
    handlers.resume = function() return bus.runtime:resume() end

    handlers.cal = function(cmd)
        if not bus.calibrate then return refuse("E_STATE", "no optical transport") end
        bus.calibrate(cmd.named.state == "on")
        return "A", {}
    end

    -- Phase 3.
    handlers.relay = function() return refuse("E_STATE", "relay not available") end

    return handlers
end

return M
