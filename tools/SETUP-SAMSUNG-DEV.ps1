$ErrorActionPreference = 'Stop'

$project = 'C:\Users\patri\Desktop\DCPP DIGITAL\3x3Homefit'
$prodPackage = 'de.homefit3x3.app'
$devPackage = 'de.homefit3x3.app.dev'
$gradlePath = Join-Path $project 'android\app\build.gradle'
$androidDir = Join-Path $project 'android'
$apk = Join-Path $project 'android\app\build\outputs\apk\debug\app-debug.apk'
$buildLog = Join-Path $env:USERPROFILE 'Desktop\3x3-dev-build.log'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

function Ensure-DebugGoogleServices {
    $debugDir = Join-Path $project 'android\app\src\debug'
    $debugFile = Join-Path $debugDir 'google-services.json'
    New-Item -ItemType Directory -Path $debugDir -Force | Out-Null

    $candidates = @(
        (Join-Path $project 'android\app\google-services.json'),
        (Join-Path $project 'google-services.json')
    )

    $base = $null
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            $raw = Get-Content -LiteralPath $candidate -Raw
            if ($raw.Contains($prodPackage)) {
                $base = $candidate
                break
            }
        }
    }

    if (-not $base) {
        $found = Get-ChildItem -LiteralPath $project -Filter 'google-services.json' -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -notmatch '\\node_modules\\|\\build\\|\\_BACKUP-' -and
                $_.FullName -ne $debugFile
            } |
            Select-Object -First 1
        if ($found) { $base = $found.FullName }
    }

    if (-not $base) {
        Write-Host 'INFO: Keine google-services.json gefunden. Dieser Schritt wird uebersprungen.' -ForegroundColor Yellow
        return
    }

    $raw = Get-Content -LiteralPath $base -Raw
    if (-not $raw.Contains($prodPackage)) {
        Write-Host "INFO: Firebase-Datei gefunden, aber Produktions-Paketname fehlt: $base" -ForegroundColor Yellow
        return
    }

    $devRaw = $raw.Replace($prodPackage, $devPackage)
    Write-Utf8NoBom $debugFile $devRaw

    try {
        $null = Get-Content -LiteralPath $debugFile -Raw | ConvertFrom-Json
    }
    catch {
        throw "Debug google-services.json ist ungueltig: $($_.Exception.Message)"
    }

    Write-Host "OK: Debug-Firebase-Konfiguration ohne BOM erzeugt: $debugFile" -ForegroundColor Green
}

function Run-GradleBuild {
    if (Test-Path -LiteralPath $buildLog) {
        Remove-Item -LiteralPath $buildLog -Force -ErrorAction SilentlyContinue
    }

    Push-Location $androidDir
    try {
        & .\gradlew.bat app:assembleDebug -x lint -x test --configure-on-demand --build-cache -PreactNativeDevServerPort=8081 -PreactNativeArchitectures=arm64-v8a --console=plain 2>&1 | Tee-Object -FilePath $buildLog
        return $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
}

Write-Host ''
Write-Host '3x3 HOME FIT - SAMSUNG DEV SETUP V2' -ForegroundColor Cyan
Write-Host 'Production-App bleibt unangetastet. DEV-App wird parallel installiert.' -ForegroundColor DarkGray
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

$oldDebugGs = Join-Path $project 'android\app\src\debug\google-services.json'
if (Test-Path -LiteralPath $oldDebugGs) {
    Copy-Item -LiteralPath $oldDebugGs -Destination (Join-Path $backupDir 'google-services-debug.json') -Force
}
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
    Write-Host "OK: Debug-Paket auf $devPackage getrennt." -ForegroundColor Green
}
else {
    Write-Host 'OK: Debug-Paket ist bereits auf .dev getrennt.' -ForegroundColor Green
}

Write-Utf8NoBom $gradlePath $text
Ensure-DebugGoogleServices

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
$code = Run-GradleBuild

if ($code -ne 0) {
    Write-Host ''
    Write-Host 'Erster Build fehlgeschlagen. Reparaturversuch fuer Debug-Firebase-Konfiguration...' -ForegroundColor Yellow
    Ensure-DebugGoogleServices
    $code = Run-GradleBuild
}

if ($code -ne 0) {
    Write-Host ''
    Write-Host 'BUILD FEHLGESCHLAGEN - die echte Ursache folgt jetzt automatisch:' -ForegroundColor Red

    if (Test-Path -LiteralPath $buildLog) {
        $patterns = 'FAILURE:|What went wrong:|Execution failed for task|Caused by:|No matching client|google-services|error:|Exception|FAILED'
        Select-String -Path $buildLog -Pattern $patterns -Context 3,8 |
            Select-Object -Last 100 |
            ForEach-Object { $_.ToString() }

        Write-Host ''
        Write-Host '----- LETZTE 180 LOG-ZEILEN -----' -ForegroundColor Yellow
        Get-Content -LiteralPath $buildLog -Tail 180

        Write-Host ''
        Write-Host "Vollstaendiger Build-Log liegt hier: $buildLog" -ForegroundColor Cyan
    }

    throw 'Gradle-Build fehlgeschlagen. Oben steht jetzt die konkrete Ursache.'
}

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
