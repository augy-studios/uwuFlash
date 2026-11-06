# Builds the signed Android app into release/<version>/ at the project root:
#
#     powershell -ExecutionPolicy Bypass -File android\build-apk.ps1
#
# From 1.1.0 the app is Flutter (lib/, android/): `flutter build apk` builds it for ARM phones (32
# and 64 bit, one APK, as the app's updater fetches the one file), signed with android.keystore
# using the passwords in keystore.properties (android/app/build.gradle), and the signature is
# checked against main-site/.well-known/assetlinks.json before it's copied out as
# release/<version>/uwuflash-<version>.apk. The version is pubspec.yaml's.
#
# The signing key was made by the first build of 1.0.0 and is kept out of git: back it up. A missing
# keystore is an error, never a new key, as a different key can't update the app already on phones.
#
# Needs Flutter (on the PATH, in FLUTTER_ROOT or in ~\flutter), a JDK 21 or later and the Android
# SDK. It finds them in JAVA_HOME and ANDROID_HOME if they're set, or else the newest JDK under
# Program Files and the SDK in ~/.bubblewrap or %LOCALAPPDATA%\Android\Sdk.

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$root = Split-Path $here -Parent
$package = 'org.uwuapps.flash'
$assetLinks = "$root\main-site\.well-known\assetlinks.json"

if (-not (Test-Path "$here\keystore.properties") -or -not (Test-Path "$here\android.keystore")) {
    throw "android.keystore and keystore.properties are missing from $here. They're not in git: restore them from your backup. A new key couldn't update the app already installed on phones."
}

function Find-Jdk {
    if ($env:JAVA_HOME -and (Test-Path "$env:JAVA_HOME\bin\java.exe")) {
        $v = & "$env:JAVA_HOME\bin\java.exe" -version 2>&1 | Out-String
        if ($v -match 'version "(\d+)' -and [int]$Matches[1] -ge 21) { return $env:JAVA_HOME }
    }
    $candidates = @('C:\Program Files\Eclipse Adoptium', 'C:\Program Files\Java', 'C:\Program Files\Microsoft') |
        Where-Object { Test-Path $_ } |
        ForEach-Object { Get-ChildItem $_ -Directory -Filter 'jdk*' } |
        Where-Object { $_.Name -match 'jdk-?(\d+)' -and [int]$Matches[1] -ge 21 -and (Test-Path "$($_.FullName)\bin\java.exe") } |
        Sort-Object { [int]([regex]::Match($_.Name, 'jdk-?(\d+)').Groups[1].Value) }
    if ($candidates) { return ($candidates | Select-Object -Last 1).FullName }
    throw 'No JDK 21 or later found. Install one (https://adoptium.net) or set JAVA_HOME to it.'
}

# The SHA-256 fingerprint assetlinks.json lists for this app, as 64 lowercase hex digits. The key
# every version before was signed with, or phones can't update to this one and the site's links
# won't open in it.
function Get-LinkedFingerprint {
    $text = Get-Content $assetLinks -Raw
    if ($text -notmatch [regex]::Escape($package)) { throw "assetlinks.json doesn't list $package's key. Restore it from git." }
    $m = [regex]::Match($text, '([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){31})')
    if (-not $m.Success) { throw "assetlinks.json has no fingerprint for $package. Restore it from git." }
    return $m.Groups[1].Value.Replace(':', '').ToLowerInvariant()
}

$expected = Get-LinkedFingerprint

$env:JAVA_HOME = Find-Jdk
$env:PATH = "$env:JAVA_HOME\bin;$env:PATH"
if (-not $env:ANDROID_HOME) {
    $bw = "$env:USERPROFILE\.bubblewrap\config.json"
    if (Test-Path $bw) { $env:ANDROID_HOME = (Get-Content $bw -Raw | ConvertFrom-Json).androidSdkPath }
    elseif (Test-Path "$env:LOCALAPPDATA\Android\Sdk") { $env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk" }
    else { throw 'No Android SDK found. Install Android Studio, or set ANDROID_HOME to an SDK.' }
}
$buildTools = Get-ChildItem "$env:ANDROID_HOME\build-tools" -Directory | Sort-Object { [version]$_.Name } | Select-Object -Last 1
if (-not $buildTools) { throw "No build-tools in $env:ANDROID_HOME. Install them with Android Studio's SDK Manager." }

$flutter = if ($env:FLUTTER_ROOT) { "$env:FLUTTER_ROOT\bin\flutter.bat" }
    elseif (Get-Command flutter -ErrorAction SilentlyContinue) { 'flutter' }
    elseif (Test-Path "$env:USERPROFILE\flutter\bin\flutter.bat") { "$env:USERPROFILE\flutter\bin\flutter.bat" }
    else { throw 'Flutter not found. Put it on the PATH, or set FLUTTER_ROOT to it.' }

$pubspec = Get-Content "$here\pubspec.yaml" -Raw
$version = [regex]::Match($pubspec, '(?m)^version:\s*([0-9.]+)').Groups[1].Value
$versionCode = [regex]::Match($pubspec, '(?m)^version:\s*[0-9.]+\+(\d+)').Groups[1].Value
Write-Host "Building uwuFlash $version (versionCode $versionCode) for Android (JDK: $env:JAVA_HOME)..."
if (Test-Path "$here\android\app\google-services.json") {
    Write-Host 'Firebase: google-services.json found, notifications included.'
} else {
    Write-Host 'Firebase: no google-services.json, so this build has no notifications (android\FIREBASE-SETUP.md).' -ForegroundColor Yellow
}

$dest = "$root\release\$version\uwuflash-$version.apk"
if (Test-Path $dest) {
    Write-Host "release\$version already has an APK, which this replaces. For a new version, raise the version in android\pubspec.yaml first, or phones won't take it as an update." -ForegroundColor Yellow
}

Push-Location $here
try {
    & $flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed.' }
    & $flutter build apk --release --target-platform android-arm,android-arm64
    if ($LASTEXITCODE -ne 0) { throw 'flutter build apk failed. Its messages are above.' }
} finally {
    Pop-Location
}

$signed = "$here\build\app\outputs\flutter-apk\app-release.apk"
if (-not (Test-Path $signed)) { throw "Gradle made no signed APK: is keystore.properties's storeFile right?" }

# Its warnings (META-INF/*.version "not protected by signature") come with every Android build and
# mean nothing here; only a failure matters. Windows PowerShell turns anything a program writes to
# stderr into an error, so only its exit code is looked at.
$ErrorActionPreference = 'Continue'
$check = & "$($buildTools.FullName)\apksigner.bat" verify --print-certs $signed 2>&1 | Out-String
$verified = $LASTEXITCODE -eq 0
$ErrorActionPreference = 'Stop'
if (-not $verified) { Write-Host $check; throw 'The signed app failed its signature check.' }
$sha = [regex]::Match($check, 'SHA-256 digest: ([0-9a-f]{64})').Groups[1].Value
if ($sha -ne $expected) {
    throw "The APK is signed with a different key ($sha) from the one assetlinks.json names ($expected), so it can't update the app already installed."
}

# Each version in a folder of its own.
New-Item -ItemType Directory -Force "$root\release\$version" | Out-Null
Copy-Item $signed $dest -Force
$size = [math]::Round((Get-Item $dest).Length / 1MB, 1)
Write-Host "Done: $dest ($size MB)" -ForegroundColor Green
