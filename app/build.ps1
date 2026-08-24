# FinSwipe release build — the ONLY way to build an APK for install.
# A bare `flutter build apk --release` produces a broken app: SUPABASE_URL /
# SUPABASE_PUBLISHABLE_KEY are compile-time String.fromEnvironment values, so
# without these defines the client points at "" — session refresh dies (users
# get signed out) and Google sign-in throws (v0.20.1 first build, 24 Aug 2026).
# The publishable key is client-side-public; it ships inside every APK.
$ErrorActionPreference = "Stop"
$version = (Select-String -Path "$PSScriptRoot\pubspec.yaml" -Pattern '^version:\s*([\d.]+)').Matches[0].Groups[1].Value
Write-Host "Building FinSwipe v$version..."
flutter build apk --release `
  --dart-define=SUPABASE_URL=https://hdgfdswzymfqgjqzqqve.supabase.co `
  --dart-define=SUPABASE_PUBLISHABLE_KEY=sb_publishable_RJZjS6Wf3H_VhDYoQm0_6w_id7eWb_G `
  --dart-define=APP_VERSION=$version
if ($LASTEXITCODE -ne 0) { throw "flutter build failed" }
$out = "$env:USERPROFILE\Desktop\finswipe-v$version.apk"
Copy-Item "$PSScriptRoot\build\app\outputs\flutter-apk\app-release.apk" $out -Force
Write-Host "-> $out"
