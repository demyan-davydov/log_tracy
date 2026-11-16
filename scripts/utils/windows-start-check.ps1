# Starts the program of the Windows distribution as Explorer does (Start-Process: a program of
# /SUBSYSTEM:WINDOWS gets no stdout or stderr) and waits for its window (CI, build.yml). Without
# one it tells what it can, into build/ci/ (an artifact of the run) and the log of the step: the
# session, the windows of the process, visible or not, the stacks of its threads (cdb of the
# Windows SDK, when the runner has it), a picture of the desktop, and a second start with its
# output in a file, which also tells whether the missing stdout is what stops it. Fails then.
param([string]$Program = "build/dist/windows/log_tracy.exe", [int]$Seconds = 30)
$ErrorActionPreference = "Stop"
$out = "build/ci"
New-Item -ItemType Directory -Force $out | Out-Null

Add-Type -ReferencedAssemblies System.Drawing, System.Windows.Forms @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class StartCheck {
    delegate bool EnumProc(IntPtr hwnd, IntPtr param);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr param);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int size);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder text, int size);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    struct Rect { public int Left, Top, Right, Bottom; }

    // The top-level windows of a process, visible or not
    public static List<string> WindowsOf(uint pid) {
        var found = new List<string>();
        EnumProc visit = (hwnd, param) => {
            uint owner;
            GetWindowThreadProcessId(hwnd, out owner);
            if (owner != pid) return true;
            var title = new StringBuilder(256);
            GetWindowText(hwnd, title, title.Capacity);
            var cls = new StringBuilder(256);
            GetClassName(hwnd, cls, cls.Capacity);
            Rect r;
            GetWindowRect(hwnd, out r);
            found.Add(String.Format("{0} visible={1} class='{2}' title='{3}' rect=({4},{5})-({6},{7})",
                hwnd, IsWindowVisible(hwnd), cls, title, r.Left, r.Top, r.Right, r.Bottom));
            return true;
        };
        EnumWindows(visit, IntPtr.Zero);
        GC.KeepAlive(visit);
        return found;
    }

    // A picture of the whole desktop
    public static void SaveDesktop(string path) {
        var bounds = System.Windows.Forms.SystemInformation.VirtualScreen;
        using (var bitmap = new System.Drawing.Bitmap(bounds.Width, bounds.Height))
        using (var g = System.Drawing.Graphics.FromImage(bitmap)) {
            g.CopyFromScreen(bounds.Left, bounds.Top, 0, 0, bitmap.Size);
            bitmap.Save(path, System.Drawing.Imaging.ImageFormat.Png);
        }
    }
}
"@

# Waits for the window of `$p`: "window", "exited" or "none"
function Wait-Window($p) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $p.Refresh()
        if ($p.HasExited) { return "exited" }
        if ($p.MainWindowHandle -ne 0) { return "window" }
    }
    return "none"
}

function Write-Section($title, $lines) {
    Write-Host "::group::$title"
    $lines | ForEach-Object { Write-Host $_ }
    Write-Host "::endgroup::"
}

$self = Get-Process -Id $PID
Write-Host "This step: session $($self.SessionId), interactive $([Environment]::UserInteractive)"

$p = Start-Process $Program -PassThru
$state = Wait-Window $p
if ($state -eq "window") {
    Write-Host "The window is shown: $($p.MainWindowTitle)"
    Stop-Process -Id $p.Id -Force
    exit 0
}

Write-Host "No window after $Seconds s: $state (process $($p.Id), session $($p.SessionId))"
if ($state -eq "exited") { Write-Host "Exit code: $($p.ExitCode)" }
else {
    Write-Section "Windows of the process" ([StartCheck]::WindowsOf([uint32]$p.Id))
    Write-Section "Threads" ($p.Threads | ForEach-Object { "$($_.Id) $($_.ThreadState) $($_.WaitReason) cpu=$($_.TotalProcessorTime)" })
    $cdb = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe" -ErrorAction SilentlyContinue
    if ($cdb) {
        & $cdb.FullName -p $p.Id -c "~*kn 40; qd" 2>&1 | Out-File "$out/stacks.txt"
        Write-Section "Stacks (cdb)" (Get-Content "$out/stacks.txt")
    } else { Write-Host "No cdb on the runner: no stacks" }
    try { [StartCheck]::SaveDesktop("$out/desktop.png"); Write-Host "The desktop: $out/desktop.png" }
    catch { Write-Host "No picture of the desktop: $_" }
    Stop-Process -Id $p.Id -Force
}
Start-Sleep -Seconds 1 # the lock of the running copy dropped (utils/single_instance)

# The same with stdout and stderr in files: a window now means the missing streams stop it
$second = Start-Process $Program -PassThru -RedirectStandardOutput "$out/stdout.txt" -RedirectStandardError "$out/stderr.txt"
$secondState = Wait-Window $second
Write-Host "With stdout and stderr in files: $secondState"
if (-not $second.HasExited) { Stop-Process -Id $second.Id -Force }
Start-Sleep -Seconds 1
Write-Section "stdout of the second start" (Get-Content "$out/stdout.txt" -ErrorAction SilentlyContinue)
Write-Section "stderr of the second start" (Get-Content "$out/stderr.txt" -ErrorAction SilentlyContinue)
throw "Log Tracy shows no window when started as from Explorer ($state)"
