@echo off
setlocal EnableDelayedExpansion

for %%I in ("%~dp0..") do set REPO=%%~fI
set FLUTTER=C:\flutter\bin\flutter.bat
set ADB=adb

set HOST_PORT=4000
set DEVICE_PORT=14000

if not exist "%FLUTTER%" (
  echo Flutter not found at %FLUTTER%
  exit /b 1
)

echo Connected devices:
%ADB% devices

rem Pick a physical device (skip emulators).
set DEVICE_ID=
for /f "skip=1 tokens=1,2" %%a in ('%ADB% devices') do (
  if "%%b"=="device" (
    echo %%a | findstr /b /c:"emulator-" >nul
    if errorlevel 1 (
      set DEVICE_ID=%%a
      goto devfound
    )
  )
)
:devfound

if "%DEVICE_ID%"=="" (
  echo No physical Android device detected. If you want emulator, run scripts\run-emulator.cmd
  exit /b 1
)

echo Using device: %DEVICE_ID%

rem Prefer the Wi-Fi adapter IP (avoid WSL/Hyper-V vEthernet like 172.19.x.x).
set LAN_IP=
for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "(Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias 'Wi-Fi' -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -and $_.IPAddress -notlike '169.254*' -and $_.IPAddress -notlike '127.*' } | Select-Object -First 1 -ExpandProperty IPAddress)"`) do set LAN_IP=%%i

echo HOST_LAN_IP=%LAN_IP%

set API_BASE=
set EXTRA_DEFINES=

rem Prefer adb reverse for physical device to avoid LAN/firewall instability.
set API_BASE=http://127.0.0.1:%DEVICE_PORT%
echo Setting adb reverse: device tcp:%DEVICE_PORT% -^> host tcp:%HOST_PORT%
%ADB% -s %DEVICE_ID% reverse --remove-all >nul 2>&1
%ADB% -s %DEVICE_ID% reverse tcp:%DEVICE_PORT% tcp:%HOST_PORT% >nul 2>&1
if errorlevel 1 (
  echo adb reverse failed. Falling back to LAN IP.
  if not "%LAN_IP%"=="" (
    set API_BASE=http://%LAN_IP%:%HOST_PORT%
    set EXTRA_DEFINES=--dart-define=HOST_LAN_IP=%LAN_IP%
  )
)
%ADB% -s %DEVICE_ID% reverse --list

echo API_BASE_URL=%API_BASE%

cd /d %REPO%\app\frontend\flutter_app

echo Running Flutter app on %DEVICE_ID%...
"%FLUTTER%" run -d %DEVICE_ID% --dart-define=API_BASE_URL=%API_BASE% %EXTRA_DEFINES%

endlocal
