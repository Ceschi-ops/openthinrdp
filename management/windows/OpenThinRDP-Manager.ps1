<#
  OpenThinRDP Manager - central management of OpenThinRDP thin clients (Windows PowerShell 5.1, WinForms).
  Reads the management folder where the devices report every 5 minutes and at every event:
    status\<hostname>.txt, status\<hostname>-events.log
  and writes the central configuration the devices read back every 5 minutes and at boot:
    config\common.conf        = EVERY device (an active key wins over the settings dialog of the device)
    config\<hostname>.conf    = exceptions for one device (wins over common.conf; also hostname, user, address)
    config\authorized_keys    = SSH public keys of the administrators (used by devices with SSH=on)
  The devices check everything again with save-config.sh and reject the WHOLE configuration if a single value
  is wrong: here the same rules run BEFORE writing. Every overwritten file is copied to config\backup\ first,
  every change goes to config\changes.log.
  Start:  OpenThinRDP-Manager.cmd [-Folder \\fileserver\thinclients]   (no -Folder = choose it, the last one is remembered)
                                  [-Language en|it]                    (no -Language = the Windows display language
                                                                        when lang\ has a file for it, else English)
  Texts:  every text of the window is in lang\en.psd1, translated in lang\<language>.psd1 (UTF-8 with BOM);
          a key missing from a translation shows the English text. Setting keys, values, the files written
          and config\changes.log stay in English: the devices and other tools read them.
  Sign:   OpenThinRDP-Manager.cmd -Sign <folder>\LATEST.txt   (an update package made by make-update.sh without -k:
                                  asks the access code of the vault, writes LATEST.txt.sig next to it)
  Vault:  vault.otr next to this file: the SSH key of the remote screen and the key that signs the updates,
          encrypted with the access code asked at the first start (OtrVault.cs)
  Tests:  . .\OpenThinRDP-Manager.ps1 -Folder <path> -FunctionsOnly [-Language en]   (loads the functions, no window)
          $env:OTR_MANAGER_SCREENSHOT = <file.png> (+ $env:OTR_MANAGER_TAB = 0, 1 or 2): draws the window into
          the PNG instead of showing it, then exits
#>
param(
  [string]$Folder,
  [string]$Language,       # en, it, ... (a file in lang\); empty = the Windows display language
  [switch]$FunctionsOnly,  # for tests: load the functions without opening the window
  [string]$Sign            # LATEST.txt of an update package to sign with the key of the vault (no window)
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
# "natural" sort of the list columns: numbers inside the text compare as numbers (thinclient2 before
# thinclient10, 192.0.2.22 before 192.0.2.165), the rest ignoring case.
# WPA key in C#: the PowerShell loop takes seconds for 8192 HMAC rounds.
if (-not ('OtrColumnSorter' -as [type])) {
  Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Text;
using System.Windows.Forms;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
public class OtrColumnSorter : System.Collections.IComparer {
    public int Column = 0;
    public int NameColumn = 0;   // equal values: by name
    public bool Descending = false;
    public int Compare(object x, object y) {
        ListViewItem a = (ListViewItem)x, b = (ListViewItem)y;
        string sa = Column < a.SubItems.Count ? a.SubItems[Column].Text : "";
        string sb = Column < b.SubItems.Count ? b.SubItems[Column].Text : "";
        int r = Natural(Durations(sa), Durations(sb));
        if (r == 0 && Column != NameColumn) { return Natural(a.SubItems.Count > NameColumn ? a.SubItems[NameColumn].Text : "", b.SubItems.Count > NameColumn ? b.SubItems[NameColumn].Text : ""); }
        return Descending ? -r : r;
    }
    // durations in minutes, so "45 min" sorts before "3 hours": uptime -p ("1 week, 3 days, 5 minutes") in
    // the Uptime column, and "N min/hours/days" in the state of the devices that stopped reporting
    static readonly Regex RxDuration = new Regex(@"\d+\s+(year|week|day|hour|minute)s?(\s*,\s*\d+\s+(year|week|day|hour|minute)s?)*");
    static readonly Regex RxPart = new Regex(@"(\d+)\s+(year|week|day|hour|minute)");
    // units in the language of the window (the state column: "3 ore", "2 giorni"), added with AddUnit
    static readonly System.Collections.Generic.Dictionary<string, long> Units = new System.Collections.Generic.Dictionary<string, long>();
    static Regex RxUnits = null;
    public static void AddUnit(string word, long minutes) {
        Units[word] = minutes;
        string[] w = new string[Units.Count]; Units.Keys.CopyTo(w, 0);
        for (int i = 0; i < w.Length; i++) w[i] = Regex.Escape(w[i]);
        RxUnits = new Regex(@"\b(\d+)\s+(" + string.Join("|", w) + @")\b");
    }
    public static string Durations(string s) {
        string r = RxDuration.Replace(s, delegate(Match u) {
            long m = 0;
            foreach (Match p in RxPart.Matches(u.Value)) {
                long n = long.Parse(p.Groups[1].Value);
                switch (p.Groups[2].Value) {
                    case "year": m += n * 525600; break; case "week": m += n * 10080; break;
                    case "day": m += n * 1440; break; case "hour": m += n * 60; break; default: m += n; break;
                }
            }
            return m + " min";
        });
        if (RxUnits != null) { r = RxUnits.Replace(r, delegate(Match u) { return (long.Parse(u.Groups[1].Value) * Units[u.Groups[2].Value]) + " min"; }); }
        return r;
    }
    public static int Natural(string a, string b) {
        int i = 0, j = 0;
        while (i < a.Length && j < b.Length) {
            if (char.IsDigit(a[i]) && char.IsDigit(b[j])) {
                int si = i, sj = j;
                while (i < a.Length && char.IsDigit(a[i])) i++;
                while (j < b.Length && char.IsDigit(b[j])) j++;
                string na = a.Substring(si, i - si).TrimStart('0'), nb = b.Substring(sj, j - sj).TrimStart('0');
                if (na.Length != nb.Length) return na.Length.CompareTo(nb.Length);
                int c = string.CompareOrdinal(na, nb); if (c != 0) return c;
            } else {
                int c = char.ToLowerInvariant(a[i]).CompareTo(char.ToLowerInvariant(b[j]));
                if (c != 0) return c; i++; j++;
            }
        }
        return (a.Length - i).CompareTo(b.Length - j);
    }
}
public static class OtrCrypto {
    // WPA key from the passphrase, as wpa_passphrase: PBKDF2-HMAC-SHA1(passphrase, SSID, 4096 rounds, 32 bytes).
    // Written by hand: Rfc2898DeriveBytes of .NET refuses salts (here the SSID) shorter than 8 bytes.
    public static string WpaPsk(string passphrase, string ssid) {
        HMACSHA1 h = new HMACSHA1(Encoding.UTF8.GetBytes(passphrase));
        byte[] salt = Encoding.UTF8.GetBytes(ssid);
        byte[] key = new byte[40];
        for (int block = 1; block <= 2; block++) {
            byte[] s = new byte[salt.Length + 4];
            Buffer.BlockCopy(salt, 0, s, 0, salt.Length);
            s[salt.Length + 3] = (byte)block;
            byte[] u = h.ComputeHash(s), t = (byte[])u.Clone();
            for (int j = 1; j < 4096; j++) { u = h.ComputeHash(u); for (int b = 0; b < 20; b++) t[b] ^= u[b]; }
            Buffer.BlockCopy(t, 0, key, (block - 1) * 20, 20);
        }
        return Hex(key, 32);
    }
    // the settings PIN as kiosk.sh checks it (pin_match): pbkdf2-sha256:<iterations>:<salt>:<key>, salted and slow
    public static string Pin(string pin) {
        byte[] salt = new byte[16];
        using (RandomNumberGenerator r = RandomNumberGenerator.Create()) { r.GetBytes(salt); }
        using (Rfc2898DeriveBytes k = new Rfc2898DeriveBytes(Encoding.UTF8.GetBytes(pin), salt, 600000, HashAlgorithmName.SHA256)) {
            return "pbkdf2-sha256:600000:" + Hex(salt, salt.Length) + ":" + Hex(k.GetBytes(32), 32);
        }
    }
    // the settings PIN of 0.1.4 and earlier: printf '%s' "$pin" | sha256sum
    public static string Sha256(string text) {
        using (SHA256 s = SHA256.Create()) { byte[] d = s.ComputeHash(Encoding.UTF8.GetBytes(text)); return Hex(d, d.Length); }
    }
    static string Hex(byte[] d, int n) { StringBuilder sb = new StringBuilder(); for (int i = 0; i < n; i++) sb.Append(d[i].ToString("x2")); return sb.ToString(); }
}
'@
}
# Ed25519, OpenPGP signatures and the vault (.NET Framework has no Ed25519): OtrVault.cs next to this file
if (-not ('OtrVault' -as [type])) { Add-Type -ReferencedAssemblies System.Numerics -Path (Join-Path $PSScriptRoot 'OtrVault.cs') }

# ---------------------------------------------------------------------------------------------
# Language: lang\en.psd1 has every text of the window, lang\<xx>.psd1 replaces the ones it translates
# (a key missing or empty there keeps the English text, never an empty label)
# ---------------------------------------------------------------------------------------------
$script:LangDir = Join-Path $PSScriptRoot 'lang'
# A language file: one table of constant texts. Read entry by entry (constants only, nothing runs): Import-PowerShellDataFile
# refuses a table with more than 500 entries.
function Import-TextTable([string]$file) {
  $errs = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errs)
  if ($errs.Count) { throw "$file, line $($errs[0].Extent.StartLineNumber): $($errs[0].Message)" }
  $h = $ast.Find({ param($a) $a -is [System.Management.Automation.Language.HashtableAst] }, $false)
  if (-not $h) { throw "$file holds no table of texts" }
  $t = @{}
  foreach ($kv in $h.KeyValuePairs) { $t[[string]$kv.Item1.SafeGetValue()] = [string]$kv.Item2.SafeGetValue() }
  $t
}
function Read-LanguageTexts([string]$dir, [string]$lang) {
  $t = @{}
  $en = Import-TextTable (Join-Path $dir 'en.psd1')
  foreach ($k in $en.Keys) { $t[$k] = $en[$k] }
  $f = Join-Path $dir "$lang.psd1"
  if ($lang -and $lang -ne 'en' -and (Test-Path -LiteralPath $f)) {
    try { $tr = Import-TextTable $f } catch { Write-Warning "$f not readable, English texts used: $($_.Exception.Message)"; $tr = @{} }
    foreach ($k in $tr.Keys) { if ($tr[$k]) { $t[$k] = $tr[$k] } }
  }
  $t
}
# -Language when given, else the Windows display language; English when lang\ has no file for it
function Select-Language([string]$wanted) {
  $lang = if ($wanted) { $wanted.ToLower() } else { (Get-UICulture).TwoLetterISOLanguageName.ToLower() }
  if ($lang -cmatch '^[a-z]{2,3}$' -and (Test-Path -LiteralPath (Join-Path $script:LangDir "$lang.psd1"))) { return $lang }
  if ($wanted -and $wanted -ne 'en') { Write-Warning "No language file lang\$wanted.psd1: English texts used" }
  'en'
}
# a text of the window; with values after the key it is a format string ({0}, {1}...). An unknown key
# shows the key itself.
function Get-Text([string]$Key) {
  $t = $script:Text[$Key]
  if (-not $t) { $t = $Key }
  if ($args.Count) { $t -f $args } else { $t }
}
try {
  $script:Language = Select-Language $Language
  $script:Text = Read-LanguageTexts $script:LangDir $script:Language
} catch {
  # the window is started hidden (OpenThinRDP-Manager.cmd): without a message box nobody would see why
  $m = "Cannot read the texts of the window in $($script:LangDir): $($_.Exception.Message)"
  if (-not $FunctionsOnly) { [void][System.Windows.Forms.MessageBox]::Show($m, 'OpenThinRDP Manager', 'OK', 'Error') }
  throw $m
}
# the state column sorts "45 min" before "3 hours" also in the words of the language
foreach ($u in @(@('DurMinutes', 1), @('DurHours', 60), @('DurDays', 1440))) {
  $w = ((Get-Text $u[0]) -replace '\{0\}', '').Trim(); if ($w) { [OtrColumnSorter]::AddUnit($w, $u[1]) }
}
# typed in a secret cell, these keep the saved Wi-Fi key / settings PIN ("(saved)" / "(set)" in English)
$script:MarkSaved = Get-Text 'MarkSaved'
$script:MarkSet = Get-Text 'MarkSet'

$script:Utf8 = New-Object System.Text.UTF8Encoding $false
$script:StaleMinutes = 15     # same threshold as SUMMARY.csv written by the devices: over it = off or offline
# keys that identify a device: central-apply.sh ignores them in common.conf
$script:HostOnly = @('HOSTNAME', 'DEFAULT_USER', 'NETMODE', 'IPADDR')
$script:SettingsFile = Join-Path $env:APPDATA 'OpenThinRDP\manager.json'

function Set-ManagementFolder([string]$path) {
  if ($path.Length -gt 3) { $path = $path.TrimEnd('\', '/') }
  $script:Folder = $path
  $script:StatusDir = Join-Path $path 'status'
  $script:ConfigDir = Join-Path $path 'config'
  $script:BackupDir = Join-Path $script:ConfigDir 'backup'
  $script:ChangeLog = Join-Path $script:ConfigDir 'changes.log'
  $script:CommonFile = Join-Path $script:ConfigDir 'common.conf'
  $script:KeysFile = Join-Path $script:ConfigDir 'authorized_keys'
}
function Get-HostFile($name) { Join-Path $script:ConfigDir "$name.conf" }

# ---------------------------------------------------------------------------------------------
# Settings: the keys of defaults.conf on the device (+ HOSTNAME, + WIFI_PSK which never leaves this tool
# as a password). Type = which save-config.sh rule applies. Default = project default (defaults.conf),
# proposed in common.conf when no device reports the key yet (a value: never translated).
# Name and description of each setting: Label_<KEY> and Help_<KEY> in lang\*.psd1; groups: Section*.
# ---------------------------------------------------------------------------------------------
$script:Section = ''
function Set-Section($textKey) { $script:Section = Get-Text $textKey }
function New-Setting($key, $type, $default, $choices = $null) {
  [pscustomobject]@{ Key = $key; Label = (Get-Text "Label_$key"); Type = $type; Default = $default; Help = (Get-Text "Help_$key"); Choices = $choices
                     HostOnly = ($script:HostOnly -contains $key); Section = $script:Section }
}
$script:Settings = @(
  (Set-Section 'SectionRemoteDesktop')
  (New-Setting 'HOSTNAME'            'host'       '')
  (New-Setting 'DEFAULT_USER'        'user'       '')
  (New-Setting 'BROKER'              'name'       '')
  (New-Setting 'BROKER_FALLBACK'     'names'      '')
  (New-Setting 'DOMAIN'              'name'       '')
  (New-Setting 'LOAD_BALANCE_INFO'   'collection' '')
  (New-Setting 'TRANSPORT'           'choice'     'auto' @('auto', 'udp', 'tcp'))
  (New-Setting 'RDP_AUTH'            'choice'     'negotiate' @('negotiate', 'kerberos', 'ntlm'))
  (New-Setting 'RDP_CERT'            'choice'     'tofu' @('tofu', 'ignore', 'verify'))
  (New-Setting 'RDP_GFX'             'gfx'        'progressive,AVC420:off,AVC444:off')
  (New-Setting 'RDP_KEYBOARD'        'rdpkbd'     '')
  (New-Setting 'MULTIMON'            'choice'     'auto' @('auto', 'off'))
  (New-Setting 'RDP_EXTRA'           'extra'      '')
  (New-Setting 'SESSION_THRESHOLD'   'threshold'  '10')
  (New-Setting 'SHUTDOWN_SECS'       'shutdown'   '10')
  (Set-Section 'SectionUsb')
  (New-Setting 'USB_MODE'            'choice'     'all' @('all', 'auto', 'disks'))
  (New-Setting 'USB_REDIRECT'        'usb'        '')
  (Set-Section 'SectionNetwork')
  (New-Setting 'NETMODE'             'choice'     'dhcp' @('dhcp', 'static'))
  (New-Setting 'IPADDR'              'ip'         '')
  (New-Setting 'NETMASK'             'mask'       '255.255.255.0')
  (New-Setting 'GATEWAY'             'ip'         '')
  (New-Setting 'DNS1'                'ip'         '')
  (New-Setting 'DNS2'                'ip'         '')
  (New-Setting 'NTP'                 'names'      '')
  (New-Setting 'WIFI'                'choice'     'off' @('off', 'on'))
  (New-Setting 'WIFI_SSID'           'ssid'       '')
  (New-Setting 'WIFI_COUNTRY'        'country'    '')
  (New-Setting 'WIFI_PSK'            'psk'        '')
  (Set-Section 'SectionManagement')
  (New-Setting 'MGMT_SHARE'          'share'      '')
  (New-Setting 'MGMT_USER'           'user'       '')
  (New-Setting 'SECURITY_UPDATES'    'choice'     'on' @('off', 'on'))
  (New-Setting 'TPM_SECRETS'         'choice'     'on' @('on', 'off'))
  (New-Setting 'UPDATE_FROM'         'choice'     'github' @('github', 'share', 'off'))
  (New-Setting 'UPDATE_GITHUB'       'repo'       'OpenThinRdp/openthinrdp')
  (New-Setting 'UPDATE_KEY'          'choice'     'any' @('any', 'site'))
  (New-Setting 'SSH'                 'choice'     'off' @('off', 'on'))
  (New-Setting 'REMOTE_SCREEN'       'choice'     'on' @('on', 'off'))
  (Set-Section 'SectionWeb')
  (New-Setting 'WEB_BUTTON'          'choice'     'none' @('none', 'app', 'browser', 'kiosk'))
  (New-Setting 'WEB_LABEL'           'text'       'Web')
  (New-Setting 'WEB_URL'             'url'        '')
  (New-Setting 'WEB_ALLOW'           'urls'       '')
  (New-Setting 'KIOSK_URL'           'url'        '')
  (New-Setting 'KIOSK_RELOAD_MIN'    'reload'     '10')
  (Set-Section 'SectionPower')
  (New-Setting 'POWER_ON_TIME'       'time'       '')
  (New-Setting 'POWER_OFF_TIME'      'time'       '')
  (New-Setting 'POWER_ON_DAYS'       'days'       '1234567')
  (Set-Section 'SectionLook')
  (New-Setting 'LANGUAGE'            'lang'       'en')
  (New-Setting 'KEYBOARD'            'kbd'        'us')
  (New-Setting 'TITLE'               'text'       'Remote desktop')
  (New-Setting 'LOGO'                'logo'       '/opt/openthinrdp/branding/logo.png')
  (New-Setting 'BG_TOP'              'color'      '#1b2733')
  (New-Setting 'BG_BOTTOM'           'color'      '#000000')
  (New-Setting 'SUPPORT_TEXT'        'text'       '')
  (New-Setting 'SETTINGS_PIN_SHA256' 'pin'        '')
)
function Get-Setting($key) { $script:Settings | Where-Object Key -eq $key | Select-Object -First 1 }

# ---------------------------------------------------------------------------------------------
# Checks: the rules of save-config.sh, with case-sensitive regexes as bash uses them
# ---------------------------------------------------------------------------------------------
$script:Rx = @{
  Host       = '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
  Name       = '^[A-Za-z0-9]([A-Za-z0-9.-]{0,252})$'
  User       = '^[A-Za-z0-9._@\\-]{1,104}$'
  Url        = '^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~:/?#@!$&()*+,;=%-]*)?$'
  BadText    = '[<>&|"`$\\]'
  Share      = '^(\\\\|//)[A-Za-z0-9.-]+[\\/][A-Za-z0-9 ._$\\/-]+$'
  Extra      = '^[A-Za-z0-9 /:+,._=#-]*$'
  Time       = '^([01][0-9]|2[0-3]):[0-5][0-9]$'
  Collection = '^[A-Za-z0-9._:/#=-]*$'
  Gfx        = '^[A-Za-z0-9:,]*$'
  RdpKbd     = '^(0x[0-9a-fA-F]{8})?$'
  Usb        = '^([0-9a-f]{4}:[0-9a-f]{4}( [0-9a-f]{4}:[0-9a-f]{4})*)?$'
  Kbd        = '^[a-z][a-z0-9_-]{1,15}$'
  Logo       = '^(/[A-Za-z0-9._/-]+\.png)?$'
  Color      = '^#[0-9a-fA-F]{6}$'
  Hex64      = '^[0-9a-fA-F]{64}$'
  SshKey     = '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com) [A-Za-z0-9+/=]+( .*)?$'
}
function Test-Ip([string]$s) {
  if ($s -cnotmatch '^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$') { return $false }
  foreach ($i in 1..4) { if ([int]$Matches[$i] -gt 255) { return $false } }
  $true
}
function ConvertTo-IpNumber([string]$s) { $p = $s.Split('.'); [uint64]$p[0] * 16777216 + [uint64]$p[1] * 65536 + [uint64]$p[2] * 256 + [uint64]$p[3] }
function Test-Mask([string]$s) {
  if (-not (Test-Ip $s)) { return $false }
  $m = ConvertTo-IpNumber $s; $inv = [uint64]4294967295 - $m
  ($m -ne 0) -and (($inv -band ($inv + 1)) -eq 0)
}
# lists: the device squeezes spaces, commas and semicolons into single spaces (tr -s ' ,;' ' ')
function Split-List([string]$v) { @($v -split '[ ,;]+' | Where-Object { $_ }) }
function Test-Text([string]$v) { ($v -cnotmatch $script:Rx.BadText) -and $v.Length -le 200 }

# error for a single value, or $null when it is good
function Test-SettingValue([string]$key, [string]$v) {
  $s = Get-Setting $key
  if (-not $s) { return (Get-Text 'ErrUnknownSetting' $key) }
  $L = $s.Label
  # a line break would put a second KEY= line in the file, read by the device as a separate setting
  if ($v -match '[\x00-\x1f\x7f]') { return (Get-Text 'ErrControlChars' $L) }
  switch ($s.Type) {
    'host'       { if ($v -cnotmatch $script:Rx.Host -or $v -cmatch '^[0-9]+$') { return (Get-Text 'ErrHostname') } }
    'user'       { if ($v -ne '' -and $v -cnotmatch $script:Rx.User) { return (Get-Text 'ErrUser') } }
    'name'       { if ($v -ne '' -and $v -cnotmatch $script:Rx.Name) { return (Get-Text 'ErrNotValid' $L) } }
    'names'      { foreach ($t in (Split-List $v)) { if (-not (Test-Ip $t) -and $t -cnotmatch $script:Rx.Name) { return (Get-Text 'ErrListValue' $L $t) } } }
    'collection' { if ($v -cnotmatch $script:Rx.Collection) { return (Get-Text 'ErrCollection') } }
    'repo'       { if ($v -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { return (Get-Text 'ErrRepo') } }
    'choice'     { if ($s.Choices -notcontains $v) { return (Get-Text 'ErrChoice' $L ($s.Choices -join ', ')) } }
    'gfx'        { if ($v -cnotmatch $script:Rx.Gfx) { return (Get-Text 'ErrGfx' $L) } }
    'rdpkbd'     { if ($v -cnotmatch $script:Rx.RdpKbd) { return (Get-Text 'ErrRdpKbd' $L) } }
    'extra'      { if ($v -cnotmatch $script:Rx.Extra) { return (Get-Text 'ErrExtra' $L) } }
    'threshold'  { if ($v -cnotmatch '^[0-9]{1,3}$' -or [int]$v -lt 5 -or [int]$v -gt 120) { return (Get-Text 'ErrThreshold') } }
    'shutdown'   { if ($v -cnotmatch '^[0-9]{1,4}$' -or [int]$v -gt 3600) { return (Get-Text 'ErrShutdown') } }
    'usb'        { if (((Split-List $v) -join ' ').ToLower() -cnotmatch $script:Rx.Usb) { return (Get-Text 'ErrUsb') } }
    'ip'         { if ($v -ne '' -and -not (Test-Ip $v)) { return (Get-Text 'ErrNotValid' $L) } }
    'mask'       { if ($v -ne '' -and -not (Test-Mask $v)) { return (Get-Text 'ErrNetmask') } }
    'ssid'       { if ($v.Length -gt 32 -or $v -match '["|\\]') { return (Get-Text 'ErrSsid') } }
    'country'    { if ($v.ToUpper() -cnotmatch '^([A-Z]{2})?$') { return (Get-Text 'ErrCountry') } }
    'psk'        { if ($v -ne $script:MarkSaved -and $v -cnotmatch $script:Rx.Hex64 -and ($v.Length -lt 8 -or $v.Length -gt 63)) { return (Get-Text 'ErrPsk') } }
    'share'      { if ($v -ne '' -and $v -cnotmatch $script:Rx.Share) { return (Get-Text 'ErrShare') } }
    'text'       { if (-not (Test-Text $v)) { return (Get-Text 'ErrText' $L) } }
    'url'        { if ($v -ne '' -and $v -cnotmatch $script:Rx.Url) { return (Get-Text 'ErrUrl' $L) } }
    'urls'       { foreach ($t in (Split-List $v)) { if ($t -cnotmatch $script:Rx.Url) { return (Get-Text 'ErrAllowedSite' $t) } } }
    'reload'     { if ($v -cnotmatch '^[0-9]{1,4}$' -or [int]$v -gt 1440) { return (Get-Text 'ErrReload') } }
    'time'       { if ($v -ne '' -and $v -cnotmatch $script:Rx.Time) { return (Get-Text 'ErrTime' $L) } }
    'days'       { if ($v -cnotmatch '^[1-7 ,;]*$') { return (Get-Text 'ErrDays') } }
    'lang'       { if ($v.ToLower() -cnotmatch '^[a-z]{2}$') { return (Get-Text 'ErrLanguage') } }
    'kbd'        { if ($v -cnotmatch $script:Rx.Kbd) { return (Get-Text 'ErrKeyboard') } }
    'logo'       { if ($v -cnotmatch $script:Rx.Logo) { return (Get-Text 'ErrLogo') } }
    'color'      { if ($v -cnotmatch $script:Rx.Color) { return (Get-Text 'ErrColor' $L) } }
    'pin'        { if ($v.Length -gt 64) { return (Get-Text 'ErrPin') } }
  }
  $null
}

# the value exactly as save-config.sh stores it. Writing anything else makes the device see a difference
# against its own (normalized) copy at every read, and apply the configuration again every 5 minutes.
function ConvertTo-Canonical([string]$key, [string]$v) {
  $s = Get-Setting $key; $v = $v.Trim()
  if ($s.Type -eq 'choice') {
    # aliases accepted by the device (older files, other languages); anything else = what the device falls back to
    $l = $v.ToLower()
    if ($s.Choices -contains $l) { return $l }
    $alias = @{ NETMODE = @{ statico = 'static' }; USB_MODE = @{ dischi = 'disks' }; WEB_BUTTON = @{ portale = 'app'; portal = 'app'; chrome = 'browser'; chromium = 'browser' } }
    if ($key -in 'WIFI', 'SSH', 'REMOTE_SCREEN', 'SECURITY_UPDATES', 'TPM_SECRETS') { if ($l -in 'yes', 'true', '1', 'si') { return 'on' }; return 'off' }
    if ($alias.ContainsKey($key) -and $alias[$key].ContainsKey($l)) { return $alias[$key][$l] }
    return $s.Choices[0]
  }
  switch ($s.Type) {
    'names'     { return (Split-List $v) -join ' ' }
    'urls'      { return (Split-List $v) -join ' ' }
    'usb'       { return ((Split-List $v) -join ' ').ToLower() }
    'country'   { return $v.ToUpper() }
    'lang'      { return $v.ToLower() }
    'pin'       { return $v.ToLower() }
    'days'      { $d = -join (@($v.ToCharArray() | Where-Object { $_ -match '[1-7]' } | Sort-Object -Unique)); if ($d) { return $d }; return '1234567' }
    { $_ -in 'threshold', 'shutdown', 'reload' } { if ($v -cmatch '^[0-9]{1,6}$') { return [string][int]$v }; return $v }
  }
  $v
}

# cross checks on the RESULTING configuration of a device (as save-config.sh will see it)
function Test-EffectiveConfig($r, $status) {
  $e = @()
  if ($r['NETMODE'] -eq 'static') {
    if (-not (Test-Ip $r['IPADDR'])) { $e += Get-Text 'ErrStaticIp' }
    if (-not (Test-Mask $r['NETMASK'])) { $e += Get-Text 'ErrStaticMask' }
    if (-not (Test-Ip $r['GATEWAY'])) { $e += Get-Text 'ErrStaticGateway' }
    if ((Test-Ip $r['IPADDR']) -and (Test-Mask $r['NETMASK']) -and (Test-Ip $r['GATEWAY'])) {
      $m = ConvertTo-IpNumber $r['NETMASK']
      if (((ConvertTo-IpNumber $r['IPADDR']) -band $m) -ne ((ConvertTo-IpNumber $r['GATEWAY']) -band $m)) { $e += Get-Text 'ErrSubnet' $r['GATEWAY'] $r['IPADDR'] }
    }
    if (-not (Test-Ip $r['DNS1'])) { $e += Get-Text 'ErrStaticDns' }
  }
  if ($r['WEB_BUTTON'] -in 'app', 'browser' -and -not $r['WEB_URL']) { $e += Get-Text 'ErrWebNeedsUrl' $r['WEB_BUTTON'] }
  if ($r['WEB_BUTTON'] -eq 'kiosk' -and -not $r['KIOSK_URL']) { $e += Get-Text 'ErrKioskNeedsUrl' }
  if ($r['UPDATE_FROM'] -eq 'share' -and -not $r['MGMT_SHARE']) { $e += Get-Text 'ErrUpdateNeedsShare' }
  if ($r['WIFI'] -eq 'on') {
    if (-not $r['WIFI_SSID'] -or (Test-SettingValue 'WIFI_SSID' $r['WIFI_SSID'])) { $e += Get-Text 'ErrWifiNeedsSsid' }
    if ($status -and $status['WIFI_STATUS'] -eq 'no adapter') { $e += Get-Text 'ErrWifiNoAdapter' }
  }
  $e
}

function Get-WpaKey([string]$passphrase, [string]$ssid) { [OtrCrypto]::WpaPsk($passphrase, $ssid) }
function Get-PinHash([string]$pin) { [OtrCrypto]::Pin($pin) }
# what the user typed in a secret cell -> what goes to the file (MarkSaved/MarkSet = keep the previous one)
function ConvertTo-WpaKey($v, $ssid) { if ($v -cmatch $script:Rx.Hex64) { $v.ToLower() } else { Get-WpaKey $v $ssid } }
function ConvertTo-PinHash($v) { if ($v -eq '') { '' } elseif ($v -cmatch $script:Rx.Hex64 -or $v -cmatch '^pbkdf2-sha256:[0-9]{4,7}:[0-9a-f]{32}:[0-9a-f]{64}$') { $v.ToLower() } else { Get-PinHash $v } }
function Format-Value($k, $v) {
  if ($null -eq $v) { Get-Text 'ValNotManaged' }
  elseif ($k -eq 'WIFI_PSK') { Get-Text 'ValWpaKey' }
  elseif ($k -eq 'SETTINGS_PIN_SHA256') { if ($v) { Get-Text 'ValPinSet' } else { Get-Text 'ValNoPin' } }
  else { "'$v'" }
}

# ---------------------------------------------------------------------------------------------
# Reading the files
# ---------------------------------------------------------------------------------------------
function Read-Lines($f) {
  for ($i = 0; $i -lt 3; $i++) {    # the device may be rewriting the file right now
    try { $t = [IO.File]::ReadAllText($f); return @($t.TrimStart([char]0xFEFF) -split "`r?`n") } catch { Start-Sleep -Milliseconds 300 }
  }
  @()
}
# ACTIVE keys of a .conf file, as central-apply.sh reads them (last one wins, # and ; lines ignored)
function Read-ConfFile($f) {
  $h = [ordered]@{}
  if (Test-Path -LiteralPath $f) {
    foreach ($l in (Read-Lines $f)) { if ($l -cmatch '^\s*([A-Z][A-Z0-9_]*)\s*=\s*(.*?)\s*$') { $h[$Matches[1]] = $Matches[2] } }
  }
  $h
}
# status\<hostname>.txt: the KEY=value lines at the top (up to the first "---" section)
function Read-StatusFile($f) {
  $h = @{}
  foreach ($l in (Read-Lines $f)) { if ($l -like '---*') { break }; if ($l -cmatch '^([A-Z][A-Z0-9_]*)=(.*)$') { $h[$Matches[1]] = $Matches[2].Trim() } }
  $h
}
function Get-ReportTime($s) {
  try { [datetime]::ParseExact($s['UPDATED'], 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) } catch { $null }
}
function Format-Minutes($m) { if ($m -lt 120) { Get-Text 'DurMinutes' $m } elseif ($m -lt 2880) { Get-Text 'DurHours' ([int]($m / 60)) } else { Get-Text 'DurDays' ([int]($m / 1440)) } }

function Get-Devices {
  $list = @()
  if (-not (Test-Path -LiteralPath $script:StatusDir)) { return @() }
  # Extension check: "*.txt" alone also matches longer extensions on Windows
  foreach ($f in @(Get-ChildItem -LiteralPath $script:StatusDir -Filter '*.txt' -File -ErrorAction SilentlyContinue | Where-Object Extension -eq '.txt')) {
    $s = Read-StatusFile $f.FullName
    if (-not $s['HOSTNAME']) { continue }
    $when = Get-ReportTime $s; if (-not $when) { $when = $f.LastWriteTime }
    $min = [int]((Get-Date) - $when).TotalMinutes
    # Kind = the colour of the state: ok, off, error, warn, info
    $state = Get-Text 'StateOk'; $kind = 'ok'
    if ($min -gt $script:StaleMinutes) { $state = Get-Text 'StateOffline' (Format-Minutes $min); $kind = 'off' }
    elseif ($s['FAILED_UNITS'] -and $s['FAILED_UNITS'] -ne 'none') { $state = Get-Text 'StateFailedUnits'; $kind = 'error' }
    elseif ($s['CENTRAL_CONFIG'] -like 'REJECTED*') { $state = Get-Text 'StateRejected'; $kind = 'warn' }
    elseif ($s['SHARE_UPDATE'] -like 'ERROR*' -or $s['SHARE_UPDATE'] -like 'IGNORED*') { $state = Get-Text 'StateUpdateError'; $kind = 'warn' }
    elseif ($s['REBOOT_REQUIRED'] -eq 'yes') { $state = Get-Text 'StateReboot'; $kind = 'info' }
    $list += [pscustomobject]@{ Name = $s['HOSTNAME']; File = $f.BaseName; State = $state; Kind = $kind; OldName = $false; Minutes = $min; When = $when; S = $s }
  }
  # same MAC under two names = the old name left behind by a rename (normally the device removes it itself)
  foreach ($g in @($list | Where-Object { $_.S['MAC'] } | Group-Object { $_.S['MAC'] } | Where-Object Count -gt 1)) {
    $sorted = @($g.Group | Sort-Object When -Descending)
    $sorted | Select-Object -Skip 1 | ForEach-Object { $_.State = Get-Text 'StateOldName' $sorted[0].Name; $_.Kind = 'off'; $_.OldName = $true }
  }
  @($list | Sort-Object Name)
}

# updates\LATEST.txt, read only: the devices install only what is signed (management/publish)
function Get-PublishedUpdate {
  $f = Join-Path $script:Folder 'updates\LATEST.txt'
  if (-not (Test-Path -LiteralPath $f)) { return (Get-Text 'UpdNone') }
  $v = (Read-Lines $f | Where-Object { $_ -match '^version=' } | Select-Object -First 1) -replace '^version=', ''
  if (-not $v) { return (Get-Text 'UpdNoVersion') }
  if (Test-Path -LiteralPath "$f.sig") { "$v" } else { Get-Text 'UpdNotSigned' $v }
}

# ---------------------------------------------------------------------------------------------
# A GitHub release into updates\: the latest release (pre-releases excluded) of UPDATE_GITHUB (common.conf,
# else the project default), for the devices with UPDATE_FROM=share. Here the package hash and the project signature
# are checked (OtrVault.cs: no gpg needed), against the project key that comes with this tool
# (openthinrdp-release.asc next to it, or rootfs/opt/openthinrdp/keys in the repository). With the site key in the
# vault the release is then signed again with it: devices with UPDATE_KEY=site accept only that signature.
# ---------------------------------------------------------------------------------------------
$script:ReleaseKey = @((Join-Path $PSScriptRoot 'openthinrdp-release.asc'), (Join-Path $PSScriptRoot '..\..\rootfs\opt\openthinrdp\keys\openthinrdp-release.asc')) |
  Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$script:ReleaseFileRx = '^openthinrdp-update-[0-9A-Za-z._-]+\.tar\.gz$'
function Get-ReleaseRepo {
  $r = (Read-ConfFile $script:CommonFile)['UPDATE_GITHUB']
  if ($r -and $r -cmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { $r } else { (Get-Setting 'UPDATE_GITHUB').Default }
}
# one file of a release: from GitHub, or from a local folder (tests)
function Get-ReleaseFile([string]$base, [string]$name, [string]$dest) {
  if ($base -match '^https?://') { Invoke-WebRequest -UseBasicParsing -Uri "$base/$name" -OutFile $dest -TimeoutSec 300 -ErrorAction Stop }
  else { Copy-Item -LiteralPath (Join-Path $base $name) -Destination $dest -ErrorAction Stop }
}
# $true = good signature of a key of the key file, $false = bad, $null = not checked here (no key file)
function Test-ReleaseSignature([string]$sig, [string]$file, [string]$keyFile) {
  if (-not $keyFile -or -not (Test-Path -LiteralPath $keyFile)) { return $null }
  try { [OtrVault]::VerifyWithKeyFile([IO.File]::ReadAllBytes($keyFile), [IO.File]::ReadAllBytes($file), [IO.File]::ReadAllText($sig)) } catch { $false }
}# version order as "sort -V" on the devices: the numbers inside compare as numbers
function Compare-Version([string]$a, [string]$b) {
  $pa = @($a -split '[^0-9A-Za-z]+'); $pb = @($b -split '[^0-9A-Za-z]+')
  for ($i = 0; $i -lt [Math]::Max($pa.Count, $pb.Count); $i++) {
    $x = if ($i -lt $pa.Count) { $pa[$i] } else { '' }; $y = if ($i -lt $pb.Count) { $pb[$i] } else { '' }
    if ($x -match '^[0-9]+$' -and $y -match '^[0-9]+$') { $c = ([long]$x).CompareTo([long]$y) } else { $c = [string]::CompareOrdinal($x, $y) }
    if ($c) { return [Math]::Sign($c) }
  }
  0
}
# the index of an update package: version, package file, its SHA-256; Ok = all three in the format the devices accept
function Read-LatestFile([string]$file) {
  $l = Read-Lines $file
  $field = { param($k) ([string]($l | Where-Object { $_ -match "^$k=" } | Select-Object -First 1) -replace "^$k=", '').Trim() }
  $v = & $field 'version'; $f = & $field 'file'; $h = & $field 'sha256'
  [pscustomobject]@{ Version = $v; File = $f; Hash = $h
    Ok = ($v -cmatch '^[0-9A-Za-z._-]+$' -and $f -cmatch $script:ReleaseFileRx -and $h -cmatch '^[0-9a-f]{64}$') }
}
# Downloads and checks the release into a temporary folder. Ok = $false with Message, or the release:
# Version, File, Signature ($true / $null = not checked here), Dir (temporary folder for Publish-Release)
function Get-Release([string]$base = '', [string]$keyFile = $script:ReleaseKey) {
  if (-not $base) { $base = "https://github.com/$(Get-ReleaseRepo)/releases/latest/download" }
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $tmp = Join-Path $env:TEMP "otr-release-$(Get-Random)"; New-Item -ItemType Directory $tmp | Out-Null
  $fail = { param($m) Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue; [pscustomobject]@{ Ok = $false; Message = $m } }
  try { Get-ReleaseFile $base 'LATEST.txt' "$tmp\LATEST.txt"; Get-ReleaseFile $base 'LATEST.txt.sig' "$tmp\LATEST.txt.sig" }
  catch { return (& $fail (Get-Text 'RelNotFound' $base $_.Exception.Message)) }
  $i = Read-LatestFile "$tmp\LATEST.txt"; $v = $i.Version; $f = $i.File; $h = $i.Hash
  if (-not $i.Ok) { return (& $fail (Get-Text 'RelNotValid')) }
  $sig = Test-ReleaseSignature "$tmp\LATEST.txt.sig" "$tmp\LATEST.txt" $keyFile
  if ($sig -eq $false) { return (& $fail (Get-Text 'RelBadSignature' $v)) }
  $cur = Join-Path $script:Folder 'updates\LATEST.txt'
  if (Test-Path -LiteralPath $cur) {
    $cv = (Read-LatestFile $cur).Version
    if ($cv -and (Compare-Version $v $cv) -le 0) { return (& $fail (Get-Text 'RelNotNewer' $v $cv)) }
  }
  try { Get-ReleaseFile $base $f "$tmp\$f" } catch { return (& $fail (Get-Text 'RelNotFound' "$base/$f" $_.Exception.Message)) }
  if ((Get-FileHash -LiteralPath "$tmp\$f" -Algorithm SHA256).Hash.ToLower() -ne $h) { return (& $fail (Get-Text 'RelBadHash' $f)) }
  [pscustomobject]@{ Ok = $true; Version = $v; File = $f; Hash = $h; Signature = $sig; Dir = $tmp; Source = $base }
}
# Copies a checked release into updates\: package first, then signature and index (a device never sees an
# index that points to a missing package); the last 3 packages are kept. Removes the temporary folder.
# $siteKey (Get-VaultSigningKey): LATEST.txt is signed again with it first, only over a project signature checked
# here; the new signature replaces the project one.
function Publish-Release($rel, $siteKey = $null) {
  try {
    if ($siteKey) {
      if ($rel.Signature -ne $true) { throw (Get-Text 'RelResignUnchecked') }
      $l = Join-Path $rel.Dir 'LATEST.txt'; $data = [IO.File]::ReadAllBytes($l)
      $sig = [OtrVault]::SignDetached($siteKey, $data, [uint32][DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
      if (-not [OtrVault]::VerifyDetached($siteKey.Public, $data, $sig)) { throw (Get-Text 'SignCheckFailed') }
      [IO.File]::WriteAllText((Join-Path $rel.Dir 'LATEST.txt.sig'), $sig, [Text.Encoding]::ASCII)
    }
    $u = Join-Path $script:Folder 'updates'
    if (-not (Test-Path -LiteralPath $u)) { New-Item -ItemType Directory -Path $u | Out-Null }
    Copy-Item -LiteralPath (Join-Path $rel.Dir $rel.File) -Destination (Join-Path $u $rel.File) -Force -ErrorAction Stop
    if ((Get-FileHash -LiteralPath (Join-Path $u $rel.File) -Algorithm SHA256).Hash.ToLower() -ne $rel.Hash) { throw (Get-Text 'RelBadHash' $rel.File) }
    foreach ($n in 'LATEST.txt.sig', 'LATEST.txt') {
      Copy-Item -LiteralPath (Join-Path $rel.Dir $n) -Destination (Join-Path $u "$n.new") -Force -ErrorAction Stop
      Move-Item -LiteralPath (Join-Path $u "$n.new") -Destination (Join-Path $u $n) -Force -ErrorAction Stop
    }
    Get-ChildItem -LiteralPath $u -Filter 'openthinrdp-update-*.tar.gz' | Where-Object Name -ne $rel.File |
      Sort-Object LastWriteTime -Descending | Select-Object -Skip 2 | Remove-Item -Force
    Add-ChangeLog ("release {0} copied into updates\ from {1} (project signature {2}{3})" -f $rel.Version, $rel.Source,
      $(if ($rel.Signature) { 'checked here' } else { 'not checked here: the devices check it' }), $(if ($siteKey) { ", signed again with the site key $($siteKey.Hex())" } else { '' }))
  } finally { Remove-Item -LiteralPath $rel.Dir -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------------------------
# Vault: the secrets of the administrators in vault.otr next to this tool, encrypted with an access code
# (OtrVault.cs: PBKDF2-HMAC-SHA256 600000 rounds, AES-256-CBC + HMAC-SHA256). Every administrator who starts the
# same copy of the tool opens it with the same code; without the code there is no remote screen and no signing.
#   ssh_private, ssh_public   the SSH key of the manager (remote screen; its public half in config\authorized_keys)
#   sign_*                    the OpenPGP key that signs the update packages (Ed25519, as gpg exports it)
# Open, the secrets stay in memory until the window closes. ssh.exe needs the private key in a file: a folder
# that only this account and SYSTEM can read, removed when the vault closes.
# ---------------------------------------------------------------------------------------------
$script:VaultFile = if ($env:OTR_MANAGER_VAULT) { $env:OTR_MANAGER_VAULT } else { Join-Path $PSScriptRoot 'vault.otr' }
$script:VaultKeysDir = Join-Path $env:LOCALAPPDATA 'OpenThinRDP\vault-keys'
$script:VaultMinCode = 8
$script:Vault = $null; $script:VaultCode = $null; $script:VaultKeyFile = $null
function Test-VaultFile { Test-Path -LiteralPath $script:VaultFile }
function Test-VaultOpen { $null -ne $script:Vault }
# $false = wrong code
function Open-Vault([string]$code) {
  $plain = [OtrVault]::Open($code, [IO.File]::ReadAllText($script:VaultFile))
  if ($null -eq $plain) { return $false }
  $h = @{}; ([Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value }
  $script:Vault = $h; $script:VaultCode = $code
  $true
}
# written next to it first, then moved over it: a vault cut in half would lose every key
function Save-Vault {
  $sealed = [OtrVault]::Seal($script:VaultCode, [Text.Encoding]::UTF8.GetBytes(($script:Vault | ConvertTo-Json -Compress)))
  $tmp = "$($script:VaultFile).new"
  [IO.File]::WriteAllText($tmp, "$sealed`r`n", [Text.Encoding]::ASCII)
  Move-Item -LiteralPath $tmp -Destination $script:VaultFile -Force
}
function New-Vault([string]$code) { $script:Vault = @{ format = 1 }; $script:VaultCode = $code; Save-Vault }
function Set-VaultCode([string]$code) { $script:VaultCode = $code; Save-Vault }
function Close-Vault { Remove-VaultKeyFile; $script:Vault = $null; $script:VaultCode = $null }
function Test-CodeStrength([string]$code) { $code.Length -ge $script:VaultMinCode }

# a new folder that only this account and SYSTEM can read (ssh.exe refuses a private key others can read)
function New-PrivateDir {
  $d = Join-Path $script:VaultKeysDir ([guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $d -Force | Out-Null
  $acl = New-Object System.Security.AccessControl.DirectorySecurity
  $acl.SetAccessRuleProtection($true, $false)
  foreach ($sid in @([System.Security.Principal.WindowsIdentity]::GetCurrent().User, (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')))) {
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
  }
  Set-Acl -LiteralPath $d -AclObject $acl
  $d
}
# the private SSH key of the vault in a file for ssh.exe -i; $null = vault closed or no key
function Get-VaultKeyFile {
  if (-not (Test-VaultOpen) -or -not $script:Vault['ssh_private']) { return $null }
  if ($script:VaultKeyFile -and (Test-Path -LiteralPath $script:VaultKeyFile)) { return $script:VaultKeyFile }
  $f = Join-Path (New-PrivateDir) 'id_manager'
  [IO.File]::WriteAllText($f, (([string]$script:Vault['ssh_private']) -replace "`r`n", "`n").TrimEnd("`n") + "`n", $script:Utf8)
  $script:VaultKeyFile = $f
  $f
}
function Remove-VaultKeyFile {
  if ($script:VaultKeyFile) { Remove-Item -LiteralPath (Split-Path $script:VaultKeyFile) -Recurse -Force -ErrorAction SilentlyContinue; $script:VaultKeyFile = $null }
  # left by a window that did not close normally
  Get-ChildItem -LiteralPath $script:VaultKeysDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
# a command on a device as otradmin with the key of the vault ($key = Get-VaultKeyFile) and no other: the keys in
# the profile of this account are not offered (IdentitiesOnly)
function Invoke-DeviceSsh([string]$ip, [string]$command, [string]$key) {
  $ErrorActionPreference = 'Continue'
  $out = & ssh.exe -i $key -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "otradmin@$ip" $command 2>&1
  @{ Code = $LASTEXITCODE; Text = (@($out) -join "`n") }
}
# the public half of a private key file, from ssh-keygen -y: fails on a key protected by a passphrase (ssh.exe could
# not use it without asking) and on anything that is not a private key
function Get-SshPublicOf([string]$keyFile) {
  $kg = (Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue).Source
  if (-not $kg) { throw (Get-Text 'ErrRemoteNoSshExe') }
  $ErrorActionPreference = 'Continue'
  $out = & $kg -y -P '' -f $keyFile 2>$null
  @($out) | Where-Object { "$_" -cmatch $script:Rx.SshKey } | Select-Object -First 1
}
# a new SSH key for the manager, made by ssh-keygen in a private folder and kept only in the vault
function New-VaultSshKey {
  $kg = (Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue).Source
  if (-not $kg) { throw (Get-Text 'ErrRemoteNoSshExe') }
  $d = New-PrivateDir; $f = Join-Path $d 'new'
  try {
    $p = Start-Process $kg -ArgumentList "-q -t ed25519 -N `"`" -C openthinrdp-manager -f `"$f`"" -WindowStyle Hidden -Wait -PassThru
    if ($p.ExitCode -ne 0 -or -not (Test-Path -LiteralPath "$f.pub")) { throw (Get-Text 'KeyCreateFailed' $p.ExitCode) }
    $script:Vault['ssh_private'] = [IO.File]::ReadAllText($f); $script:Vault['ssh_public'] = ([IO.File]::ReadAllText("$f.pub")).Trim()
  } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
  Remove-VaultKeyFile; Save-Vault
  $script:Vault['ssh_public']
}
# an existing private key (e.g. the one an administrator used so far), copied into the vault
function Import-VaultSshKey([string]$file) {
  $d = New-PrivateDir; $f = Join-Path $d 'import'
  try {
    Copy-Item -LiteralPath $file -Destination $f
    $pub = Get-SshPublicOf $f
    if (-not $pub) { throw (Get-Text 'VaultSshNotUsable' $file) }
    $script:Vault['ssh_private'] = [IO.File]::ReadAllText($f); $script:Vault['ssh_public'] = "$pub".Trim()
  } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
  Remove-VaultKeyFile; Save-Vault
  $script:Vault['ssh_public']
}
# the key that signs: the file of gpg --export-secret-keys (armored or binary, without a passphrase)
function Import-VaultSigningKey([string]$file) {
  $k = [OtrVault]::ReadSecretKey([IO.File]::ReadAllBytes($file))
  $script:Vault['sign_seed'] = [OtrVault]::ToHex($k.Seed); $script:Vault['sign_public'] = [OtrVault]::ToHex($k.Public)
  $script:Vault['sign_fingerprint'] = $k.Hex(); $script:Vault['sign_created'] = [long]$k.Created; $script:Vault['sign_user'] = [string]$k.User
  Save-Vault
  $k
}
# a new key of the site, made here (random, Ed25519) and kept only in the vault; its public half is Export-VaultPublicKey
function New-VaultSiteKey([string]$user) {
  $k = [OtrVault]::NewSigningKey($user, [uint32][DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
  $script:Vault['sign_seed'] = [OtrVault]::ToHex($k.Seed); $script:Vault['sign_public'] = [OtrVault]::ToHex($k.Public)
  $script:Vault['sign_fingerprint'] = $k.Hex(); $script:Vault['sign_created'] = [long]$k.Created; $script:Vault['sign_user'] = $user
  Save-Vault
  $k
}
# update-key.asc for the devices: the public key with its self-signature (the same file every time)
function Export-VaultPublicKey([string]$file) {
  $k = Get-VaultSigningKey; if (-not $k) { throw (Get-Text 'VaultNoSigningKey') }
  [IO.File]::WriteAllText($file, [OtrVault]::ExportPublic($k), [Text.Encoding]::ASCII)
  $k
}
# The public site key to one device over SSH (the key of the vault), checked and installed there by site-key.sh:
# the first time it cannot come through the folder (whoever may write there would choose the key) nor, outside
# the project, signed by the project key. $null = done, else the reason.
function Send-SiteKey($d, [string]$sshKey, [string]$armored) {
  $ip = ([string]$d.S['IP']) -replace '/.*$', ''
  if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return (Get-Text 'ErrRemoteNoIp') }
  if ($d.S['CFG_SSH'] -ne 'on') { return (Get-Text 'SendKeyNoSsh') }
  $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($armored))
  $r = Invoke-DeviceSsh $ip "test -x /opt/openthinrdp/site-key.sh || { echo ERROR=old; exit 1; }; echo $b64 | base64 -d | sudo /opt/openthinrdp/site-key.sh install" $sshKey
  if ($r.Text -match '(?m)^OK=([0-9A-F]{40})') { return $null }
  if ($r.Text -match '(?m)^ERROR=old') { return (Get-Text 'SendKeyOldVersion') }
  if ($r.Text -match '(?m)^ERROR=(.+)$') { return $Matches[1] }
  $t = $r.Text.Trim(); if ($t) { $t } else { "ssh $($r.Code)" }
}
# the key that signs the releases again before they go into updates\: the site key of the vault (not the project key,
# whose signature the release already has); $null = vault closed or no site key
function Get-ResignKey {
  $k = Get-VaultSigningKey
  if ($k -and (Get-SigningKeyRole $k.Hex()) -eq 'own') { $k } else { $null }
}
function Get-VaultSigningKey {
  if (-not (Test-VaultOpen) -or -not $script:Vault['sign_seed']) { return $null }
  $k = New-Object 'OtrVault+SigningKey'
  $k.Seed = [OtrVault]::FromHex($script:Vault['sign_seed']); $k.Public = [OtrVault]::FromHex($script:Vault['sign_public'])
  $k.Fingerprint = [OtrVault]::FromHex($script:Vault['sign_fingerprint']); $k.Created = [uint32]$script:Vault['sign_created']; $k.User = $script:Vault['sign_user']
  $k
}
# project = the key of the GitHub releases (rootfs/opt/openthinrdp/keys next to this tool), own = any other: the
# devices accept it only as update-key.asc of their image
function Get-SigningKeyRole([string]$fingerprint) {
  try { if ((Test-Path -LiteralPath $script:ReleaseKey) -and ([OtrVault]::Fingerprints([IO.File]::ReadAllBytes($script:ReleaseKey)) -contains $fingerprint)) { return 'project' } } catch { }
  'own'
}
# Signs the LATEST.txt of an update package (make-update.sh without -k): its format is checked, and the package
# next to it against its hash when it is there; the signature is checked again before LATEST.txt.sig is written.
function Invoke-SignUpdate([string]$file) {
  $k = Get-VaultSigningKey
  if (-not $k) { throw (Get-Text 'VaultNoSigningKey') }
  $i = Read-LatestFile $file
  if (-not $i.Ok) { throw (Get-Text 'SignNotValid' $file) }
  $pkg = Join-Path (Split-Path -LiteralPath $file) $i.File
  $has = Test-Path -LiteralPath $pkg
  if ($has -and (Get-FileHash -LiteralPath $pkg -Algorithm SHA256).Hash.ToLower() -ne $i.Hash) { throw (Get-Text 'SignBadHash' $i.File) }
  $data = [IO.File]::ReadAllBytes($file)
  $sig = [OtrVault]::SignDetached($k, $data, [uint32][DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
  if (-not [OtrVault]::VerifyDetached($k.Public, $data, $sig)) { throw (Get-Text 'SignCheckFailed') }
  [IO.File]::WriteAllText("$file.sig", $sig, [Text.Encoding]::ASCII)
  [pscustomobject]@{ Version = $i.Version; Fingerprint = $k.Hex(); Role = (Get-SigningKeyRole $k.Hex()); PackageChecked = $has; Signature = "$file.sig" }
}

# ---------------------------------------------------------------------------------------------
# Writing the .conf files: replaces the existing lines (also commented ones) and keeps the comments
#   $managed = KEY -> value (active line) or $null (commented line: not managed from here)
#   $renameMac = MAC of a device being renamed ('' = remove the mark, $null = leave it as it is)
# ---------------------------------------------------------------------------------------------
$script:RenameRx = '^#\s*rename-mac:\s*([0-9A-Fa-f:]{17})'
function Write-ConfFile($f, $managed, [string[]]$header, $renameMac = $null) {
  if (-not (Test-Path -LiteralPath $script:ConfigDir)) { New-Item -ItemType Directory -Path $script:ConfigDir | Out-Null }
  $lines = New-Object System.Collections.Generic.List[string]
  if (Test-Path -LiteralPath $f) { foreach ($l in (Read-Lines $f)) { $lines.Add($l) } } else { foreach ($l in $header) { $lines.Add($l) } }
  while ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
  $before = Read-ConfFile $f
  $added = @()
  foreach ($k in @($managed.Keys)) {
    $v = $managed[$k]
    $idx = @(); for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -cmatch "^\s*#?\s*$k\s*=") { $idx += $i } }
    $active = @($idx | Where-Object { $lines[$_] -notmatch '^\s*#' })
    if ($null -ne $v) {
      $at = if ($active.Count) { $active[0] } elseif ($idx.Count) { $idx[0] } else { -1 }
      if ($at -ge 0) { $lines[$at] = "$k=$v" } else { $added += "$k=$v" }
      foreach ($i in ($active | Where-Object { $_ -ne $at } | Sort-Object -Descending)) { $lines.RemoveAt($i) }
    } else {
      foreach ($i in $active) { $lines[$i] = '#' + $lines[$i].Trim() }
    }
  }
  if ($added.Count) { $lines.Add(''); $lines.Add("# added by the OpenThinRDP manager on $(Get-Date -Format 'yyyy-MM-dd HH:mm')"); foreach ($a in $added) { $lines.Add($a) } }
  # the MAC mark lets the rename completion recognize the device: the device deletes its status files
  # under the old name, so the old status cannot be compared any more
  if ($null -ne $renameMac) {
    for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i] -match $script:RenameRx) { $lines.RemoveAt($i) } }
    if ($renameMac) { $lines.Add("# rename-mac: $renameMac   (rename pending: identifies the device under its new name)") }
  }
  # backup copy and change log
  if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f -Destination (Get-BackupPath $f) }
  [IO.File]::WriteAllText($f, (($lines -join "`r`n") + "`r`n"), $script:Utf8)
  $after = Read-ConfFile $f
  $diff = @()
  foreach ($k in (@($before.Keys) + @($after.Keys) | Select-Object -Unique)) {
    $a = if ($before.Contains($k)) { $before[$k] } else { '(not managed)' }
    $b = if ($after.Contains($k)) { $after[$k] } else { '(not managed)' }
    if ($a -cne $b) {
      if ($k -in 'WIFI_PSK', 'SETTINGS_PIN_SHA256') { $a = $a -replace '^([0-9a-f]{64}|pbkdf2-sha256:.*)$', '(hash)'; $b = $b -replace '^([0-9a-f]{64}|pbkdf2-sha256:.*)$', '(new hash)' }
      $diff += "$k`: $a -> $b"
    }
  }
  if ($diff.Count) { Add-ChangeLog ("{0}: {1}" -f [IO.Path]::GetFileName($f), ($diff -join '; ')) }
  $diff
}
# config\backup\<name>-<time><ext>; a second save within the same second gets -2, -3... instead of
# overwriting the first copy
function Get-BackupPath($file) {
  if (-not (Test-Path -LiteralPath $script:BackupDir)) { New-Item -ItemType Directory -Path $script:BackupDir | Out-Null }
  $base = Join-Path $script:BackupDir ("{0}-{1:yyyyMMdd-HHmmss}" -f [IO.Path]::GetFileNameWithoutExtension($file), (Get-Date))
  $ext = [IO.Path]::GetExtension($file); $p = "$base$ext"; $n = 1
  while (Test-Path -LiteralPath $p) { $n++; $p = "$base-$n$ext" }
  $p
}
function Add-ChangeLog($text) {
  $line = "{0:yyyy-MM-dd HH:mm:ss} {1} {2}" -f (Get-Date), $env:USERNAME, $text
  [IO.File]::AppendAllText($script:ChangeLog, $line + "`r`n", $script:Utf8)
}
$script:HostHeader = @(
  '# Exceptions for ONE device (written by the OpenThinRDP manager).',
  '# They win over common.conf. Lines starting with # are not managed from here (common.conf or the device decide).',
  '')
$script:CommonHeader = @(
  '# Settings for EVERY device (written by the OpenThinRDP manager).',
  '# An active key wins over the settings dialog of each device. Lines starting with # are not managed from here.',
  '')

# ---------------------------------------------------------------------------------------------
# Save plans: checks and final values, without the window (the window only asks and shows)
# ---------------------------------------------------------------------------------------------
# configuration of a device after the save: what it reports now + common.conf + its own file
function Get-EffectiveConfig($status, $common, $hostConf) {
  $r = @{}
  foreach ($s in $script:Settings) {
    $k = $s.Key; if ($k -eq 'WIFI_PSK') { continue }
    $r[$k] = if ($k -eq 'HOSTNAME') { $status['HOSTNAME'] } else { $status["CFG_$k"] }
    if (-not $s.HostOnly -and $common.Contains($k) -and $null -ne $common[$k]) { $r[$k] = ConvertTo-Canonical $k $common[$k] }
    if ($hostConf.Contains($k) -and $null -ne $hostConf[$k]) { $r[$k] = ConvertTo-Canonical $k $hostConf[$k] }
  }
  $r
}

function Get-DeviceSavePlan($dev, $managed) {
  $err = @(); $notes = @()
  foreach ($k in @($managed.Keys)) { if ($null -ne $managed[$k]) { $e = Test-SettingValue $k $managed[$k]; if ($e) { $err += $e } } }
  $common = Read-ConfFile $script:CommonFile
  $hostVals = @{}; foreach ($k in @($managed.Keys)) { if ($null -ne $managed[$k] -and $k -ne 'WIFI_PSK') { $hostVals[$k] = $managed[$k] } }
  if (-not $err.Count) { $r = Get-EffectiveConfig $dev.S $common $hostVals; $err += @(Test-EffectiveConfig $r $dev.S) }
  $f = Get-HostFile $dev.Name
  $before = Read-ConfFile $f
  $final = [ordered]@{}
  foreach ($k in @($managed.Keys)) {
    $v = $managed[$k]
    if ($null -eq $v) { $final[$k] = $null }
    elseif ($k -eq 'WIFI_PSK') {
      # the WPA key depends on the SSID: computed here for the network the device will use
      $ssid = if ($err.Count) { $null } else { $r['WIFI_SSID'] }
      if ($err.Count) { }
      elseif (-not $ssid) { $err += Get-Text 'ErrPskNeedsSsid' }
      elseif ($v -eq $script:MarkSaved) {
        # the saved key was computed for the SSID in force when it was written: this file, else common.conf,
        # else the device's own
        $oldSsid = if ($before.Contains('WIFI_SSID')) { $before['WIFI_SSID'] } elseif ($common.Contains('WIFI_SSID')) { $common['WIFI_SSID'] } else { $dev.S['CFG_WIFI_SSID'] }
        if (-not $before['WIFI_PSK']) { $err += Get-Text 'ErrPskNoKeyDevice' }
        elseif ($oldSsid -cne $ssid) { $err += Get-Text 'ErrPskOtherNetwork' $oldSsid }
        else { $final[$k] = $before['WIFI_PSK'] }
      } else { $final[$k] = ConvertTo-WpaKey $v $ssid }
    }
    elseif ($k -eq 'SETTINGS_PIN_SHA256') {
      if ($v -eq $script:MarkSet) { if ($before.Contains($k)) { $final[$k] = $before[$k] } else { $err += Get-Text 'ErrPinNoneDevice' } }
      else { $final[$k] = ConvertTo-PinHash $v }
    }
    else { $final[$k] = ConvertTo-Canonical $k $v }
  }
  $changes = @(); foreach ($k in @($final.Keys)) {
    $a = if ($before.Contains($k)) { $before[$k] } else { $null }
    if ($a -cne $final[$k]) { $changes += "$((Get-Setting $k).Label): $(Format-Value $k $a) -> $(Format-Value $k $final[$k])" }
  }
  $mac = ''
  if ($null -ne $final['HOSTNAME'] -and $final['HOSTNAME'] -ne $dev.Name) {
    $mac = [string]$dev.S['MAC']
    $notes += Get-Text 'NoteRename' $final['HOSTNAME']
  }
  if ($null -ne $final['NETMODE'] -or $null -ne $final['IPADDR']) { $notes += Get-Text 'NoteNetwork' }
  [pscustomobject]@{ File = $f; Errors = $err; Values = $final; Changes = $changes; Notes = $notes; RenameMac = $mac }
}

function Get-CommonSavePlan($managed, $devices) {
  $err = @(); $warn = @(); $notes = @()
  foreach ($k in @($managed.Keys)) {
    if ($script:HostOnly -contains $k -and $null -ne $managed[$k]) { $err += Get-Text 'ErrHostOnlyInCommon' $k; continue }
    if ($null -ne $managed[$k]) { $e = Test-SettingValue $k $managed[$k]; if ($e) { $err += $e } }
  }
  $before = Read-ConfFile $script:CommonFile
  $final = [ordered]@{}
  foreach ($k in @($managed.Keys)) {
    $v = $managed[$k]
    if ($null -eq $v) { $final[$k] = $null }
    elseif ($k -eq 'WIFI_PSK') {
      # every device computes nothing: the key in common.conf is valid only for the SSID managed here too
      $ssid = $managed['WIFI_SSID']
      if (-not $ssid) { $err += Get-Text 'ErrPskNeedsSsidCommon' }
      elseif ($v -eq $script:MarkSaved) {
        if (-not $before['WIFI_PSK']) { $err += Get-Text 'ErrPskNoKeyCommon' }
        elseif ($before['WIFI_SSID'] -cne $ssid) { $err += Get-Text 'ErrPskOtherNetwork' $before['WIFI_SSID'] }
        else { $final[$k] = $before['WIFI_PSK'] }
      } else { $final[$k] = ConvertTo-WpaKey $v $ssid }
    }
    elseif ($k -eq 'SETTINGS_PIN_SHA256') {
      if ($v -eq $script:MarkSet) { if ($before.Contains($k)) { $final[$k] = $before[$k] } else { $err += Get-Text 'ErrPinNoneCommon' } }
      else { $final[$k] = ConvertTo-PinHash $v }
    }
    else { $final[$k] = ConvertTo-Canonical $k $v }
  }
  # combinations that every device would reject, whatever it has of its own
  if ($final['WEB_BUTTON'] -in 'app', 'browser' -and $final['WEB_URL'] -eq '') { $err += Get-Text 'ErrWebEmptyAll' $final['WEB_BUTTON'] }
  if ($final['WEB_BUTTON'] -eq 'kiosk' -and $final['KIOSK_URL'] -eq '') { $err += Get-Text 'ErrKioskEmptyAll' }
  if ($final['WIFI'] -eq 'on' -and $final['WIFI_SSID'] -eq '') { $err += Get-Text 'ErrWifiEmptyAll' }
  if ($final['UPDATE_FROM'] -eq 'share' -and $final['MGMT_SHARE'] -eq '') { $err += Get-Text 'ErrUpdateNeedsShare' }
  if (-not $err.Count) {
    # each known device as it will be: a device that rejects keeps its previous configuration (all of it)
    $commonVals = @{}; foreach ($k in @($final.Keys)) { if ($null -ne $final[$k]) { $commonVals[$k] = $final[$k] } }
    foreach ($d in @($devices | Where-Object { -not $_.OldName })) {
      $hc = Read-ConfFile (Get-HostFile $d.Name)
      foreach ($e in @(Test-EffectiveConfig (Get-EffectiveConfig $d.S $commonVals $hc) $d.S)) { $warn += "$($d.Name): $e" }
      # a key of its own computed with the SSID of common.conf goes wrong when that SSID changes
      if ($hc.Contains('WIFI_PSK') -and -not $hc.Contains('WIFI_SSID') -and $null -ne $final['WIFI_SSID'] -and $final['WIFI_SSID'] -cne $before['WIFI_SSID']) {
        $warn += Get-Text 'WarnOwnWifiKey' $d.Name $before['WIFI_SSID']
      }
    }
  }
  $changes = @(); foreach ($k in @($final.Keys)) {
    $a = if ($before.Contains($k)) { $before[$k] } else { $null }
    if ($a -cne $final[$k]) { $changes += "$((Get-Setting $k).Label): $(Format-Value $k $a) -> $(Format-Value $k $final[$k])" }
  }
  $risky = @($final.Keys | Where-Object { $_ -in 'BROKER', 'DOMAIN', 'LOAD_BALANCE_INFO', 'MGMT_SHARE', 'NETMASK', 'GATEWAY', 'DNS1', 'WIFI', 'SSH', 'SETTINGS_PIN_SHA256' } |
             Where-Object { $(if ($before.Contains($_)) { $before[$_] } else { $null }) -cne $final[$_] })
  if ($risky.Count) { $notes += Get-Text 'NoteRisky' ($risky -join ', ') }
  [pscustomobject]@{ File = $script:CommonFile; Errors = $err; Warnings = $warn; Values = $final; Changes = $changes; Notes = $notes }
}

# keys in a .conf that the devices ignore: unknown, or device-only keys in common.conf. MGMT_PASSWORD is used by
# the devices although this tool does not edit it (a password is written in the file by hand, or set on the device)
function Get-IgnoredKeys($conf, [switch]$Common) {
  @($conf.Keys | Where-Object { (-not (Get-Setting $_) -and $_ -ne 'MGMT_PASSWORD') -or ($Common -and $script:HostOnly -contains $_) })
}

# ---------------------------------------------------------------------------------------------
# SSH keys: config\authorized_keys. The device keeps only the lines in this format (comments and
# anything else are dropped), and an EMPTY file removes every key, while a MISSING file leaves the
# last keys in place: so this tool never deletes the file.
# ---------------------------------------------------------------------------------------------
function Test-AuthorizedKeys([string]$text) {
  $err = @(); $n = 0
  foreach ($l in ($text -split "`r?`n")) {
    $n++; $t = $l.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    if ($t -cnotmatch $script:Rx.SshKey) { $err += Get-Text 'ErrKeyLine' $n }
  }
  $err
}
function Get-KeyLines([string]$text) { @($text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -cmatch $script:Rx.SshKey }) }
function Get-KeyLabel([string]$line) { $p = $line -split ' ', 3; if ($p.Count -ge 3 -and $p[2]) { $p[2] } else { "$($p[0]) ...$($p[1].Substring([Math]::Max(0, $p[1].Length - 12)))" } }
function Save-AuthorizedKeys([string]$text) {
  if (-not (Test-Path -LiteralPath $script:ConfigDir)) { New-Item -ItemType Directory -Path $script:ConfigDir | Out-Null }
  $old = if (Test-Path -LiteralPath $script:KeysFile) { Get-KeyLines ((Read-Lines $script:KeysFile) -join "`n") } else { @() }
  $new = Get-KeyLines $text
  $out = @($text -split "`r?`n" | ForEach-Object { $_.TrimEnd() })
  while ($out.Count -gt 0 -and $out[$out.Count - 1] -eq '') { $out = @($out | Select-Object -First ($out.Count - 1)) }
  if (Test-Path -LiteralPath $script:KeysFile) { Copy-Item -LiteralPath $script:KeysFile -Destination (Get-BackupPath $script:KeysFile) }
  [IO.File]::WriteAllText($script:KeysFile, $(if ($out.Count) { ($out -join "`r`n") + "`r`n" } else { '' }), $script:Utf8)
  $plus = @($new | Where-Object { $old -cnotcontains $_ } | ForEach-Object { Get-KeyLabel $_ })
  $minus = @($old | Where-Object { $new -cnotcontains $_ } | ForEach-Object { Get-KeyLabel $_ })
  if ($plus.Count -or $minus.Count) {
    Add-ChangeLog ("authorized_keys: {0} -> {1} keys{2}{3}" -f $old.Count, $new.Count, $(if ($plus.Count) { "; added: $($plus -join ', ')" } else { '' }), $(if ($minus.Count) { "; removed: $($minus -join ', ')" } else { '' }))
  }
  [pscustomobject]@{ Before = $old.Count; After = $new.Count; Added = $plus; Removed = $minus }
}

# ---------------------------------------------------------------------------------------------
# Rename: <old>.conf with HOSTNAME=<new> stays until the device reports with the new name (same MAC);
# then it becomes <new>.conf, otherwise the device would lose its exceptions under the new name
# ---------------------------------------------------------------------------------------------
function Complete-Renames {
  $done = @()
  if (-not (Test-Path -LiteralPath $script:ConfigDir)) { return @() }
  foreach ($f in @(Get-ChildItem -LiteralPath $script:ConfigDir -Filter '*.conf' -File -ErrorAction SilentlyContinue | Where-Object Extension -eq '.conf')) {
    $old = $f.BaseName; if ($old -eq 'common') { continue }
    $c = Read-ConfFile $f.FullName; $new = $c['HOSTNAME']
    if (-not $new -or $new -eq $old) { continue }
    $newStatus = Join-Path $script:StatusDir "$new.txt"; $oldStatus = Join-Path $script:StatusDir "$old.txt"
    if (-not (Test-Path -LiteralPath $newStatus)) { continue }
    $sn = Read-StatusFile $newStatus
    $mark = @(Read-Lines $f.FullName | Where-Object { $_ -match $script:RenameRx } | ForEach-Object { [regex]::Match($_, $script:RenameRx).Groups[1].Value }) | Select-Object -First 1
    if ($mark) {
      if ($sn['MAC'] -ne $mark) { continue }                                   # another device with that name
    } else {
      # file written by hand, no MAC mark: the report must come after the file, and the old status (if
      # still there) must be the same device
      $when = Get-ReportTime $sn; if (-not $when -or $when -le $f.LastWriteTime) { continue }
      if ((Test-Path -LiteralPath $oldStatus) -and (Read-StatusFile $oldStatus)['MAC'] -ne $sn['MAC']) { continue }
    }
    $dest = Get-HostFile $new
    if (Test-Path -LiteralPath $dest) { continue }                             # never overwritten
    $lines = @(Read-Lines $f.FullName | Where-Object { $_ -cnotmatch '^\s*#?\s*HOSTNAME\s*=' -and $_ -notmatch $script:RenameRx })
    # the removed lines can leave an "# added by..." line with nothing under it at the end
    $n = $lines.Count; while ($n -gt 0 -and ($lines[$n - 1] -eq '' -or $lines[$n - 1] -like '# added by the OpenThinRDP manager*')) { $n-- }
    $lines = @($lines | Select-Object -First $n)
    [IO.File]::WriteAllText($dest, (($lines -join "`r`n").TrimEnd() + "`r`n"), $script:Utf8)
    Move-Item -LiteralPath $f.FullName -Destination (Get-BackupPath $f.FullName)
    # status under the old name: the device removes it itself; one left behind (folder unreachable at that
    # moment) would stay in the list forever
    $prev = Join-Path $script:StatusDir 'previous-names'
    foreach ($s in @("$old.txt", "$old-events.log")) {
      $p = Join-Path $script:StatusDir $s
      if (Test-Path -LiteralPath $p) { if (-not (Test-Path -LiteralPath $prev)) { New-Item -ItemType Directory -Path $prev | Out-Null }; Move-Item -LiteralPath $p -Destination (Join-Path $prev $s) -Force }
    }
    # logo and background picture of the device follow it
    $bo = Get-BrandingDir $old; $bn = Get-BrandingDir $new
    if ((Test-Path -LiteralPath $bo) -and -not (Test-Path -LiteralPath $bn)) { Move-Item -LiteralPath $bo -Destination $bn }
    Add-ChangeLog ("rename completed: {0} -> {1} ({0}.conf becomes {1}.conf)" -f $old, $new)
    $done += "$old -> $new"
  }
  $done
}

# ---------------------------------------------------------------------------------------------
# Logo and background picture: config\branding\<kind>.png for every device, config\branding\<hostname>\<kind>.png for
# one (branding.sh on the device; the device file wins). Any picture is scaled down to fit and saved as PNG:
# the devices accept only PNG files up to 2 MB, logo up to 400 x 240, background up to 1024 x 640.
# ---------------------------------------------------------------------------------------------
$script:BrandingSize = @{ logo = @(300, 120); splash = @(640, 400) }
function Get-BrandingDir([string]$hostName = '') {
  $d = Join-Path $script:ConfigDir 'branding'; if ($hostName) { Join-Path $d $hostName } else { $d }
}
function Get-BrandingFile([string]$kind, [string]$hostName = '') { Join-Path (Get-BrandingDir $hostName) "$kind.png" }
# the picture a device shows: its own, else the common one, else the image's own (File = $null)
function Get-BrandingSource([string]$kind, [string]$hostName = '') {
  if ($hostName) { $f = Get-BrandingFile $kind $hostName; if (Test-Path -LiteralPath $f) { return [pscustomobject]@{ From = 'device'; File = $f } } }
  $f = Get-BrandingFile $kind; if (Test-Path -LiteralPath $f) { return [pscustomobject]@{ From = 'common'; File = $f } }
  [pscustomobject]@{ From = 'image'; File = $null }
}
# a copy in memory: Image.FromFile would keep the file locked until the window closes
function Read-Picture([string]$file) {
  $ms = New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($file))
  try { $i = [System.Drawing.Image]::FromStream($ms); try { New-Object System.Drawing.Bitmap($i) } finally { $i.Dispose() } } finally { $ms.Dispose() }
}
function Save-BrandingImage([string]$source, [string]$kind, [string]$hostName = '') {
  $max = $script:BrandingSize[$kind]
  try { $img = Read-Picture $source } catch { throw (Get-Text 'BrandLoadFailed' $_.Exception.Message) }
  try {
    # [double]: 640 / 640 is an Int32 in PowerShell, and Min(Int32, Double) would round the other ratio to 1
    $k = [Math]::Min(1.0, [Math]::Min([double]$max[0] / $img.Width, [double]$max[1] / $img.Height))
    $w = [Math]::Max(1, [int][Math]::Round($img.Width * $k)); $h = [Math]::Max(1, [int][Math]::Round($img.Height * $k))
    $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
      $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'; $g.CompositingQuality = 'HighQuality'
      $g.Clear([System.Drawing.Color]::Transparent)
      # TileFlipXY: no half transparent frame along the edges when scaling down
      $ia = New-Object System.Drawing.Imaging.ImageAttributes; $ia.SetWrapMode('TileFlipXY')
      $g.DrawImage($img, (New-Object System.Drawing.Rectangle(0, 0, $w, $h)), 0, 0, $img.Width, $img.Height, 'Pixel', $ia)
    } finally { $g.Dispose() }
  } finally { $img.Dispose() }
  $dest = Get-BrandingFile $kind $hostName
  $dir = Split-Path $dest; if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  # written aside first: a device never reads half a file (it reads only <kind>.png)
  $tmp = "$dest.new"
  try { $bmp.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $bmp.Dispose() }
  if ((Get-Item -LiteralPath $tmp).Length -gt 2MB) { Remove-Item -LiteralPath $tmp; throw (Get-Text 'BrandTooBig') }
  $rel = if ($hostName) { "branding\$hostName\$kind.png" } else { "branding\$kind.png" }
  if (Test-Path -LiteralPath $dest) { Move-Item -LiteralPath $dest -Destination (Get-BackupPath ($rel -replace '\\', '-')) }
  Move-Item -LiteralPath $tmp -Destination $dest
  Add-ChangeLog ("{0}: new picture {1} x {2} px (from {3})" -f $rel, $w, $h, [IO.Path]::GetFileName($source))
  [pscustomobject]@{ File = $dest; Width = $w; Height = $h }
}
function Remove-BrandingImage([string]$kind, [string]$hostName = '') {
  $dest = Get-BrandingFile $kind $hostName
  if (-not (Test-Path -LiteralPath $dest)) { return $false }
  $rel = if ($hostName) { "branding\$hostName\$kind.png" } else { "branding\$kind.png" }
  Move-Item -LiteralPath $dest -Destination (Get-BackupPath ($rel -replace '\\', '-'))
  # an empty device folder would stay forever after the device is gone
  if ($hostName -and -not @(Get-ChildItem -LiteralPath (Get-BrandingDir $hostName) -Force).Count) { Remove-Item -LiteralPath (Get-BrandingDir $hostName) }
  Add-ChangeLog "${rel}: removed"
  $true
}

# ---------------------------------------------------------------------------------------------
# Permissions of the management folder (docs/management.md#account). Every device can read the password of
# its account, so that account must be able to write in status\ only: settings, logos and updates read-only.
# Read from the NTFS permissions; the permissions of the share can only take rights away.
# ---------------------------------------------------------------------------------------------
# rights that change something: write/create, append/create folders, extended attributes, delete children,
# attributes, delete, permissions, owner
$script:WriteMask = 0x2 -bor 0x4 -bor 0x10 -bor 0x40 -bor 0x100 -bor 0x10000 -bor 0x40000 -bor 0x80000
# Administrators, SYSTEM, CREATOR OWNER, and (any domain) Domain Admins, Enterprise Admins: expected to write
$script:AdminSid = '^(S-1-5-32-544|S-1-5-18|S-1-3-0|S-1-5-21-.+-(512|519))$'
# groups that mean "every user": Everyone, Authenticated Users, NETWORK, Users, Domain Users
$script:EveryoneSid = '^(S-1-1-0|S-1-5-11|S-1-5-2|S-1-5-32-545|S-1-5-21-.+-513)$'

# the account the devices use: what they report (MGMT_ACCOUNT, since 0.1.6), else MGMT_USER of common.conf
function Get-MgmtAccounts($devices) {
  $a = @($devices | ForEach-Object { $_.S['MGMT_ACCOUNT'] } | Where-Object { $_ -and $_ -ne 'none' })
  if (-not $a.Count) {
    $c = Read-ConfFile $script:CommonFile
    if ($c['MGMT_USER']) { $a = @(if ($c['MGMT_USER'] -match '[\\@]' -or -not $c['DOMAIN']) { $c['MGMT_USER'] } else { "$($c['DOMAIN'])\$($c['MGMT_USER'])" }) }
  }
  @($a | Sort-Object -Unique)
}
function Get-SidName([string]$sid) {
  try { (New-Object Security.Principal.SecurityIdentifier $sid).Translate([Security.Principal.NTAccount]).Value } catch { $sid }
}
# the SIDs that count for an account: itself, its domain groups (nested too) and the groups every signed-in
# account is in on a file server
function Get-AccountSids([string]$account) {
  $sid = (New-Object Security.Principal.NTAccount $account).Translate([Security.Principal.SecurityIdentifier]).Value
  $sids = @($sid, 'S-1-1-0', 'S-1-5-11', 'S-1-5-2', 'S-1-5-32-545')
  try {
    $de = New-Object DirectoryServices.DirectoryEntry "LDAP://<SID=$sid>"
    $de.RefreshCache([string[]]@('tokenGroups'))
    foreach ($b in $de.Properties['tokenGroups']) { $sids += (New-Object Security.Principal.SecurityIdentifier ([byte[]]$b), 0).Value }
  } catch { }   # local account or no domain controller: the account and the groups of everybody
  @($sids | Sort-Object -Unique)
}
# rights of an access rule as plain file rights (generic rights mapped the way NTFS maps them)
function Get-RuleMask($rule) {
  $m = [int64]([int]$rule.FileSystemRights) -band 0xFFFFFFFFL
  if ($m -band 0x10000000) { $m = $m -bor 0x1F01FF }   # GENERIC_ALL
  if ($m -band 0x40000000) { $m = $m -bor 0x116 }      # GENERIC_WRITE
  if ($m -band 0x80000000) { $m = $m -bor 0x120089 }   # GENERIC_READ
  $m -band 0x1F01FF
}
# what $sids may do on $path, and who gives write rights: to them, and to anybody else who is not an
# administrator. Windows reads the rules in their order and the first one that allows or denies a right
# decides it: a Deny after an Allow of the same right changes nothing (an inherited Deny comes after an
# explicit Allow, and the rules of the parent folder before those of the grandparent).
function Get-PathAccess([string]$path, [string[]]$sids) {
  $granted = 0L; $denied = 0L; $via = @(); $others = @()
  $rules = (Get-Acl -LiteralPath $path).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
  foreach ($r in $rules) {
    if ($r.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
    $id = $r.IdentityReference.Value; $m = Get-RuleMask $r
    if ($sids -contains $id) {
      $new = $m -band (-bnot ($granted -bor $denied))
      if ($r.AccessControlType -eq 'Deny') { $denied = $denied -bor $new }
      else { $granted = $granted -bor $new; if ($new -band $script:WriteMask) { $via += $id } }
    }
    elseif ($r.AccessControlType -eq 'Allow' -and ($m -band $script:WriteMask) -and $id -notmatch $script:AdminSid) { $others += $id }
  }
  [pscustomobject]@{ Mask = $granted; Via = @($via | Sort-Object -Unique); Others = @($others | Sort-Object -Unique) }
}
# the check: one line per finding, Problem = something to correct
function Test-FolderPermissions([string]$account) {
  $out = New-Object Collections.ArrayList
  $add = { param($problem, $text) [void]$out.Add([pscustomobject]@{ Problem = $problem; Text = $text }) }
  try { $sids = Get-AccountSids $account } catch { & $add $true (Get-Text 'PermUnknownAccount' $account); return $out }
  $names = { param($l) (@($l | ForEach-Object { Get-SidName $_ }) -join ', ') }
  $st = Get-PathAccess $script:StatusDir $sids
  if (($st.Mask -band 0x7) -eq 0x7) { & $add $false (Get-Text 'PermStatusOk') } else { & $add $true (Get-Text 'PermStatusNoWrite') }
  # read-only places: the folder itself, config\ with logos (not backup\: only the manager uses it), updates\
  $ro = @($script:Folder, $script:ConfigDir)
  $bd = Join-Path $script:ConfigDir 'branding'
  if (Test-Path -LiteralPath $bd) { $ro += @($bd) + @(Get-ChildItem -LiteralPath $bd -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object FullName) }
  $ro += @(Get-ChildItem -LiteralPath $script:ConfigDir -File -Force -ErrorAction SilentlyContinue | ForEach-Object FullName)
  $ud = Join-Path $script:Folder 'updates'
  if (Test-Path -LiteralPath $ud) { $ro += @($ud) + @(Get-ChildItem -LiteralPath $ud -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object FullName) }
  # the same finding on many files = one line: text key + who, with the places
  $found = [ordered]@{}
  $note = { param($key, $who, $rel) $k = "$key|$who"; if (-not $found.Contains($k)) { $found[$k] = New-Object Collections.ArrayList }; [void]$found[$k].Add($rel) }
  $root = $script:Folder.TrimEnd('\') + '\'
  foreach ($p in $ro) {
    $a = Get-PathAccess $p $sids
    $dir = (Get-Item -LiteralPath $p -Force).PSIsContainer
    $rel = if ($p -eq $script:Folder) { Get-Text 'PermTheFolder' } else { $p.Substring($root.Length) + $(if ($dir) { '\' } else { '' }) }
    if ($a.Mask -band $script:WriteMask) { & $note 'PermDevicesWrite' (& $names $a.Via) $rel }
    $every = @($a.Others | Where-Object { $_ -match $script:EveryoneSid })
    if ($every.Count) { & $note 'PermEveryoneWrites' (& $names $every) $rel }
    if ($dir -and -not ($a.Mask -band 0x1)) { & $note 'PermNoRead' '' $rel }
  }
  foreach ($k in $found.Keys) {
    $key, $who = $k -split '\|', 2; $l = $found[$k]
    $where = (@($l | Select-Object -First 4) -join ', ') + $(if ($l.Count -gt 4) { ' ' + (Get-Text 'PermMore' ($l.Count - 4)) } else { '' })
    & $add $true (Get-Text $key $where $who)
  }
  if (-not @($out | Where-Object Problem).Count) { & $add $false (Get-Text 'PermReadOnlyOk') }
  $out
}

# ---------------------------------------------------------------------------------------------
# Problems: the event logs of all devices (status\<hostname>-events.log) read together, so that a broker refusing
# sign-ins on six devices this morning shows as one line, not as six files nobody opens.
# Each rule: the kind (text Prob_<kind> in lang\*.psd1) and the event it recognizes; named groups user, broker,
# code, where (what the line is grouped by besides the kind).
# ---------------------------------------------------------------------------------------------
$script:ProblemRules = @(
  @{ K = 'AttemptFailed'; R = '^attempt \d+ for (?<user>\S+) on (?<broker>\S+) failed after \d+s \(code (?<code>\d+), (?<where>\w+)\)' }
  @{ K = 'DesktopUnavailable'; R = '^desktop not available for (?<user>\S+) after \d+ attempts: (?<where>\S*)' }
  @{ K = 'SignInRefused'; R = '^sign-in refused for (?<user>\S+) \(code (?<code>\d+)\)' }
  @{ K = 'NoNetwork'; R = '^attempt \d+ for (?<user>\S+): no network' }
  @{ K = 'Dropped'; R = '^session of (?<user>\S+) DROPPED after [^(]*\((?<where>.+), code (?<code>\d+)\)' }
  @{ K = 'TooManyDrops'; R = '^too many drops in a row for (?<user>\S+)' }
  @{ K = 'TakenOver'; R = '^session of (?<user>\S+) (disconnected after .* while its VM still runs|taken over by another device)' }
  @{ K = 'Watchdog'; R = '^watchdog: ' }
  @{ K = 'UdpBlocked'; R = '^UDP only: the session of (?<user>\S+)' }
  @{ K = 'UpdateFailed'; R = '^software update (?<where>\S+) FAILED' }
  @{ K = 'ConfigRejected'; R = '^(central configuration REJECTED|settings rejected)' }
  @{ K = 'WrongPin'; R = '^settings: wrong PIN' }
)
# causes as the devices log them (kiosk.sh reason/err_class) -> texts of the manager; brokers stay as they are
$script:CauseText = @{ 'network lost' = 'CauseNetLost'; 'killed (watchdog or kill -9)' = 'CauseKilled'; 'net' = 'CauseNet'; 'dns' = 'CauseDns'
  'broker' = 'CauseBroker'; 'vm' = 'CauseVm'; 'udp' = 'CauseUdp'; 'other' = 'CauseOther' }
function Get-WhereLabel([string]$w) {
  if ($script:CauseText.ContainsKey($w)) { return (Get-Text $script:CauseText[$w]) }
  if ($w -match '^error (\d+)$') { return (Get-Text 'CauseError' $Matches[1]) }
  $w
}
$script:HostNames = @{}
# a broker given as an address shown with its name (cached: one lookup per address)
function Get-HostLabel([string]$h) {
  if ($h -notmatch '^\d+\.\d+\.\d+\.\d+$') { return ($h -split '\.')[0].ToLower() }
  if (-not $script:HostNames.ContainsKey($h)) { $script:HostNames[$h] = try { ([Net.Dns]::GetHostEntry($h).HostName -split '\.')[0].ToLower() } catch { $h } }
  $script:HostNames[$h]
}
# every problem event since $since: time, device, kind, user, broker (the server really contacted when the device
# logged it: "broker X: connecting to Y (Kerberos)"), code, where, the line itself
function Get-ProblemEvents([datetime]$since) {
  $out = New-Object Collections.ArrayList
  if (-not (Test-Path -LiteralPath $script:StatusDir)) { return @() }
  foreach ($f in @(Get-ChildItem -LiteralPath $script:StatusDir -Filter '*-events.log' -File -ErrorAction SilentlyContinue)) {
    $dev = $f.BaseName -replace '-events$', ''; $node = ''; $nodeAt = [datetime]::MinValue
    foreach ($l in (Read-Lines $f.FullName)) {
      if ($l -notmatch '^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (.*)$') { continue }
      $t = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture); $txt = $Matches[2]
      if ($txt -match '^broker \S+: connecting to (\S+)') { $node = $Matches[1]; $nodeAt = $t; continue }
      if ($t -lt $since) { continue }
      foreach ($r in $script:ProblemRules) {
        if ($txt -notmatch $r.R) { continue }
        $b = "$($Matches['broker'])"; if ($b -and $node -and ($t - $nodeAt).TotalSeconds -le 120) { $b = $node }
        [void]$out.Add([pscustomobject]@{ Time = $t; Device = $dev; Kind = $r.K; User = "$($Matches['user'])"; Broker = $(if ($b) { Get-HostLabel $b } else { '' })
          Code = "$($Matches['code'])"; Where = "$($Matches['where'])"; Text = $txt })
        break
      }
    }
  }
  @($out | Sort-Object Time)
}
# one line per kind and place (broker for sign-in failures, cause for drops): how many times, how many devices
# and users, when last. Wide = the same problem on 3 or more devices: rather the server or the network than a device.
function Get-ProblemSummary($events) {
  @($events | Group-Object { "$($_.Kind)|$(if ($_.Broker) { $_.Broker } else { $_.Where })" } | ForEach-Object {
    $k, $w = $_.Name -split '\|', 2; $g = $_.Group
    $devs = @($g.Device | Sort-Object -Unique); $users = @($g.User | Where-Object { $_ } | Sort-Object -Unique)
    [pscustomobject]@{ Kind = $k; Where = $w; Count = $g.Count; Devices = $devs; Users = $users; First = ($g | Select-Object -First 1).Time
      Last = ($g | Select-Object -Last 1).Time; Wide = ($devs.Count -ge 3); Events = $g }
  } | Sort-Object @{ Expression = 'Wide'; Descending = $true }, @{ Expression = 'Count'; Descending = $true })
}
# the headline: the problems that touched most devices, in one sentence each
function Get-ProblemHeadline($summary) {
  # an empty summary comes as $null, and @($null) has one element
  if (-not @($summary | Where-Object { $_ }).Count) { return (Get-Text 'ProbNone') }
  (@($summary | Sort-Object @{ Expression = { $_.Devices.Count }; Descending = $true }, @{ Expression = 'Count'; Descending = $true } | Select-Object -First 3 | ForEach-Object {
    Get-Text 'ProbHeadline' (Get-Text "Prob_$($_.Kind)") $(if ($_.Where) { " ($(Get-WhereLabel $_.Where))" } else { '' }) $_.Count $_.Devices.Count
  }) -join "   $([char]0x00B7)   ")
}

function Get-LastFolder {
  try { if (Test-Path -LiteralPath $script:SettingsFile) { return [string](Get-Content -LiteralPath $script:SettingsFile -Raw | ConvertFrom-Json).Folder } } catch { }
  $null
}
function Save-LastFolder($path) {
  try {
    $d = Split-Path $script:SettingsFile
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
    [IO.File]::WriteAllText($script:SettingsFile, (@{ Folder = $path } | ConvertTo-Json), $script:Utf8)
  } catch { }
}

if ($Folder) { Set-ManagementFolder $Folder }
if ($FunctionsOnly) { return }

# =============================================================================================
# Window
#   left: the pages (Devices, Common settings, SSH keys, Problems); top: the actions on the folder.
#   Devices: the list on the left, the selected device on the right (header with its actions, then Settings,
#   Summary, Events and the full report). The settings grids show the help of the selected setting in full
#   under the grid instead of a column cut after a few words.
# =============================================================================================
[System.Windows.Forms.Application]::EnableVisualStyles()
function Show-Message($title, $text, $icon = 'Warning') { [void][System.Windows.Forms.MessageBox]::Show($text, $title, 'OK', $icon) }
function Confirm-Action($title, $text, $default = 'Button1') {
  [System.Windows.Forms.MessageBox]::Show($text, $title, 'YesNo', 'Question', $default) -eq 'Yes'
}

# The access code of the vault. Open: one box; Create and Change: the code twice. $true = the vault is open (or
# created, or has the new code); $false = the administrator went on without it. Opening takes a couple of seconds
# (600000 rounds): the window says so meanwhile.
function Show-CodeDialog([ValidateSet('Open', 'Create', 'Change')][string]$mode, $owner = $null) {
  $font = New-Object System.Drawing.Font('Segoe UI', 9.75); $Width = 500
  $w = New-Object System.Windows.Forms.Form
  $w.Text = Get-Text "Vault${mode}Title"; $w.Font = $font; $w.FormBorderStyle = 'FixedDialog'; $w.MaximizeBox = $false; $w.MinimizeBox = $false
  $w.StartPosition = if ($owner) { 'CenterParent' } else { 'CenterScreen' }; $w.ShowInTaskbar = -not $owner; $w.TopMost = -not $owner
  $note = New-Object System.Windows.Forms.Label; $note.Text = Get-Text "Vault${mode}Text" $script:VaultFile $script:VaultMinCode
  # the height as the label itself wraps the text (a long path breaks inside, unlike a measure by words)
  $note.Font = $font; $nh = $note.GetPreferredSize((New-Object System.Drawing.Size(($Width - 32), 0))).Height
  $note.SetBounds(16, 14, $Width - 32, $nh + 4); $y = $note.Bottom + 12
  $l1 = New-Object System.Windows.Forms.Label; $l1.Text = Get-Text 'VaultCode'; $l1.AutoSize = $true; $l1.Location = New-Object System.Drawing.Point(16, ($y + 4))
  $t1 = New-Object System.Windows.Forms.TextBox; $t1.UseSystemPasswordChar = $true; $t1.SetBounds(180, $y, $Width - 196, 26); $y += 36
  $w.Controls.AddRange(@($note, $l1, $t1))
  $t2 = $null
  if ($mode -ne 'Open') {
    $l2 = New-Object System.Windows.Forms.Label; $l2.Text = Get-Text 'VaultCodeAgain'; $l2.AutoSize = $true; $l2.Location = New-Object System.Drawing.Point(16, ($y + 4))
    $t2 = New-Object System.Windows.Forms.TextBox; $t2.UseSystemPasswordChar = $true; $t2.SetBounds(180, $y, $Width - 196, 26); $y += 36
    $w.Controls.AddRange(@($l2, $t2))
  }
  $err = New-Object System.Windows.Forms.Label; $err.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#dc2626'); $err.SetBounds(16, $y, $Width - 32, 40); $y += 44
  $ok = New-Object System.Windows.Forms.Button; $ok.Text = Get-Text "Vault${mode}Ok"
  $no = New-Object System.Windows.Forms.Button; $no.Text = Get-Text $(if ($mode -eq 'Change' -or -not $owner) { 'BtnCancel' } else { 'VaultWithout' })
  foreach ($b in @($ok, $no)) { $b.Height = 30; $b.Width = [Math]::Max(110, [System.Windows.Forms.TextRenderer]::MeasureText($b.Text, $font).Width + 28) }
  $no.Location = New-Object System.Drawing.Point(($Width - 16 - $no.Width), $y); $ok.Location = New-Object System.Drawing.Point(($no.Left - 8 - $ok.Width), $y)
  $no.DialogResult = 'Cancel'; $w.AcceptButton = $ok; $w.CancelButton = $no
  $w.Controls.AddRange(@($err, $ok, $no)); $w.ClientSize = New-Object System.Drawing.Size($Width, ($y + 46))
  $ok.add_Click({
    $code = $t1.Text; $err.Text = ''; $why = $null
    if ($mode -eq 'Open') {
      $err.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#6b7280'); $err.Text = Get-Text 'VaultOpening'; $w.Cursor = 'WaitCursor'; $w.Refresh()
      try { $good = Open-Vault $code } catch { $good = $false; $why = $_.Exception.Message } finally { $w.Cursor = 'Default' }
      $err.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#dc2626')
      if ($good) { $w.DialogResult = 'OK'; $w.Close(); return }
      $err.Text = if ($why) { Get-Text 'VaultNotReadable' $why } else { Get-Text 'VaultWrongCode' }
      $t1.SelectAll(); $t1.Focus(); return
    }
    if (-not (Test-CodeStrength $code)) { $err.Text = Get-Text 'VaultCodeShort' $script:VaultMinCode; $t1.Focus(); return }
    if ($code -cne $t2.Text) { $err.Text = Get-Text 'VaultCodeDiffer'; $t2.Text = ''; $t2.Focus(); return }
    $w.Cursor = 'WaitCursor'; $w.Refresh()
    try { if ($mode -eq 'Create') { New-Vault $code } else { Set-VaultCode $code } }
    catch { $err.Text = Get-Text 'VaultSaveFailed' $_.Exception.Message; return } finally { $w.Cursor = 'Default' }
    $w.DialogResult = 'OK'; $w.Close()
  })
  $w.add_Shown({ $t1.Focus() })
  $r = if ($owner) { $w.ShowDialog($owner) } else { $w.ShowDialog() }
  $r -eq 'OK'
}

# -Sign: only the access code, then LATEST.txt.sig next to the LATEST.txt given (the .cmd starts this hidden: the
# result in a message box too). Exit code 0 = signed, 1 = error, 2 = no code given.
if ($Sign) {
  $rc = 0
  try {
    if (-not (Test-Path -LiteralPath $Sign -PathType Leaf)) { throw (Get-Text 'SignNoFile' $Sign) }
    if (-not (Test-VaultFile)) { throw (Get-Text 'VaultMissing' $script:VaultFile) }
    if (-not (Show-CodeDialog 'Open')) { $rc = 2 }
    else {
      $r = Invoke-SignUpdate (Resolve-Path -LiteralPath $Sign).ProviderPath
      $m = Get-Text 'SignDone' $r.Version $r.Fingerprint (Get-Text "SignRole_$($r.Role)") $r.Signature
      if (-not $r.PackageChecked) { $m += "`r`n`r`n" + (Get-Text 'SignNoPackage') }
      [Console]::Out.WriteLine($m); Show-Message (Get-Text 'SignTitle') $m 'Information'
    }
  } catch {
    $rc = 1; [Console]::Error.WriteLine($_.Exception.Message); Show-Message (Get-Text 'SignTitle') $_.Exception.Message 'Error'
  } finally { Close-Vault }
  exit $rc
}

# no default path: every installation has its own folder; the last one chosen is proposed
if (-not $Folder) {
  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
  $dlg.Description = Get-Text 'FolderDialog'
  $dlg.ShowNewFolderButton = $false
  $last = Get-LastFolder; if ($last) { $dlg.SelectedPath = $last }
  if ($dlg.ShowDialog() -ne 'OK' -or -not $dlg.SelectedPath) { return }
  $Folder = $dlg.SelectedPath
  Set-ManagementFolder $Folder
}
if (-not (Test-Path -LiteralPath $script:Folder)) {
  Show-Message (Get-Text 'FolderNotFoundTitle') (Get-Text 'FolderNotFoundText' $script:Folder) 'Error'
  return
}
if (-not (Test-Path -LiteralPath $script:StatusDir) -and -not (Test-Path -LiteralPath $script:ConfigDir)) {
  if (-not (Confirm-Action (Get-Text 'EmptyFolderTitle') (Get-Text 'EmptyFolderText' $script:Folder) 'Button2')) { return }
}
if (-not $env:OTR_MANAGER_SCREENSHOT) { Save-LastFolder $script:Folder }

# ---------------------------------------------------------------------------------------------
# Look: fonts, colours (the shell in the default top colour of the devices' sign-in screen), icons
# ---------------------------------------------------------------------------------------------
$fontBase = New-Object System.Drawing.Font('Segoe UI', 9.75)
$fontSmall = New-Object System.Drawing.Font('Segoe UI', 9)
$fontMono = New-Object System.Drawing.Font('Consolas', 9.75)
$fontBold = New-Object System.Drawing.Font('Segoe UI', 9.75, [System.Drawing.FontStyle]::Bold)
$fontSmallBold = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$fontNav = New-Object System.Drawing.Font('Segoe UI', 10.5)
$fontApp = New-Object System.Drawing.Font('Segoe UI Semibold', 12.5)
$fontTitle = New-Object System.Drawing.Font('Segoe UI Semibold', 15)
$fontPageTitle = New-Object System.Drawing.Font('Segoe UI Semibold', 13)

function New-Color([string]$hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
$script:Theme = @{
  Shell = New-Color '#1b2733'; ShellHover = New-Color '#25384a'; ShellSelected = New-Color '#2b4156'; ShellText = New-Color '#e8eef4'; ShellMuted = New-Color '#93a4b5'
  Accent = New-Color '#2563eb'; AccentDark = New-Color '#1d4ed8'; AccentSoft = New-Color '#dbeafe'
  Page = New-Color '#f3f5f8'; Card = New-Color '#ffffff'; Line = New-Color '#e2e6ec'; Text = New-Color '#1f2937'; Muted = New-Color '#6b7280'; Hover = New-Color '#f1f3f6'
  Section = New-Color '#eef2f7'; Own = New-Color '#fff7d6'; Managed = New-Color '#eaf1ff'
}
# state colours: strong (dot, text) and soft (background of the state label)
$script:KindColor = @{ ok = New-Color '#16a34a'; off = New-Color '#9ca3af'; error = New-Color '#dc2626'; warn = New-Color '#d97706'; info = New-Color '#2563eb' }
$script:KindSoft = @{ ok = New-Color '#dcfce7'; off = New-Color '#f1f2f4'; error = New-Color '#fee2e2'; warn = New-Color '#fef3c7'; info = New-Color '#dbeafe' }

# icons from the symbol font of Windows 10/11 (Segoe Fluent Icons on 11, Segoe MDL2 Assets on 10); without
# either the buttons show their text only
$script:IconFont = @('Segoe Fluent Icons', 'Segoe MDL2 Assets') | Where-Object { $n = $_; @([System.Drawing.FontFamily]::Families | Where-Object Name -eq $n).Count } | Select-Object -First 1
$script:Glyph = @{ Refresh = 'E72C'; Folder = 'E838'; Download = 'E896'; Shield = 'EA18'; Devices = 'E977'; Settings = 'E713'; Key = 'E8D7'; Warning = 'E7BA'
  Screen = 'E7F4'; Picture = 'E91B'; Save = 'E74E'; Undo = 'E7A7'; Delete = 'E74D'; Add = 'E710'; Search = 'E721'; Document = 'E8A5'
  Lock = 'E72E'; Unlock = 'E785'; Certificate = 'EB95' }
function New-Glyph([string]$name, $color, [int]$size = 16) {
  if (-not $script:IconFont -or -not $script:Glyph.ContainsKey($name)) { return $null }
  $bmp = New-Object System.Drawing.Bitmap($size, $size)
  $g = [System.Drawing.Graphics]::FromImage($bmp); $g.TextRenderingHint = 'AntiAliasGridFit'
  $f = New-Object System.Drawing.Font($script:IconFont, [single]($size * 0.75), [System.Drawing.GraphicsUnit]::Pixel)
  $sf = New-Object System.Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
  $br = New-Object System.Drawing.SolidBrush($color)
  $g.DrawString([string][char][Convert]::ToInt32($script:Glyph[$name], 16), $f, $br, (New-Object System.Drawing.RectangleF(0, 0, $size, $size)), $sf)
  $br.Dispose(); $sf.Dispose(); $f.Dispose(); $g.Dispose()
  $bmp
}
# the state dot of the device list; the height of the picture sets the height of the rows
function New-Dot($color, [int]$w = 16, [int]$h = 26) {
  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  $g = [System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'
  $br = New-Object System.Drawing.SolidBrush($color); $d = 10
  $g.FillEllipse($br, [single](($w - $d) / 2), [single](($h - $d) / 2), $d, $d)
  $br.Dispose(); $g.Dispose()
  $bmp
}

# Sizes from the texts, so that longer translations fit: a column is never narrower than its title or
# than the samples given (labels, placeholders), a button never narrower than its text.
function Get-TextWidth($text, $font = $fontBase) { [System.Windows.Forms.TextRenderer]::MeasureText([string]$text, $font).Width }
function Get-FitWidth($width, $texts, $font = $fontBase, $pad = 16) {
  foreach ($t in @($texts)) { $width = [Math]::Max($width, (Get-TextWidth $t $font) + $pad) }
  $width
}
function Measure-Note($text, $width, $font = $fontBase) {
  [System.Windows.Forms.TextRenderer]::MeasureText([string]$text, $font, (New-Object System.Drawing.Size([Math]::Max(50, $width), 0)), [System.Windows.Forms.TextFormatFlags]::WordBreak).Height
}
# plain buttons of the small dialogs (logo, remote screen)
function New-Button($textKey, $minWidth, $height) {
  $b = New-Object System.Windows.Forms.Button; $b.Text = Get-Text $textKey; $b.Font = $fontBase
  $b.Size = New-Object System.Drawing.Size((Get-FitWidth $minWidth $b.Text -pad 20), $height)
  $b
}
# flat buttons of the window: primary (the one action of a page), secondary, danger (removes something),
# toolbar (on the dark top bar)
function New-ActionButton([string]$textKey, [string]$glyph = '', [string]$style = 'secondary') {
  $b = New-Object System.Windows.Forms.Button
  $b.Text = Get-Text $textKey; $b.Font = $fontBase; $b.FlatStyle = 'Flat'; $b.Cursor = 'Hand'; $b.Height = 32; $b.UseVisualStyleBackColor = $false
  $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
  switch ($style) {
    'primary' { $b.BackColor = $Theme.Accent; $fg = [System.Drawing.Color]::White; $b.FlatAppearance.BorderColor = $Theme.Accent; $b.FlatAppearance.MouseOverBackColor = $Theme.AccentDark; $b.FlatAppearance.MouseDownBackColor = $Theme.AccentDark }
    'danger' { $b.BackColor = $Theme.Card; $fg = $script:KindColor.error; $b.FlatAppearance.BorderColor = New-Color '#f3c4c4'; $b.FlatAppearance.MouseOverBackColor = $script:KindSoft.error }
    'toolbar' { $b.BackColor = $Theme.Shell; $fg = $Theme.ShellText; $b.FlatAppearance.BorderSize = 0; $b.FlatAppearance.MouseOverBackColor = $Theme.ShellHover; $b.FlatAppearance.MouseDownBackColor = $Theme.ShellSelected }
    default { $b.BackColor = $Theme.Card; $fg = $Theme.Text; $b.FlatAppearance.BorderColor = New-Color '#cfd5dd'; $b.FlatAppearance.MouseOverBackColor = $Theme.Hover }
  }
  $b.ForeColor = $fg
  $img = if ($glyph) { New-Glyph $glyph $fg 16 } else { $null }
  if ($img) { $b.Image = $img; $b.ImageAlign = 'MiddleLeft'; $b.TextImageRelation = 'ImageBeforeText'; $b.Padding = New-Object System.Windows.Forms.Padding(8, 0, 6, 0) }
  $b.Width = (Get-TextWidth $b.Text) + $(if ($img) { 50 } else { 30 })
  $b
}
function New-Panel($dock, $back, [int]$height = 0, [int]$width = 0) {
  $p = New-Object System.Windows.Forms.Panel; $p.Dock = $dock; if ($back) { $p.BackColor = $back }
  if ($height) { $p.Height = $height }; if ($width) { $p.Width = $width }
  $p
}
function New-Label([string]$text, $font = $fontBase, $color = $null) {
  $l = New-Object System.Windows.Forms.Label; $l.Text = $text; $l.Font = $font; $l.AutoSize = $true
  $l.ForeColor = if ($color) { $color } else { $Theme.Text }; $l.BackColor = [System.Drawing.Color]::Transparent
  $l
}
# a thin line on one side of a panel
function Add-Line($p, [string]$side = 'Top') {
  $p.Tag = @{ Line = $side }
  $p.add_Paint({ param($s, $e)
    $pen = New-Object System.Drawing.Pen($Theme.Line)
    switch ($s.Tag.Line) {
      'Top' { $e.Graphics.DrawLine($pen, 0, 0, $s.Width, 0) }
      'Bottom' { $e.Graphics.DrawLine($pen, 0, $s.Height - 1, $s.Width, $s.Height - 1) }
      'Box' { $e.Graphics.DrawRectangle($pen, 0, 0, $s.Width - 1, $s.Height - 1) }
    }
    $pen.Dispose() })
}
# search boxes with a grey hint inside (EM_SETCUEBANNER)
if (-not ('OtrNative' -as [type])) {
  Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class OtrNative { [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, string l); }'
}
function New-SearchBox([string]$cueKey, [int]$width) {
  $t = New-Object System.Windows.Forms.TextBox; $t.Font = $fontBase; $t.Width = $width; $t.Tag = Get-Text $cueKey
  $t.add_HandleCreated({ param($s, $e) [void][OtrNative]::SendMessage($s.Handle, 0x1501, [IntPtr]1, [string]$s.Tag) })
  $t
}
# a bar of buttons: left = the actions of the page, right = the one that removes something
function New-ActionBar($left, $right = @()) {
  $p = New-Panel 'Bottom' $Theme.Card 56; Add-Line $p 'Top'
  $p.Padding = New-Object System.Windows.Forms.Padding(12, 12, 12, 10)
  $fl = New-Object System.Windows.Forms.FlowLayoutPanel; $fl.Dock = 'Left'; $fl.AutoSize = $true; $fl.WrapContents = $false; $fl.BackColor = $Theme.Card
  foreach ($b in $left) { $fl.Controls.Add($b) }
  $p.Controls.Add($fl)
  if (@($right).Count) {
    $fr = New-Object System.Windows.Forms.FlowLayoutPanel; $fr.Dock = 'Right'; $fr.AutoSize = $true; $fr.WrapContents = $false; $fr.FlowDirection = 'RightToLeft'; $fr.BackColor = $Theme.Card
    foreach ($b in $right) { $b.Margin = New-Object System.Windows.Forms.Padding(8, 0, 0, 0); $fr.Controls.Add($b) }
    $p.Controls.Add($fr)
  }
  $p
}
# title and explanation on top of a page; the explanation wraps and the header grows with it
function New-PageHeader([string]$title, [string]$text) {
  $p = New-Panel 'Top' $Theme.Page 80
  $p.Padding = New-Object System.Windows.Forms.Padding(16, 12, 16, 10)
  $t = New-Label $title $fontPageTitle; $t.AutoSize = $false; $t.Dock = 'Top'; $t.Height = 32
  $n = New-Label $text $fontBase $Theme.Muted; $n.AutoSize = $false; $n.Dock = 'Fill'
  $p.Controls.Add($n); $p.Controls.Add($t)
  $p.Tag = @{ Note = $n }
  # the height from the Layout event of the page: it runs before the page arranges its docked children
  $p.add_ParentChanged({ param($q, $e)
    if ($q.Parent) { $q.Parent.add_Layout({ param($c, $e)
      foreach ($h in $c.Controls) { if ($h.Tag -is [hashtable] -and $h.Tag.ContainsKey('Note')) {
        $need = 12 + 32 + (Measure-Note $h.Tag.Note.Text ($c.DisplayRectangle.Width - 32)) + 12
        if ($h.Height -ne $need) { $h.Height = $need } } } }) } })
  $p
}
# the help of the selected setting, under a settings grid
function New-HelpPanel([string]$default) {
  $p = New-Panel 'Bottom' $Theme.Page 104; Add-Line $p 'Top'
  $p.Padding = New-Object System.Windows.Forms.Padding(14, 8, 14, 6)
  $t = New-Label '' $fontBold; $t.AutoSize = $false; $t.Dock = 'Top'; $t.Height = 22
  $b = New-Label $default $fontBase $Theme.Muted; $b.AutoSize = $false; $b.Dock = 'Fill'
  $p.Controls.Add($b); $p.Controls.Add($t)
  $p.Tag = @{ Line = 'Top'; Title = $t; Body = $b; Default = $default }
  $p
}
function Show-Help($panel, $s) {
  if ($s) { $panel.Tag.Title.Text = "$($s.Label)   $([char]0x00B7)   $($s.Key)"; $panel.Tag.Body.Text = $s.Help; $panel.Tag.Body.ForeColor = $Theme.Text }
  else { $panel.Tag.Title.Text = ''; $panel.Tag.Body.Text = $panel.Tag.Default; $panel.Tag.Body.ForeColor = $Theme.Muted }
}

# ---------------------------------------------------------------------------------------------
# The window: dark bar on top (folder actions), pages on the left, status bar
# ---------------------------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = Get-Text 'WindowTitle' $script:Folder
$form.Size = New-Object System.Drawing.Size(1440, 880)
$form.MinimumSize = New-Object System.Drawing.Size(1100, 680)
$form.StartPosition = 'CenterScreen'
$form.Font = $fontBase; $form.BackColor = $Theme.Page
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
if ($wa.Width -lt $form.Width -or $wa.Height -lt $form.Height) { $form.WindowState = 'Maximized' }

$root = New-Panel 'Fill' $Theme.Page
$bar = New-Object System.Windows.Forms.StatusStrip
$bar.BackColor = $Theme.Card; $bar.SizingGrip = $false; $bar.Font = $fontSmall
$barText = New-Object System.Windows.Forms.ToolStripStatusLabel
$barText.Spring = $true; $barText.TextAlign = 'MiddleLeft'; $barText.ForeColor = $Theme.Muted
[void]$bar.Items.Add($barText)

# top bar: name, folder, actions on the folder
$header = New-Panel 'Top' $Theme.Shell 56
$lblApp = New-Label (Get-Text 'AppName') $fontApp $Theme.ShellText; $lblApp.Location = New-Object System.Drawing.Point(18, 15)
$lblFolder = New-Label $script:Folder $fontSmall $Theme.ShellMuted; $lblFolder.Location = New-Object System.Drawing.Point(($lblApp.Left + (Get-TextWidth $lblApp.Text $fontApp) + 14), 21)
$tools = New-Object System.Windows.Forms.FlowLayoutPanel; $tools.Dock = 'Right'; $tools.AutoSize = $true; $tools.WrapContents = $false
$tools.FlowDirection = 'RightToLeft'; $tools.BackColor = $Theme.Shell; $tools.Padding = New-Object System.Windows.Forms.Padding(0, 12, 10, 0)
$btnPerm = New-ActionButton 'BtnCheckPermissions' 'Shield' 'toolbar'
$btnRelease = New-ActionButton 'BtnImportRelease' 'Download' 'toolbar'
$btnOpen = New-ActionButton 'BtnOpenFolder' 'Folder' 'toolbar'
$btnRefresh = New-ActionButton 'BtnRefresh' 'Refresh' 'toolbar'
$btnVaultTool = New-ActionButton 'VaultToolClosed' 'Lock' 'toolbar'
$btnVaultTool.Width = (@('VaultToolClosed', 'VaultToolOpen', 'VaultToolNone') | ForEach-Object { Get-TextWidth (Get-Text $_) } | Measure-Object -Maximum).Maximum + 50
foreach ($b in @($btnVaultTool, $btnPerm, $btnRelease, $btnOpen, $btnRefresh)) { $b.Margin = New-Object System.Windows.Forms.Padding(4, 0, 0, 0); $tools.Controls.Add($b) }
$tips = New-Object System.Windows.Forms.ToolTip
$tips.SetToolTip($btnRefresh, (Get-Text 'NoteDevices')); $tips.SetToolTip($lblFolder, $script:Folder)
$header.Controls.AddRange(@($lblApp, $lblFolder, $tools))
# a long folder path ends with ... before the actions
$lblFolder.AutoSize = $false; $lblFolder.AutoEllipsis = $true; $lblFolder.Height = 20
$header.add_Resize({ param($s, $e) $lblFolder.Width = [Math]::Max(40, $s.ClientSize.Width - $tools.Width - $lblFolder.Left - 16) })

# pages on the left: a dark column, the selected page marked by a line in the accent colour
$nav = New-Panel 'Left' $Theme.Shell 0 210
$nav.Padding = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
$content = New-Panel 'Fill' $Theme.Page
$script:Page = 0; $script:NavButtons = @(); $script:Pages = @()
function New-NavButton([string]$textKey, [string]$glyph, [int]$index) {
  $b = New-Object System.Windows.Forms.Button
  $b.Text = '  ' + (Get-Text $textKey); $b.Font = $fontNav; $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0; $b.Cursor = 'Hand'
  $b.Dock = 'Top'; $b.Height = 46; $b.TextAlign = 'MiddleLeft'; $b.ForeColor = $Theme.ShellText; $b.BackColor = $Theme.Shell; $b.UseVisualStyleBackColor = $false
  $b.FlatAppearance.MouseOverBackColor = $Theme.ShellHover; $b.FlatAppearance.MouseDownBackColor = $Theme.ShellSelected
  $b.Padding = New-Object System.Windows.Forms.Padding(18, 0, 0, 0)
  $img = New-Glyph $glyph $Theme.ShellText 18
  if ($img) { $b.Image = $img; $b.ImageAlign = 'MiddleLeft'; $b.TextImageRelation = 'ImageBeforeText' }
  $b.Tag = @{ Index = $index; Count = '' }
  $b.add_Paint({ param($s, $e)
    if ($s.Tag.Index -eq $script:Page) { $br = New-Object System.Drawing.SolidBrush($Theme.Accent); $e.Graphics.FillRectangle($br, 0, 8, 4, $s.Height - 16); $br.Dispose() }
    if ($s.Tag.Count) {
      $r = New-Object System.Drawing.Rectangle(0, 0, ($s.Width - 16), $s.Height)
      [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$s.Tag.Count, $fontSmall, $r, $Theme.ShellMuted, [System.Windows.Forms.TextFormatFlags]'Right, VerticalCenter')
    } })
  $b.add_Click({ param($s, $e) Select-Page $s.Tag.Index })
  $b
}
$navDevices = New-NavButton 'NavDevices' 'Devices' 0
$navCommon = New-NavButton 'NavCommon' 'Settings' 1
$navKeys = New-NavButton 'NavKeys' 'Key' 2
$navProblems = New-NavButton 'NavProblems' 'Warning' 3
$navVault = New-NavButton 'NavVault' 'Lock' 4
$script:NavButtons = @($navDevices, $navCommon, $navKeys, $navProblems, $navVault)
# Dock Top stacks the last added on top; the vault next to the SSH keys
foreach ($b in @($navProblems, $navVault, $navKeys, $navCommon, $navDevices)) { $nav.Controls.Add($b) }

# ---------------- Devices page: list | selected device ----------------
$pageDevices = New-Panel 'Fill' $Theme.Page
$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'; $split.Orientation = 'Vertical'; $split.BackColor = $Theme.Page; $split.SplitterWidth = 10
$split.Panel1.Padding = New-Object System.Windows.Forms.Padding(12, 12, 0, 12); $split.Panel2.Padding = New-Object System.Windows.Forms.Padding(0, 12, 12, 12)
$split.FixedPanel = 'Panel1'

# list card: search, counts, the list, a note on how often it changes
$listCard = New-Panel 'Fill' $Theme.Card; Add-Line $listCard 'Box'; $listCard.Padding = New-Object System.Windows.Forms.Padding(1)
$listTop = New-Panel 'Top' $Theme.Card 72
$txtDevSearch = New-SearchBox 'SearchDevices' 200; $txtDevSearch.Location = New-Object System.Drawing.Point(12, 12); $txtDevSearch.Anchor = 'Top, Left, Right'
$lblDevCount = New-Label '' $fontSmall $Theme.Muted; $lblDevCount.Location = New-Object System.Drawing.Point(12, 46)
$listTop.Controls.AddRange(@($txtDevSearch, $lblDevCount))
$listTop.add_Resize({ param($s, $e) $txtDevSearch.Width = [Math]::Max(80, $s.ClientSize.Width - 24) })

$imgDots = New-Object System.Windows.Forms.ImageList; $imgDots.ColorDepth = 'Depth32Bit'; $imgDots.ImageSize = New-Object System.Drawing.Size(16, 26)
foreach ($k in @('ok', 'off', 'error', 'warn', 'info')) { $imgDots.Images.Add($k, (New-Dot $script:KindColor[$k])) }
$list = New-Object System.Windows.Forms.ListView
$list.Dock = 'Fill'; $list.View = 'Details'; $list.FullRowSelect = $true; $list.MultiSelect = $false; $list.HideSelection = $false
$list.BorderStyle = 'None'; $list.SmallImageList = $imgDots; $list.ShowItemToolTips = $true; $list.Font = $fontBase
# the last column takes the rest of the width: no horizontal scroll bar for a few pixels
$list.add_Resize({ param($s, $e) if ($s.Columns.Count -lt 2) { return }; $w = 0; for ($k = 0; $k -lt $s.Columns.Count - 1; $k++) { $w += $s.Columns[$k].Width }
  $s.Columns[$s.Columns.Count - 1].Width = [Math]::Max(60, $s.ClientSize.Width - $w - 2) })
foreach ($c in @(@('ColDevice', 105), @('ColState', 110), @('ColUser', 80), @('ColVersion', 52), @('ColLastReport', 64))) {
  # room for the sort arrow too
  $title = Get-Text $c[0]
  [void]$list.Columns.Add($title, (Get-FitWidth $c[1] "$title $([char]0x25B2)" -pad 14))
}
# click on a header = sort by that column, second click = reverse; the arrow shows which.
# The chosen order stays when the list refreshes by itself.
$script:Sorter = New-Object OtrColumnSorter
$script:Sorter.Column = 0; $script:Sorter.NameColumn = 0
$script:Titles = @($list.Columns | ForEach-Object { $_.Text })
function Show-SortMark {
  for ($k = 0; $k -lt $list.Columns.Count; $k++) {
    $list.Columns[$k].Text = if ($k -eq $script:Sorter.Column) { $script:Titles[$k] + ' ' + $(if ($script:Sorter.Descending) { [char]0x25BC } else { [char]0x25B2 }) } else { $script:Titles[$k] }
  }
}
$list.ListViewItemSorter = $script:Sorter
$list.add_ColumnClick({ param($s, $e)
  if ($script:Sorter.Column -eq $e.Column) { $script:Sorter.Descending = -not $script:Sorter.Descending } else { $script:Sorter.Column = $e.Column; $script:Sorter.Descending = $false }
  $list.Sort(); Show-SortMark
  if ($list.SelectedItems.Count) { $list.SelectedItems[0].EnsureVisible() } })
Show-SortMark
$lblListNote = New-Label (Get-Text 'NoteDevices') $fontSmall $Theme.Muted; $lblListNote.AutoSize = $false; $lblListNote.Dock = 'Bottom'; $lblListNote.Height = 46
$lblListNote.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 4); $lblListNote.BackColor = $Theme.Card
$listCard.Controls.Add($list); $listCard.Controls.Add($lblListNote); $listCard.Controls.Add($listTop)
$split.Panel1.Controls.Add($listCard)

# selected device: header (name, state, address, version, last report, session) with its actions
$devCard = New-Panel 'Fill' $Theme.Card; Add-Line $devCard 'Box'; $devCard.Padding = New-Object System.Windows.Forms.Padding(1)
$devHead = New-Panel 'Top' $Theme.Card 92; Add-Line $devHead 'Bottom'
$lblDevName = New-Label '' $fontTitle; $lblDevName.Location = New-Object System.Drawing.Point(18, 12)
$lblDevState = New-Label '' $fontSmallBold; $lblDevState.Padding = New-Object System.Windows.Forms.Padding(8, 3, 8, 3); $lblDevState.Visible = $false
$lblDevInfo = New-Label '' $fontBase $Theme.Muted; $lblDevInfo.Location = New-Object System.Drawing.Point(20, 56)
$devActions = New-Object System.Windows.Forms.FlowLayoutPanel; $devActions.AutoSize = $true; $devActions.AutoSizeMode = 'GrowAndShrink'; $devActions.WrapContents = $false
$devActions.FlowDirection = 'RightToLeft'; $devActions.BackColor = $Theme.Card; $devActions.Anchor = 'Top, Right'
$btnRemoteDev = New-ActionButton 'BtnRemoteScreen' 'Screen' 'primary'
$btnBrandDev = New-ActionButton 'BtnBranding' 'Picture' 'secondary'
foreach ($b in @($btnRemoteDev, $btnBrandDev)) { $b.Margin = New-Object System.Windows.Forms.Padding(8, 0, 0, 0); $devActions.Controls.Add($b) }
$tips.SetToolTip($btnRemoteDev, (Get-Text 'TipRemoteScreen'))
$devHead.Controls.AddRange(@($lblDevName, $lblDevState, $lblDevInfo, $devActions))
# the actions in the top right corner, over the first line only: the line under the name keeps the whole width
$devHead.add_Resize({ param($s, $e) $devActions.Location = New-Object System.Drawing.Point(($s.ClientSize.Width - $devActions.Width - 16), 14) })

$detail = New-Object System.Windows.Forms.TabControl
$detail.Dock = 'Fill'; $detail.Padding = New-Object System.Drawing.Point(16, 6); $detail.Font = $fontBase
$tabDevSettings = New-Object System.Windows.Forms.TabPage (Get-Text 'TabSettings')
$tabSummary = New-Object System.Windows.Forms.TabPage (Get-Text 'TabSummary')
$tabEvents = New-Object System.Windows.Forms.TabPage (Get-Text 'TabEvents')
$tabStatus = New-Object System.Windows.Forms.TabPage (Get-Text 'TabReport')
$detail.TabPages.AddRange(@($tabDevSettings, $tabSummary, $tabEvents, $tabStatus))
foreach ($t in $detail.TabPages) { $t.BackColor = $Theme.Card }
function New-TextView { $t = New-Object System.Windows.Forms.TextBox; $t.Multiline = $true; $t.ReadOnly = $true; $t.ScrollBars = 'Both'; $t.WordWrap = $false; $t.Dock = 'Fill'; $t.Font = $fontMono; $t.BackColor = $Theme.Card; $t.BorderStyle = 'None'; $t }
$txtStatus = New-TextView; $tabStatus.Controls.Add($txtStatus); $tabStatus.Padding = New-Object System.Windows.Forms.Padding(8)
$txtEvents = New-TextView; $tabEvents.Controls.Add($txtEvents); $tabEvents.Padding = New-Object System.Windows.Forms.Padding(8)
# summary: what the device reports, in groups, readable
$lvSummary = New-Object System.Windows.Forms.ListView
$lvSummary.Dock = 'Fill'; $lvSummary.View = 'Details'; $lvSummary.HeaderStyle = 'None'; $lvSummary.BorderStyle = 'None'; $lvSummary.FullRowSelect = $true
$lvSummary.ShowGroups = $true; $lvSummary.Font = $fontBase
[void]$lvSummary.Columns.Add('', 230); [void]$lvSummary.Columns.Add('', 600)
$lvSummary.add_Resize({ param($s, $e) $s.Columns[1].Width = [Math]::Max(200, $s.ClientSize.Width - $s.Columns[0].Width - 4) })
$tabSummary.Controls.Add($lvSummary); $tabSummary.Padding = New-Object System.Windows.Forms.Padding(8)

function New-Grid {
  $g = New-Object System.Windows.Forms.DataGridView
  $g.Dock = 'Fill'; $g.AllowUserToAddRows = $false; $g.AllowUserToDeleteRows = $false; $g.AllowUserToResizeRows = $false; $g.RowHeadersVisible = $false
  $g.SelectionMode = 'CellSelect'; $g.AutoSizeRowsMode = 'None'; $g.EditMode = 'EditOnEnter'; $g.BackgroundColor = $Theme.Card; $g.BorderStyle = 'None'
  $g.CellBorderStyle = 'SingleHorizontal'; $g.GridColor = $Theme.Line; $g.EnableHeadersVisualStyles = $false
  $g.ColumnHeadersBorderStyle = 'None'; $g.ColumnHeadersHeightSizeMode = 'DisableResizing'; $g.ColumnHeadersHeight = 34
  $hs = $g.ColumnHeadersDefaultCellStyle; $hs.BackColor = $Theme.Card; $hs.ForeColor = $Theme.Muted; $hs.Font = $fontSmallBold; $hs.SelectionBackColor = $Theme.Card; $hs.SelectionForeColor = $Theme.Muted
  $hs.Padding = New-Object System.Windows.Forms.Padding(6, 0, 0, 0)
  $ds = $g.DefaultCellStyle; $ds.SelectionBackColor = $Theme.AccentSoft; $ds.SelectionForeColor = $Theme.Text; $ds.ForeColor = $Theme.Text; $ds.Font = $fontBase
  $ds.Padding = New-Object System.Windows.Forms.Padding(6, 0, 6, 0)
  $g.RowTemplate.Height = 30
  # no flicker when scrolling
  $g.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic, Instance').SetValue($g, $true, $null)
  $g.add_DataError({ param($s, $e) $e.ThrowException = $false })
  $g
}
function Add-TextColumn($g, $titleKey, $width, $readOnly, $samples = @(), $boldSamples = @()) {
  $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $col.HeaderText = Get-Text $titleKey; $col.ReadOnly = $readOnly; $col.SortMode = 'NotSortable'
  if ($width) { $col.Width = Get-FitWidth (Get-FitWidth (Get-FitWidth $width $col.HeaderText $fontSmallBold 20) $samples $fontBase 18) $boldSamples $fontBold 18 } else { $col.AutoSizeMode = 'Fill'; $col.MinimumWidth = 130 }
  [void]$g.Columns.Add($col)
}
function Add-CheckColumn($g, $titleKey, $width) {
  $col = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn; $col.HeaderText = Get-Text $titleKey
  $col.Width = Get-FitWidth $width $col.HeaderText $fontSmallBold 18; [void]$g.Columns.Add($col)
}
# a search box over a grid: hides the settings that do not match (name, key or help) and the groups left empty
function Set-GridFilter($g, [string]$text) {
  $g.CurrentCell = $null
  $t = [System.Management.Automation.WildcardPattern]::Escape($text.Trim())
  $section = $null; $any = $false
  foreach ($r in $g.Rows) {
    if ($null -eq $r.Tag) { if ($section) { $section.Visible = $any -or -not $t }; $section = $r; $any = $false; continue }
    $s = $r.Tag
    $show = (-not $t) -or ($s.Label -like "*$t*") -or ($s.Key -like "*$t*") -or ($s.Help -like "*$t*")
    $r.Visible = $show; if ($show) { $any = $true }
  }
  if ($section) { $section.Visible = $any -or -not $t }
}
function New-FilterBar($grid) {
  $p = New-Panel 'Top' $Theme.Card 48
  $t = New-SearchBox 'SearchSettings' 280; $t.Location = New-Object System.Drawing.Point(10, 11)
  $t.Tag = Get-Text 'SearchSettings'
  $t.add_TextChanged({ param($s, $e) Set-GridFilter $s.Parent.Tag.Grid $s.Text })
  $p.Controls.Add($t); $p.Tag = @{ Grid = $grid; Box = $t }
  $p
}
# the first column holds the setting names and the group titles (bold)
$labels = @($script:Settings | ForEach-Object { $_.Label })
$sections = @($script:Settings | ForEach-Object { $_.Section } | Select-Object -Unique)

# settings of the selected device: in use | comes from | value for this device | exception
$gridDev = New-Grid
Add-TextColumn $gridDev 'ColSetting' 150 $true $labels $sections
Add-TextColumn $gridDev 'ColInUse' 130 $true
Add-TextColumn $gridDev 'ColSource' 110 $true @((Get-Text 'SrcThis'), (Get-Text 'SrcCommon'), (Get-Text 'SrcDevice'), (Get-Text 'SrcPending'))
Add-TextColumn $gridDev 'ColThisDevice' $null $false
Add-CheckColumn $gridDev 'ColExceptionTick' 78
$helpDev = New-HelpPanel (Get-Text 'HelpDevice' (Get-Text 'ColExceptionTick'))
$gridDev.Tag = $helpDev
$btnSaveDev = New-ActionButton 'BtnSave' 'Save' 'primary'
$btnReloadDev = New-ActionButton 'BtnUndo' 'Undo' 'secondary'
$btnClearDev = New-ActionButton 'BtnRemoveExceptions' 'Delete' 'danger'
$lblDirtyDev = New-Label (Get-Text 'Unsaved') $fontSmallBold $script:KindColor.warn; $lblDirtyDev.Margin = New-Object System.Windows.Forms.Padding(6, 8, 0, 0); $lblDirtyDev.Visible = $false
$barDev = New-ActionBar @($btnSaveDev, $btnReloadDev, $lblDirtyDev) @($btnClearDev)
$filterDev = New-FilterBar $gridDev
$tabDevSettings.Controls.Add($gridDev); $tabDevSettings.Controls.Add($filterDev); $tabDevSettings.Controls.Add($helpDev); $tabDevSettings.Controls.Add($barDev)

$devCard.Controls.Add($detail); $devCard.Controls.Add($devHead)
$split.Panel2.Controls.Add($devCard)
$pageDevices.Controls.Add($split)

# ---------------- Common settings page ----------------
$pageCommon = New-Panel 'Fill' $Theme.Page
$comCard = New-Panel 'Fill' $Theme.Card; Add-Line $comCard 'Box'; $comCard.Padding = New-Object System.Windows.Forms.Padding(1)
$comWrap = New-Panel 'Fill' $Theme.Page; $comWrap.Padding = New-Object System.Windows.Forms.Padding(12, 0, 12, 12)
$gridCom = New-Grid
Add-TextColumn $gridCom 'ColSetting' 190 $true $labels $sections
Add-TextColumn $gridCom 'ColValueAll' $null $false
Add-CheckColumn $gridCom 'ColManagedHere' 110
$helpCom = New-HelpPanel (Get-Text 'HelpCommon' (Get-Text 'ColManagedHere'))
$gridCom.Tag = $helpCom
$btnSaveCom = New-ActionButton 'BtnSave' 'Save' 'primary'
$btnReloadCom = New-ActionButton 'BtnUndo' 'Undo' 'secondary'
$btnBrandCom = New-ActionButton 'BtnBranding' 'Picture' 'secondary'
$lblDirtyCom = New-Label (Get-Text 'Unsaved') $fontSmallBold $script:KindColor.warn; $lblDirtyCom.Margin = New-Object System.Windows.Forms.Padding(6, 8, 0, 0); $lblDirtyCom.Visible = $false
$barCom = New-ActionBar @($btnSaveCom, $btnReloadCom, $btnBrandCom, $lblDirtyCom)
$filterCom = New-FilterBar $gridCom
$comCard.Controls.Add($gridCom); $comCard.Controls.Add($filterCom); $comCard.Controls.Add($helpCom); $comCard.Controls.Add($barCom)
$comWrap.Controls.Add($comCard)
$pageCommon.Controls.Add($comWrap); $pageCommon.Controls.Add((New-PageHeader (Get-Text 'NavCommon') (Get-Text 'PageCommonNote' (Get-Text 'ColManagedHere'))))

# ---------------- SSH keys page ----------------
$pageKeys = New-Panel 'Fill' $Theme.Page
$keysWrap = New-Panel 'Fill' $Theme.Page; $keysWrap.Padding = New-Object System.Windows.Forms.Padding(12, 0, 12, 12)
$keysCard = New-Panel 'Fill' $Theme.Card; Add-Line $keysCard 'Box'; $keysCard.Padding = New-Object System.Windows.Forms.Padding(1)
$txtKeys = New-Object System.Windows.Forms.TextBox
$txtKeys.Multiline = $true; $txtKeys.ScrollBars = 'Both'; $txtKeys.WordWrap = $false; $txtKeys.Dock = 'Fill'; $txtKeys.Font = $fontMono; $txtKeys.AcceptsReturn = $true; $txtKeys.BorderStyle = 'None'
$keysPad = New-Panel 'Fill' $Theme.Card; $keysPad.Padding = New-Object System.Windows.Forms.Padding(10, 8, 6, 6); $keysPad.Controls.Add($txtKeys)
$btnSaveKeys = New-ActionButton 'BtnSave' 'Save' 'primary'
$btnReloadKeys = New-ActionButton 'BtnUndo' 'Undo' 'secondary'
$btnMyKey = New-ActionButton 'BtnAddMyKey' 'Add' 'secondary'
$btnKeyFile = New-ActionButton 'BtnAddKeyFile' 'Document' 'secondary'
$lblDirtyKeys = New-Label (Get-Text 'Unsaved') $fontSmallBold $script:KindColor.warn; $lblDirtyKeys.Margin = New-Object System.Windows.Forms.Padding(6, 8, 0, 0); $lblDirtyKeys.Visible = $false
$tips.SetToolTip($btnMyKey, (Get-Text 'TipAddMyKey'))
$barKeys = New-ActionBar @($btnSaveKeys, $btnReloadKeys, $btnMyKey, $btnKeyFile, $lblDirtyKeys)
$keysCard.Controls.Add($keysPad); $keysCard.Controls.Add($barKeys)
$keysWrap.Controls.Add($keysCard)
$pageKeys.Controls.Add($keysWrap); $pageKeys.Controls.Add((New-PageHeader (Get-Text 'PageKeysTitle') (Get-Text 'NoteKeys')))

# ---------------- Problems page ----------------
$pageProblems = New-Panel 'Fill' $Theme.Page
$probWrap = New-Panel 'Fill' $Theme.Page; $probWrap.Padding = New-Object System.Windows.Forms.Padding(12, 0, 12, 12)
$probCard = New-Panel 'Fill' $Theme.Card; Add-Line $probCard 'Box'; $probCard.Padding = New-Object System.Windows.Forms.Padding(1)
$probTop = New-Panel 'Top' $Theme.Card 82; Add-Line $probTop 'Bottom'
$lblPeriod = New-Label (Get-Text 'ProbPeriod'); $lblPeriod.Location = New-Object System.Drawing.Point(14, 16)
$cmbPeriod = New-Object System.Windows.Forms.ComboBox; $cmbPeriod.DropDownStyle = 'DropDownList'; $cmbPeriod.Width = 160; $cmbPeriod.Font = $fontBase
[void]$cmbPeriod.Items.AddRange(@((Get-Text 'ProbToday'), (Get-Text 'Prob24h'), (Get-Text 'Prob7d'), (Get-Text 'Prob30d'))); $cmbPeriod.SelectedIndex = 1
$cmbPeriod.Location = New-Object System.Drawing.Point((22 + (Get-TextWidth $lblPeriod.Text)), 12)
$btnProbRefresh = New-ActionButton 'BtnRefresh' 'Refresh' 'secondary'; $btnProbRefresh.Location = New-Object System.Drawing.Point(($cmbPeriod.Right + 10), 10)
$lblHeadline = New-Label '' $fontBold; $lblHeadline.AutoSize = $false; $lblHeadline.Location = New-Object System.Drawing.Point(14, 50); $lblHeadline.Height = 24
$lblHeadline.Anchor = 'Top, Left, Right'; $lblHeadline.Width = 1000
$probTop.Controls.AddRange(@($lblPeriod, $cmbPeriod, $btnProbRefresh, $lblHeadline))
$probTop.add_Resize({ param($s, $e) $lblHeadline.Width = [Math]::Max(100, $s.ClientSize.Width - 28) })
$probSplit = New-Object System.Windows.Forms.SplitContainer; $probSplit.Dock = 'Fill'; $probSplit.Orientation = 'Horizontal'; $probSplit.BackColor = $Theme.Line; $probSplit.SplitterWidth = 1
$probSplit.Panel1.BackColor = $Theme.Card; $probSplit.Panel2.BackColor = $Theme.Card
$probList = New-Object System.Windows.Forms.ListView
$probList.Dock = 'Fill'; $probList.View = 'Details'; $probList.FullRowSelect = $true; $probList.MultiSelect = $false; $probList.HideSelection = $false; $probList.BorderStyle = 'None'
$probList.SmallImageList = $imgDots; $probList.Font = $fontBase
foreach ($c in @(@('ColProblem', 330), @('ColWhere', 180), @('ColTimes', 60), @('ColDevicesN', 230), @('ColUsers', 200), @('ColFirstTime', 100), @('ColLastTime', 100))) {
  [void]$probList.Columns.Add((Get-Text $c[0]), (Get-FitWidth $c[1] (Get-Text $c[0]) -pad 14)) }
$probText = New-TextView
$probPad = New-Panel 'Fill' $Theme.Card; $probPad.Padding = New-Object System.Windows.Forms.Padding(10, 8, 6, 6); $probPad.Controls.Add($probText)
$probSplit.Panel1.Controls.Add($probList); $probSplit.Panel2.Controls.Add($probPad)
$probCard.Controls.Add($probSplit); $probCard.Controls.Add($probTop)
$probWrap.Controls.Add($probCard)
$pageProblems.Controls.Add($probWrap); $pageProblems.Controls.Add((New-PageHeader (Get-Text 'NavProblems') (Get-Text 'ProbNote')))

# ---------------- Vault page ----------------
# three blocks: the vault (open, close, code), the SSH key of the manager, the key that signs the updates
$pageVault = New-Panel 'Fill' $Theme.Page
$vaultWrap = New-Panel 'Fill' $Theme.Page; $vaultWrap.Padding = New-Object System.Windows.Forms.Padding(12, 0, 12, 12)
$vaultCard = New-Panel 'Fill' $Theme.Card; Add-Line $vaultCard 'Box'; $vaultCard.Padding = New-Object System.Windows.Forms.Padding(1); $vaultCard.AutoScroll = $true
function New-VaultBlock([string]$titleKey, [string]$glyph, $buttons) {
  $p = New-Panel 'Top' $Theme.Card 150; $p.Padding = New-Object System.Windows.Forms.Padding(18, 14, 18, 14)
  $t = New-Label ('  ' + (Get-Text $titleKey)) $fontBold; $t.AutoSize = $false; $t.Dock = 'Top'; $t.Height = 28
  $img = New-Glyph $glyph $Theme.Accent 18; if ($img) { $t.Image = $img; $t.ImageAlign = 'MiddleLeft'; $t.Text = '      ' + (Get-Text $titleKey) }
  $t.TextAlign = 'MiddleLeft'
  $n = New-Label '' $fontBase $Theme.Muted; $n.AutoSize = $false; $n.Dock = 'Fill'; $n.Padding = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
  $fl = New-Object System.Windows.Forms.FlowLayoutPanel; $fl.Dock = 'Bottom'; $fl.Height = 34; $fl.WrapContents = $false; $fl.BackColor = $Theme.Card
  foreach ($b in $buttons) { $fl.Controls.Add($b) }
  $p.Controls.Add($n); $p.Controls.Add($fl); $p.Controls.Add($t)
  $p.Tag = @{ Line = 'Bottom'; Note = $n }
  $p.add_Paint({ param($s, $e) $pen = New-Object System.Drawing.Pen($Theme.Line); $e.Graphics.DrawLine($pen, 0, $s.Height - 1, $s.Width, $s.Height - 1); $pen.Dispose() })
  $p
}
$btnVaultOpen = New-ActionButton 'BtnVaultOpen' 'Unlock' 'primary'
$btnVaultCode = New-ActionButton 'BtnVaultCode' 'Key' 'secondary'
$btnVaultSshAdd = New-ActionButton 'BtnVaultSshAdd' 'Add' 'primary'
$btnVaultSshNew = New-ActionButton 'BtnVaultSshNew' 'Refresh' 'secondary'
$btnVaultSshImport = New-ActionButton 'BtnVaultSshImport' 'Document' 'secondary'
$btnVaultSign = New-ActionButton 'BtnVaultSign' 'Certificate' 'primary'
$btnVaultSignImport = New-ActionButton 'BtnVaultSignImport' 'Document' 'secondary'
$btnVaultSignNew = New-ActionButton 'BtnVaultSignNew' 'Add' 'secondary'
$btnVaultSignExport = New-ActionButton 'BtnVaultSignExport' 'Save' 'secondary'
$btnVaultSignSend = New-ActionButton 'BtnVaultSignSend' 'Devices' 'secondary'
# the open/create/close button changes its text: wide enough for the longest
$btnVaultOpen.Width = (@('BtnVaultOpen', 'BtnVaultCreate', 'BtnVaultClose') | ForEach-Object { Get-TextWidth (Get-Text $_) } | Measure-Object -Maximum).Maximum + 50
$blkVault = New-VaultBlock 'VaultBlockTitle' 'Lock' @($btnVaultOpen, $btnVaultCode)
$blkSsh = New-VaultBlock 'VaultSshTitle' 'Screen' @($btnVaultSshAdd, $btnVaultSshNew, $btnVaultSshImport)
$blkSign = New-VaultBlock 'VaultSignTitle' 'Certificate' @($btnVaultSign, $btnVaultSignSend, $btnVaultSignExport, $btnVaultSignNew, $btnVaultSignImport)
# Dock Top stacks the last added on top
foreach ($b in @($blkSign, $blkSsh, $blkVault)) { $vaultCard.Controls.Add($b) }
$vaultWrap.Controls.Add($vaultCard)
$pageVault.Controls.Add($vaultWrap); $pageVault.Controls.Add((New-PageHeader (Get-Text 'NavVault') (Get-Text 'PageVaultNote')))
# each block as high as its text
function Set-VaultHeights {
  foreach ($b in @($blkVault, $blkSsh, $blkSign)) {
    $need = 14 + 28 + 4 + (Measure-Note $b.Tag.Note.Text ($vaultCard.ClientSize.Width - 40)) + 10 + 34 + 14
    if ($b.Height -ne $need) { $b.Height = $need }
  }
}
$vaultCard.add_Resize({ Set-VaultHeights })

$script:Pages = @($pageDevices, $pageCommon, $pageKeys, $pageProblems, $pageVault)
foreach ($p in $script:Pages) { $p.Visible = $false; $content.Controls.Add($p) }
# Fill first, then the edges: the last one added takes its side first
$root.Controls.Add($content); $root.Controls.Add($nav); $root.Controls.Add($header); $root.Controls.Add($bar)
$form.Controls.Add($root)

# ---------------------------------------------------------------------------------------------
# Behaviour
# ---------------------------------------------------------------------------------------------
$script:Devices = @(); $script:Selected = $null; $script:Loading = $false; $script:Listing = $false

function Select-Page([int]$i) {
  $script:Page = $i
  for ($k = 0; $k -lt $script:Pages.Count; $k++) {
    $script:Pages[$k].Visible = ($k -eq $i)
    $b = $script:NavButtons[$k]; $b.BackColor = if ($k -eq $i) { $Theme.ShellSelected } else { $Theme.Shell }; $b.Invalidate()
  }
  if ($i -eq 3) { Update-ProblemView }
  if ($i -eq 4) { Update-VaultView }
}

function Set-Cell($row, $col, $s, $value) {
  if ($s.Type -eq 'choice') {
    $cb = New-Object System.Windows.Forms.DataGridViewComboBoxCell
    foreach ($c in $s.Choices) { [void]$cb.Items.Add($c) }
    $cb.FlatStyle = 'Flat'; $cb.DisplayStyle = 'DropDownButton'; $row.Cells[$col] = $cb
    $cb.Value = if ($null -ne $value -and $value -ne '') { ConvertTo-Canonical $s.Key $value } else { $s.Choices[0] }
  } else { $row.Cells[$col].Value = [string]$value }
}
function Get-Cell($row, $col) { $v = $row.Cells[$col].Value; if ($null -eq $v) { '' } else { ([string]$v).Trim() } }
# the settings are many: a title row per group (Tag = $null, skipped when saving)
function Add-SectionRow($g, $title, $checkCol) {
  $i = $g.Rows.Add(); $r = $g.Rows[$i]
  $r.Cells[$checkCol] = New-Object System.Windows.Forms.DataGridViewTextBoxCell
  $r.Cells[0].Value = $title; $r.ReadOnly = $true; $r.Tag = $null; $r.Height = 32
  $r.DefaultCellStyle.BackColor = $Theme.Section; $r.DefaultCellStyle.SelectionBackColor = $Theme.Section; $r.DefaultCellStyle.Font = $fontBold
  $r.DefaultCellStyle.ForeColor = $Theme.Text; $r.DefaultCellStyle.SelectionForeColor = $Theme.Text
}
# Managed values of a grid: KEY -> value, or $null when the tick is off
function Get-GridValues($g, $valueCol, $checkCol) {
  $m = [ordered]@{}
  foreach ($r in $g.Rows) { if ($null -eq $r.Tag) { continue }; $m[$r.Tag.Key] = if ($r.Cells[$checkCol].Value -eq $true) { Get-Cell $r $valueCol } else { $null } }
  $m
}
# a ticked row in the colour of its kind (own value of a device / managed for all); the value of an unticked row
# is only a proposal (ticking pins it) and stays grey
function Set-RowLook($r, $valueCol, $checkCol, $tint) {
  $on = $r.Cells[$checkCol].Value -eq $true
  $r.DefaultCellStyle.BackColor = if ($on) { $tint } else { $Theme.Card }
  $r.Cells[$valueCol].Style.ForeColor = if ($on) { $Theme.Text } else { $Theme.Muted }
}
function Set-Dirty([string]$what, [bool]$on) {
  switch ($what) { 'dev' { $lblDirtyDev.Visible = $on } 'com' { $lblDirtyCom.Visible = $on } 'keys' { $lblDirtyKeys.Visible = $on } }
}

function Get-SessionUser($s) {
  $v = [string]$s['SESSION']
  if ($v -match '^active \((.+)\)$') { return $Matches[1] }
  if ($v -and $v -ne 'none') { return $v }
  # a screen that shows a web page (WEB_BUTTON=kiosk) has no Windows session: the page is what it shows
  if ($s['CFG_WEB_BUTTON'] -eq 'kiosk') { return (Get-Text 'UserKiosk') }
  ''
}
function Get-Version($s) { (([string]$s['SOFTWARE']).Trim() -split '\s+')[-1] }
function Get-Seen($d) { if ($d.Minutes -lt 1) { Get-Text 'SeenNow' } else { Get-Text 'SeenAgo' (Format-Minutes $d.Minutes) } }

function Update-DeviceList {
  try {
    $renamed = @(Complete-Renames)
    $script:Devices = @(Get-Devices)
  } catch { $barText.Text = Get-Text 'ErrReadFolder' $script:Folder $_.Exception.Message; return }
  $sel = if ($script:Selected) { $script:Selected.File } else { $null }
  $f = [System.Management.Automation.WildcardPattern]::Escape($txtDevSearch.Text.Trim())
  $script:Listing = $true
  $list.BeginUpdate(); $list.Items.Clear()
  foreach ($d in $script:Devices) {
    $s = $d.S; $user = Get-SessionUser $s
    if ($f -and -not (@($d.Name, $d.State, $s['IP'], $user, $s['DEFAULT_USER'], $s['MAC']) | Where-Object { "$_" -like "*$f*" })) { continue }
    $it = New-Object System.Windows.Forms.ListViewItem($d.Name)
    $it.ImageKey = $d.Kind; $it.UseItemStyleForSubItems = $false; $it.BackColor = $Theme.Card
    foreach ($v in @($d.State, $user, (Get-Version $s), (Get-Seen $d))) { [void]$it.SubItems.Add([string]$v) }
    $it.SubItems[1].ForeColor = if ($d.Kind -eq 'ok') { $Theme.Text } else { $script:KindColor[$d.Kind] }
    if (-not $user) { $it.SubItems[2].Text = '' }
    $it.ToolTipText = "$($d.Name)   $([char]0x00B7)   $($d.State)   $([char]0x00B7)   $($s['IP'])"
    foreach ($x in $it.SubItems) { $x.BackColor = $Theme.Card }
    $it.Tag = $d
    [void]$list.Items.Add($it)
    if ($d.File -eq $sel) { $it.Selected = $true; $script:Selected = $d }
  }
  $list.Sort()
  $list.EndUpdate()
  $script:Listing = $false
  if ($list.SelectedItems.Count) { $list.SelectedItems[0].EnsureVisible() }
  $on = @($script:Devices | Where-Object { $_.Minutes -le $script:StaleMinutes }).Count
  $bad = @($script:Devices | Where-Object { $_.Kind -in 'error', 'warn' }).Count
  $lblDevCount.Text = Get-Text 'DevCount' $script:Devices.Count $on $bad
  $navDevices.Tag.Count = "$($script:Devices.Count)"; $navDevices.Invalidate()
  $upd = try { Get-PublishedUpdate } catch { '?' }
  $barText.Text = Get-Text 'StatusBar' $script:Folder $script:Devices.Count $on $upd (Get-Date) $(if ($renamed.Count) { Get-Text 'StatusRenamed' ($renamed -join ', ') } else { '' })
  if ($script:Selected) { Update-DeviceHeader $script:Selected }
}

# header of the selected device: refreshed with the list, without touching the settings being edited
function Update-DeviceHeader($d) {
  if (-not $d) {
    $lblDevName.Text = Get-Text 'NoDevice'; $lblDevState.Visible = $false; $lblDevInfo.Text = ''
    $btnRemoteDev.Enabled = $false; $btnBrandDev.Enabled = $false; return
  }
  $s = $d.S
  $lblDevName.Text = $d.Name
  $lblDevState.Text = $d.State; $lblDevState.ForeColor = $script:KindColor[$d.Kind]; $lblDevState.BackColor = $script:KindSoft[$d.Kind]; $lblDevState.Visible = $true
  $lblDevState.Location = New-Object System.Drawing.Point(($lblDevName.Right + 12), ($lblDevName.Top + [int](($lblDevName.Height - $lblDevState.Height) / 2) + 1))
  $dot = "   $([char]0x00B7)   "; $parts = @()
  $ip = ([string]$s['IP']) -replace '/.*$', ''; if ($ip) { $parts += $ip }
  $v = Get-Version $s; if ($v) { $parts += Get-Text 'DevVersion' $v }
  $parts += Get-Text 'DevLastReport' (Get-Seen $d)
  $u = Get-SessionUser $s
  $parts += if ($u -and $u -eq (Get-Text 'UserKiosk') -and $s['SESSION'] -in $null, '', 'none') { Get-Text 'DevKioskPage' } elseif ($u) { Get-Text 'DevSessionOf' $u } else { Get-Text 'DevNoSession' }
  $lblDevInfo.Text = $parts -join $dot
  $btnRemoteDev.Enabled = $true; $btnBrandDev.Enabled = $true
}

function Update-Summary($d) {
  $s = $d.S
  $lvSummary.BeginUpdate(); $lvSummary.Items.Clear(); $lvSummary.Groups.Clear()
  $groups = [ordered]@{
    SumSession = @(@('ColSession', $s['SESSION']), @('ColDefaultUser', $s['DEFAULT_USER']), @('ColTransport', $s['TRANSPORT']), @('ColWebButton', $(
      $w = [string]$s['CFG_WEB_BUTTON']; if ($s['CFG_POWER_ON_TIME'] -or $s['CFG_POWER_OFF_TIME']) { $w += "   ($($s['CFG_POWER_ON_TIME'])-$($s['CFG_POWER_OFF_TIME']))" }; $w)))
    SumNetwork = @(@('ColIp', $s['IP']), @('ColMac', $s['MAC']), @('ColNetwork', $s['NETWORK']), @('ColWifi', $s['WIFI_STATUS']))
    SumSoftware = @(@('ColSoftware', $s['SOFTWARE']), @('ColFreeRdp', $s['FREERDP']), @('ColShareUpdate', $s['SHARE_UPDATE']), @('SumUpdateKeys', $(
      # where the updates come from, which signature they need, and the site key the device has (0.1.13 and later)
      if ($s['UPDATE_KEY']) { Get-Text 'SumUpdateKeysValue' $s['UPDATE_FROM'] $s['UPDATE_KEY'] $(if ($s['SITE_KEY'] -match '^[0-9A-F]{40}$') { ($s['SITE_KEY'] -replace '(.{4})', '$1 ').Trim() } else { Get-Text 'SumSiteKeyNone' }) }
      else { [string]$s['UPDATE_FROM'] })), @('ColSecurityUpdates', $(
      $x = [string]$s['SECURITY_UPDATES']; if ($s['LAST_UPDATE']) { $x = Get-Text 'LastUpdate' $x $s['LAST_UPDATE'] }; $x)))
    SumManagement = @(@('ColCentralConfig', $s['CENTRAL_CONFIG']), @('SumSecrets', $s['SECRETS']), @('SumSsh', $s['CFG_SSH']), @('SumRemoteScreen', $s['CFG_REMOTE_SCREEN']), @('ColUptime', $s['UPTIME']))
  }
  foreach ($gk in $groups.Keys) {
    $grp = New-Object System.Windows.Forms.ListViewGroup((Get-Text $gk)); [void]$lvSummary.Groups.Add($grp)
    foreach ($row in $groups[$gk]) {
      $val = [string]$row[1]; if (-not $val) { $val = [string][char]0x2014 }
      $it = New-Object System.Windows.Forms.ListViewItem((Get-Text $row[0]), $grp); $it.ForeColor = $Theme.Muted; $it.UseItemStyleForSubItems = $false
      $sub = $it.SubItems.Add($val); $sub.ForeColor = $Theme.Text
      [void]$lvSummary.Items.Add($it)
    }
  }
  $lvSummary.EndUpdate()
}

function Show-Device($d) {
  $script:Selected = $d
  Update-DeviceHeader $d
  if (-not $d) { $gridDev.Rows.Clear(); $txtStatus.Text = ''; $txtEvents.Text = ''; $lvSummary.Items.Clear(); return }
  $txtStatus.Text = (Read-Lines (Join-Path $script:StatusDir "$($d.File).txt")) -join "`r`n"
  $ev = @(Read-Lines (Join-Path $script:StatusDir "$($d.File)-events.log") | Where-Object { $_ })
  $txtEvents.Text = ($ev | Select-Object -Last 400) -join "`r`n"
  $txtEvents.SelectionStart = $txtEvents.Text.Length; $txtEvents.ScrollToCaret()
  Update-Summary $d
  Update-DeviceGrid
}

# value reported by the device for a setting (the secrets never come back as such)
function Get-ReportedValue($d, $s) {
  if ($s.Key -eq 'WIFI_PSK') { return (Get-Text 'ValNeverReadBack') }
  $v = if ($s.Key -eq 'HOSTNAME') { $d.S['HOSTNAME'] } else { $d.S["CFG_$($s.Key)"] }
  if ($null -eq $v) { return $null }
  if ($s.Key -eq 'SETTINGS_PIN_SHA256') { if ($v) { return $script:MarkSet } else { return (Get-Text 'ValNoPin') } }
  $v
}

function Update-DeviceGrid {
  $d = $script:Selected; if (-not $d) { return }
  $script:Loading = $true
  $common = Read-ConfFile $script:CommonFile
  $exc = Read-ConfFile (Get-HostFile $d.Name)
  $gridDev.Rows.Clear(); $section = $null
  $arrow = [string][char]0x2192
  foreach ($s in $script:Settings) {
    if ($s.Section -ne $section) { $section = $s.Section; Add-SectionRow $gridDev $section 4 }
    $now = Get-ReportedValue $d $s
    $nowText = if ($null -eq $now) { Get-Text 'ValNotReported' } else { $now }
    $use = $exc.Contains($s.Key)
    $inCommon = -not $s.HostOnly -and $common.Contains($s.Key)
    # where the value in force comes from, and the one on its way when the device has not applied it yet
    $src = if ($use) { 'SrcThis' } elseif ($inCommon) { 'SrcCommon' } else { 'SrcDevice' }
    $target = if ($use) { $exc[$s.Key] } elseif ($inCommon) { $common[$s.Key] } else { $null }
    $pending = $false
    if ($null -ne $target -and $null -ne $now -and $s.Key -notin 'WIFI_PSK', 'SETTINGS_PIN_SHA256') { $pending = (ConvertTo-Canonical $s.Key $target) -cne [string]$now }
    $i = $gridDev.Rows.Add(); $r = $gridDev.Rows[$i]
    $r.Cells[0].Value = $s.Label; $r.Cells[1].Value = [string]$nowText; $r.Tag = $s
    # on its way: where it comes from and the value in the tooltip, the cell stays short
    $r.Cells[2].Value = if ($pending) { "$arrow " + (Get-Text 'SrcPending') } else { Get-Text $src }
    $r.Cells[2].Style.ForeColor = if ($pending) { $script:KindColor.warn } elseif ($use) { New-Color '#a16207' } elseif ($inCommon) { $Theme.Accent } else { $Theme.Muted }
    $r.Cells[2].ToolTipText = if ($pending) { Get-Text 'TipPending' (Get-Text $src) (ConvertTo-Canonical $s.Key $target) } elseif ($s.HostOnly) { Get-Text 'ValDeviceOnly' } elseif ($common.Contains($s.Key)) { "common.conf: $(if ($s.Key -in 'WIFI_PSK', 'SETTINGS_PIN_SHA256') { $script:MarkSaved } else { $common[$s.Key] })" } else { Get-Text 'ValDeviceDecides' }
    $r.Cells[1].ToolTipText = [string]$nowText
    # without an exception the cell proposes the current value: ticking the box alone pins it
    $init = if ($use) { $exc[$s.Key] } elseif ($null -ne $now -and $s.Key -ne 'SETTINGS_PIN_SHA256') { $now } else { '' }
    if ($s.Key -eq 'WIFI_PSK') { $init = if ($use) { $script:MarkSaved } else { '' } }
    if ($s.Key -eq 'SETTINGS_PIN_SHA256' -and $use) { $init = if ($exc[$s.Key]) { $script:MarkSet } else { '' } }
    Set-Cell $r 3 $s $init
    $r.Cells[4].Value = $use
    Set-RowLook $r 3 4 $Theme.Own
  }
  $ign = @(Get-IgnoredKeys $exc)
  if ($ign.Count) { $barText.Text = Get-Text 'IgnoredKeysDevice' $d.Name ($ign -join ', ') }
  Set-GridFilter $gridDev $filterDev.Tag.Box.Text
  $gridDev.CurrentCell = $null; Show-Help $helpDev $null
  $script:Loading = $false; Set-Dirty 'dev' $false
}

function Update-CommonGrid {
  $script:Loading = $true
  $common = Read-ConfFile $script:CommonFile
  $commented = @{}
  foreach ($l in (Read-Lines $script:CommonFile)) { if ($l -cmatch '^\s*#\s*([A-Z][A-Z0-9_]*)\s*=\s*(.*?)\s*$') { $commented[$Matches[1]] = $Matches[2] } }
  $gridCom.Rows.Clear(); $section = $null
  foreach ($s in @($script:Settings | Where-Object { -not $_.HostOnly })) {
    if ($s.Section -ne $section) { $section = $s.Section; Add-SectionRow $gridCom $section 2 }
    $i = $gridCom.Rows.Add(); $r = $gridCom.Rows[$i]; $r.Tag = $s
    $r.Cells[0].Value = $s.Label
    # value proposed when the key is not managed yet: the commented line, else the first device that
    # reports it, else the project default
    $v = if ($common.Contains($s.Key)) { $common[$s.Key] } elseif ($commented.ContainsKey($s.Key)) { $commented[$s.Key] } else {
      $dd = $script:Devices | Where-Object { $null -ne $_.S["CFG_$($s.Key)"] } | Select-Object -First 1
      if ($dd) { $dd.S["CFG_$($s.Key)"] } else { $s.Default } }
    if ($s.Key -eq 'WIFI_PSK') { $v = if ($common.Contains('WIFI_PSK')) { $script:MarkSaved } else { '' } }
    if ($s.Key -eq 'SETTINGS_PIN_SHA256') { $v = if ($common[$s.Key]) { $script:MarkSet } else { '' } }
    Set-Cell $r 1 $s $v
    $r.Cells[2].Value = $common.Contains($s.Key)
    Set-RowLook $r 1 2 $Theme.Managed
  }
  $ign = @(Get-IgnoredKeys $common -Common)
  if ($ign.Count) { $barText.Text = Get-Text 'IgnoredKeysCommon' ($ign -join ', ') }
  Set-GridFilter $gridCom $filterCom.Tag.Box.Text
  $gridCom.CurrentCell = $null; Show-Help $helpCom $null
  $script:Loading = $false; Set-Dirty 'com' $false
}

function Update-KeysView {
  $script:Loading = $true
  $txtKeys.Text = if (Test-Path -LiteralPath $script:KeysFile) { (Read-Lines $script:KeysFile) -join "`r`n" } else { '' }
  $txtKeys.SelectionStart = 0; $txtKeys.SelectionLength = 0     # all selected, one key press would erase the list
  $script:Loading = $false; Set-Dirty 'keys' $false
}

function Save-Device {
  $d = $script:Selected; if (-not $d) { return }
  [void]$gridDev.EndEdit()
  $plan = Get-DeviceSavePlan $d (Get-GridValues $gridDev 3 4)
  if ($plan.Errors.Count) { Show-Message (Get-Text 'MsgInvalidTitle') ((Get-Text 'MsgNotSaved') + "`r`n`r`n- " + ($plan.Errors -join "`r`n- ")); return }
  if (-not $plan.Changes.Count) { Show-Message (Get-Text 'MsgNoChangesTitle') (Get-Text 'MsgNoChanges') 'Information'; return }
  $extra = if ($plan.Notes.Count) { "`r`n`r`n" + ($plan.Notes -join "`r`n`r`n") } else { '' }
  if (-not (Confirm-Action (Get-Text 'ConfirmSaveDeviceTitle' $d.Name) ((Get-Text 'ConfirmSaveDevice' $d.Name) + "`r`n`r`n- " + ($plan.Changes -join "`r`n- ") + $extra))) { return }
  try { [void](Write-ConfFile $plan.File $plan.Values $script:HostHeader $plan.RenameMac) } catch { Show-Message (Get-Text 'MsgErrorTitle') (Get-Text 'MsgSaveFailed' $_.Exception.Message) 'Error'; return }
  $barText.Text = Get-Text 'SavedDevice' $plan.File (Get-Text 'ColSource')
  Update-DeviceGrid
}

function Clear-Device {
  $d = $script:Selected; if (-not $d) { return }
  $f = Get-HostFile $d.Name
  if (-not (Test-Path -LiteralPath $f)) { Show-Message (Get-Text 'MsgNoExceptionsTitle') (Get-Text 'MsgNoExceptions' $d.Name) 'Information'; return }
  if (-not (Confirm-Action (Get-Text 'ConfirmRemoveTitle') (Get-Text 'ConfirmRemove' $d.Name) 'Button2')) { return }
  Move-Item -LiteralPath $f -Destination (Get-BackupPath $f)
  Add-ChangeLog "$($d.Name).conf: all exceptions removed"
  Update-DeviceGrid
}

function Save-Common {
  [void]$gridCom.EndEdit()
  $plan = Get-CommonSavePlan (Get-GridValues $gridCom 1 2) $script:Devices
  if ($plan.Errors.Count) { Show-Message (Get-Text 'MsgInvalidTitle') ((Get-Text 'MsgNotSaved') + "`r`n`r`n- " + ($plan.Errors -join "`r`n- ")); return }
  if (-not $plan.Changes.Count) { Show-Message (Get-Text 'MsgNoChangesTitle') (Get-Text 'MsgNoChanges') 'Information'; return }
  $extra = ''
  if ($plan.Warnings.Count) {
    $w = @($plan.Warnings | Select-Object -First 15); if ($plan.Warnings.Count -gt 15) { $w += Get-Text 'MsgMoreWarnings' ($plan.Warnings.Count - 15) }
    $extra += "`r`n`r`n" + (Get-Text 'MsgWillReject') + "`r`n- " + ($w -join "`r`n- ")
  }
  if ($plan.Notes.Count) { $extra += "`r`n`r`n" + ($plan.Notes -join "`r`n`r`n") }
  # with problems the safe answer is No
  $def = if ($plan.Warnings.Count -or $plan.Notes.Count) { 'Button2' } else { 'Button1' }
  if (-not (Confirm-Action (Get-Text 'ConfirmSaveCommonTitle') ((Get-Text 'ConfirmSaveCommon') + "`r`n`r`n- " + ($plan.Changes -join "`r`n- ") + $extra) $def)) { return }
  try { [void](Write-ConfFile $plan.File $plan.Values $script:CommonHeader) } catch { Show-Message (Get-Text 'MsgErrorTitle') (Get-Text 'MsgSaveFailed' $_.Exception.Message) 'Error'; return }
  $barText.Text = Get-Text 'SavedCommon' $plan.File (Get-Text 'ColSource')
  Update-CommonGrid
  if ($script:Selected) { Update-DeviceGrid }
}

function Save-Keys {
  $err = @(Test-AuthorizedKeys $txtKeys.Text)
  if ($err.Count) { Show-Message (Get-Text 'MsgKeysInvalidTitle') ((Get-Text 'MsgKeysNotSaved') + "`r`n`r`n- " + ($err -join "`r`n- ")); return }
  $n = @(Get-KeyLines $txtKeys.Text).Count
  $msg = if ($n) { Get-Text 'ConfirmSaveKeys' $n } else { Get-Text 'ConfirmSaveKeysEmpty' }
  if (-not (Confirm-Action (Get-Text 'ConfirmSaveKeysTitle') $msg $(if ($n) { 'Button1' } else { 'Button2' }))) { return }
  try { $r = Save-AuthorizedKeys $txtKeys.Text } catch { Show-Message (Get-Text 'MsgErrorTitle') (Get-Text 'MsgSaveFailed' $_.Exception.Message) 'Error'; return }
  $barText.Text = Get-Text 'SavedKeys' $script:KeysFile $r.Before $r.After
  Update-KeysView; Update-VaultView
}
# a public key into the list (not saved yet); $false = not a key line
function Add-KeyLine([string]$line) {
  $line = "$line".Trim()
  if ($line -cnotmatch $script:Rx.SshKey) { return $false }
  $body = ($line -split ' ')[1]
  if (@(Get-KeyLines $txtKeys.Text | Where-Object { ($_ -split ' ')[1] -ceq $body }).Count) { $barText.Text = Get-Text 'KeyAlready' (Get-KeyLabel $line); return $true }
  $t = $txtKeys.Text.TrimEnd()
  $txtKeys.Text = $(if ($t) { "$t`r`n$line" } else { $line }) + "`r`n"
  $barText.Text = Get-Text 'KeyAdded' (Get-KeyLabel $line)
  $true
}
# the key of the manager (in the vault, made when missing): the one the remote screen uses
function Add-MyKey {
  if (-not (Request-VaultOpen)) { return }
  if (-not $script:Vault['ssh_public']) {
    try { [void](New-VaultSshKey) } catch { Show-Message (Get-Text 'VaultTitle') $_.Exception.Message 'Error'; return } finally { Update-VaultView }
  }
  [void](Add-KeyLine $script:Vault['ssh_public']); Select-Page 2
}

# ---------------- vault ----------------
# the vault open: created at the first use (asking the code), opened with the code otherwise; $false = not open
function Request-VaultOpen {
  if (Test-VaultOpen) { return $true }
  if (-not (Test-VaultFile)) { return (Start-VaultCreate) }
  $ok = Show-CodeDialog 'Open' $form
  Update-VaultView
  $ok
}
# a new vault: the code, then a new SSH key for the manager, put in the SSH keys list (saved from there)
function Start-VaultCreate {
  if (-not (Show-CodeDialog 'Create' $form)) { Update-VaultView; return $false }
  $line = $null
  try { $line = New-VaultSshKey } catch { Show-Message (Get-Text 'VaultTitle') $_.Exception.Message 'Error' }
  Update-VaultView
  if ($line) { [void](Add-KeyLine $line); Select-Page 2; Show-Message (Get-Text 'VaultTitle') (Get-Text 'VaultCreated') 'Information' }
  $true
}
# the public SSH key of the vault is in config\authorized_keys (saved)
function Test-VaultKeyListed {
  if (-not (Test-VaultOpen) -or -not $script:Vault['ssh_public'] -or -not (Test-Path -LiteralPath $script:KeysFile)) { return $false }
  $body = ([string]$script:Vault['ssh_public'] -split ' ')[1]
  @(Get-KeyLines ((Read-Lines $script:KeysFile) -join "`n") | Where-Object { ($_ -split ' ')[1] -ceq $body }).Count -gt 0
}
function Update-VaultView {
  $open = Test-VaultOpen; $exists = Test-VaultFile
  $state = if ($open) { 'Open' } elseif ($exists) { 'Closed' } else { 'None' }
  $btnVaultTool.Text = Get-Text "VaultTool$state"
  $btnVaultTool.Image = New-Glyph $(if ($open) { 'Unlock' } else { 'Lock' }) $(if ($state -eq 'None') { $script:KindColor.warn } else { $Theme.ShellText }) 16
  $blkVault.Tag.Note.Text = Get-Text "VaultState$state" $script:VaultFile
  $btnVaultOpen.Text = Get-Text $(if ($open) { 'BtnVaultClose' } elseif ($exists) { 'BtnVaultOpen' } else { 'BtnVaultCreate' })
  $btnVaultOpen.Image = New-Glyph $(if ($open) { 'Lock' } else { 'Unlock' }) ([System.Drawing.Color]::White) 16
  $btnVaultCode.Enabled = $open
  if (-not $open) { $blkSsh.Tag.Note.Text = Get-Text 'VaultClosedNote'; $blkSign.Tag.Note.Text = Get-Text 'VaultClosedNote' }
  else {
    $pub = [string]$script:Vault['ssh_public']
    $blkSsh.Tag.Note.Text = if ($pub) { (Get-KeyLabel $pub) + "   $([char]0x00B7)   " + ($pub -split ' ')[0] + "`r`n" + (Get-Text $(if (Test-VaultKeyListed) { 'VaultSshListed' } else { 'VaultSshNotListed' })) } else { Get-Text 'VaultSshNone' }
    $k = Get-VaultSigningKey
    $blkSign.Tag.Note.Text = if ($k) {
      $fp = ($k.Hex() -replace '(.{4})', '$1 ').Trim()
      $when = [DateTimeOffset]::FromUnixTimeSeconds($k.Created).LocalDateTime.ToString('d')
      Get-Text 'VaultSignSet' $fp $k.User $when (Get-Text "VaultRole_$(Get-SigningKeyRole $k.Hex())")
    } else { Get-Text 'VaultSignNone' }
  }
  foreach ($b in @($btnVaultSshAdd, $btnVaultSshNew, $btnVaultSshImport, $btnVaultSignImport, $btnVaultSignNew)) { $b.Enabled = $open }
  $btnVaultSshAdd.Enabled = $open -and [bool]$script:Vault['ssh_public']
  $btnVaultSign.Enabled = $open -and [bool]$script:Vault['sign_seed']
  $btnVaultSignExport.Enabled = $btnVaultSign.Enabled
  # sending makes sense for a key of the site only: the devices have the project key already
  $btnVaultSignSend.Enabled = $btnVaultSign.Enabled -and [bool](Get-ResignKey)
  Set-VaultHeights
}
function Switch-Vault {
  if (Test-VaultOpen) { Close-Vault; Update-VaultView; $barText.Text = Get-Text 'VaultClosedNow'; return }
  [void](Request-VaultOpen)
}
function Import-SshKeyDialog {
  $ofd = New-Object System.Windows.Forms.OpenFileDialog; $ofd.Title = Get-Text 'VaultSshImportTitle'; $ofd.Filter = Get-Text 'VaultSshFilter'
  $d = Join-Path $env:USERPROFILE '.ssh'; if (Test-Path -LiteralPath $d) { $ofd.InitialDirectory = $d }
  if ($ofd.ShowDialog() -ne 'OK') { return }
  if ($script:Vault['ssh_private'] -and -not (Confirm-Action (Get-Text 'VaultTitle') (Get-Text 'VaultSshReplace') 'Button2')) { return }
  try { $line = Import-VaultSshKey $ofd.FileName } catch { Show-Message (Get-Text 'VaultTitle') $_.Exception.Message 'Error'; return } finally { Update-VaultView }
  Show-Message (Get-Text 'VaultTitle') (Get-Text 'VaultSshImported' (Get-KeyLabel $line) $ofd.FileName) 'Information'
}
function New-SshKeyAction {
  if (-not (Confirm-Action (Get-Text 'VaultTitle') (Get-Text $(if ($script:Vault['ssh_private']) { 'VaultSshReplace' } else { 'VaultSshNewConfirm' })) 'Button2')) { return }
  try { $line = New-VaultSshKey } catch { Show-Message (Get-Text 'VaultTitle') $_.Exception.Message 'Error'; return } finally { Update-VaultView }
  [void](Add-KeyLine $line); Select-Page 2
}
function Import-SigningKeyDialog {
  $ofd = New-Object System.Windows.Forms.OpenFileDialog; $ofd.Title = Get-Text 'VaultSignImportTitle'; $ofd.Filter = Get-Text 'VaultSignFilter'
  if ($ofd.ShowDialog() -ne 'OK') { return }
  if ($script:Vault['sign_seed'] -and -not (Confirm-Action (Get-Text 'VaultTitle') (Get-Text 'VaultSignReplace' $script:Vault['sign_fingerprint']) 'Button2')) { return }
  try { $k = Import-VaultSigningKey $ofd.FileName } catch { Show-Message (Get-Text 'VaultTitle') (Get-Text 'VaultSignNotValid' $_.Exception.Message) 'Error'; return } finally { Update-VaultView }
  Add-ChangeLog "vault: signing key $($k.Hex()) imported"
  # the exported file holds the key without any protection
  if (Confirm-Action (Get-Text 'VaultTitle') (Get-Text 'VaultSignDeleteFile' $k.Hex() $ofd.FileName)) {
    try { Remove-Item -LiteralPath $ofd.FileName -Force } catch { Show-Message (Get-Text 'VaultTitle') $_.Exception.Message 'Error' }
  }
}
# a new key of this site, in the vault; then its public half to save (update-key.asc)
function New-SiteKeyAction {
  $msg = if ($script:Vault['sign_seed']) { Get-Text 'VaultSignNewReplace' $script:Vault['sign_fingerprint'] } else { Get-Text 'VaultSignNewConfirm' }
  if (-not (Confirm-Action (Get-Text 'VaultTitle') $msg $(if ($script:Vault['sign_seed']) { 'Button2' } else { 'Button1' }))) { return }
  Add-Type -AssemblyName Microsoft.VisualBasic
  $def = if ($env:USERDNSDOMAIN) { "Thin client updates ($($env:USERDNSDOMAIN.ToLower()))" } else { 'Thin client updates' }
  $user = [Microsoft.VisualBasic.Interaction]::InputBox((Get-Text 'VaultSignNewName'), (Get-Text 'VaultTitle'), $def).Trim()
  if (-not $user) { return }
  if ($user.Length -gt 100 -or $user -match '[\x00-\x1f]') { Show-Message (Get-Text 'VaultTitle') (Get-Text 'VaultSignNewBadName'); return }
  try { $k = New-VaultSiteKey $user } catch { Show-Message (Get-Text 'VaultTitle') $_.Exception.Message 'Error'; return } finally { Update-VaultView }
  Add-ChangeLog "vault: new site key $($k.Hex()) ($user)"
  Show-Message (Get-Text 'VaultTitle') (Get-Text 'VaultSignNewDone' $k.Hex()) 'Information'
  Export-PublicKeyDialog
}
# the site key to every device that reports a different one (or none): over SSH, one by one, with the result of each
function Send-SiteKeyAction {
  $k = Get-VaultSigningKey; $key = Get-VaultKeyFile
  if (-not $k) { return }
  if (-not $key) { Show-Message (Get-Text 'VaultTitle') (Get-Text 'ErrRemoteNoVaultKey'); return }
  $fp = $k.Hex()
  $todo = @($script:Devices | Where-Object { $_.Kind -ne 'off' -and $_.S['SITE_KEY'] -ne $fp })
  $off = @($script:Devices | Where-Object { $_.Kind -eq 'off' -and $_.S['SITE_KEY'] -ne $fp })
  if (-not $todo.Count) { Show-Message (Get-Text 'VaultTitle') (Get-Text 'SendKeyNothing' $fp $off.Count) 'Information'; return }
  if (-not (Confirm-Action (Get-Text 'VaultTitle') (Get-Text 'SendKeyConfirm' $fp ($todo.Name -join ', ') $off.Count))) { return }
  $armored = [OtrVault]::ExportPublic($k); $lines = @()
  $form.Cursor = 'WaitCursor'
  try {
    foreach ($d in $todo) {
      $barText.Text = Get-Text 'SendKeyRunning' $d.Name; [System.Windows.Forms.Application]::DoEvents()
      $why = Send-SiteKey $d $key $armored
      $lines += if ($why) { "$([char]0x2717) $($d.Name): $why" } else { "$([char]0x2713) $($d.Name)" }
    }
  } finally { $form.Cursor = 'Default'; $barText.Text = '' }
  Add-ChangeLog "site key $fp sent over SSH: $(@($lines | ForEach-Object { $_.Substring(2) }) -join '; ')"
  Show-Message (Get-Text 'VaultTitle') ((Get-Text 'SendKeyDone' $fp $off.Count) + "`r`n`r`n" + ($lines -join "`r`n")) 'Information'
}
function Export-PublicKeyDialog {
  $sfd = New-Object System.Windows.Forms.SaveFileDialog; $sfd.Title = Get-Text 'VaultSignExportTitle'; $sfd.FileName = 'update-key.asc'
  $sfd.Filter = 'update-key.asc|*.asc'
  if ($sfd.ShowDialog() -ne 'OK') { return }
  try { $k = Export-VaultPublicKey $sfd.FileName } catch { Show-Message (Get-Text 'VaultTitle') $_.Exception.Message 'Error'; return }
  Show-Message (Get-Text 'VaultTitle') (Get-Text 'VaultSignExported' $sfd.FileName $k.Hex()) 'Information'
}
function Invoke-SignDialog {
  $ofd = New-Object System.Windows.Forms.OpenFileDialog; $ofd.Title = Get-Text 'SignTitle'; $ofd.Filter = 'LATEST.txt|LATEST.txt|*.txt|*.txt'
  if ($ofd.ShowDialog() -ne 'OK') { return }
  try { $r = Invoke-SignUpdate $ofd.FileName } catch { Show-Message (Get-Text 'SignTitle') $_.Exception.Message 'Error'; return }
  Add-ChangeLog "update $($r.Version) signed with key $($r.Fingerprint) ($($r.Signature))"
  $m = Get-Text 'SignDone' $r.Version $r.Fingerprint (Get-Text "SignRole_$($r.Role)") $r.Signature
  if (-not $r.PackageChecked) { $m += "`r`n`r`n" + (Get-Text 'SignNoPackage') }
  Show-Message (Get-Text 'SignTitle') $m 'Information'
}
function Add-KeyFromFile {
  $ofd = New-Object System.Windows.Forms.OpenFileDialog; $ofd.Title = Get-Text 'KeyFileTitle'; $ofd.Filter = Get-Text 'KeyFilter'
  $d = Join-Path $env:USERPROFILE '.ssh'; if (Test-Path -LiteralPath $d) { $ofd.InitialDirectory = $d }
  if ($ofd.ShowDialog() -ne 'OK') { return }
  $n = 0; foreach ($l in (Read-Lines $ofd.FileName)) { if (Add-KeyLine $l) { $n++ } }
  if (-not $n) { Show-Message (Get-Text 'KeyTitle') (Get-Text 'KeyNotValid' $ofd.FileName) }
}

# Logo and background picture of every device ($d = $null) or of one device: a preview on the background colors, where the
# picture comes from, Choose... and Remove for this level
function Show-BrandingDialog($d) {
  $hostName = if ($d) { $d.Name } else { '' }
  $common = Read-ConfFile $script:CommonFile
  $bgKey = { param($k, $def) $v = if ($d -and $d.S["CFG_$k"]) { $d.S["CFG_$k"] } elseif ($common[$k]) { $common[$k] } else { $def }
             try { [System.Drawing.ColorTranslator]::FromHtml($v) } catch { [System.Drawing.ColorTranslator]::FromHtml($def) } }
  $top = & $bgKey 'BG_TOP' '#1b2733'; $bottom = & $bgKey 'BG_BOTTOM' '#000000'
  $dlg = New-Object System.Windows.Forms.Form
  $dlg.Text = if ($d) { Get-Text 'BrandTitleDevice' $hostName } else { Get-Text 'BrandTitleCommon' }
  $dlg.Font = $fontBase; $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
  $dlg.StartPosition = 'CenterParent'; $dlg.ClientSize = New-Object System.Drawing.Size(700, 600)
  $note = New-Object System.Windows.Forms.Label; $note.SetBounds(12, 10, 676, 60)
  $note.Text = if ($d) { Get-Text 'BrandNoteDevice' $hostName } else { Get-Text 'BrandNoteCommon' }
  if ($d -and $d.S['BRANDING']) { $note.Text += "`r`n" + (Get-Text 'BrandReported' $d.S['BRANDING']) }
  $dlg.Controls.Add($note)
  $y = 76
  foreach ($kind in @('logo', 'splash')) {
    $box = New-Object System.Windows.Forms.GroupBox; $box.Text = Get-Text $(if ($kind -eq 'logo') { 'BrandLogo' } else { 'BrandSplash' })
    $ph = if ($kind -eq 'logo') { 150 } else { 260 }
    $box.SetBounds(12, $y, 676, $ph + 34); $y += $ph + 44
    $pic = New-Object System.Windows.Forms.PictureBox; $pic.SetBounds(12, 22, 470, $ph); $pic.SizeMode = 'CenterImage'
    $pic.Tag = @{ Top = $top; Bottom = $bottom }
    $pic.add_Paint({ param($s, $e)
      $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($s.ClientRectangle, $s.Tag.Top, $s.Tag.Bottom, 90.0)
      $e.Graphics.FillRectangle($br, $s.ClientRectangle); $br.Dispose()
      if ($s.Tag.Image) { $i = $s.Tag.Image
        $k = [Math]::Min(1.0, [Math]::Min([double]($s.Width - 8) / $i.Width, [double]($s.Height - 8) / $i.Height)); $w = [int]($i.Width * $k); $h = [int]($i.Height * $k)
        $e.Graphics.DrawImage($i, [int](($s.Width - $w) / 2), [int](($s.Height - $h) / 2), $w, $h) }
      elseif ($s.Tag.Text) { [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $s.Tag.Text, $fontBase, $s.ClientRectangle, [System.Drawing.Color]::White) } })
    $lbl = New-Object System.Windows.Forms.Label; $lbl.SetBounds(494, 22, 172, 60)
    $choose = New-Button 'BtnChoose' 172 27; $choose.Location = New-Object System.Drawing.Point(494, 88)
    $remove = New-Button 'BtnRemovePicture' 172 27; $remove.Location = New-Object System.Drawing.Point(494, 121)
    $state = @{ Kind = $kind; Host = $hostName; Pic = $pic; Label = $lbl; Remove = $remove }
    $refresh = {
      param($st)
      $src = Get-BrandingSource $st.Kind $st.Host
      if ($st.Pic.Tag.Image) { $st.Pic.Tag.Image.Dispose(); $st.Pic.Tag.Image = $null }
      $st.Pic.Tag.Text = ''
      if ($src.File) { try { $st.Pic.Tag.Image = Read-Picture $src.File } catch { $st.Pic.Tag.Text = $_.Exception.Message } }
      else { $st.Pic.Tag.Text = Get-Text 'BrandImageOwn' }
      $size = if ($st.Pic.Tag.Image) { "{0} x {1} px" -f $st.Pic.Tag.Image.Width, $st.Pic.Tag.Image.Height } else { '' }
      $st.Label.Text = switch ($src.From) { 'device' { Get-Text 'BrandFromDevice' $size } 'common' { Get-Text 'BrandFromCommon' $size } default { Get-Text 'BrandFromImage' } }
      # Remove only what belongs to this level: a device cannot remove the common picture
      $st.Remove.Enabled = Test-Path -LiteralPath (Get-BrandingFile $st.Kind $st.Host)
      $st.Pic.Invalidate()
    }
    $choose.Tag = @{ State = $state; Refresh = $refresh }; $remove.Tag = $choose.Tag
    $choose.add_Click({ param($s, $e)
      $ofd = New-Object System.Windows.Forms.OpenFileDialog; $ofd.Title = Get-Text 'BrandChooseTitle'; $ofd.Filter = Get-Text 'BrandFilter'
      if ($ofd.ShowDialog() -ne 'OK') { return }
      try { $r = Save-BrandingImage $ofd.FileName $s.Tag.State.Kind $s.Tag.State.Host; $barText.Text = Get-Text 'SavedBranding' $r.File $r.Width $r.Height }
      catch { Show-Message (Get-Text 'MsgErrorTitle') $_.Exception.Message 'Error' }
      & $s.Tag.Refresh $s.Tag.State })
    $remove.add_Click({ param($s, $e)
      if (-not (Confirm-Action (Get-Text 'BrandRemoveTitle') (Get-Text 'BrandRemoveConfirm') 'Button2')) { return }
      try { if (Remove-BrandingImage $s.Tag.State.Kind $s.Tag.State.Host) { $barText.Text = Get-Text 'RemovedBranding' (Get-BrandingFile $s.Tag.State.Kind $s.Tag.State.Host) } }
      catch { Show-Message (Get-Text 'MsgErrorTitle') $_.Exception.Message 'Error' }
      & $s.Tag.Refresh $s.Tag.State })
    $box.Controls.AddRange(@($pic, $lbl, $choose, $remove)); $dlg.Controls.Add($box)
    & $refresh $state
  }
  $close = New-Button 'BtnClose' 100 27; $close.Location = New-Object System.Drawing.Point((688 - $close.Width), ($y + 2)); $close.DialogResult = 'Cancel'
  $dlg.Controls.Add($close); $dlg.CancelButton = $close
  $dlg.ClientSize = New-Object System.Drawing.Size(700, ($y + 40)); $dlg.Tag = $dlg.ClientSize
  if ($env:OTR_MANAGER_BRANDING_SHOT) {   # test: draws the dialog into a PNG and closes it
    # control by control at their own size: Windows clamps the dialog to a small test screen, not its controls
    $dlg.add_Shown({ try { $dlg.Refresh(); $cs = $dlg.Tag; $b = New-Object System.Drawing.Bitmap($cs.Width, $cs.Height)
      $gb = [System.Drawing.Graphics]::FromImage($b); $gb.Clear($dlg.BackColor); $gb.Dispose()
      foreach ($c in $dlg.Controls) { $c.DrawToBitmap($b, $c.Bounds) }
      $b.Save($env:OTR_MANAGER_BRANDING_SHOT, [System.Drawing.Imaging.ImageFormat]::Png)
    } catch { [Console]::Error.WriteLine("branding screenshot failed: $($_.Exception.Message)") } finally { $dlg.Close() } })
  }
  [void]$dlg.ShowDialog($form)
  foreach ($c in $dlg.Controls) { if ($c -is [System.Windows.Forms.GroupBox]) { foreach ($p in $c.Controls) { if ($p -is [System.Windows.Forms.PictureBox] -and $p.Tag.Image) { $p.Tag.Image.Dispose() } } } }
  $dlg.Dispose()
}

# changing a value ticks "exception" / "managed here" by itself; the tick colours the row
$gridDev.add_CellValueChanged({ param($s, $e)
  if ($script:Loading -or $e.RowIndex -lt 0 -or $null -eq $gridDev.Rows[$e.RowIndex].Tag) { return }
  $r = $gridDev.Rows[$e.RowIndex]
  if ($e.ColumnIndex -eq 3) { $r.Cells[4].Value = $true }
  Set-RowLook $r 3 4 $Theme.Own; Set-Dirty 'dev' $true })
$gridCom.add_CellValueChanged({ param($s, $e)
  if ($script:Loading -or $e.RowIndex -lt 0 -or $null -eq $gridCom.Rows[$e.RowIndex].Tag) { return }
  $r = $gridCom.Rows[$e.RowIndex]
  if ($e.ColumnIndex -eq 1) { $r.Cells[2].Value = $true }
  Set-RowLook $r 1 2 $Theme.Managed; Set-Dirty 'com' $true })
foreach ($g in @($gridDev, $gridCom)) {
  $g.add_CurrentCellDirtyStateChanged({ param($s, $e) if ($s.IsCurrentCellDirty) { [void]$s.CommitEdit('CurrentCellChange') } })
  # the help of the selected setting under the grid
  $g.add_CurrentCellChanged({ param($s, $e) if ($script:Loading) { return }; $r = $s.CurrentRow; Show-Help $s.Tag $(if ($r) { $r.Tag } else { $null }) })
}
$txtKeys.add_TextChanged({ if (-not $script:Loading) { Set-Dirty 'keys' $true } })

$list.add_SelectedIndexChanged({ if (-not $script:Listing -and $list.SelectedItems.Count -eq 1) { Show-Device $list.SelectedItems[0].Tag } })
$txtDevSearch.add_TextChanged({ Update-DeviceList })
$btnRefresh.add_Click({
  Update-DeviceList
  if ($script:Selected) { $n = $script:Selected.File; $q = $script:Devices | Where-Object File -eq $n | Select-Object -First 1; if ($q) { Show-Device $q } }
  if ($script:Page -eq 3) { Update-ProblemView } })
$btnOpen.add_Click({ Start-Process explorer.exe $script:Folder })
$btnRelease.add_Click({
  $form.Cursor = 'WaitCursor'
  try { $rel = Get-Release } catch { $rel = [pscustomobject]@{ Ok = $false; Message = $_.Exception.Message } } finally { $form.Cursor = 'Default' }
  if (-not $rel.Ok) { Show-Message (Get-Text 'RelTitle') $rel.Message 'Information'; return }
  # the site key signs it again: the vault opened for it when there is one
  if ((Test-VaultFile) -and -not (Test-VaultOpen)) { [void](Request-VaultOpen) }
  $site = Get-ResignKey
  if ($site -and $rel.Signature -ne $true) { Show-Message (Get-Text 'RelTitle') (Get-Text 'RelResignUnchecked') 'Error'; Remove-Item -LiteralPath $rel.Dir -Recurse -Force -ErrorAction SilentlyContinue; return }
  $sigText = if ($rel.Signature) { Get-Text 'RelSigChecked' } else { Get-Text 'RelSigNotChecked' }
  $siteOnly = (Read-ConfFile $script:CommonFile)['UPDATE_KEY'] -eq 'site'
  $sigText += "`r`n" + $(if ($site) { Get-Text 'RelResign' $site.Hex() } elseif ($siteOnly) { Get-Text 'RelNoResignWarn' } else { Get-Text 'RelNoResign' })
  if (-not (Confirm-Action (Get-Text 'RelTitle') (Get-Text 'RelConfirm' $rel.Version (Get-PublishedUpdate) $sigText) 'Button2')) {
    Remove-Item -LiteralPath $rel.Dir -Recurse -Force -ErrorAction SilentlyContinue; return }
  try { Publish-Release $rel $site; Show-Message (Get-Text 'RelTitle') (Get-Text 'RelDone' $rel.Version) 'Information' }
  catch { Show-Message (Get-Text 'RelTitle') (Get-Text 'RelCopyFailed' $_.Exception.Message) 'Error' }
  Update-DeviceList
})
$btnPerm.add_Click({
  $acc = @(Get-MgmtAccounts $script:Devices)
  if (-not $acc.Count) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    $a = [Microsoft.VisualBasic.Interaction]::InputBox((Get-Text 'PermAskAccount'), (Get-Text 'PermTitle'), '')
    if (-not $a.Trim()) { return }; $acc = @($a.Trim())
  }
  $form.Cursor = 'WaitCursor'; $bad = $false
  try {
    $lines = foreach ($x in $acc) {
      Get-Text 'PermAccount' $x
      foreach ($r in (Test-FolderPermissions $x)) { if ($r.Problem) { $bad = $true; "  $([char]0x2717) $($r.Text)" } else { "  $([char]0x2713) $($r.Text)" } }
      ''
    }
    $lines += Get-Text 'PermFooter'
  } catch { $bad = $true; $lines = @($_.Exception.Message) } finally { $form.Cursor = 'Default' }
  Show-Message (Get-Text 'PermTitle') ($lines -join "`r`n") $(if ($bad) { 'Warning' } else { 'Information' })
})
function Update-ProblemView {
  $since = switch ($cmbPeriod.SelectedIndex) { 0 { (Get-Date).Date } 1 { (Get-Date).AddHours(-24) } 2 { (Get-Date).AddDays(-7) } default { (Get-Date).AddDays(-30) } }
  $form.Cursor = 'WaitCursor'
  try { $sum = Get-ProblemSummary (Get-ProblemEvents $since) } finally { $form.Cursor = 'Default' }
  $lblHeadline.Text = Get-ProblemHeadline $sum
  $lblHeadline.ForeColor = if (@($sum | Where-Object { $_ }).Count) { $Theme.Text } else { $script:KindColor.ok }
  $probList.BeginUpdate(); $probList.Items.Clear(); $probText.Text = ''
  foreach ($p in @($sum | Where-Object { $_ })) {
    $it = New-Object System.Windows.Forms.ListViewItem (Get-Text "Prob_$($p.Kind)")
    $it.ImageKey = if ($p.Wide) { 'warn' } else { 'off' }
    foreach ($v in @((Get-WhereLabel $p.Where), "$($p.Count)", "$($p.Devices.Count): $($p.Devices -join ', ')", ($p.Users -join ', '), $p.First.ToString('dd/MM HH:mm'), $p.Last.ToString('dd/MM HH:mm'))) { [void]$it.SubItems.Add($v) }
    if ($p.Wide) { $it.BackColor = $script:KindSoft.warn }
    $it.Tag = $p; [void]$probList.Items.Add($it)
  }
  $probList.EndUpdate()
}
$probList.add_SelectedIndexChanged({
  if ($probList.SelectedItems.Count -ne 1) { return }
  $probText.Text = (@($probList.SelectedItems[0].Tag.Events | ForEach-Object { '{0:dd/MM HH:mm:ss}  {1,-14} {2}' -f $_.Time, $_.Device, $_.Text }) -join "`r`n")
})
$cmbPeriod.add_SelectedIndexChanged({ if ($script:Page -eq 3) { Update-ProblemView } })
# ---------------- remote screen ----------------
# The screen of the device in the default browser: over SSH (the key of the manager in the vault, as otradmin) the
# device starts x11vnc and the noVNC viewer on 127.0.0.1 with a one-time password (remote-screen.sh); an SSH tunnel
# brings them to a free local port. Nothing is installed on this PC: the ssh.exe of Windows 10/11 and the browser.
# Only the key of the vault is offered (IdentitiesOnly): the keys in the profile of this account do not open
# screens. The device shows a notice while it lasts and stops by itself after 2 hours; closing the window here ends it.
function Start-RemoteScreen($d) {
  $name = $d.Name; $ip = ([string]$d.S['IP']) -replace '/.*$', ''
  if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) { Show-Message (Get-Text 'RemoteTitle' $name) (Get-Text 'ErrRemoteNoSshExe'); return }
  if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { Show-Message (Get-Text 'RemoteTitle' $name) (Get-Text 'ErrRemoteNoIp'); return }
  if ($d.S['CFG_SSH'] -ne 'on') { Show-Message (Get-Text 'RemoteTitle' $name) (Get-Text 'ErrRemoteNoSsh'); return }
  if (-not (Request-VaultOpen)) { return }
  $key = Get-VaultKeyFile
  if (-not $key) { Show-Message (Get-Text 'RemoteTitle' $name) (Get-Text 'ErrRemoteNoVaultKey'); Select-Page 4; return }
  $form.Cursor = 'WaitCursor'; $barText.Text = Get-Text 'RemoteStarting' $name; [System.Windows.Forms.Application]::DoEvents()
  try {
    $r = Invoke-DeviceSsh $ip 'sudo /opt/openthinrdp/remote-screen.sh start' $key
    $pw = if ($r.Text -match '(?m)^PASSWORD=(\S+)') { $Matches[1] } else { '' }
    if (-not $pw) {
      $why = if ($r.Text -match '(?m)^ERROR=(.+)$') { $Matches[1] } else { $r.Text.Trim() }
      Show-Message (Get-Text 'RemoteTitle' $name) (Get-Text 'ErrRemoteFailed' $why); return
    }
    # a free local port, then the tunnel to the viewer on the device (127.0.0.1:6080 there)
    $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0); $l.Start(); $port = $l.LocalEndpoint.Port; $l.Stop()
    # Start-Process joins the arguments with spaces: the path of the key in quotes
    $tunnel = Start-Process ssh.exe -WindowStyle Hidden -PassThru -ArgumentList @('-N', '-i', "`"$key`"", '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new',
      '-o', 'ExitOnForwardFailure=yes', '-o', 'ServerAliveInterval=15', '-L', "${port}:127.0.0.1:6080", "otradmin@$ip")
    $ok = $false
    for ($i = 0; $i -lt 40 -and -not $tunnel.HasExited; $i++) {
      try { $c = New-Object System.Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $port); $c.Close(); $ok = $true; break } catch { Start-Sleep -Milliseconds 250 }
    }
    if (-not $ok) {
      if (-not $tunnel.HasExited) { $tunnel.Kill() }
      [void](Invoke-DeviceSsh $ip 'sudo /opt/openthinrdp/remote-screen.sh stop' $key)
      Show-Message (Get-Text 'RemoteTitle' $name) (Get-Text 'ErrRemoteFailed' (Get-Text 'ErrRemoteTunnel')); return
    }
    Start-Process "http://127.0.0.1:$port/vnc_lite.html?password=$pw&scale=true"
    Add-ChangeLog (Get-Text 'LogRemoteScreen' $name)
  } finally { $form.Cursor = 'Default'; $barText.Text = '' }
  # while this window is open the remote screen stays on; closing it ends it on the device too
  $w = New-Object System.Windows.Forms.Form
  $w.Text = Get-Text 'RemoteTitle' $name; $w.Font = $fontBase; $w.StartPosition = 'CenterParent'; $w.FormBorderStyle = 'FixedDialog'
  $w.MinimizeBox = $false; $w.MaximizeBox = $false; $w.ClientSize = New-Object System.Drawing.Size(460, 130)
  $t = New-Object System.Windows.Forms.Label; $t.Text = Get-Text 'RemoteRunning' $name; $t.SetBounds(14, 12, 432, 70)
  $b = New-Button 'BtnRemoteEnd' 140 28; $b.Location = New-Object System.Drawing.Point((460 - $b.Width - 14), 90)
  $b.add_Click({ $w.Close() }); $w.AcceptButton = $b; $w.Controls.AddRange(@($t, $b))
  [void]$w.ShowDialog($form)
  if (-not $tunnel.HasExited) { $tunnel.Kill() }
  [void](Invoke-DeviceSsh $ip 'sudo /opt/openthinrdp/remote-screen.sh stop' $key)
}

$btnProbRefresh.add_Click({ Update-ProblemView })
$btnSaveDev.add_Click({ Save-Device })
$btnReloadDev.add_Click({ Update-DeviceGrid })
$btnClearDev.add_Click({ Clear-Device })
$btnSaveCom.add_Click({ Save-Common })
$btnReloadCom.add_Click({ Update-CommonGrid })
$btnBrandDev.add_Click({ if ($script:Selected) { Show-BrandingDialog $script:Selected } })
$btnRemoteDev.add_Click({ if ($script:Selected) { Start-RemoteScreen $script:Selected } })
$btnBrandCom.add_Click({ Show-BrandingDialog $null })
$btnSaveKeys.add_Click({ Save-Keys })
$btnReloadKeys.add_Click({ Update-KeysView })
$btnMyKey.add_Click({ Add-MyKey })
$btnKeyFile.add_Click({ Add-KeyFromFile })
$btnVaultTool.add_Click({ Select-Page 4 })
$btnVaultOpen.add_Click({ Switch-Vault })
$btnVaultCode.add_Click({ if (Show-CodeDialog 'Change' $form) { $barText.Text = Get-Text 'VaultCodeChanged' } })
$btnVaultSshAdd.add_Click({ [void](Add-KeyLine $script:Vault['ssh_public']); Select-Page 2 })
$btnVaultSshNew.add_Click({ New-SshKeyAction })
$btnVaultSshImport.add_Click({ Import-SshKeyDialog })
$btnVaultSign.add_Click({ Invoke-SignDialog })
$btnVaultSignImport.add_Click({ Import-SigningKeyDialog })
$btnVaultSignNew.add_Click({ New-SiteKeyAction })
$btnVaultSignExport.add_Click({ Export-PublicKeyDialog })
$btnVaultSignSend.add_Click({ Send-SiteKeyAction; Update-DeviceList })
# the secrets leave memory and the disk with the window
$form.add_FormClosed({ Close-Vault })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 60000
$timer.add_Tick({ Update-DeviceList })      # the list and the header only: grids being edited are left alone

$form.add_Shown({
  $split.SplitterDistance = [Math]::Max(400, [Math]::Min(500, [int]($split.Width * 0.38)))
  Select-Page 0
  Update-DeviceList; Update-CommonGrid; Update-KeysView
  if ($list.Items.Count) { $list.Items[0].Selected = $true } else { Show-Device $null }
  $timer.Start()
  # the access code at every start: the vault opened, or created the first time (both can be skipped)
  if ($env:OTR_MANAGER_SCREENSHOT) { if ($env:OTR_MANAGER_VAULT_CODE -and (Test-VaultFile)) { [void](Open-Vault $env:OTR_MANAGER_VAULT_CODE) } }
  else { [void](Request-VaultOpen) }
  Update-VaultView
})
if ($env:OTR_MANAGER_BRANDING_SHOT) {   # test: the logo dialog (of OTR_MANAGER_BRANDING_HOST, or common) into a PNG
  $form.add_Shown({ Show-BrandingDialog ($script:Devices | Where-Object Name -eq $env:OTR_MANAGER_BRANDING_HOST | Select-Object -First 1); $form.Close() })
}
if ($env:OTR_MANAGER_SCREENSHOT) {   # test: draws the window into a PNG instead of leaving it open
  # OTR_MANAGER_TAB = page (0 devices, 1 common, 2 keys, 3 problems), OTR_MANAGER_DETAIL = tab of the selected device,
  # OTR_MANAGER_DEVICE = the device to select, OTR_MANAGER_ROW = the setting whose help shows
  # an error must close the window and be reported: nobody is there to close it
  $form.add_Shown({ try {
    if ($env:OTR_MANAGER_DEVICE) { foreach ($it in $list.Items) { if ($it.Text -eq $env:OTR_MANAGER_DEVICE) { $it.Selected = $true } } }
    if ($env:OTR_MANAGER_TAB) { Select-Page ([int]$env:OTR_MANAGER_TAB) }
    if ($env:OTR_MANAGER_DETAIL) { $detail.SelectedIndex = [int]$env:OTR_MANAGER_DETAIL }
    if ($env:OTR_MANAGER_ROW) {
      $g = if ($script:Page -eq 1) { $gridCom } else { $gridDev }
      foreach ($r in $g.Rows) { if ($r.Tag -and $r.Tag.Key -eq $env:OTR_MANAGER_ROW) { $g.CurrentCell = $r.Cells[0]; break } }
    }
    # Windows clamps a window to the screen: the contents are drawn at the intended size instead (child controls
    # are not clamped), without the title bar
    $w = 1440; $h = 840
    $root.Dock = 'None'; $root.SetBounds(0, 0, $w, $h)
    $split.SplitterDistance = 470; $form.Refresh(); [System.Windows.Forms.Application]::DoEvents()
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $root.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $w, $h)))
    $bmp.Save($env:OTR_MANAGER_SCREENSHOT, [System.Drawing.Imaging.ImageFormat]::Png)
  } catch { [Console]::Error.WriteLine("screenshot failed: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))") } finally { $form.Close() } })
}
[void]$form.ShowDialog()
