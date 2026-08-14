@echo off
rem FinSwipe Admin one-click launcher: reuse a running server, else start one.
rem Pinned to port 8787 - Streamlit's default 8501 belongs to other projects
rem on this machine (market_agent).
rem Pinned interpreter: a bare Python appeared at C:\Python314 and took over
rem PATH (2026-08-14) with no streamlit installed - "python" is not safe here.
set PYEXE=C:\Users\Tanis\AppData\Local\Python\pythoncore-3.14-64\python.exe
cd /d "%~dp0.."
netstat -an | findstr ":8787" | findstr LISTENING >nul
if %errorlevel%==0 (
  start "" "http://localhost:8787"
) else (
  start "FinSwipe Admin" /min cmd /c ""%PYEXE%" -m streamlit run admin/app.py --server.port 8787"
)
