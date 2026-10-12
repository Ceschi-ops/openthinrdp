' OpenThinRDP Manager without any console window behind it (double-click). The .cmd does the same and accepts
' -Folder and -Language; here they can be added at the end of the command line below.
Set sh = CreateObject("WScript.Shell")
d = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & d & "\OpenThinRDP-Manager.ps1""", 0, False