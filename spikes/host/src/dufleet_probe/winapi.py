"""The few Win32 calls the kit needs, through ctypes. Import only on Windows."""

from __future__ import annotations

import ctypes
import time
from ctypes import wintypes

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)
shell32 = ctypes.WinDLL("shell32")

ULONG_PTR = ctypes.c_size_t
INPUT_KEYBOARD = 1
KEYEVENTF_KEYUP = 0x0002
KEYEVENTF_UNICODE = 0x0004
KEYEVENTF_SCANCODE = 0x0008
VK_SHIFT, SC_LSHIFT = 0x10, 0x2A
VK_MENU, SC_ALT = 0x12, 0x38
KEYS = {"enter": (0x0D, 0x1C), "esc": (0x1B, 0x01), "slash": (0xBF, 0x35), "t": (0x54, 0x14)}


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", wintypes.LONG), ("dy", wintypes.LONG), ("mouseData", wintypes.DWORD),
                ("dwFlags", wintypes.DWORD), ("time", wintypes.DWORD), ("dwExtraInfo", ULONG_PTR)]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", wintypes.WORD), ("wScan", wintypes.WORD), ("dwFlags", wintypes.DWORD),
                ("time", wintypes.DWORD), ("dwExtraInfo", ULONG_PTR)]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [("uMsg", wintypes.DWORD), ("wParamL", wintypes.WORD), ("wParamH", wintypes.WORD)]


class _INPUT_UNION(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _anonymous_ = ("u",)
    _fields_ = [("type", wintypes.DWORD), ("u", _INPUT_UNION)]


WNDENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

user32.SendInput.argtypes = (wintypes.UINT, ctypes.POINTER(INPUT), ctypes.c_int)
user32.SendInput.restype = wintypes.UINT
user32.GetForegroundWindow.restype = wintypes.HWND
user32.SetForegroundWindow.argtypes = (wintypes.HWND,)
user32.BringWindowToTop.argtypes = (wintypes.HWND,)
user32.ShowWindow.argtypes = (wintypes.HWND, ctypes.c_int)
user32.IsIconic.argtypes = (wintypes.HWND,)
user32.IsWindowVisible.argtypes = (wintypes.HWND,)
user32.GetWindowTextLengthW.argtypes = (wintypes.HWND,)
user32.GetWindowTextW.argtypes = (wintypes.HWND, wintypes.LPWSTR, ctypes.c_int)
user32.GetWindowThreadProcessId.argtypes = (wintypes.HWND, ctypes.POINTER(wintypes.DWORD))
user32.GetWindowThreadProcessId.restype = wintypes.DWORD
user32.AttachThreadInput.argtypes = (wintypes.DWORD, wintypes.DWORD, wintypes.BOOL)
user32.EnumWindows.argtypes = (WNDENUMPROC, wintypes.LPARAM)
user32.VkKeyScanW.argtypes = (wintypes.WCHAR,)
user32.VkKeyScanW.restype = ctypes.c_short
user32.MapVirtualKeyW.argtypes = (wintypes.UINT, wintypes.UINT)
user32.MapVirtualKeyW.restype = wintypes.UINT
kernel32.GetCurrentThreadId.restype = wintypes.DWORD
kernel32.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
kernel32.OpenProcess.restype = wintypes.HANDLE
kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
advapi32.OpenProcessToken.argtypes = (wintypes.HANDLE, wintypes.DWORD, ctypes.POINTER(wintypes.HANDLE))
advapi32.GetTokenInformation.argtypes = (wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD,
                                         ctypes.POINTER(wintypes.DWORD))


def is_admin() -> bool:
    return bool(shell32.IsUserAnAdmin())


def process_elevated(pid: int) -> bool | None:
    """True if the process runs elevated, None if Windows won't say."""
    handle = kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not handle:
        return None
    token = wintypes.HANDLE()
    try:
        if not advapi32.OpenProcessToken(handle, 0x0008, ctypes.byref(token)):  # TOKEN_QUERY
            return None
        elevation, size = wintypes.DWORD(), wintypes.DWORD()
        ok = advapi32.GetTokenInformation(token, 20, ctypes.byref(elevation), ctypes.sizeof(elevation),
                                          ctypes.byref(size))  # TokenElevation
        return bool(elevation.value) if ok else None
    finally:
        if token:
            kernel32.CloseHandle(token)
        kernel32.CloseHandle(handle)


def find_windows(substrings: list[str]) -> list[tuple[int, str, int]]:
    """Visible top-level windows whose title contains one of the substrings: (hwnd, title, pid)."""
    found: list[tuple[int, str, int]] = []
    wanted = [s.lower() for s in substrings]

    @WNDENUMPROC
    def callback(hwnd, _lparam):
        if not user32.IsWindowVisible(hwnd):
            return True
        length = user32.GetWindowTextLengthW(hwnd)
        if length == 0:
            return True
        buf = ctypes.create_unicode_buffer(length + 1)
        user32.GetWindowTextW(hwnd, buf, length + 1)
        if any(w in buf.value.lower() for w in wanted):
            pid = wintypes.DWORD()
            user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
            found.append((hwnd, buf.value, pid.value))
        return True

    user32.EnumWindows(callback, 0)
    return found


def foreground() -> int | None:
    return user32.GetForegroundWindow()


def _key(vk: int, scan: int, flags: int) -> INPUT:
    inp = INPUT(type=INPUT_KEYBOARD)
    inp.ki = KEYBDINPUT(vk, scan, flags, 0, 0)
    return inp


def _send(inputs: list[INPUT]) -> None:
    array = (INPUT * len(inputs))(*inputs)
    sent = user32.SendInput(len(inputs), array, ctypes.sizeof(INPUT))
    if sent != len(inputs):
        raise OSError(ctypes.get_last_error(), "SendInput was blocked (UIPI or a locked desktop?)")


def focus(hwnd: int, alt_trick: bool = False) -> bool:
    """Brings hwnd to the foreground; True only if Windows confirms it."""
    if user32.IsIconic(hwnd):
        user32.ShowWindow(hwnd, 9)  # SW_RESTORE
    if foreground() == hwnd:
        return True
    current = kernel32.GetCurrentThreadId()
    threads = {user32.GetWindowThreadProcessId(foreground(), None), user32.GetWindowThreadProcessId(hwnd, None)}
    attached = [t for t in threads if t and t != current and user32.AttachThreadInput(current, t, True)]
    try:
        if alt_trick:  # a synthetic Alt tap lifts Windows' foreground lock
            _send([_key(VK_MENU, SC_ALT, 0), _key(VK_MENU, SC_ALT, KEYEVENTF_KEYUP)])
        user32.BringWindowToTop(hwnd)
        user32.SetForegroundWindow(hwnd)
    finally:
        for t in attached:
            user32.AttachThreadInput(current, t, False)
    time.sleep(0.2)
    return foreground() == hwnd


def press(name: str) -> None:
    """A named key as a normal key event (virtual key plus scan code)."""
    vk, scan = KEYS[name]
    _send([_key(vk, scan, 0), _key(vk, scan, KEYEVENTF_KEYUP)])


def type_text(text: str, mode: str, delay: float = 0.005) -> None:
    """Types text as Unicode packets, scan codes, or virtual keys."""
    for ch in text:
        if mode == "unicode":
            units = ch.encode("utf-16-le")
            for i in range(0, len(units), 2):
                code = int.from_bytes(units[i:i + 2], "little")
                _send([_key(0, code, KEYEVENTF_UNICODE), _key(0, code, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP)])
        else:
            try:
                mapped = user32.VkKeyScanW(ch)
            except (TypeError, ctypes.ArgumentError):  # outside the Basic Multilingual Plane
                mapped = -1
            if mapped == -1:  # no key for this character on the current layout
                type_text(ch, "unicode", 0)
                continue
            vk, shift = mapped & 0xFF, bool((mapped >> 8) & 1)
            scan = user32.MapVirtualKeyW(vk, 0)  # MAPVK_VK_TO_VSC
            if mode == "scancode":
                down, up = _key(0, scan, KEYEVENTF_SCANCODE), _key(0, scan, KEYEVENTF_SCANCODE | KEYEVENTF_KEYUP)
                shift_down = _key(0, SC_LSHIFT, KEYEVENTF_SCANCODE)
                shift_up = _key(0, SC_LSHIFT, KEYEVENTF_SCANCODE | KEYEVENTF_KEYUP)
            else:
                down, up = _key(vk, scan, 0), _key(vk, scan, KEYEVENTF_KEYUP)
                shift_down, shift_up = _key(VK_SHIFT, SC_LSHIFT, 0), _key(VK_SHIFT, SC_LSHIFT, KEYEVENTF_KEYUP)
            _send(([shift_down] if shift else []) + [down, up] + ([shift_up] if shift else []))
        time.sleep(delay)
