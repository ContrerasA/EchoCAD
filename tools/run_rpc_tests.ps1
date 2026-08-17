# Windows equivalent of tools/run_rpc_tests.sh: launch the app with the
# automation server and run every tests/rpc/test_*.py against it (fresh app
# per test). Requires Python 3 on PATH (py or python).
#
# Usage (PowerShell):
#   tools\run_rpc_tests.ps1 [name-filter]
#   $env:GODOT = "C:\path\to\Godot_v4.7.1-stable_win64.exe"
#   $env:HEADLESS = "1"        # force headless (recommended unattended —
#                              # windowed runs flake from real mouse focus)
#   $env:PORT = "4777"

param([string]$Filter = "")

$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

function Find-Godot {
    if ($env:GODOT -and (Test-Path $env:GODOT)) { return $env:GODOT }
    foreach ($name in @("godot4.7.1", "godot4", "godot", "Godot_v4.7.1-stable_win64.exe")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    Write-Error "godot binary not found — set `$env:GODOT to your Godot 4.7 executable"
}

function Find-Python {
    foreach ($name in @("py", "python3", "python")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    Write-Error "Python 3 not found on PATH (install from python.org or the Store)"
}

$godot = Find-Godot
$python = Find-Python
$port = if ($env:PORT) { $env:PORT } else { "4777" }
$headless = @()
if ($env:HEADLESS -eq "1") { $headless = @("--headless") }

$pass = 0
$fail = 0

foreach ($f in Get-ChildItem tests\rpc -Filter test_*.py) {
    $name = $f.BaseName
    if ($Filter -and ($name -notlike "*$Filter*")) { continue }
    $app = Start-Process -FilePath $godot `
        -ArgumentList (@("--path", ".") + $headless + @("--", "--automation-port=$port")) `
        -PassThru -WindowStyle Hidden
    $env:ECHOCAD_PORT = $port
    & $python $f.FullName
    if ($LASTEXITCODE -eq 0) {
        $pass++
    } else {
        Write-Output "FAIL $name"
        $fail++
    }
    # test_shell quits the app itself via app.quit; kill leftovers.
    Stop-Process -Id $app.Id -ErrorAction SilentlyContinue
    Wait-Process -Id $app.Id -ErrorAction SilentlyContinue
}

Write-Output "rpc passed=$pass failed=$fail"
exit $(if ($fail -eq 0) { 0 } else { 1 })
