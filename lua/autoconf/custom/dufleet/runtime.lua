-- The skill runtime: one job at a time (docs/protocol.md, "Jobs").
--
-- `run` starts a job, `cancel` ends it, `pause` holds it and `resume` continues it. Each
-- tick steps the running job's skill. A phase change sends an E skill_state event, and the
-- end of the job sends R. While the job runs, dub.job holds it as JSON. A job still there
-- when the bus starts was cut off by a restart: the bus reports it failed, so the hub does
-- not wait for a result that will never come.
--
-- A skill is a table with:
--   phase                 the phase a job starts in
--   check(params, env)    the job's settings from its key=value parameters, or nil, an
--                         error code and a message (the run command's N)
--   step(job, env, now)   nil while the job runs; true and result data when it is done;
--                         false, an error code, a message and optional data when it failed.
--                         It may change job.phase and keep its own state in job.
--   stop(job, env)        halts the ship, for cancel and pause: true, or nil and a reason
--   resume(job, env)      optional: the phase a paused job continues in (default: phase)
--
-- env holds what skills use: ah (archhud_adapter), now(), position() and speed() (m/s).
-- job has id, skill, phase, cfg (from check), paused, and active: seconds spent running.

local jsonenc = require("autoconf/custom/dufleet/jsonenc")

local M = { KEY = "dub.job" }
local Runtime = {}
Runtime.__index = Runtime

-- The codes an R frame may carry (protocol.schema.json, $defs.result). The companion drops
-- a body that does not match, and the job's command would then wait forever.
M.RESULT_ERRORS = { E_STATE = true, E_BUSY = true, E_LINK = true, E_FUEL = true, E_INTERNAL = true }

-- ctx: store, outbox, env, skills (name -> skill), and optionally log(msg).
function M.new(ctx)
    return setmetatable({ store = ctx.store, outbox = ctx.outbox, env = ctx.env, skills = ctx.skills or {},
        log = ctx.log or function() end, job = nil }, Runtime)
end

local function refuse(code, msg)
    return "N", { err = code, msg = msg }
end

-- The parameters as "k=v" tokens, sorted: what dub.job keeps of them.
local function argsText(params)
    local list = {}
    for k, v in pairs(params) do list[#list + 1] = k .. "=" .. v end
    table.sort(list)
    return table.concat(list, " ")
end

-- "idle", or "<skill>:<phase>" for T.st.
function Runtime:status()
    local job = self.job
    if not job then return "idle" end
    return (job.skill .. ":" .. (job.paused and "paused" or job.phase)):sub(1, 40)
end

function Runtime:save()
    local job = self.job
    self.store:set(M.KEY, jsonenc.encode({ job = job.id, skill = job.skill, args = job.args, phase = job.phase,
        paused = job.paused ~= nil }))
end

function Runtime:event(from, to)
    local job = self.job
    self.outbox:push("E", jsonenc.encode({ ev = "skill_state", job = job.id, skill = job.skill, from = from, to = to }))
end

function Runtime:finish(ok, code, msg, data)
    local job = self.job
    self.job = nil
    self.store:del(M.KEY)
    local body = { job = job.id, skill = job.skill, ok = ok, data = data }
    if not ok then
        body.err = M.RESULT_ERRORS[code] and code or "E_INTERNAL"
        body.msg = jsonenc.clip(msg or tostring(code), 120)
    end
    self.outbox:push("R", jsonenc.encode(body))
end

function Runtime:run(cmd)
    local name, id = cmd.named.skill, cmd.named.job
    if self.job then return refuse("E_BUSY", "skill " .. self.job.skill .. " running") end
    local skill = self.skills[name]
    if not skill then return refuse("E_STATE", "skill " .. name .. " not available yet") end
    local cfg, code, msg = skill.check(cmd.params, self.env)
    if not cfg then return refuse(code or "E_ARGS", msg or "bad parameters") end
    local job = { id = id, skill = name, args = argsText(cmd.params), phase = skill.phase, cfg = cfg, active = 0 }
    self.job = job
    self:save()
    return "A", { job = id }, function() self:event("idle", job.phase) end
end

-- Ends the job, or with no job just stops the ship: the dashboard's stop button.
function Runtime:cancel(cmd)
    local job, want = self.job, cmd.named.job
    if want and (not job or job.id ~= want) then return refuse("E_STATE", "no job " .. want) end
    local ok, why
    if job then
        ok, why = self.skills[job.skill].stop(job, self.env)
    else
        ok, why = self.env.ah.stop()
    end
    if not ok then return refuse("E_STATE", why or "could not stop") end
    if not job then return "A", { data = { idle = true } } end
    self:finish(false, "E_STATE", "cancelled")
    return "A", { job = job.id }
end

function Runtime:pause()
    local job = self.job
    if not job then return refuse("E_STATE", "no job running") end
    if job.paused then return "A", { job = job.id } end
    local ok, why = self.skills[job.skill].stop(job, self.env)
    if not ok then return refuse("E_STATE", why or "could not stop") end
    job.paused, job.last = true, nil
    self:save()
    return "A", { job = job.id }, function() self:event(job.phase, "paused") end
end

function Runtime:resume()
    local job = self.job
    if not job then return refuse("E_STATE", "no job running") end
    if not job.paused then return "A", { job = job.id } end
    local skill = self.skills[job.skill]
    job.paused = nil
    job.phase = skill.resume and skill.resume(job, self.env) or skill.phase
    self:save()
    return "A", { job = job.id }, function() self:event("paused", job.phase) end
end

-- One step of the running job. A skill error fails the job (E_INTERNAL) after trying to stop the ship.
function Runtime:step(now)
    local job = self.job
    if not job or job.paused then return end
    if job.last then job.active = job.active + (now - job.last) end
    job.last = now
    local skill = self.skills[job.skill]
    local before = job.phase
    local ok, done, a, b, c = pcall(skill.step, job, self.env, now)
    if not ok then
        self.log("skill " .. job.skill .. ": " .. tostring(done))
        pcall(skill.stop, job, self.env)
        done, a, b, c = false, "E_INTERNAL", "skill error; see D frames", nil
    end
    if job.phase ~= before then self:event(before, job.phase) end
    if done == true then
        self:finish(true, nil, nil, a)
    elseif done == false then
        self:finish(false, a, b, c)
    elseif job.phase ~= before then
        self:save()
    end
end

-- At bus start: reports a job that a restart cut off.
function Runtime:recover()
    local saved = self.store:get(M.KEY)
    if not saved then return end
    self.store:del(M.KEY)
    local id, skill = saved:match('"job":"(j_%w+)"'), saved:match('"skill":"([%w_]+)"')
    if not (id and skill) then
        self.log("dub.job unreadable, dropped")
        return
    end
    self.outbox:push("R", jsonenc.encode({ job = id, skill = skill, ok = false, err = "E_STATE",
        msg = "interrupted by a restart" }))
end

return M
