param([string]$Shot)
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class M {
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
Add-Type -AssemblyName System.Drawing
$p = Get-Process aurora-video-recorder -ErrorAction Stop
$h = $p.MainWindowHandle
[M]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x0043) | Out-Null
Start-Sleep -Milliseconds 700
$c = New-Object M+RECT
[M]::GetClientRect($h, [ref]$c) | Out-Null
$r = New-Object M+RECT
[M]::GetWindowRect($h, [ref]$r) | Out-Null
$w = $c.Right; $len = $c.Bottom
$bmp = New-Object System.Drawing.Bitmap $w, $len
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $len))
$bmp.Save($Shot)
"saved ${w}x${len}"
