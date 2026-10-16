<#
  Builds the launcher of the manager: <Name>.exe next to OpenThinRDP-Manager.ps1, with the OpenThinRDP icon
  (openthinrdp.ico), from Launcher.cs, with the C# compiler that comes with Windows (.NET Framework 4).
    .\build-launcher.ps1                                  OpenThinRDP-Manager.exe
    .\build-launcher.ps1 -Name Thin-clients -Folder \\fileserver\thinclients -Language en
                                                          Thin-clients.exe + Thin-clients.args (its arguments)
  The .exe only starts the script: copy it with the other files of the manager.
#>
param(
  [string]$Name = 'OpenThinRDP-Manager',
  [string]$Folder,      # written into <Name>.args: the management folder to open
  [string]$Language     # written into <Name>.args: en, it...
)
$ErrorActionPreference = 'Stop'
if ($Name -notmatch '^[A-Za-z0-9._ -]+$') { throw "Name not valid: $Name" }
$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { throw "C# compiler not found: $csc" }
$exe = Join-Path $PSScriptRoot "$Name.exe"
& $csc /nologo /target:winexe /optimize+ /platform:anycpu "/win32icon:$(Join-Path $PSScriptRoot 'openthinrdp.ico')" "/out:$exe" /reference:System.Windows.Forms.dll (Join-Path $PSScriptRoot 'Launcher.cs')
if ($LASTEXITCODE -ne 0) { throw "csc failed ($LASTEXITCODE)" }
$a = @()
if ($Folder) { $a += "-Folder `"$Folder`"" }
if ($Language) { $a += "-Language $Language" }
if ($a.Count) { [IO.File]::WriteAllText((Join-Path $PSScriptRoot "$Name.args"), ($a -join ' ') + "`r`n") }
Get-Item -LiteralPath $exe | Select-Object Name, Length
