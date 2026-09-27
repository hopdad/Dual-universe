"""How the bus treats a command, given the (epoch, cseq) it last executed.

The bus runs this in Lua; the Python copy is the reference for the vectors and lets
the companion predict replies.

- execute:    newer epoch, or same epoch and a higher cseq (gaps are fine)
- replay:     same epoch and cseq as the last one: re-send the stored reply, do not run it again
- superseded: same epoch, lower cseq: refuse with E_STATE
- stale:      older epoch: refuse with E_EPOCH
"""


def decide(last_epoch: int, last_cseq: int, epoch: int, cseq: int) -> str:
    if epoch < last_epoch:
        return "stale"
    if epoch > last_epoch or cseq > last_cseq:
        return "execute"
    if cseq == last_cseq:
        return "replay"
    return "superseded"
