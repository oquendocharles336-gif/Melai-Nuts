@echo off
REM ==========================================================================
REM  Melai Nuts - starts the ADMIN WEBSITE (Laravel) on http://127.0.0.1:8000
REM  First run also installs everything it needs. Keep this window open.
REM ==========================================================================
setlocal
cd /d "%~dp0admin"

where php >nul 2>nul || (echo [!] PHP not found. Install PHP 8.2+ ^(e.g. XAMPP^) and add it to PATH. See README "How to open the admin website". & pause & exit /b 1)
where composer >nul 2>nul || (echo [!] Composer not found. Install it from https://getcomposer.org/Composer-Setup.exe then open a NEW terminal. & pause & exit /b 1)

if not exist vendor\autoload.php (
  echo [setup] composer install ...
  call composer install --no-interaction || (pause & exit /b 1)
)
if not exist .env (
  echo [setup] creating .env ...
  copy .env.example .env >nul
  call php artisan key:generate
  if not exist database\database.sqlite type nul > database\database.sqlite
  echo.
  echo [!] Open admin\.env and fill in ADMIN_EMAIL, ADMIN_PASSWORD, FIREBASE_WEB_API_KEY and SUPABASE_DB_*
  echo     ^(the website only shows the app's real data; there is no demo mode^). Then run this file again.
  notepad .env
  pause
  exit /b 0
)
if not exist database\database.sqlite type nul > database\database.sqlite
call php artisan migrate --seed --force || (echo [!] Set ADMIN_EMAIL and ADMIN_PASSWORD in admin\.env first. & pause & exit /b 1)
if not exist public\build\manifest.json (
  where npm >nul 2>nul || (echo [!] Node.js not found. Install it from https://nodejs.org & pause & exit /b 1)
  echo [setup] building the page styles ...
  call npm install
  call npm run build
)

echo.
echo  Admin website: http://127.0.0.1:8000   ^(close this window or press Ctrl+C to stop^)
echo.
start "" http://127.0.0.1:8000
php artisan serve --host=127.0.0.1 --port=8000