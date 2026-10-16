<#
  Builds the launcher of the manager: <Name>.exe with the OpenThinRDP icon (openthinrdp.ico), from Launcher.cs, with
  the C# compiler that comes with Windows (.NET Framework 4).
    .\build-launcher.ps1                                  OpenThinRDP-Manager.exe next to the script
    .\build-launcher.ps1 -Name Thin-clients -Folder \\fileserver\thinclients -Language en
                                                          Thin-clients.exe + Thin-clients.args (its arguments)
    .\build-launcher.ps1 -Name Thin-clients -Folder \\fileserver\thinclients -Install
                                                          the same on THIS PC, in %ProgramData%\OpenThinRDP, finding
                                                          the manager where this script is (<Name>.script), and a
                                                          shortcut on the desktop
  Windows shows the icon of a shortcut only for a program on a local disk: with the manager on a file share, -Install
  on every PC that starts it (the manager itself stays on the share, one copy for all).
#>
param(
  [string]$Name = 'OpenThinRDP-Manager',
  [string]$Folder,      # written into <Name>.args: the management folder to open
  [string]$Language,    # written into <Name>.args: en, it...
  [switch]$Install      # build into %ProgramData%\OpenThinRDP and put a shortcut on the desktop
)
$ErrorActionPreference = 'Stop'
if ($Name -notmatch '^[A-Za-z0-9._ -]+$') { throw "Name not valid: $Name" }
$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { throw "C# compiler not found: $csc" }
$dest = if ($Install) { Join-Path $env:ProgramData 'OpenThinRDP' } else { $PSScriptRoot }
if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest | Out-Null }
$exe = Join-Path $dest "$Name.exe"
& $csc /nologo /target:winexe /optimize+ /platform:anycpu "/win32icon:$(Join-Path $PSScriptRoot 'openthinrdp.ico')" "/out:$exe" /reference:System.Windows.Forms.dll (Join-Path $PSScriptRoot 'Launcher.cs')
if ($LASTEXITCODE -ne 0) { throw "csc failed ($LASTEXITCODE)" }
$a = @()
if ($Folder) { $a += "-Folder `"$Folder`"" }
if ($Language) { $a += "-Language $Language" }
if ($a.Count) { [IO.File]::WriteAllText((Join-Path $dest "$Name.args"), ($a -join ' ') + "`r`n") }
if ($Install) {
  [IO.File]::WriteAllText((Join-Path $dest "$Name.script"), (Join-Path $PSScriptRoot 'OpenThinRDP-Manager.ps1') + "`r`n")
  $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) "$Name.lnk"
  $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
  $sc.TargetPath = $exe; $sc.WorkingDirectory = $dest; $sc.Description = 'OpenThinRDP Manager'; $sc.Save()
  Write-Output "shortcut: $lnk"
}
Get-Item -LiteralPath $exe | Select-Object FullName, Length
