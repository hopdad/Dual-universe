-- How the bus treats a command, given the (epoch, cseq) it last executed
-- (docs/protocol.md, "Delivery, dedupe and epochs").
--   execute     newer epoch, or same epoch and a higher cseq (gaps are fine)
--   replay      same epoch and cseq: re-send the stored reply, do not run it again
--   superseded  same epoch, lower cseq: refuse with E_STATE
--   stale       older epoch: refuse with E_EPOCH

local M = {}

function M.decide(lastEpoch, lastCseq, epoch, cseq)
    if epoch < lastEpoch then return "stale" end
    if epoch > lastEpoch or cseq > lastCseq then return "execute" end
    if cseq == lastCseq then return "replay" end
    return "superseded"
end

return M
