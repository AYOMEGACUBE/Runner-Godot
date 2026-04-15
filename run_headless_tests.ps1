$ErrorActionPreference = "Stop"

$godot = $null
$exact = Get-ChildItem -Path "D:\1" -Filter "Godot_v4.5.1-stable_win64.exe" -Recurse -ErrorAction SilentlyContinue |
    Sort-Object FullName |
    Where-Object { -not $_.PSIsContainer } |
    Select-Object -First 1
if ($exact) {
    $godot = $exact.FullName
}
if (-not $godot) {
    Write-Error "Godot executable not found under D:\1"
    exit 2
}

$tests = Get-ChildItem -Path "3301_/3301_test" -Filter "*.gd" |
    Where-Object { $_.Name -notmatch "^tools_" } |
    Sort-Object Name

$fails = @()
foreach ($t in $tests) {
    $script = "res://3301_/3301_test/$($t.Name)"
    Write-Output "=== RUN $script ==="
    $p = Start-Process -FilePath $godot -ArgumentList @("--headless", "--path", "D:\YandexDisk\Projects\Runner\Godot", "-s", $script) -NoNewWindow -Wait -PassThru
    $code = 0
    if ($p -and $p.ExitCode -ne $null) {
        $code = [int]$p.ExitCode
    }
    if ($code -ne 0) {
        $fails += $script
        Write-Output "=== FAIL $script code=$code ==="
    } else {
        Write-Output "=== PASS $script ==="
    }
}

if ($fails.Count -gt 0) {
    Write-Output "FAILED_TESTS:"
    $fails | ForEach-Object { Write-Output $_ }
    exit 1
}

Write-Output "ALL_TESTS_PASSED"
exit 0
