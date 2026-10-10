@echo off
rem OpenThinRDP Manager: opens the management tool (nothing to install). Optional: -Folder \\fileserver\thinclients
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0OpenThinRDP-Manager.ps1" %*
