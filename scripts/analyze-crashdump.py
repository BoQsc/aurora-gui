#!/usr/bin/env python3
"""Name the fault behind a Windows crash dump without installing a debugger.

Usage:
    python scripts/analyze-crashdump.py <crash.dmp> [app.exe]

The app's own `logs/dumps/*.dmp` are often 0 bytes, because the in-process
MiniDumpWriteDump can fail on the dying thread. Windows still writes a
full-memory dump to:

    %LOCALAPPDATA%\\CrashDumps\\<exe>.<pid>.dmp

This prints:
  * the exception code/address and whether the fault was a read or a write;
  * the module and offset that the fault address falls in;
  * the general-purpose registers (for a `memcpy` fault, RCX/RDX are the
    destination/source and R8 is the length - R8 = 0xFFFF...FFFF means an
    underflowed unsigned length, the classic `ptrdiff_t -1` promotion);
  * the RBP-walked call stack, symbolized through the sibling `.pdb` with
    dbghelp `SymFromAddr` (the legacy `SymGetSymFromAddr64` misses non-public
    symbols).

Requires the `minidump` package (`pip install minidump`) and the `.pdb` next to
`app.exe` (a release `dub build` emits it).
"""

import ctypes
import sys
from ctypes import wintypes

try:
    from minidump.minidumpfile import MinidumpFile
except ImportError:
    sys.exit("the 'minidump' package is required: pip install minidump")


def pe_stamp(exe):
    """(TimeDateStamp, SizeOfImage) from the on-disk PE, for a build compare."""
    import struct
    data = open(exe, "rb").read()
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    tds = struct.unpack_from("<I", data, pe + 8)[0]
    opt = pe + 24
    size = struct.unpack_from("<I", data, opt + 56)[0]
    return tds, size


def load_dbghelp(exe, base, size):
    dbghelp = ctypes.WinDLL("dbghelp", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

    dbghelp.SymSetOptions.argtypes = [wintypes.DWORD]
    dbghelp.SymSetOptions(0x1 | 0x2 | 0x10 | 0x40)  # deferred|undname|lines|anything
    dbghelp.SymInitialize.argtypes = [wintypes.HANDLE, ctypes.c_char_p,
                                      wintypes.BOOL]
    h = kernel32.GetCurrentProcess()
    if not dbghelp.SymInitialize(h, None, False):
        raise OSError("SymInitialize failed: %d" % ctypes.get_last_error())

    dbghelp.SymLoadModuleExW.argtypes = [
        wintypes.HANDLE, wintypes.HANDLE, wintypes.LPCWSTR, wintypes.LPCWSTR,
        ctypes.c_ulonglong, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD]
    dbghelp.SymLoadModuleExW.restype = ctypes.c_ulonglong
    loaded = dbghelp.SymLoadModuleExW(h, None, exe, None, base, size, None, 0)
    if not loaded:
        raise OSError("SymLoadModuleExW failed for %s (missing .pdb?)" % exe)

    dbghelp.SymFromAddr.argtypes = [wintypes.HANDLE, ctypes.c_ulonglong,
                                    ctypes.POINTER(ctypes.c_ulonglong),
                                    ctypes.c_void_p]
    dbghelp.SymFromAddr.restype = wintypes.BOOL
    dbghelp.SymGetLineFromAddr64.argtypes = [
        wintypes.HANDLE, ctypes.c_ulonglong, ctypes.POINTER(wintypes.DWORD),
        ctypes.c_void_p]
    dbghelp.SymGetLineFromAddr64.restype = wintypes.BOOL
    return dbghelp, h, loaded


class _Line(ctypes.Structure):
    _fields_ = [("SizeOfStruct", wintypes.DWORD), ("Key", ctypes.c_void_p),
                ("LineNumber", wintypes.DWORD), ("FileName", ctypes.c_char_p),
                ("Address", ctypes.c_ulonglong)]


def symbolize(dbghelp, h, addr):
    buf = ctypes.create_string_buffer(2048)
    ctypes.c_uint32.from_buffer(buf, 0).value = 88   # SYMBOL_INFO.SizeOfStruct
    ctypes.c_uint32.from_buffer(buf, 80).value = 1900  # MaxNameLen
    disp = ctypes.c_ulonglong(0)
    name = None
    if dbghelp.SymFromAddr(h, addr, ctypes.byref(disp), buf):
        raw = ctypes.string_at(ctypes.addressof(buf) + 84)
        name = "%s + 0x%x" % (raw.decode("utf-8", "replace"), disp.value)
    line = _Line()
    line.SizeOfStruct = ctypes.sizeof(_Line)
    ld = wintypes.DWORD(0)
    where = None
    if dbghelp.SymGetLineFromAddr64(h, addr, ctypes.byref(ld), ctypes.byref(line)):
        where = "%s(%d)" % (line.FileName.decode("ascii", "replace"),
                            line.LineNumber)
    return name, where


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    dump_path = sys.argv[1]
    exe = sys.argv[2] if len(sys.argv) > 2 else None

    d = MinidumpFile.parse(dump_path)
    rec = d.exception.exception_records[0].ExceptionRecord
    code = int(rec.ExceptionCode_raw)
    addr = rec.ExceptionAddress
    info = list(rec.ExceptionInformation)
    access = {0: "read", 1: "write", 8: "execute"}.get(
        info[0] if info else -1, "?")
    print("exception: code=0x%08X address=0x%X access=%s%s" % (
        code, addr, access,
        (" target=0x%X" % info[1]) if len(info) > 1 else ""))

    modules = d.modules.modules
    fault_mod = None
    exe_mod = None
    for m in modules:
        if m.baseaddress <= addr < m.baseaddress + m.size:
            fault_mod = m
        if exe and m.name.lower() == exe.lower():
            exe_mod = m
    if fault_mod:
        print("fault in: %s + 0x%X" % (fault_mod.name,
                                       addr - fault_mod.baseaddress))
    else:
        print("fault address is not inside any loaded module")

    tid = d.exception.exception_records[0].ThreadId
    th = next((t for t in d.threads.threads if t.ThreadId == tid), None)
    if th is None:
        sys.exit("faulting thread not found in the dump")
    ctx = th.ContextObject
    for n in ("Rax", "Rbx", "Rcx", "Rdx", "Rsi", "Rdi", "R8", "R9",
              "R10", "R11", "R12", "R13", "R14", "R15", "Rbp", "Rsp", "Rip"):
        v = getattr(ctx, n, 0)
        print("  %-4s 0x%016X" % (n, v))
    print("  (RCX/RDX = memcpy dest/src, R8 = length when the fault is a copy)")

    # Read memory through the dump's segments (full dumps keep all pages).
    def read_qword(a):
        try:
            for seg in d.get_reader().memory_segments:
                if seg.inrange(a):
                    want = min(seg.end_virtual_address - a, 8)
                    if want < 8:
                        return None
                    return int.from_bytes(
                        seg.read(a, 8, d.get_reader().file_handle), "little")
        except Exception:
            return None
        return None

    if exe and exe_mod:
        # Symbols only describe the build they were emitted for. A rebuilt exe
        # silently resolves to the wrong function with total confidence, so
        # compare the dump module's PE stamp with the on-disk exe first.
        try:
            tds, size = pe_stamp(exe)
            if tds != exe_mod.timestamp or size != exe_mod.size:
                print("WARNING: the on-disk exe does not match the crashing "
                      "build (dump %08X/%X vs exe %08X/%X); symbol names below "
                      "may be wrong. Use the archived pdb under "
                      "logs/symbols/ for the same build key."
                      % (exe_mod.timestamp, exe_mod.size, tds, size))
        except Exception:
            pass
        try:
            dbghelp, h, _ = load_dbghelp(exe, exe_mod.baseaddress, exe_mod.size)
        except OSError as e:
            sys.exit(str(e))
    else:
        dbghelp = h = None

    print("stack:")
    rbp = ctx.Rbp
    seen = 0
    while rbp and seen < 64:
        ret = read_qword(rbp + 8)
        nxt = read_qword(rbp)
        if ret is None:
            break
        text = "  0x%016X" % ret
        if dbghelp:
            name, where = symbolize(dbghelp, h, ret)
            if name:
                text += "  " + name
            if where:
                text += "  %s" % where
        print(text)
        if nxt is None or nxt <= rbp:
            break
        rbp = nxt
        seen += 1
    if seen == 0:
        print("  (no RBP chain; the module may be built without frame pointers)")


if __name__ == "__main__":
    main()
