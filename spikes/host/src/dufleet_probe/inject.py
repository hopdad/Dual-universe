"""Spikes S3 and S4: can the companion type into the game's Lua chat?

Focuses the game window, opens chat, types a /b line and submits it, in one of three
modes: Unicode packets, scan codes, or virtual keys. The probe counts the /b lines
it receives and shows the last input length on its panel; with a working log (S0)
`logwatch` also sees the echo lines. Before every line the script checks the game
still has focus and stops if it doesn't.
"""

from __future__ import annotations

import time

from dufleet_probe.kit import IS_WINDOWS, save_json

DEFAULT_TITLES = ["Dual Universe", "MyDU", "My Dual Universe"]
SWEEP = (40, 80, 120, 200, 255, 256, 300, 400, 512, 1000)
SKIP_PROCESSES = {"python.exe", "pythonw.exe", "cmd.exe", "powershell.exe", "pwsh.exe", "conhost.exe",
                  "windowsterminal.exe", "explorer.exe", "code.exe"}


def sweep_lines() -> list[str]:
    """Lines of exact lengths, each saying its own length, for the input-length test."""
    lines = []
    for n in SWEEP:
        head = f"/b echo L{n} "
        lines.append(head + "x" * max(0, n - len(head)))
    return lines


def _pick_window(args):
    from dufleet_probe import winapi

    windows = winapi.find_windows(args.title or DEFAULT_TITLES)
    if args.hwnd:
        windows = [w for w in windows if w[0] == args.hwnd]
    else:
        try:
            import psutil

            windows = [w for w in windows if psutil.Process(w[2]).name().lower() not in SKIP_PROCESSES]
        except Exception:
            pass
    if len(windows) != 1:
        for hwnd, title, pid in windows:
            print(f"  hwnd {hwnd}  pid {pid}  {title}")
        if not windows:
            raise SystemExit("Game window not found; pass --title (see game_windows in s8_paths.json)")
        raise SystemExit("Need exactly one game window; pass --hwnd or --title")
    return windows[0]


def run(args) -> int:
    lines = sweep_lines() if args.length_sweep else [args.text.format(n=i + 1) for i in range(args.count)]
    if args.dry_run:
        close = ", then Esc" if args.close_key == "esc" else ""
        print(f"mode {args.mode}, open with {args.open_key}, then Enter{close}:")
        for line in lines:
            print(f"  [{len(line)}] {line[:80]}")
        return 0
    if not IS_WINDOWS:
        raise SystemExit("inject needs Windows")
    from dufleet_probe import winapi

    hwnd, title, pid = _pick_window(args)
    game_elevated, me_admin = winapi.process_elevated(pid), winapi.is_admin()
    print(f"Target: {title} (pid {pid}); game elevated: {game_elevated}; this terminal elevated: {me_admin}")
    if game_elevated and not me_admin:
        print("Warning: Windows blocks input from a normal process into an elevated one (UIPI). "
              "Run this terminal as administrator, or start the game without elevation.")
    print("Make sure the Lua tab of the chat is selected. Typing starts in 5 s; do not touch mouse or keyboard.")
    time.sleep(5)
    sent = []
    for i, line in enumerate(lines, 1):
        if not winapi.focus(hwnd, alt_trick=args.alt_trick):
            print("Stopped: could not bring the game to the foreground (try --alt-trick).")
            break
        if args.open_key != "none":
            winapi.press(args.open_key)
            time.sleep(args.open_delay)
        if winapi.foreground() != hwnd:
            print("Stopped: the game lost focus.")
            break
        started = time.time()
        winapi.type_text(line, args.mode, args.char_delay)
        winapi.press("enter")
        if args.close_key == "esc":
            time.sleep(0.1)
            winapi.press("esc")
        sent.append({"n": i, "length": len(line), "t": round(started, 3), "typing_s": round(time.time() - started, 3)})
        print(f"  sent {i}/{len(lines)} ({len(line)} chars)")
        time.sleep(args.interval)
    summary = {"mode": args.mode, "open_key": args.open_key, "close_key": args.close_key,
               "game_elevated": game_elevated, "terminal_elevated": me_admin, "sent": sent}
    path = save_json(args.results, f"s3_inject_{args.mode}{'_sweep' if args.length_sweep else ''}.json", summary)
    print(f"Sent {len(sent)} line(s). Saved {path}. Note the probe panel's A2 line (count and last input length).")
    return 0


def add_parser(sub) -> None:
    p = sub.add_parser("inject", help="S3/S4: type /b lines into the game's Lua chat (Windows)")
    p.add_argument("--mode", choices=("unicode", "scancode", "vk"), default="unicode")
    p.add_argument("--text", default="/b ping {n}", help="line to send; {n} is replaced by its number")
    p.add_argument("--count", type=int, default=3)
    p.add_argument("--length-sweep", action="store_true", help="send /b echo lines of 40 to 1000 characters")
    p.add_argument("--open-key", choices=("enter", "slash", "t", "none"), default="enter",
                   help="key that opens the chat input")
    p.add_argument("--close-key", choices=("none", "esc"), default="none", help="key after submitting")
    p.add_argument("--open-delay", type=float, default=0.3)
    p.add_argument("--char-delay", type=float, default=0.005)
    p.add_argument("--interval", type=float, default=2.0, help="seconds between lines")
    p.add_argument("--title", action="append", help="window title substring (repeatable)")
    p.add_argument("--hwnd", type=int, help="exact window handle, from the list printed on ambiguity")
    p.add_argument("--alt-trick", action="store_true", help="tap Alt to get past Windows' focus lock")
    p.add_argument("--dry-run", action="store_true", help="print the plan only")
    p.set_defaults(func=run)
