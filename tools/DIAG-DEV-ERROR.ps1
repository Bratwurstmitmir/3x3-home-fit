$ErrorActionPreference = 'Continue'

$project = 'C:\Users\patri\Desktop\DCPP DIGITAL\3x3Homefit'
$devPackage = 'de.homefit3x3.app.dev'
$report = Join-Path $env:USERPROFILE 'Desktop\3x3-development-error.txt'
$metroOut = Join-Path $env:USERPROFILE 'Desktop\3x3-metro-out.txt'
$metroErr = Join-Path $env:USERPROFILE 'Desktop\3x3-metro-error.txt'
$bundleLog = Join-Path $env:USERPROFILE 'Desktop\3x3-bundle-check.txt'
$tempExport = Join-Path $env:TEMP '3x3-expo-export-check'

foreach ($f in @($report,$metroOut,$metroErr,$bundleLog)) {
    Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath $tempExport -Recurse -Force -ErrorAction SilentlyContinue

function Add-Report([string]$Text) {
    $Text | Tee-Object -FilePath $report -Append
}

Add-Report '=== 3x3 HOME FIT - DEVELOPMENT ERROR DIAGNOSE ==='
Add-Report ("Zeit: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Add-Report ''

if (!(Test-Path -LiteralPath $project)) {
    throw "Projektordner nicht gefunden: $project"
}
Set-Location -LiteralPath $project

Add-Report '--- 1. Expo Doctor ---'
$doctor = & npx expo-doctor 2>&1
$doctor | Tee-Object -FilePath $report -Append

Add-Report ''
Add-Report '--- 2. JS/Metro Bundle-Check ---'
$bundle = & npx expo export --platform android --dev --clear --output-dir $tempExport 2>&1
$bundle | Tee-Object -FilePath $bundleLog
$bundle | Tee-Object -FilePath $report -Append
$bundleExit = $LASTEXITCODE
Add-Report ("Bundle Exit Code: " + $bundleExit)

if ($bundleExit -ne 0) {
    Add-Report ''
    Add-Report '*** BUNDLE-FEHLER GEFUNDEN ***'
    $bundle |
        Select-String -Pattern 'Error|Unable to resolve|SyntaxError|ReferenceError|TypeError|Cannot find|Failed|TransformError' -Context 3,10 |
        Select-Object -Last 80 |
        ForEach-Object { Add-Report $_.ToString() }

    Add-Report ''
    Add-Report "Bericht: $report"
    Write-Host ''
    Write-Host 'BUNDLE-FEHLER GEFUNDEN. Kein weiterer Startversuch noetig.' -ForegroundColor Red
    Get-Content -LiteralPath $report -Tail 140
    exit 1
}

Add-Report ''
Add-Report 'Bundle-Check erfolgreich. Fehler liegt sehr wahrscheinlich erst zur Laufzeit.'

Add-Report ''
Add-Report '--- 3. Vorhandenes Metro auf Port 8081 beenden ---'
try {
    $listeners = Get-NetTCPConnection -LocalPort 8081 -State Listen -ErrorAction SilentlyContinue
    foreach ($listener in $listeners) {
        $ownerPid = $listener.OwningProcess
        if ($ownerPid -and $ownerPid -ne $PID) {
            Add-Report ("Stoppe Prozess auf 8081, PID " + $ownerPid)
            Stop-Process -Id $ownerPid -Force -ErrorAction SilentlyContinue
        }
    }
} catch {
    Add-Report ("INFO: Port-Pruefung: " + $_.Exception.Message)
}
Start-Sleep -Seconds 2

Add-Report ''
Add-Report '--- 4. Metro kontrolliert starten ---'
$metroArgs = @(
    'expo','start','--dev-client','--localhost','--clear','--non-interactive'
)
$metro = Start-Process -FilePath 'npx.cmd' -ArgumentList $metroArgs -WorkingDirectory $project -PassThru -RedirectStandardOutput $metroOut -RedirectStandardError $metroErr
Add-Report ("Metro PID: " + $metro.Id)

$ready = $false
for ($i=0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    $combined = ''
    if (Test-Path -LiteralPath $metroOut) { $combined += (Get-Content -LiteralPath $metroOut -Raw -ErrorAction SilentlyContinue) }
    if (Test-Path -LiteralPath $metroErr) { $combined += (Get-Content -LiteralPath $metroErr -Raw -ErrorAction SilentlyContinue) }
    if ($combined -match 'Metro waiting|Waiting on|localhost:8081|127\.0\.0\.1:8081') {
        $ready = $true
        break
    }
}
Add-Report ("Metro bereit erkannt: " + $ready)

Add-Report ''
Add-Report '--- 5. Samsung + USB-Metro ---'
$devices = & adb devices
$devices | Tee-Object -FilePath $report -Append
& adb reverse tcp:8081 tcp:8081 | Out-Null
Add-Report 'adb reverse tcp:8081 -> tcp:8081 gesetzt.'

$installed = & adb shell pm list packages
if (-not ($installed | Where-Object { $_ -match [regex]::Escape($devPackage) })) {
    Add-Report "FEHLER: DEV-Paket $devPackage ist nicht installiert."
    throw "DEV-App nicht installiert. Bericht: $report"
}

Add-Report ''
Add-Report '--- 6. DEV-App gezielt starten ---'
$cfgRaw = & npx expo config --json 2>&1
$cfg = $null
try { $cfg = $cfgRaw | ConvertFrom-Json } catch {}

$scheme = $null
if ($cfg -and $cfg.scheme -is [string] -and -not [string]::IsNullOrWhiteSpace($cfg.scheme)) {
    $scheme = $cfg.scheme
}
elseif ($cfg -and $cfg.scheme -is [System.Array] -and $cfg.scheme.Count -gt 0) {
    $scheme = [string]$cfg.scheme[0]
}
elseif ($cfg -and -not [string]::IsNullOrWhiteSpace($cfg.slug)) {
    $scheme = 'exp+' + $cfg.slug
}
else {
    $scheme = 'exp+3x3-home-fit'
}

$uri = $scheme + '://expo-development-client/?url=http%3A%2F%2F127.0.0.1%3A8081'
Add-Report ("Scheme: " + $scheme)
Add-Report ("URI: " + $uri)

& adb logcat -c | Out-Null
& adb shell am force-stop $devPackage | Out-Null
Start-Sleep -Milliseconds 700
$startResult = & adb shell am start -W -a android.intent.action.VIEW -d $uri -p $devPackage 2>&1
$startResult | Tee-Object -FilePath $report -Append

Add-Report ''
Add-Report 'Warte 10 Sekunden auf Bundle/Runtime...'
Start-Sleep -Seconds 10

Add-Report ''
Add-Report '--- 7. DEV-Prozessstatus ---'
$appPid = (& adb shell pidof $devPackage 2>&1 | Out-String).Trim()
if ($appPid) {
    Add-Report ("DEV-Prozess laeuft. PID: " + $appPid)
} else {
    Add-Report 'DEV-Prozess laeuft NICHT.'
}

Add-Report ''
Add-Report '--- 8. Metro-Ausgabe ---'
if (Test-Path -LiteralPath $metroOut) {
    Get-Content -LiteralPath $metroOut -Tail 220 | Tee-Object -FilePath $report -Append
}
if (Test-Path -LiteralPath $metroErr) {
    Get-Content -LiteralPath $metroErr -Tail 220 | Tee-Object -FilePath $report -Append
}

Add-Report ''
Add-Report '--- 9. Relevanter Android/React-Native Logcat ---'
$logcat = & adb logcat -d -v time
$important = $logcat | Where-Object {
    $_ -match 'FATAL EXCEPTION|AndroidRuntime|ReactNativeJS|ReactNative|Expo|homefit3x3|TypeError|ReferenceError|Invariant Violation|Unable to resolve|Cannot find|SyntaxError|Unhandled|Error:|Exception'
}
$important | Select-Object -Last 320 | Tee-Object -FilePath $report -Append

Add-Report ''
Add-Report '--- 10. Automatisch erkannte Kernfehler ---'
$all = ''
if (Test-Path -LiteralPath $metroOut) { $all += (Get-Content -LiteralPath $metroOut -Raw -ErrorAction SilentlyContinue) }
if (Test-Path -LiteralPath $metroErr) { $all += (Get-Content -LiteralPath $metroErr -Raw -ErrorAction SilentlyContinue) }
$all += ($important -join [Environment]::NewLine)

$matches = $all -split [Environment]::NewLine | Where-Object {
    $_ -match 'ERROR|Error:|TypeError|ReferenceError|SyntaxError|Unable to resolve|Cannot find|Invariant Violation|FATAL EXCEPTION|AndroidRuntime|Unhandled'
}
$matches | Select-Object -Last 120 | Tee-Object -FilePath $report -Append

Add-Report ''
Add-Report ("Vollstaendiger Bericht: " + $report)

Write-Host ''
Write-Host 'DIAGNOSE FERTIG.' -ForegroundColor Green
Write-Host "Bericht: $report" -ForegroundColor Cyan
Write-Host ''
Write-Host 'WICHTIGSTE ZEILEN:' -ForegroundColor Yellow
Get-Content -LiteralPath $report -Tail 180
