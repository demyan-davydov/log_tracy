@echo off
:: Builds the project on Windows and runs its unittests.
:: From macOS or Linux, check-windows-compile.sh checks that it compiles.

cd /d "%~dp0.."

echo Building...
dub build --compiler=ldc2 --arch=x86_64
if %errorlevel% neq 0 (
    echo Build failed!
    exit /b %errorlevel%
)

echo Running unittests...
dub test --compiler=ldc2 --arch=x86_64
if %errorlevel% neq 0 (
    echo Tests failed!
    exit /b %errorlevel%
)

echo All OK
