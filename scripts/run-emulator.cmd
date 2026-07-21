@echo off
setlocal EnableDelayedExpansion
for %%I in ("%~dp0..") do set REPO=%%~fI
set FLUTTER=C:\src\flutter\bin\flutter.bat
set ADB=adb
set API_BASE=http://10.0.2.2:4000

cd /d %REPO%\app\frontend\flutter_app

if not exist "%FLUTTER%" (
  echo Flutter not found at %FLUTTER%
  exit /b 1
)

set DEVICE_ID=
for /f "tokens=1,2" %%a in ('%ADB% devices ^| findstr /R "^emulator-"') do (
  if "%%b"=="device" (
    set DEVICE_ID=%%a
    goto devfound
  )
)
:devfound

if "%DEVICE_ID%"=="" (
  echo No emulator detected. Start an emulator from Android Studio Device Manager first.
  %ADB% devices
  exit /b 1
)

echo Using emulator: %DEVICE_ID%
echo Setting up adb reverse: emulator tcp:4000 -^> host tcp:4000
%ADB% -s %DEVICE_ID% reverse tcp:4000 tcp:4000 >nul 2>&1

echo Running Flutter app on emulator...
"%FLUTTER%" run -d %DEVICE_ID% --dart-define=API_BASE_URL=%API_BASE%

endlocal
