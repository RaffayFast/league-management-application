# Builds the release APK and copies it to mobile/release/app-release.apk.
# Usage (from mobile/):  powershell -ExecutionPolicy Bypass -File .\build_apk.ps1
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

flutter pub get
dart format lib test
flutter analyze
flutter test
flutter build apk --release

$out = "build\app\outputs\flutter-apk\app-release.apk"
if (-not (Test-Path $out)) { throw "APK not produced at $out" }
New-Item -ItemType Directory -Force release | Out-Null
Copy-Item $out release\app-release.apk -Force
$size = (Get-Item release\app-release.apk).Length
Write-Host "APK ready: mobile\release\app-release.apk ($size bytes)"
