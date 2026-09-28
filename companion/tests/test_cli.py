import json

from dufleet.cli import main
from dufleet.protocol import encode_frame, parse_command


def test_cmd_prints_lines_with_a_running_counter(tmp_path, capsys):
    state = tmp_path / "state.json"
    assert main(["cmd", "ping", "--state", str(state)]) == 0
    assert main(["cmd", "setid", "hauler-1", "--state", str(state)]) == 0
    first, second = capsys.readouterr().out.splitlines()
    assert (parse_command(first).epoch, parse_command(first).cseq) == (1, 1)
    assert (parse_command(second).cseq, parse_command(second).named) == (2, {"id": "hauler-1"})
    assert main(["cmd", "ping", "--epoch", "2", "--state", str(state)]) == 0
    assert parse_command(capsys.readouterr().out.strip()).cseq == 1  # a new epoch starts again at 1


def test_cmd_refuses_what_the_bus_would_refuse(tmp_path, capsys):
    assert main(["cmd", "run", "goto", "j_1", "p=::pos{0,2,1,2,3}", "--state", str(tmp_path / "s")]) == 2
    assert "E_PARSE" in capsys.readouterr().err


def test_decode_reads_chat_or_log_lines(tmp_path, capsys):
    lines = encode_frame("b1", "A", 1, '{"e":1,"ref":1}') + encode_frame(
        "b1", "E", 2, json.dumps({"ev": "note", "data": {"text": "x" * 300}}), maxline=120)
    log = tmp_path / "log.xml"
    records = (f"<record>\n  <millis>{1790000000000 + i}</millis>\n  <logger>Lua</logger>\n"
               f"  <message>{line.replace(chr(34), '&quot;')}</message>\n</record>" for i, line in enumerate(lines))
    log.write_text("\n".join(records), encoding="utf-8")
    assert main(["decode", str(log), "--xml"]) == 0
    out = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert [(m["kind"], m["seq"]) for m in out] == [("A", 1), ("E", 2)]
    assert out[1]["body"]["data"]["text"] == "x" * 300


def test_decode_reads_pasted_chat(capsys, monkeypatch):
    import io

    pasted = "[Lua] " + encode_frame("b1", "H", 1, '{"boot":"k3f9","cseq":0,"epoch":0,"v":"0.1.0"}')[0] + "\n"
    monkeypatch.setattr("sys.stdin", io.StringIO(pasted + "some other chat\n"))
    assert main(["decode"]) == 0
    (msg,) = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert msg["kind"] == "H" and "valid" not in msg


def test_sim_says_which_settings_are_missing(monkeypatch, capsys):
    for name in ("SUPABASE_URL", "SUPABASE_KEY", "DEVICE_EMAIL", "DEVICE_PASSWORD"):
        monkeypatch.delenv(f"DUFLEET_{name}", raising=False)
    assert main(["sim", "--bot", "11111111-2222-3333-4444-555555555555"]) == 2
    assert "DUFLEET_SUPABASE_URL" in capsys.readouterr().err
    for name, value in (("SUPABASE_URL", "https://x.supabase.co"), ("SUPABASE_KEY", "k"),
                        ("DEVICE_EMAIL", "d@x"), ("DEVICE_PASSWORD", "p")):
        monkeypatch.setenv(f"DUFLEET_{name}", value)
    assert main(["sim", "--bot", "hauler-1"]) == 2
    assert "bot.id" in capsys.readouterr().err


def test_run_reports_a_bad_config(tmp_path, capsys):
    path = tmp_path / "companion.toml"
    path.write_text("[hub]\nurl = 'https://x.supabase.co'\n", encoding="utf-8")
    assert main(["run", "--config", str(path)]) == 2
    assert "hub.publishable_key" in capsys.readouterr().err
