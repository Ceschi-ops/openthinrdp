@echo off
rem OpenThinRDP Manager: opens the management tool (nothing to install). Optional: -Folder \\fileserver\thinclients
rem and -Language en or it (default: the Windows display language); -Sign <folder>\LATEST.txt signs an update package
rem with the key of the vault (asks only the access code). Every argument is passed on as it is.
rem -UpdateManager runs here, in this console: its result on the screen and its exit code (0 updated, 1 error, 2 nothing
rem to do). One line, read whole before it runs: the update may replace this very file.
echo(%*| findstr /i /c:"-UpdateManager" >nul && (powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0OpenThinRDP-Manager.ps1" %* & call exit /b %%errorlevel%%)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0OpenThinRDP-Manager.ps1" %*
