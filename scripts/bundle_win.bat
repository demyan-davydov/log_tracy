@echo off
cd /d "%~dp0.."
set APP_NAME=dlt_explorer.exe
set DIST_DIR=dist_windows

echo Building %APP_NAME% for Windows...
dub build --build=release --config=application --arch=x86_64

if %errorlevel% neq 0 (
    echo Build failed!
    exit /b %errorlevel%
)

echo Creating distribution directory...
if exist "%DIST_DIR%" rmdir /s /q "%DIST_DIR%"
mkdir "%DIST_DIR%"

:: Copy binary
copy "%APP_NAME%" "%DIST_DIR%\"

:: Copy the Sciter library of the built architecture (x86_64)
copy "libs\windows\x64\sciter.dll" "%DIST_DIR%\"
if %errorlevel% neq 0 (
    echo Copying sciter.dll failed!
    exit /b 1
)

:: Copy resources
xcopy "resources" "%DIST_DIR%\resources\" /E /I /Y
if exist "resources\main.htm" copy "resources\main.htm" "%DIST_DIR%\"

echo.
echo Done! Windows distribution created in '%DIST_DIR%'.
pause
