@echo off
setlocal
cd /d "%~dp0"
set "AGENT_PYTHON=%USERPROFILE%\anaconda3\python.exe"
if exist "%AGENT_PYTHON%" goto ready
set "AGENT_PYTHON=python"
where python >nul 2>nul
if errorlevel 1 (
  echo Python was not found. Install Python or use your Python environment.
  pause
  exit /b 1
)
:ready
echo Preparing local analysis data...
"%AGENT_PYTHON%" -m agent.build_db
if errorlevel 1 goto failed
echo Keep this window open while using the assistant. Press Ctrl+C to stop.
"%AGENT_PYTHON%" -m agent.web --open
if errorlevel 1 goto failed
exit /b 0
:failed
echo Startup failed. Read the error above and agent\README.md.
pause
exit /b 1
