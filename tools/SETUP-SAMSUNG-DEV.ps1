$ErrorActionPreference = 'Stop'

$project = 'C:\Users\patri\Desktop\DCPP DIGITAL\3x3Homefit'
$prodPackage = 'de.homefit3x3.app'
$devPackage = 'de.homefit3x3.app.dev'
$gradlePath = Join-Path $project 'android\app\build.gradle'

Write-Host ''
Write-Host '3x3 HOME FIT - SAMSUNG DEV SETUP' -ForegroundColor Cyan
Write-Host 'Die bestehende App bleibt unangetastet. Debug wird parallel als .dev installiert.' -ForegroundColor DarkGray
Write-Host ''

if (!(Test-Path -LiteralPath $project)) {
    throw "Projektordner nicht gefunden: $project"
}
if (!(Test-Path -LiteralPath $gradlePath)) {
    throw 'android\app\build.gradle wurde nicht gefunden.'
}

Set-Location -LiteralPath $project

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path $project "_BACKUP-DEV-SAMSUNG-$stamp"
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
Copy-Item -LiteralPath $gradlePath -Destination (Join-Path $backupDir 'build.gradle') -Force
Write-Host "OK: Backup erstellt: $backupDir" -ForegroundColor Green

$text = Get-Content -LiteralPath $gradlePath -Raw
if ($text -notmatch 'applicationIdSuffix\s+["'']\.dev["'']') {
    $buildTypes = [regex]::Match($text, '(?m)^\s*buildTypes\s*\{')
    if (!$buildTypes.Success) {
        throw 'buildTypes-Block wurde nicht gefunden.'
    }

    $afterBuildTypesIndex = $buildTypes.Index + $buildTypes.Length
    $tail = $text.Substring($afterBuildTypesIndex)
    $debugBlock = [regex]::Match($tail, '(?m)^(?<indent>\s*)debug\s*\{')
    if (!$debugBlock.Success) {
        throw 'debug-Block innerhalb buildTypes wurde nicht gefunden.'
    }

    $insertAt = $afterBuildTypesIndex + $debugBlock.Index + $debugBlock.Length
    $indent = $debugBlock.Groups['indent'].Value + '    '
    $nl = [Environment]::NewLine
    $insert = $nl + $indent + 'applicationIdSuffix ".dev"' + $nl + $indent + 'versionNameSuffix "-dev"'
    $text = $text.Insert($insertAt, $insert)
    Set-Content -LiteralPath $gradlePath -Value $text -Encoding UTF8
    Write-Host "OK: Debug-Paket auf $devPackage getrennt." -ForegroundColor Green
}
else {
    Write-Host 'OK: Debug-Paket ist bereits auf .dev getrennt.' -ForegroundColor Green
}

$googleServices = Join-Path $project 'android\app\google-services.json'
$debugGoogleServicesDir = Join-Path $project 'android\app\src\debug'
$debugGoogleServices = Join-Path $debugGoogleServicesDir 'google-services.json'

if (Test-Path -LiteralPath $googleServices) {
    New-Item -ItemType Directory -Path $debugGoogleServicesDir -Force | Out-Null

    if (Test-Path -LiteralPath $debugGoogleServices) {
        Copy-Item -LiteralPath $debugGoogleServices -Destination (Join-Path $backupDir 'google-services-debug.json') -Force
    }

    $gsText = Get-Content -LiteralPath $googleServices -Raw
    if ($gsText.Contains($prodPackage)) {
        $gsText = $gsText.Replace($prodPackage, $devPackage)
        Set-Content -LiteralPath $debugGoogleServices -Value $gsText -Encoding UTF8
        Write-Host 'OK: Debug google-services.json fuer .dev erzeugt.' -ForegroundColor Green
    }
    else {
        Write-Host 'INFO: google-services.json enthaelt den Produktions-Paketnamen nicht. Keine Aenderung noetig.' -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host 'Pruefe Expo...' -ForegroundColor Cyan
& npx expo-doctor
if ($LASTEXITCODE -ne 0) {
    throw 'expo-doctor meldet Fehler. Build wurde gestoppt.'
}

Write-Host ''
Write-Host 'Pruefe Samsung ueber ADB...' -ForegroundColor Cyan
$adbLines = & adb devices
$deviceLines = @($adbLines | Where-Object { $_ -match '\tdevice$' })
if ($deviceLines.Count -lt 1) {
    throw 'Kein freigegebenes Android-Geraet gefunden. Samsung per USB anschliessen und USB-Debugging erlauben.'
}
Write-Host 'OK: Samsung erkannt.' -ForegroundColor Green

Write-Host ''
Write-Host 'Baue 3x3 HOME FIT DEV...' -ForegroundColor Cyan
Push-Location (Join-Path $project 'android')
try {
    & .\gradlew.bat app:assembleDebug -x lint -x test --configure-on-demand --build-cache -PreactNativeDevServerPort=8081 -PreactNativeArchitectures=arm64-v8a
    if ($LASTEXITCODE -ne 0) {
        throw 'Gradle-Build fehlgeschlagen.'
    }
}
finally {
    Pop-Location
}

$apk = Join-Path $project 'android\app\build\outputs\apk\debug\app-debug.apk'
if (!(Test-Path -LiteralPath $apk)) {
    throw "Debug-APK nicht gefunden: $apk"
}
Write-Host 'OK: Debug-APK gebaut.' -ForegroundColor Green

Write-Host ''
Write-Host 'Installiere DEV-App parallel zur bestehenden App...' -ForegroundColor Cyan
& adb install -r $apk
if ($LASTEXITCODE -ne 0) {
    throw 'ADB-Installation fehlgeschlagen.'
}

& adb reverse tcp:8081 tcp:8081
if ($LASTEXITCODE -ne 0) {
    throw 'adb reverse fuer Port 8081 fehlgeschlagen.'
}
Write-Host 'OK: USB-Verbindung zu Metro steht.' -ForegroundColor Green

Write-Host ''
Write-Host 'Starte Metro in einem zweiten PowerShell-Fenster...' -ForegroundColor Cyan
$metroCommand = "Set-Location -LiteralPath '$project'; npx expo start --dev-client --localhost"
Start-Process powershell.exe -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-Command',$metroCommand
Start-Sleep -Seconds 8

$slug = '3x3-home-fit'
try {
    $cfgRaw = & npx expo config --json
    $cfg = $cfgRaw | ConvertFrom-Json
    if (![string]::IsNullOrWhiteSpace($cfg.slug)) {
        $slug = $cfg.slug
    }
}
catch {
    Write-Host 'INFO: Expo-Slug konnte nicht automatisch gelesen werden. Fallback wird verwendet.' -ForegroundColor Yellow
}

$uri = 'exp+' + $slug + '://expo-development-client/?url=http%3A%2F%2F127.0.0.1%3A8081'
& adb shell am start -a android.intent.action.VIEW -d $uri | Out-Null

if ($LASTEXITCODE -ne 0) {
    & adb shell monkey -p $devPackage -c android.intent.category.LAUNCHER 1 | Out-Null
}

Write-Host ''
Write-Host 'FERTIG.' -ForegroundColor Green
Write-Host "Bestehende App: $prodPackage - NICHT geloescht." -ForegroundColor Green
Write-Host "DEV-App:        $devPackage - parallel installiert." -ForegroundColor Green
Write-Host ''
Write-Host 'JETZT AUF DEM SAMSUNG TESTEN:' -ForegroundColor Yellow
Write-Host '1. Training starten'
Write-Host '2. Startposition + Bewegung pruefen'
Write-Host '3. Timer bis 00:00 laufen lassen'
Write-Host '4. Signalton + kurze Vibration pruefen'
