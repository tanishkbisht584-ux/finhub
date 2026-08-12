@echo off
rem FinSwipe Admin one-click launcher: reuse a running server, else start one.
cd /d "%~dp0.."
netstat -an | findstr ":8501" | findstr LISTENING >nul
if %errorlevel%==0 (
  start "" "http://localhost:8501"
) else (
  start "FinSwipe Admin" /min cmd /c "python -m streamlit run admin/app.py"
)
