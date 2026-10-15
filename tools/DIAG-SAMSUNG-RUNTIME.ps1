$ErrorActionPreference = 'Stop'

$devPackage = 'de.homefit3x3.app.dev'
$project = 'C:\Users\patri\Desktop\DCPP DIGITAL\3x3Homefit'
$report = Join-Path $env:USERPROFILE 'Desktop\3x3-runtime-diagnose.txt'

function Add-Report([string]$Text) {
    $Text | Tee-Object -FilePath $report -Append
}

if (Test-Path -LiteralPath $report) {
    Remove-Item -LiteralPath $report -Force
}

Add-Report '=== 3x3 HOME FIT RUNTIME-DIAGNOSE ==='
Add-Report ("Zeit: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Add-Report ''

Add-Report '--- ADB-Geraete ---'
$devices = & adb devices
$devices | Tee-Object -FilePath $report -Append
if (-not ($devices | Where-Object { $_ -match '\tdevice$' })) {
    throw 'Kein freigegebenes Android-Geraet gefunden.'
}

Add-Report ''
Add-Report '--- Installierte 3x3-Pakete ---'
$packages = & adb shell pm list packages
$homefitPackages = @($packages | Where-Object { $_ -match 'homefit3x3' })
$homefitPackages | Tee-Object -FilePath $report -Append

if (-not ($homefitPackages -match [regex]::Escape($devPackage))) {
    Add-Report "FEHLER: DEV-Paket $devPackage ist nicht installiert."
    throw "DEV-App ist nicht installiert. Diagnose: $report"
}

Add-Report ''
Add-Report '--- APK-Pfad DEV ---'
(& adb shell pm path $devPackage) | Tee-Object -FilePath $report -Append

Add-Report ''
Add-Report '--- Launcher aufloesen ---'
$resolveArgs = @(
    'shell','cmd','package','resolve-activity','--brief',
    '-a','android.intent.action.MAIN',
    '-c','android.intent.category.LAUNCHER',
    $devPackage
)
$resolved = (& adb @resolveArgs 2>&1 | Out-String).Trim()
Add-Report $resolved

$component = ($resolved -split [Environment]::NewLine | Where-Object { $_ -match '/' } | Select-Object -Last 1).Trim()

Add-Report ''
Add-Report '--- Metro-Port via USB ---'
(& adb reverse --list) | Tee-Object -FilePath $report -Append
& adb reverse tcp:8081 tcp:8081 | Out-Null
Add-Report 'adb reverse tcp:8081 -> tcp:8081 gesetzt.'

Add-Report ''
Add-Report '--- App-Start + Logcat ---'
& adb logcat -c | Out-Null
& adb shell am force-stop $devPackage | Out-Null
Start-Sleep -Milliseconds 500

if ($component) {
    Add-Report "Starte exakte Launcher-Komponente: $component"
    (& adb shell am start -W -n $component 2>&1) | Tee-Object -FilePath $report -Append
}
else {
    Add-Report 'Launcher-Komponente nicht automatisch aufgeloest. Fallback via monkey.'
    (& adb shell monkey -p $devPackage -c android.intent.category.LAUNCHER 1 2>&1) | Tee-Object -FilePath $report -Append
}

Start-Sleep -Seconds 5

Add-Report ''
Add-Report '--- Prozessstatus ---'
$pid = (& adb shell pidof $devPackage 2>&1 | Out-String).Trim()
if ($pid) {
    Add-Report "DEV-Prozess laeuft. PID: $pid"
} else {
    Add-Report 'DEV-Prozess laeuft NICHT mehr -> sehr wahrscheinlich Runtime-Crash oder Startproblem.'
}

Add-Report ''
Add-Report '--- Aktuelle Activity ---'
(& adb shell dumpsys activity activities 2>&1 |
    Select-String -Pattern 'mResumedActivity|topResumedActivity|homefit3x3' |
    Select-Object -Last 30 |
    ForEach-Object { $_.Line }) | Tee-Object -FilePath $report -Append

Add-Report ''
Add-Report '--- Relevante Logcat-Zeilen ---'
$log = & adb logcat -d -v time
$relevant = $log | Where-Object {
    $_ -match 'FATAL EXCEPTION|AndroidRuntime|ReactNativeJS|ReactNative|Expo|homefit3x3|Unable to start activity|Unable to instantiate|Process: de\.homefit3x3\.app\.dev|ClassNotFoundException|SecurityException|UnsatisfiedLinkError|NoSuchMethodError|IllegalStateException'
}
$relevant | Select-Object -Last 220 | Tee-Object -FilePath $report -Append

Add-Report ''
Add-Report '--- Diagnose-Ende ---'
Add-Report "Vollstaendiger Bericht: $report"

Write-Host ''
Write-Host 'DIAGNOSE FERTIG.' -ForegroundColor Green
Write-Host "Bericht: $report" -ForegroundColor Cyan
Write-Host ''
Write-Host 'Die wichtigsten letzten Zeilen:' -ForegroundColor Yellow
Get-Content -LiteralPath $report -Tail 120
