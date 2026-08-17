# Windows equivalent of tools/run_tests.sh: run every headless test in
# tests/*.gd. Prints FAIL <name> per failure; exits non-zero on any failure.
#
# Usage (PowerShell):
#   tools\run_tests.ps1 [name-filter]
#   $env:GODOT = "C:\path\to\Godot_v4.7.1-stable_win64.exe"   # override binary
#
# Without $env:GODOT set, the script looks for godot/godot4 on PATH.

param([string]$Filter = "")

$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

function Find-Godot {
    if ($env:GODOT -and (Test-Path $env:GODOT)) { return $env:GODOT }
    foreach ($name in @("godot4.7.1", "godot4", "godot", "Godot_v4.7.1-stable_win64.exe")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    Write-Error "godot binary not found - set `$env:GODOT to your Godot 4.7 executable (the console build, Godot_*_win64_console.exe, shows test output best)"
}

$godot = Find-Godot
$pass = 0
$fail = 0

foreach ($f in Get-ChildItem tests -Filter *.gd) {
    $t = $f.BaseName
    if ($Filter -and ($t -notlike "*$Filter*")) { continue }
    # cmd /c owns the redirection: PS 5.1 wraps native stderr in ErrorRecords,
    # which terminates the script under $ErrorActionPreference = "Stop".
    cmd /c "`"$godot`" --headless --path . --script `"res://tests/$t.gd`" >nul 2>&1"
    if ($LASTEXITCODE -eq 0) {
        $pass++
    } else {
        Write-Output "FAIL $t"
        $fail++
    }
}

Write-Output "passed=$pass failed=$fail"
exit $(if ($fail -eq 0) { 0 } else { 1 })
