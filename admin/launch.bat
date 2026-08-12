@echo off
rem FinSwipe Admin one-click launcher: reuse a running server, else start one.
rem Pinned to port 8787 — Streamlit's default 8501 belongs to other projects
rem on this machine (seen 2026-08-12: market_agent), and sharing it opened
rem the wrong app.
cd /d "%~dp0.."
netstat -an | findstr ":8787" | findstr LISTENING >nul
if %errorlevel%==0 (
  start "" "http://localhost:8787"
) else (
  start "FinSwipe Admin" /min cmd /c "python -m streamlit run admin/app.py --server.port 8787"
)
