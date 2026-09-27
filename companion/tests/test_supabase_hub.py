"""SupabaseHub against a recording stand-in for supabase-py, checked against the SQL itself:
every RPC and parameter it uses must exist in supabase/migrations, and every column it writes
must be one the device may write."""

import asyncio
import re

from conftest import ROOT

from dufleet.hub import BotReport
from dufleet.supabase_hub import SupabaseHub

MIGRATIONS = "\n".join(p.read_text() for p in sorted((ROOT / "supabase" / "migrations").glob("*.sql")))


def sql_functions() -> dict[str, set[str]]:
    out = {}
    for name, params in re.findall(r"create function public\.(\w+)\(([^)]*)\)", MIGRATIONS):
        out[name] = {p.split()[0] for p in params.replace("\n", " ").split(",") if p.strip()}
    return out


def device_insert_columns(table: str) -> set[str]:
    m = re.search(rf"grant insert \(([^)]*)\)(?:, update \([^)]*\))?\s+on public\.{table} to authenticated", MIGRATIONS)
    if m:
        return {c.strip() for c in m.group(1).split(",")}
    # granted on every column: take them from the create table statement
    body = re.search(rf"create table public\.{table} \((.*?)\n\);", MIGRATIONS, re.S).group(1)
    lines = [line.strip() for line in body.splitlines()]
    return {line.split()[0] for line in lines if line and not line.startswith(("unique", "--"))}


class Result:
    def __init__(self, data):
        self.data = data


class Query:
    """A fluent table query: records every call as (name, args, kwargs)."""

    def __init__(self, recorder, table):
        self.recorder, self.steps = recorder, []
        recorder.calls.append({"table": table, "steps": self.steps})

    def __getattr__(self, name):
        def step(*args, **kwargs):
            self.steps.append((name, args, kwargs))
            return self

        return step

    async def execute(self):
        return Result(self.recorder.data)


class Rpc:
    def __init__(self, data):
        self.data = data

    async def execute(self):
        return Result(self.data)


class Recorder:
    def __init__(self, data=None):
        self.calls, self.data = [], data

    def rpc(self, fn, params):
        self.calls.append({"rpc": fn, "params": params})
        return Rpc(self.data)

    def table(self, name):
        return Query(self, name)


ROW = {"id": "c1", "bot_id": "b", "epoch": 1, "cseq": 7, "verb": "ping", "args": [], "job_id": None,
       "status": "claimed", "attempts": 1}


def run(coro):
    return asyncio.run(coro)


def test_every_rpc_and_parameter_exists_in_the_sql():
    functions = sql_functions()
    rec = Recorder([ROW])
    hub = SupabaseHub(rec)
    run(hub.recover_inflight("b"))
    run(hub.claim_next_command("b", 60))
    run(hub.command_progress("c1", "acked", None, {"x": 1}))
    rec.data = 3
    run(hub.sync_epoch("b", 1, 7))
    rec.data = None
    run(hub.bot_report("b", BotReport("ready", "0.1.0", "k3f9", "2.105")))
    rpcs = [c for c in rec.calls if "rpc" in c]
    assert [c["rpc"] for c in rpcs] == ["recover_inflight", "claim_next_command", "command_progress", "sync_epoch",
                                        "bot_report"]
    for c in rpcs:
        assert c["rpc"] in functions, c["rpc"]
        assert set(c["params"]) == functions[c["rpc"]], (c["rpc"], set(c["params"]), functions[c["rpc"]])


def test_results_map_to_command_rows():
    hub = SupabaseHub(Recorder([ROW]))
    cmd = run(hub.claim_next_command("b", 60))
    assert (cmd.id, cmd.epoch, cmd.cseq, cmd.verb, cmd.args) == ("c1", 1, 7, "ping", ())
    assert run(SupabaseHub(Recorder([])).claim_next_command("b", 60)) is None
    assert run(SupabaseHub(Recorder(None)).recover_inflight("b")) is None
    assert run(SupabaseHub(Recorder(4)).sync_epoch("b", 1, 1)) == 4


def test_writes_use_only_columns_the_device_may_write():
    rec = Recorder(None)
    hub = SupabaseHub(rec)
    state = {"wx": 1.0, "speed_kmh": 18, "skill": "idle", "skill_phase": None, "autopilot": "manual"}
    run(hub.upsert_state("b", state))
    run(hub.insert_telemetry("b", {"v": 18}))
    run(hub.insert_event("b", "skill_state", 0, {"ev": "skill_state"}))
    writes = {c["table"]: c for c in rec.calls}
    for table, method in (("bot_state", "upsert"), ("telemetry", "insert"), ("events", "insert")):
        payload = next(args[0] for name, args, _ in writes[table]["steps"] if name == method)
        assert set(payload) <= device_insert_columns(table), (table, set(payload) - device_insert_columns(table))


def test_job_lookup_filters_on_bot_job_and_acked():
    rec = Recorder([{"id": "c9"}])
    assert run(SupabaseHub(rec).acked_command_for_job("b", "j_1")) == "c9"
    eqs = [args for name, args, _ in rec.calls[0]["steps"] if name == "eq"]
    assert eqs == [("bot_id", "b"), ("job_id", "j_1"), ("status", "acked")]
