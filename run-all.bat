@echo off
REM ==========================================================================
REM  Melai Nuts - starts the ADMIN WEBSITE (in its own window) and the APP together.
REM  Usage:  run-all.bat              (asks Flutter which device to use)
REM          run-all.bat emulator-5554 (a specific device id from "flutter devices")
REM ==========================================================================
setlocal
cd /d "%~dp0"

start "Melai Admin website" cmd /k call "%~dp0start-admin.bat"

if not exist env\firebase.json (echo [!] env\firebase.json is missing - copy env\firebase.example.json and fill it in. & pause & exit /b 1)
if not exist env\supabase.json (echo [!] env\supabase.json is missing - copy env\supabase.example.json and fill it in. & pause & exit /b 1)

if "%~1"=="" (
  flutter run --dart-define-from-file=env/firebase.json --dart-define-from-file=env/supabase.json
) else (
  flutter run -d %1 --dart-define-from-file=env/firebase.json --dart-define-from-file=env/supabase.json
)