#!/usr/bin/env python3
"""Run an aseprite-dmi Lua scenario inside an isolated, portable Aseprite (Windows).

    py tools/aseprite_runner.py tools/tests/<scenario>.lua [--gui] [--param k=v ...]

See tools/tests/README.md.
"""

from __future__ import annotations

import argparse
import contextlib
import ctypes
import hashlib
import json
import msvcrt
import os
import shutil
import struct
import subprocess
import sys
import time
import winreg
import zlib
from ctypes import wintypes
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TESTS_DIR = REPO / "tools" / "tests"
BOOTSTRAP = TESTS_DIR / "bootstrap.lua"
DLL_NAME = "dmi.dll"
RUN_MAX_AGE_S = 6 * 3600

EXIT_PASS, EXIT_FAIL, EXIT_TIMEOUT, EXIT_CRASH, EXIT_SETUP = 0, 1, 2, 3, 4


class SetupError(Exception):
    pass


def cache_root() -> Path:
    if override := os.environ.get("ASEPRITE_DMI_TEST_CACHE"):
        return Path(override).resolve()
    return Path(os.environ["LOCALAPPDATA"]) / "aseprite-dmi-test"


def find_source_exe() -> Path:
    if override := os.environ.get("ASEPRITE_EXE"):
        return Path(override)
    steam = Path(r"C:\Program Files (x86)\Steam")
    with contextlib.suppress(OSError), winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as key:
        steam = Path(winreg.QueryValueEx(key, "SteamPath")[0])
    return steam / "steamapps" / "common" / "Aseprite" / "Aseprite.exe"


def win_path(path: Path) -> str:
    """Absolute backslash path: the form Aseprite hashes for script trust."""
    return os.path.normpath(os.path.abspath(path))


@contextlib.contextmanager
def file_lock(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a+b") as file:
        file.seek(0)
        while True:
            try:
                msvcrt.locking(file.fileno(), msvcrt.LK_NBLCK, 1)
                break
            except OSError:
                time.sleep(0.2)
        try:
            yield
        finally:
            file.seek(0)
            msvcrt.locking(file.fileno(), msvcrt.LK_UNLCK, 1)


def prepare_install(source_exe: Path) -> Path:
    """Copies the Aseprite install into the shared cache once per exe build."""
    if not source_exe.is_file():
        raise SetupError(f"Aseprite not found at {source_exe} (set ASEPRITE_EXE)")
    st = source_exe.stat()
    install = cache_root() / "aseprite" / f"{st.st_size}-{st.st_mtime_ns}"
    exe = install / source_exe.name
    with file_lock(cache_root() / "install.lock"):
        if not exe.is_file():
            print(f"[runner] Copying {source_exe.parent} to {install}")
            staging = install.with_name(f"{install.name}.tmp{os.getpid()}")
            shutil.rmtree(staging, ignore_errors=True)
            shutil.copytree(source_exe.parent, staging)
            # Portable-mode guard: even if ASEPRITE_USER_FOLDER were ignored, %APPDATA% stays untouched.
            (staging / "aseprite.ini").write_text("[general]\ndata_recovery = false\n", encoding="utf-8")
            os.replace(staging, install)
    return exe


def script_keys(path: Path) -> set[str]:
    """[script_access] keys: sha1 of the chunk name, i.e. the path the script was loaded from."""
    path = win_path(path)
    return {hashlib.sha1(p.encode()).hexdigest() for p in (path, path.replace("\\", "/"))}


def window_size(text: str) -> tuple[int, int]:
    try:
        width, height = map(int, text.lower().split("x"))
    except ValueError:
        raise argparse.ArgumentTypeError(f"expected WxH, e.g. 1366x768, got {text!r}") from None
    return width, height


def write_config(user_dir: Path, trusted: list[Path], window: tuple[int, int]) -> None:
    keys = sorted({k for p in trusted for k in script_keys(p)})
    (user_dir / "aseprite.ini").write_text("\n".join([
        "[general]", "data_recovery = false", "show_home = false",
        "[updater]", f"last_check = {int(time.time())}", "wait_days = 3650.000000",
        "[GfxMode]", "Maximized = false", f"Frame = 40 40 {window[0]} {window[1]}",
        "[script_access]", *(f"{k} = 31" for k in keys), "",
    ]), encoding="utf-8")


def install_extension(user_dir: Path, dll: Path) -> Path:
    """Installs the extension into the run's user folder, as tools/build.py packages it."""
    ext = user_dir / "extensions" / "aseprite-dmi"
    ext.mkdir(parents=True)
    for name in ("package.json", "LICENSE", "README.md"):
        shutil.copy2(REPO / name, ext)
    shutil.copytree(REPO / "scripts", ext / "scripts")
    if (REPO / "registry").is_dir():
        shutil.copytree(REPO / "registry", ext / "registry", ignore=shutil.ignore_patterns("*.md"))
    shutil.copy2(dll, ext / DLL_NAME)
    return ext


kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
kernel32.CreateJobObjectW.restype = wintypes.HANDLE
kernel32.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
kernel32.TerminateJobObject.argtypes = [wintypes.HANDLE, wintypes.UINT]
kernel32.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]


class JOBOBJECT_EXTENDED_LIMIT_INFORMATION(ctypes.Structure):
    _fields_ = [
        ("PerProcessUserTimeLimit", ctypes.c_int64), ("PerJobUserTimeLimit", ctypes.c_int64),
        ("LimitFlags", wintypes.DWORD), ("MinimumWorkingSetSize", ctypes.c_size_t),
        ("MaximumWorkingSetSize", ctypes.c_size_t), ("ActiveProcessLimit", wintypes.DWORD),
        ("Affinity", ctypes.c_size_t), ("PriorityClass", wintypes.DWORD), ("SchedulingClass", wintypes.DWORD),
        ("IoInfo", ctypes.c_uint64 * 6), ("ProcessMemoryLimit", ctypes.c_size_t),
        ("JobMemoryLimit", ctypes.c_size_t), ("PeakProcessMemoryUsed", ctypes.c_size_t),
        ("PeakJobMemoryUsed", ctypes.c_size_t),
    ]


class OwnProcess:
    """An Aseprite we launched, in a job object so killing it takes its children and nothing else."""

    def __init__(self, args: list[str], env: dict[str, str], log_path: Path, kill_on_exit: bool):
        with open(log_path, "wb") as log:
            self.proc = subprocess.Popen(args, env=env, stdout=log, stderr=subprocess.STDOUT,
                                         stdin=subprocess.DEVNULL, cwd=REPO)
        self.pid = self.proc.pid
        self.job = kernel32.CreateJobObjectW(None, None)
        if kill_on_exit:
            info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION(LimitFlags=0x2000)  # KILL_ON_JOB_CLOSE
            kernel32.SetInformationJobObject(self.job, 9, ctypes.byref(info), ctypes.sizeof(info))
        if not kernel32.AssignProcessToJobObject(self.job, int(self.proc._handle)):
            self.job = None

    def alive(self) -> bool:
        return self.proc.poll() is None

    def wait(self, timeout: float) -> bool:
        try:
            self.proc.wait(timeout)
            return True
        except subprocess.TimeoutExpired:
            return False

    def kill(self) -> None:
        if self.job:
            kernel32.TerminateJobObject(self.job, 1)
        self.proc.kill()
        self.wait(10)


user32 = ctypes.WinDLL("user32", use_last_error=True)
gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)
WNDENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
user32.EnumWindows.argtypes = [WNDENUMPROC, wintypes.LPARAM]
user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
user32.IsWindowVisible.argtypes = [wintypes.HWND]
user32.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
user32.GetClientRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
user32.GetWindowDC.argtypes = [wintypes.HWND]
user32.GetWindowDC.restype = wintypes.HDC
user32.ReleaseDC.argtypes = [wintypes.HWND, wintypes.HDC]
user32.PrintWindow.argtypes = [wintypes.HWND, wintypes.HDC, wintypes.UINT]
user32.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
user32.SendMessageTimeoutW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM,
                                       wintypes.UINT, wintypes.UINT, ctypes.POINTER(ctypes.c_size_t)]
user32.AttachThreadInput.argtypes = [wintypes.DWORD, wintypes.DWORD, wintypes.BOOL]
user32.GetKeyboardState.argtypes = [ctypes.c_char_p]
user32.SetKeyboardState.argtypes = [ctypes.c_char_p]
user32.MapVirtualKeyW.argtypes = [wintypes.UINT, wintypes.UINT]
user32.VkKeyScanW.argtypes = [wintypes.WCHAR]
user32.VkKeyScanW.restype = ctypes.c_short
gdi32.CreateCompatibleDC.argtypes = [wintypes.HDC]
gdi32.CreateCompatibleDC.restype = wintypes.HDC
gdi32.CreateCompatibleBitmap.argtypes = [wintypes.HDC, ctypes.c_int, ctypes.c_int]
gdi32.CreateCompatibleBitmap.restype = wintypes.HBITMAP
gdi32.SelectObject.argtypes = [wintypes.HDC, wintypes.HGDIOBJ]
gdi32.SelectObject.restype = wintypes.HGDIOBJ
gdi32.GetDIBits.argtypes = [wintypes.HDC, wintypes.HBITMAP, wintypes.UINT, wintypes.UINT,
                            ctypes.c_void_p, ctypes.c_void_p, wintypes.UINT]
gdi32.DeleteObject.argtypes = [wintypes.HGDIOBJ]
gdi32.DeleteDC.argtypes = [wintypes.HDC]


def window_rect(hwnd: int) -> wintypes.RECT:
    rect = wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    return rect


def main_window(pid: int) -> int | None:
    """The largest visible top-level window of pid."""
    found = []

    def callback(hwnd, _):
        owner = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == pid and user32.IsWindowVisible(hwnd):
            r = window_rect(hwnd)
            found.append(((r.right - r.left) * (r.bottom - r.top), hwnd))
        return True

    user32.EnumWindows(WNDENUMPROC(callback), 0)
    return max(found)[1] if found else None


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [
        ("biSize", wintypes.DWORD), ("biWidth", wintypes.LONG), ("biHeight", wintypes.LONG),
        ("biPlanes", wintypes.WORD), ("biBitCount", wintypes.WORD), ("biCompression", wintypes.DWORD),
        ("biSizeImage", wintypes.DWORD), ("biXPelsPerMeter", wintypes.LONG),
        ("biYPelsPerMeter", wintypes.LONG), ("biClrUsed", wintypes.DWORD), ("biClrImportant", wintypes.DWORD),
    ]


def write_png(path: Path, width: int, height: int, bgra: bytes) -> None:
    rgb = bytearray(width * height * 3)
    rgb[0::3], rgb[1::3], rgb[2::3] = bgra[2::4], bgra[1::4], bgra[0::4]
    stride = width * 3
    raw = b"".join(b"\x00" + rgb[y * stride:(y + 1) * stride] for y in range(height))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def screenshot(pid: int, out: Path) -> None:
    """PrintWindow capture of the main window: works with Aseprite in the background."""
    hwnd = main_window(pid)
    if not hwnd:
        raise RuntimeError("no visible Aseprite window to capture")
    rect = window_rect(hwnd)
    width, height = rect.right - rect.left, rect.bottom - rect.top
    src_dc = user32.GetWindowDC(hwnd)
    mem_dc = gdi32.CreateCompatibleDC(src_dc)
    bitmap = gdi32.CreateCompatibleBitmap(src_dc, width, height)
    old = gdi32.SelectObject(mem_dc, bitmap)
    try:
        header = BITMAPINFOHEADER(biSize=ctypes.sizeof(BITMAPINFOHEADER), biWidth=width,
                                  biHeight=-height, biPlanes=1, biBitCount=32)
        buf = ctypes.create_string_buffer(width * height * 4)
        if not (user32.PrintWindow(hwnd, mem_dc, 2)  # PW_RENDERFULLCONTENT
                and gdi32.GetDIBits(mem_dc, bitmap, 0, height, buf, ctypes.byref(header), 0)):
            raise RuntimeError("window capture failed")
    finally:
        gdi32.SelectObject(mem_dc, old)
        gdi32.DeleteObject(bitmap)
        gdi32.DeleteDC(mem_dc)
        user32.ReleaseDC(hwnd, src_dc)
    write_png(out, width, height, buf.raw)


# Input is sent as window messages, never touching the real cursor, focus or keyboard.
# laf (os/win/window.cpp) reads mouse positions from lParam and Ctrl/Shift from MK_* in
# wParam; for keys it reads modifiers/characters from the UI thread's key state.

VK = {
    "backspace": 0x08, "tab": 0x09, "enter": 0x0D, "return": 0x0D, "pause": 0x13, "capslock": 0x14,
    "esc": 0x1B, "escape": 0x1B, "space": 0x20, "pageup": 0x21, "pagedown": 0x22, "end": 0x23,
    "home": 0x24, "left": 0x25, "up": 0x26, "right": 0x27, "down": 0x28, "insert": 0x2D,
    "delete": 0x2E, "del": 0x2E, "plus": 0xBB, "minus": 0xBD, "comma": 0xBC, "period": 0xBE,
    **{f"f{i}": 0x6F + i for i in range(1, 25)},
}
EXTENDED_VKS = {0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2D, 0x2E, 0x5B}
MOD_VKS = {"ctrl": (0x11, 0xA2), "control": (0x11, 0xA2), "shift": (0x10, 0xA0), "alt": (0x12, 0xA4),
           "win": (0x5B, 0x5B)}
MK_FLAGS = {"ctrl": 0x08, "control": 0x08, "shift": 0x04}
MOUSE_MSGS = {"left": (0x201, 0x202, 0x203, 0x01), "right": (0x204, 0x205, 0x206, 0x02),
              "middle": (0x207, 0x208, 0x209, 0x10)}  # down, up, dblclk, MK_ button
WM_KEYDOWN, WM_KEYUP, WM_SYSKEYDOWN, WM_SYSKEYUP, WM_IME_CHAR, WM_MOUSEMOVE = 0x100, 0x101, 0x104, 0x105, 0x286, 0x200


def vk_code(name: str) -> int:
    key = name.lower()
    if key in VK:
        return VK[key]
    if len(key) == 1 and key.isalnum():
        return ord(key.upper())
    raise ValueError(f"unknown key {name!r}")


def split_mods(mods: str) -> list[str]:
    names = [m.lower() for m in mods.replace(" ", "").split("+") if m]
    if unknown := [m for m in names if m not in MOD_VKS]:
        raise ValueError(f"unknown modifier {unknown[0]!r}")
    return names


def send_msg(hwnd: int, msg: int, wparam: int, lparam: int) -> None:
    result = ctypes.c_size_t()
    if not user32.SendMessageTimeoutW(hwnd, msg, wparam, lparam, 0x0002, 3000, ctypes.byref(result)):
        raise RuntimeError(f"Aseprite did not process message 0x{msg:x} (hung?)")


def key_msg(hwnd: int, msg: int, vk: int) -> None:
    up = msg in (WM_KEYUP, WM_SYSKEYUP)
    lparam = 1 | user32.MapVirtualKeyW(vk, 0) << 16 | (vk in EXTENDED_VKS) << 24 | (0xC0000000 if up else 0)
    send_msg(hwnd, msg, vk, lparam)


class ThreadKeyState:
    """Sets the pressed keys GetKeyState sees on Aseprite's UI thread (via AttachThreadInput)."""

    def __init__(self, hwnd: int):
        self.me = kernel32.GetCurrentThreadId()
        self.target = user32.GetWindowThreadProcessId(hwnd, None)

    def __enter__(self):
        if not user32.AttachThreadInput(self.me, self.target, True):
            raise RuntimeError("AttachThreadInput to the Aseprite UI thread failed")
        self.saved = ctypes.create_string_buffer(256)
        user32.GetKeyboardState(self.saved)
        return self

    def press(self, vks: list[int]) -> None:
        state = ctypes.create_string_buffer(self.saved.raw, 256)
        for vk in vks:
            state[vk] = b"\x80"
        user32.SetKeyboardState(state)

    def __exit__(self, *exc):
        user32.SetKeyboardState(self.saved)
        user32.AttachThreadInput(self.me, self.target, False)


def post_combo(hwnd: int, keys: ThreadKeyState, combo: str) -> None:
    *mod_text, key_name = combo.replace(" ", "").split("+")
    mods, key = split_mods("+".join(mod_text)), vk_code(key_name)
    down, up = (WM_SYSKEYDOWN, WM_SYSKEYUP) if "alt" in mods else (WM_KEYDOWN, WM_KEYUP)
    held: list[int] = []
    for name in mods:
        held += MOD_VKS[name]
        keys.press(held)
        key_msg(hwnd, down, MOD_VKS[name][0])
    keys.press(held + [key])
    key_msg(hwnd, down, key)
    time.sleep(0.05)  # modifiers must stay pressed while the UI loop handles the key
    keys.press(held)
    key_msg(hwnd, up, key)
    for name in reversed(mods):
        key_msg(hwnd, up, MOD_VKS[name][0])
    keys.press([])


def post_text(hwnd: int, keys: ThreadKeyState, text: str) -> None:
    for ch in text:
        scan = user32.VkKeyScanW(ch)
        if scan != -1 and not (scan >> 8) & 0x6:  # a key of the layout, maybe with Shift
            vk = scan & 0xFF
            held = list(MOD_VKS["shift"]) if (scan >> 8) & 1 else []
            keys.press(held + [vk])
            key_msg(hwnd, WM_KEYDOWN, vk)
            keys.press(held)
            key_msg(hwnd, WM_KEYUP, vk)
            keys.press([])
        else:
            send_msg(hwnd, WM_IME_CHAR, ord(ch), 1)  # laf turns this into a KeyDown with the char
        time.sleep(0.01)


def post_mouse(hwnd: int, keys: ThreadKeyState, action: dict, x: int, y: int) -> None:
    # Posted in one burst: laf's TrackMouseEvent sees the real cursor elsewhere and queues
    # WM_MOUSELEAVE after the first move, which would clear the widget under the mouse.
    lparam = (y & 0xFFFF) << 16 | (x & 0xFFFF)
    mods = split_mods(action.get("mods", ""))
    mk = sum(MK_FLAGS.get(m, 0) for m in mods)
    msgs = [(WM_MOUSEMOVE, mk)]
    if "click" in action:
        down, up, dbl, flag = MOUSE_MSGS[action.get("button", "left")]
        msgs += [(down, mk | flag), (up, mk)]
        if action.get("double"):
            msgs += [(dbl, mk | flag), (up, mk)]
    keys.press([vk for m in mods for vk in MOD_VKS[m]])
    for msg, wparam in msgs:
        if not user32.PostMessageW(hwnd, msg, wparam, lparam):
            raise RuntimeError(f"PostMessage 0x{msg:x} failed ({ctypes.get_last_error()})")
    time.sleep(0.1)  # modifiers must stay pressed while the UI loop handles the click
    keys.press([])


class RequestServer:
    """Serves T.input/T.screenshot: <run>/requests/req-N.json -> ack-N.json."""

    def __init__(self, run_dir: Path, pid: int):
        self.dir = run_dir / "requests"
        self.shots_dir = run_dir / "screenshots"
        self.pid = pid
        self.next_id = 1

    def poll(self) -> None:
        while True:
            try:
                request = json.loads((self.dir / f"req-{self.next_id}.json").read_text(encoding="utf-8"))
            except (OSError, ValueError):
                return
            try:
                ack = {"ok": True, **self.handle(request)}
            except Exception as e:  # reported to the scenario, which fails with it
                ack = {"ok": False, "error": f"{type(e).__name__}: {e}"}
            tmp = self.dir / f"ack-{self.next_id}.tmp"
            tmp.write_text(json.dumps(ack), encoding="utf-8")
            os.replace(tmp, self.dir / f"ack-{self.next_id}.json")
            self.next_id += 1

    def handle(self, request: dict) -> dict:
        if request["type"] == "screenshot":
            name = "".join(c if c.isalnum() or c in "-_." else "_" for c in request["name"])
            out = self.shots_dir / f"{name}.png"
            screenshot(self.pid, out)
            return {"path": win_path(out)}
        hwnd = main_window(self.pid)
        if not hwnd:
            raise RuntimeError("no visible Aseprite window")
        client = wintypes.RECT()
        user32.GetClientRect(hwnd, ctypes.byref(client))
        scale = max(1, round(client.right / request["ui_width"]))  # laf's integer screen scale
        with ThreadKeyState(hwnd) as keys:
            for action in request["actions"]:
                if "wait" in action:
                    time.sleep(action["wait"])
                    continue
                if "key" in action:
                    post_combo(hwnd, keys, action["key"])
                elif "text" in action:
                    post_text(hwnd, keys, action["text"])
                elif pos := action.get("click") or action.get("move"):
                    post_mouse(hwnd, keys, action, round(pos["x"] * scale), round(pos["y"] * scale))
                else:
                    raise ValueError(f"unknown action {action}")
                time.sleep(0.03)
        return {"scale": scale}


def new_run_dir(scenario: Path, mode: str) -> Path:
    runs = cache_root() / "runs"
    runs.mkdir(parents=True, exist_ok=True)
    for stale in runs.iterdir():  # by age, so concurrent runs are never pruned
        with contextlib.suppress(OSError):
            if stale.is_dir() and time.time() - stale.stat().st_mtime > RUN_MAX_AGE_S:
                shutil.rmtree(stale, ignore_errors=True)
    run = runs / f"{time.strftime('%Y%m%d-%H%M%S')}-{os.getpid()}-{scenario.stem}-{mode}"
    for sub in ("tmp", "systemp", "user", "requests"):
        (run / sub).mkdir(parents=True)
    return run


def read_result(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except (OSError, ValueError):
        return None  # not written yet, or mid-write


def run(args: argparse.Namespace) -> int:
    scenario = Path(args.scenario).resolve()
    if not scenario.is_file():
        raise SetupError(f"scenario not found: {scenario}")
    mode = "gui" if args.gui else "batch"
    if args.build and subprocess.run(["cargo", "build"], cwd=REPO / "lib").returncode != 0:
        raise SetupError("cargo build failed")
    dll = REPO / "lib" / "target" / "debug" / DLL_NAME
    if not dll.is_file():
        raise SetupError(f"{dll} not found; run cargo build in lib/ or pass --build")

    exe = prepare_install(find_source_exe())
    run_dir = new_run_dir(scenario, mode)
    user_dir = run_dir / "user"
    result_path = run_dir / "result.json"
    quit_path = run_dir / "quit"

    # Every chunk that does io/loadlib needs trust, including helpers a scenario dofile()s.
    trusted = [BOOTSTRAP, *scenario.parent.rglob("*.lua"), *TESTS_DIR.rglob("*.lua")]
    if mode == "gui":
        ext = install_extension(user_dir, dll)
        trusted += ext.rglob("*.lua")
        dll_used = ext / DLL_NAME
    else:
        dll_used = run_dir / DLL_NAME  # a copy, so a running test never locks lib/target against cargo
        shutil.copy2(dll, dll_used)
    write_config(user_dir, trusted, args.window)

    params = {
        "harness_mode": mode,
        "harness_repo": win_path(REPO),
        "harness_scenario": win_path(scenario),
        "harness_result": win_path(result_path),
        "harness_quit": win_path(quit_path),
        "harness_requests": win_path(run_dir / "requests"),
        "harness_tmp": win_path(run_dir / "tmp"),
        "harness_dll": win_path(dll_used),
    }
    for item in args.param:
        key, sep, value = item.partition("=")
        if not sep or not key or key.startswith("harness_"):
            raise SetupError(f"bad --param {item!r} (want k=v, k not starting with harness_)")
        params[key] = value

    cmd = [str(exe), "-b" if mode == "batch" else "--noinapp"]
    for key, value in params.items():
        cmd += ["--script-param", f"{key}={value}"]
    cmd += ["--script", win_path(BOOTSTRAP)]
    env = {**os.environ, "ASEPRITE_USER_FOLDER": win_path(user_dir)}
    env["TMP"] = env["TEMP"] = win_path(run_dir / "systemp")  # per-run app.fs.tempPath, hence TEMP_DIR

    timeout = args.timeout or (60 if mode == "batch" else 120)
    print(f"[runner] {mode} | run dir {run_dir}")
    start = time.monotonic()
    proc = OwnProcess(cmd, env, run_dir / "aseprite.log", kill_on_exit=not args.keep_open)
    server = RequestServer(run_dir, proc.pid) if mode == "gui" else None
    try:
        while time.monotonic() - start < timeout:
            if server:
                server.poll()
            result = read_result(result_path)
            if (result and result.get("status") == "done") or not proc.alive():
                break
            time.sleep(0.05)
        result = read_result(result_path)
        finished = bool(result and result.get("status") == "done")

        if mode == "gui" and proc.alive() and (args.screenshot or not finished):
            out = Path(args.screenshot).resolve() if finished else run_dir / "timeout.png"
            time.sleep(0.5)  # let the last frame paint
            try:
                screenshot(proc.pid, out)
                print(f"[runner] screenshot -> {out}")
            except Exception as e:  # must not skip the cleanup below
                print(f"[runner] screenshot failed: {e}")

        if not finished:
            status = "timeout" if proc.alive() else "crash"
        else:
            status = "pass" if result.get("ok") else "fail"

        if args.keep_open and proc.alive():
            print(f"[runner] --keep-open: leaving Aseprite PID {proc.pid} running")
        elif finished and proc.alive():
            # Batch exits by itself; GUI exits on the quit marker.
            if mode == "gui":
                quit_path.write_text("quit", encoding="utf-8")
            if not proc.wait(15) and mode == "gui":
                with contextlib.suppress(Exception):
                    screenshot(proc.pid, run_dir / "exit_stuck.png")
                print(f"[runner] graceful quit stalled; see {run_dir / 'exit_stuck.png'}")
                if hwnd := main_window(proc.pid):
                    user32.PostMessageW(hwnd, 0x0010, 0, 0)  # WM_CLOSE
                proc.wait(10)
    finally:
        if not args.keep_open and proc.alive():
            proc.kill()

    elapsed = time.monotonic() - start
    if result is not None:
        print(json.dumps(result, indent=2))
    log = (run_dir / "aseprite.log").read_text(encoding="utf-8", errors="replace")[-4000:]
    if log.strip() and status != "pass":
        print("[runner] Aseprite output:\n" + log)
    name = scenario.name
    if status == "pass":
        print(f"PASS {name} ({mode}) {result.get('assertions', 0)} assertions, {elapsed:.1f}s")
        return EXIT_PASS
    if status == "fail":
        print(f"FAIL {name} ({mode}): {result.get('message')}")
        if result.get("traceback"):
            print(result["traceback"])
        return EXIT_FAIL
    if status == "timeout":
        print(f"TIMEOUT {name} ({mode}) after {timeout}s; killed own Aseprite PID {proc.pid}; "
              f"see {run_dir / 'timeout.png'}")
        return EXIT_TIMEOUT
    print(f"CRASH {name} ({mode}): Aseprite exited with {proc.proc.returncode} before finishing")
    return EXIT_CRASH


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("scenario", help="Lua scenario, e.g. tools/tests/smoke_editor.lua")
    parser.add_argument("--param", action="append", default=[], metavar="K=V", help="scenario parameter (repeatable)")
    parser.add_argument("--gui", action="store_true", help="run with UI and the installed extension (real init)")
    parser.add_argument("--screenshot", metavar="PNG", help="GUI: capture the window when the scenario is done")
    parser.add_argument("--timeout", type=float, metavar="S", help="seconds before killing Aseprite (60 batch, 120 GUI)")
    parser.add_argument("--keep-open", action="store_true", help="GUI: leave Aseprite running afterwards")
    parser.add_argument("--window", type=window_size, default=(1600, 1000), metavar="WxH",
                        help="GUI: main window size in screen px (default 1600x1000)")
    parser.add_argument("--build", action="store_true", help="run cargo build in lib/ first")
    args = parser.parse_args()
    if (args.keep_open or args.screenshot) and not args.gui:
        parser.error("--keep-open and --screenshot need --gui")
    # Per-monitor DPI awareness, so window rects and PrintWindow use real pixels.
    user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
    try:
        return run(args)
    except SetupError as e:
        print(f"[runner] setup error: {e}", file=sys.stderr)
        return EXIT_SETUP


if __name__ == "__main__":
    sys.exit(main())
