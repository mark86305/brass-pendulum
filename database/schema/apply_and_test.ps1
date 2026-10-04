# Brass Pendulum - apply schema, run tests, or reset to a clean schema.
#
#   .\apply_and_test.ps1 -Conn "<connection string without password>" -Mode test
#       Applies G1-G4 to an EMPTY database, then runs the four test files.
#       Expect: G1, G2, G3, G4 TESTS PASSED (27 + 33 + 62 + 23 = 145).
#
#   .\apply_and_test.ps1 -Conn "<connection string without password>" -Mode reset
#       DROPS the sgpt schema and everything in it, then applies G1-G4 only.
#       Leaves 37 tables: 32 empty, 5 holding the schema's own starting rows.
#
# The password is asked for once and never written to disk or history.
# Each file runs in its own psql session: the test files define temporary
# helper functions with the same names, and the Group 3 tests depend on the
# clock moving between statements, so files must not share one batch.

param(
    [Parameter(Mandatory = $true)][string]$Conn,
    [Parameter(Mandatory = $true)][ValidateSet("test", "reset")][string]$Mode
)

# "Continue", not "Stop": Windows PowerShell treats psql NOTICE lines on stderr as
# errors under "Stop". Failures are detected from psql exit codes instead.
$ErrorActionPreference = "Continue"
$here = $PSScriptRoot

$psql = Get-ChildItem "C:\Program Files\PostgreSQL\*\bin\psql.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
if (-not $psql) { Write-Host "psql.exe not found under C:\Program Files\PostgreSQL" -ForegroundColor Red; exit 1 }

if ($Conn -notmatch "sslmode=") { $Conn = if ($Conn -match "\?") { "${Conn}&sslmode=require" } else { "${Conn}?sslmode=require" } }

$schema = @(
    "SpecGPT_Schema-G1_D04_2026-09-12.sql",
    "2026_09_11_SpeculativeGPT_Schema_G2_Draft2.sql",
    "SpecGPT_Schema-G3_D02_2026-09-12.sql",
    "SpecGPT_Schema-G4_D01_2026-09-12.sql"
)
$tests = @(
    "SpecGPT_Schema-G1_D04_Tests_2026-09-12.sql",
    "2026_09_11_SpeculativeGPT_Schema_G2_Draft2_Tests.sql",
    "SpecGPT_Schema-G3_D02_Tests_2026-09-12.sql",
    "SpecGPT_Schema-G4_D01_Tests_2026-09-12.sql"
)

$secure = Read-Host "Database password (from Bitwarden)" -AsSecureString
$env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))

function Invoke-Sql([string]$label, [string[]]$psqlArgs) {
    Write-Host "-- $label" -ForegroundColor Cyan
    $out = & $psql.FullName -X -q -v ON_ERROR_STOP=1 -d $Conn @psqlArgs 2>&1
    $code = $LASTEXITCODE
    $passed = $out | Select-String "TESTS PASSED"
    if ($passed) { Write-Host ("   " + $passed.Line.Trim()) -ForegroundColor Green }
    if ($code -ne 0) {
        Write-Host "   FAILED (exit code $code). Last lines:" -ForegroundColor Red
        $out | Select-Object -Last 15 | ForEach-Object { Write-Host "   $_" }
        throw "Stopped at: $label"
    }
}

try {
    $existing = & $psql.FullName -X -q -t -A -d $Conn -c "select count(*) from information_schema.schemata where schema_name='sgpt'" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not connect: $existing" }

    if ($Mode -eq "test" -and "$existing".Trim() -ne "0") {
        throw "The sgpt schema already exists. Tests must run on an empty database. Use -Mode reset first, then -Mode test."
    }

    if ($Mode -eq "reset") {
        $confirm = Read-Host "This DELETES the sgpt schema and all its data. Type RESET to continue"
        if ($confirm -cne "RESET") { throw "Cancelled. Nothing was changed." }
        Invoke-Sql "drop schema sgpt" @("-c", "drop schema if exists sgpt cascade")
    }

    foreach ($f in $schema) { Invoke-Sql "apply $f" @("-f", (Join-Path $here $f)) }

    if ($Mode -eq "test") {
        foreach ($f in $tests) { Invoke-Sql "test  $f" @("-f", (Join-Path $here $f)) }
        Write-Host "`nAll four test files passed. Expected total: 145 (27 + 33 + 62 + 23)." -ForegroundColor Green
    } else {
        $q = "select 'tables: ' || (select count(*) from information_schema.tables where table_schema='sgpt' and table_type='BASE TABLE') " +
             "union all select 'run_type_step: ' || count(*) from sgpt.run_type_step " +
             "union all select 'schedule_slot: ' || count(*) from sgpt.schedule_slot " +
             "union all select 'system_state: ' || count(*) from sgpt.system_state " +
             "union all select 'instrument: ' || count(*) from sgpt.instrument " +
             "union all select 'revision_parameter: ' || count(*) from sgpt.revision_parameter " +
             "union all select 'window_run: ' || count(*) from sgpt.window_run"
        $check = & $psql.FullName -X -q -t -A -d $Conn -c $q 2>&1
        Write-Host "`nClean schema in place. Expected: tables 37, run_type_step 18, schedule_slot 6, system_state 1, instrument 13, revision_parameter 17, window_run 0" -ForegroundColor Green
        $check | ForEach-Object { Write-Host "   $_" }
    }
}
catch {
    Write-Host "`n$_" -ForegroundColor Red
    exit 1
}
finally {
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
}
