param([string]$Phase = "pick")
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class M {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
}
'@
Add-Type -AssemblyName System.Drawing

$rec = Get-Process aurora-video-recorder -ErrorAction Stop | Select-Object -First 1
$h = $rec.MainWindowHandle
[M]::SetWindowPos($h, [IntPtr](-2), 0, 0, 0, 0, 0x0043) | Out-Null   # HWND_NOTOPMOST, show
Start-Sleep -Milliseconds 500
[M]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x0043) | Out-Null   # HWND_TOPMOST
Start-Sleep -Milliseconds 500

function ClickClient([IntPtr]$win, [int]$x, [int]$y) {
    $p = New-Object M+POINT
    $p.X = $x; $p.Y = $y
    [M]::ClientToScreen($win, [ref]$p) | Out-Null
    [M]::SetCursorPos($p.X, $p.Y) | Out-Null
    Start-Sleep -Milliseconds 250
    [M]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 90
    [M]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 400
}

function Shot([IntPtr]$win, [string]$path) {
    $c = New-Object M+RECT
    [M]::GetClientRect($win, [ref]$c) | Out-Null
    $p0 = New-Object M+POINT
    [M]::ClientToScreen($win, [ref]$p0) | Out-Null
    $bmp = New-Object System.Drawing.Bitmap $c.Right, $c.Bottom
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($p0.X, $p0.Y, 0, 0, (New-Object System.Drawing.Size $c.Right, $c.Bottom))
    $bmp.Save($path)
    $bmp.Dispose()
}

if ($Phase -eq "pick") {
    # "Choose window..." sits under the capture-target hint.
    # "Choose window..." is the full-width row under the size hint (y≈316-350).
    ClickClient $h 300 333
    Shot $h "C:\Users\windows10\AppData\Local\Temp\vr-pick-mode.png"
    "picking=1"
}

if ($Phase -eq "choose") {
    # Click the middle of the Notepad window to select it.
    $note = Get-Process notepad -ErrorAction Stop | Select-Object -First 1
    $nr = New-Object M+RECT
    [M]::GetWindowRect($note.MainWindowHandle, [ref]$nr) | Out-Null
    $cx = [int](($nr.Left + $nr.Right) / 2)
    $cy = [int](($nr.Top + $nr.Bottom) / 2)
    [M]::SetCursorPos($cx, $cy) | Out-Null
    Start-Sleep -Milliseconds 300
    [M]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 90
    [M]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 800
    "clicked notepad at $cx,$cy"
    Shot $h "C:\Users\windows10\AppData\Local\Temp\vr-picked.png"
}

if ($Phase -eq "record") {
    ClickClient $h 380 96      # Record
    Start-Sleep -Seconds 3
    "ffmpeg=" + [bool](Get-Process ffmpeg -ErrorAction SilentlyContinue)
    ClickClient $h 380 96      # Stop
    Start-Sleep -Seconds 4
}
