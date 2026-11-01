@echo off
setlocal
cd /d "%~dp0"

echo m4a trim tool
echo.

where python >nul 2>nul
if errorlevel 1 (
    echo ERROR: Python not found. Please install Python and add it to PATH.
    pause
    exit /b 1
)

if not exist "%~dp0trim_m4a_start.py" (
    echo ERROR: trim_m4a_start.py not found in this folder.
    pause
    exit /b 1
)

set /p SECONDS=Seconds to trim from start (e.g. 5): 

if "%SECONDS%"=="" (
    echo No input. Aborting.
    pause
    exit /b 1
)

echo.
python "%~dp0trim_m4a_start.py" %SECONDS%

echo.
echo Done.
pause
