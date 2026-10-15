$ErrorActionPreference = 'Stop'

$project = 'C:\Users\patri\Desktop\DCPP DIGITAL\3x3Homefit'
$devPackage = 'de.homefit3x3.app.dev'

if (!(Test-Path -LiteralPath $project)) {
    throw "Projektordner nicht gefunden: $project"
}

Set-Location -LiteralPath $project

$devices = & adb devices
if (-not ($devices | Where-Object { $_ -match '\tdevice$' })) {
    throw 'Kein freigegebenes Samsung per ADB gefunden.'
}

$installed = & adb shell pm list packages
if (-not ($installed | Where-Object { $_ -match [regex]::Escape($devPackage) })) {
    throw "DEV-App $devPackage ist nicht installiert."
}

& adb reverse tcp:8081 tcp:8081 | Out-Null

$cfgRaw = & npx expo config --json
if ($LASTEXITCODE -ne 0) {
    throw 'Expo-Konfiguration konnte nicht gelesen werden.'
}
$cfg = $cfgRaw | ConvertFrom-Json

$scheme = $null
if ($cfg.scheme -is [string] -and -not [string]::IsNullOrWhiteSpace($cfg.scheme)) {
    $scheme = $cfg.scheme
}
elseif ($cfg.scheme -is [System.Array] -and $cfg.scheme.Count -gt 0) {
    $scheme = [string]$cfg.scheme[0]
}
elseif (-not [string]::IsNullOrWhiteSpace($cfg.slug)) {
    $scheme = 'exp+' + $cfg.slug
}
else {
    $scheme = 'exp+3x3-home-fit'
}

$uri = $scheme + '://expo-development-client/?url=http%3A%2F%2F127.0.0.1%3A8081'

Write-Host ''
Write-Host '3x3 HOME FIT - VERBINDE DEV-APP MIT METRO' -ForegroundColor Cyan
Write-Host "Scheme: $scheme" -ForegroundColor DarkGray
Write-Host 'USB-Port 8081 ist verbunden.' -ForegroundColor Green
Write-Host "Ich erzwinge DEV-Paket: $devPackage (kein App-Auswahldialog)." -ForegroundColor Green

& adb shell am force-stop $devPackage | Out-Null
Start-Sleep -Milliseconds 500

$result = & adb shell am start -W -a android.intent.action.VIEW -d $uri -p $devPackage 2>&1
$result

Start-Sleep -Seconds 3

$appPid = (& adb shell pidof $devPackage 2>&1 | Out-String).Trim()
if ($appPid) {
    Write-Host ''
    Write-Host "OK: DEV-App laeuft. PID $appPid" -ForegroundColor Green
    $active = (& adb shell dumpsys activity activities 2>&1 | Select-String -Pattern 'mResumedActivity|topResumedActivity|de\.homefit3x3\.app' | Select-Object -Last 10 | ForEach-Object { $_.Line })
    if ($active) {
        Write-Host 'Aktive 3x3-Activity:' -ForegroundColor Cyan
        $active
    }
    Write-Host 'Wenn auf dem Samsung noch der Development-Build-Bildschirm steht, einmal Reload antippen.' -ForegroundColor Yellow
} else {
    Write-Host ''
    Write-Host 'DEV-App-Prozess laeuft nicht. Relevante Logcat-Zeilen:' -ForegroundColor Red
    & adb logcat -d -v time |
        Select-String -Pattern 'FATAL EXCEPTION|AndroidRuntime|ReactNativeJS|Expo|homefit3x3' |
        Select-Object -Last 120
}
