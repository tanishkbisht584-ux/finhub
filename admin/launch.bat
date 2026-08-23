@echo off
rem FinSwipe Admin one-click launcher: (re)start the server on port 8787 and open it.
rem Restarts rather than reuses so a double-click always serves the current code
rem (views/ + navigation structure changed 2026-08-23; a stale process 404s).
rem Pinned to port 8787 - Streamlit's default 8501 belongs to other projects
rem on this machine (market_agent).
rem Pinned interpreter: a bare Python appeared at C:\Python314 and took over
rem PATH (2026-08-14) with no streamlit installed - "python" is not safe here.
set PYEXE=C:\Users\Tanis\AppData\Local\Python\pythoncore-3.14-64\python.exe
cd /d "%~dp0.."
for /f "tokens=5" %%p in ('netstat -ano ^| findstr ":8787" ^| findstr LISTENING') do taskkill /PID %%p /F >nul 2>&1
start "FinSwipe Admin" /min cmd /c ""%PYEXE%" -m streamlit run admin/app.py --server.port 8787"
timeout /t 3 >nul
start "" "http://localhost:8787"
