@echo off
rem OpenThinRDP Manager: opens the management tool (nothing to install). Optional: -Folder \\fileserver\thinclients
rem and -Language en or it (default: the Windows display language); -Sign <folder>\LATEST.txt signs an update package
rem with the key of the vault (asks only the access code). Every argument is passed on as it is.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0OpenThinRDP-Manager.ps1" %*
