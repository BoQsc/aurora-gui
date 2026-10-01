"""A disposable Win32 window records actual native and posted mouse messages."""
import ctypes as c
from ctypes import wintypes as w
import json
import sys
import time
from pathlib import Path

directory = Path(sys.argv[1])
user32 = c.windll.user32
kernel32 = c.windll.kernel32
proc_type = c.WINFUNCTYPE(c.c_ssize_t, w.HWND, w.UINT, c.c_size_t, c.c_ssize_t)
events = []
labels = {0x201: 'left_down', 0x202: 'left_up', 0x204: 'right_down',
          0x205: 'right_up', 0x207: 'middle_down', 0x208: 'middle_up'}
user32.DefWindowProcW.argtypes = [w.HWND, w.UINT, c.c_size_t, c.c_ssize_t]
user32.DefWindowProcW.restype = c.c_ssize_t
@proc_type
def procedure(hwnd, message, wp, lp):
    if message in labels:
        events.append(labels[message])
        return 0
    return user32.DefWindowProcW(hwnd, message, wp, lp)

class WindowClass(c.Structure):
    _fields_ = [('style', w.UINT), ('procedure', proc_type), ('class_extra', c.c_int),
                ('window_extra', c.c_int), ('instance', w.HINSTANCE), ('icon', w.HICON),
                ('cursor', w.HANDLE), ('background', w.HBRUSH),
                ('menu', w.LPCWSTR), ('name', w.LPCWSTR)]
kernel32.GetModuleHandleW.argtypes = [w.LPCWSTR]
kernel32.GetModuleHandleW.restype = w.HINSTANCE
instance = kernel32.GetModuleHandleW(None)
name = 'AuroraMouseButtonFixture'
cls = WindowClass(0, procedure, 0, 0, instance, None, None, w.HBRUSH(6), None, name)
user32.RegisterClassW.argtypes = [c.POINTER(WindowClass)]
assert user32.RegisterClassW(c.byref(cls))
user32.CreateWindowExW.argtypes = [w.DWORD, w.LPCWSTR, w.LPCWSTR, w.DWORD,
    c.c_int, c.c_int, c.c_int, c.c_int, w.HWND, w.HMENU, w.HINSTANCE, c.c_void_p]
user32.CreateWindowExW.restype = w.HWND
user32.DestroyWindow.argtypes = [w.HWND]
user32.PeekMessageW.argtypes = [c.POINTER(w.MSG), w.HWND, w.UINT, w.UINT, w.UINT]
user32.TranslateMessage.argtypes = [c.POINTER(w.MSG)]
user32.DispatchMessageW.argtypes = [c.POINTER(w.MSG)]
user32.DispatchMessageW.restype = c.c_ssize_t
hwnd = user32.CreateWindowExW(8, name, 'Aurora Mouse Button Fixture',
    0x10000000 | 0x00CF0000, 40, 400, 320, 180, None, None, instance, None)
assert hwnd
try:
    started = time.monotonic()
    message = w.MSG()
    while not (directory / 'stop').exists() and time.monotonic() - started < 60:
        while user32.PeekMessageW(c.byref(message), None, 0, 0, 1):
            user32.TranslateMessage(c.byref(message))
            user32.DispatchMessageW(c.byref(message))
        pending = directory / 'events.tmp'
        pending.write_text(json.dumps(events), encoding='utf-8')
        pending.replace(directory / 'events.json')
        time.sleep(0.02)
finally:
    user32.DestroyWindow(hwnd)
