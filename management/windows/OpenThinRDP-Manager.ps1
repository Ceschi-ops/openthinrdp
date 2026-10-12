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
  Tests:  . .\OpenThinRDP-Manager.ps1 -Folder <path> -FunctionsOnly [-Language en]   (loads the functions, no window)
          $env:OTR_MANAGER_SCREENSHOT = <file.png> (+ $env:OTR_MANAGER_TAB = 0, 1 or 2): draws the window into
          the PNG instead of showing it, then exits
#>
param(
  [string]$Folder,
  [string]$Language,       # en, it, ... (a file in lang\); empty = the Windows display language
  [switch]$FunctionsOnly   # for tests: load the functions without opening the window
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
    public int Column = 1;
    public bool Descending = false;
    public int Compare(object x, object y) {
        ListViewItem a = (ListViewItem)x, b = (ListViewItem)y;
        string sa = Column < a.SubItems.Count ? a.SubItems[Column].Text : "";
        string sb = Column < b.SubItems.Count ? b.SubItems[Column].Text : "";
        int r = Natural(Durations(sa), Durations(sb));
        if (r == 0 && Column != 1) { return Natural(a.SubItems.Count > 1 ? a.SubItems[1].Text : "", b.SubItems.Count > 1 ? b.SubItems[1].Text : ""); }
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
    // the settings PIN as kiosk.sh checks it: printf '%s' "$pin" | sha256sum
    public static string Sha256(string text) {
        using (SHA256 s = SHA256.Create()) { byte[] d = s.ComputeHash(Encoding.UTF8.GetBytes(text)); return Hex(d, d.Length); }
    }
    static string Hex(byte[] d, int n) { StringBuilder sb = new StringBuilder(); for (int i = 0; i < n; i++) sb.Append(d[i].ToString("x2")); return sb.ToString(); }
}
'@
}

# ---------------------------------------------------------------------------------------------
# Language: lang\en.psd1 has every text of the window, lang\<xx>.psd1 replaces the ones it translates
# (a key missing or empty there keeps the English text, never an empty label)
# ---------------------------------------------------------------------------------------------
$script:LangDir = Join-Path $PSScriptRoot 'lang'
function Read-LanguageTexts([string]$dir, [string]$lang) {
  $t = @{}
  $en = Import-PowerShellDataFile -LiteralPath (Join-Path $dir 'en.psd1')
  foreach ($k in $en.Keys) { $t[$k] = $en[$k] }
  $f = Join-Path $dir "$lang.psd1"
  if ($lang -and $lang -ne 'en' -and (Test-Path -LiteralPath $f)) {
    try { $tr = Import-PowerShellDataFile -LiteralPath $f } catch { Write-Warning "$f not readable, English texts used: $($_.Exception.Message)"; $tr = @{} }
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
  (New-Setting 'RDP_AUTH'            'choice'     'negotiate' @('negotiate', 'ntlm'))
  (New-Setting 'RDP_CERT'            'choice'     'tofu' @('tofu', 'ignore', 'verify'))
  (New-Setting 'RDP_GFX'             'gfx'        'progressive,AVC420:off,AVC444:off')
  (New-Setting 'RDP_KEYBOARD'        'rdpkbd'     '')
  (New-Setting 'MULTIMON'            'choice'     'auto' @('auto', 'off'))
  (New-Setting 'RDP_EXTRA'           'extra'      '')
  (New-Setting 'SESSION_THRESHOLD'   'threshold'  '10')
  (New-Setting 'SHUTDOWN_SECS'       'shutdown'   '10')
  (Set-Section 'SectionUsb')
  (New-Setting 'USB_MODE'            'choice'     'all' @('all', 'disks'))
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
  (New-Setting 'UPDATE_FROM'         'choice'     'github' @('github', 'share', 'off'))
  (New-Setting 'UPDATE_GITHUB'       'repo'       'OpenThinRdp/openthinrdp')
  (New-Setting 'SSH'                 'choice'     'off' @('off', 'on'))
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
    if ($key -in 'WIFI', 'SSH', 'SECURITY_UPDATES') { if ($l -in 'yes', 'true', '1', 'si') { return 'on' }; return 'off' }
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
function Get-PinHash([string]$pin) { [OtrCrypto]::Sha256($pin) }
# what the user typed in a secret cell -> what goes to the file (MarkSaved/MarkSet = keep the previous one)
function ConvertTo-WpaKey($v, $ssid) { if ($v -cmatch $script:Rx.Hex64) { $v.ToLower() } else { Get-WpaKey $v $ssid } }
function ConvertTo-PinHash($v) { if ($v -eq '') { '' } elseif ($v -cmatch $script:Rx.Hex64) { $v.ToLower() } else { Get-PinHash $v } }
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
    $state = Get-Text 'StateOk'; $color = [System.Drawing.Color]::FromArgb(220, 245, 220)
    if ($min -gt $script:StaleMinutes) { $state = Get-Text 'StateOffline' (Format-Minutes $min); $color = [System.Drawing.Color]::FromArgb(230, 230, 230) }
    elseif ($s['FAILED_UNITS'] -and $s['FAILED_UNITS'] -ne 'none') { $state = Get-Text 'StateFailedUnits'; $color = [System.Drawing.Color]::FromArgb(255, 205, 205) }
    elseif ($s['CENTRAL_CONFIG'] -like 'REJECTED*') { $state = Get-Text 'StateRejected'; $color = [System.Drawing.Color]::FromArgb(255, 225, 190) }
    elseif ($s['SHARE_UPDATE'] -like 'ERROR*' -or $s['SHARE_UPDATE'] -like 'IGNORED*') { $state = Get-Text 'StateUpdateError'; $color = [System.Drawing.Color]::FromArgb(255, 225, 190) }
    elseif ($s['REBOOT_REQUIRED'] -eq 'yes') { $state = Get-Text 'StateReboot'; $color = [System.Drawing.Color]::FromArgb(255, 245, 190) }
    $list += [pscustomobject]@{ Name = $s['HOSTNAME']; File = $f.BaseName; State = $state; OldName = $false; Color = $color; Minutes = $min; When = $when; S = $s }
  }
  # same MAC under two names = the old name left behind by a rename (normally the device removes it itself)
  foreach ($g in @($list | Where-Object { $_.S['MAC'] } | Group-Object { $_.S['MAC'] } | Where-Object Count -gt 1)) {
    $sorted = @($g.Group | Sort-Object When -Descending)
    $sorted | Select-Object -Skip 1 | ForEach-Object { $_.State = Get-Text 'StateOldName' $sorted[0].Name; $_.OldName = $true }
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
# else the project default), for the devices with UPDATE_FROM=share. The devices check the project signature
# themselves; here the package hash is always checked, the signature too when gpg is available (Git for
# Windows has it) and the project key is next to this tool (rootfs/opt/openthinrdp/keys in the repository).
# ---------------------------------------------------------------------------------------------
$script:ReleaseKey = Join-Path $PSScriptRoot '..\..\rootfs\opt\openthinrdp\keys\openthinrdp-release.asc'
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
# $true = good signature of the key, $false = bad, $null = not checked here (no gpg, or no key file)
function Test-ReleaseSignature([string]$sig, [string]$file, [string]$keyFile) {
  $gpg = @("$env:ProgramFiles\Git\usr\bin\gpg.exe", (Get-Command gpg.exe -ErrorAction SilentlyContinue).Source) |
    Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
  if (-not $gpg -or -not $keyFile -or -not (Test-Path -LiteralPath $keyFile)) { return $null }
  $gh = Join-Path $env:TEMP "otr-gpg-$(Get-Random)"; New-Item -ItemType Directory $gh | Out-Null
  # the gpg of Git for Windows is an MSYS program: it wants /c/x/y (C:\x and C:/x are read as relative paths),
  # and //server/share; Gpg4win wants Windows paths
  $msys = $gpg -like '*\usr\bin\gpg.exe'
  $p = { param($x) $q = (Resolve-Path -LiteralPath $x).ProviderPath
         if (-not $msys) { $q } elseif ($q -like '\\*') { $q -replace '\\', '/' } else { '/' + $q.Substring(0, 1).ToLower() + ($q.Substring(2) -replace '\\', '/') } }
  # gpg writes its notes on stderr: with "Stop", Windows PowerShell 5.1 turns them into errors even with 2>$null
  $ErrorActionPreference = 'Continue'
  try {
    & $gpg --homedir (& $p $gh) --batch --quiet --import (& $p $keyFile) 2>$null | Out-Null
    & $gpg --homedir (& $p $gh) --batch --quiet --verify (& $p $sig) (& $p $file) 2>$null | Out-Null
    $LASTEXITCODE -eq 0
  } finally { Remove-Item -LiteralPath $gh -Recurse -Force -ErrorAction SilentlyContinue }
}
# version order as "sort -V" on the devices: the numbers inside compare as numbers
function Compare-Version([string]$a, [string]$b) {
  $pa = @($a -split '[^0-9A-Za-z]+'); $pb = @($b -split '[^0-9A-Za-z]+')
  for ($i = 0; $i -lt [Math]::Max($pa.Count, $pb.Count); $i++) {
    $x = if ($i -lt $pa.Count) { $pa[$i] } else { '' }; $y = if ($i -lt $pb.Count) { $pb[$i] } else { '' }
    if ($x -match '^[0-9]+$' -and $y -match '^[0-9]+$') { $c = ([long]$x).CompareTo([long]$y) } else { $c = [string]::CompareOrdinal($x, $y) }
    if ($c) { return [Math]::Sign($c) }
  }
  0
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
  $l = Read-Lines "$tmp\LATEST.txt"
  $field = { param($lines, $k) ([string]($lines | Where-Object { $_ -match "^$k=" } | Select-Object -First 1) -replace "^$k=", '').Trim() }
  $v = & $field $l 'version'; $f = & $field $l 'file'; $h = & $field $l 'sha256'
  if ($v -cnotmatch '^[0-9A-Za-z._-]+$' -or $f -cnotmatch $script:ReleaseFileRx -or $h -cnotmatch '^[0-9a-f]{64}$') { return (& $fail (Get-Text 'RelNotValid')) }
  $sig = Test-ReleaseSignature "$tmp\LATEST.txt.sig" "$tmp\LATEST.txt" $keyFile
  if ($sig -eq $false) { return (& $fail (Get-Text 'RelBadSignature' $v)) }
  $cur = Join-Path $script:Folder 'updates\LATEST.txt'
  if (Test-Path -LiteralPath $cur) {
    $cv = & $field (Read-Lines $cur) 'version'
    if ($cv -and (Compare-Version $v $cv) -le 0) { return (& $fail (Get-Text 'RelNotNewer' $v $cv)) }
  }
  try { Get-ReleaseFile $base $f "$tmp\$f" } catch { return (& $fail (Get-Text 'RelNotFound' "$base/$f" $_.Exception.Message)) }
  if ((Get-FileHash -LiteralPath "$tmp\$f" -Algorithm SHA256).Hash.ToLower() -ne $h) { return (& $fail (Get-Text 'RelBadHash' $f)) }
  [pscustomobject]@{ Ok = $true; Version = $v; File = $f; Hash = $h; Signature = $sig; Dir = $tmp; Source = $base }
}
# Copies a checked release into updates\: package first, then signature and index (a device never sees an
# index that points to a missing package); the last 3 packages are kept. Removes the temporary folder.
function Publish-Release($rel) {
  try {
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
    Add-ChangeLog ("release {0} copied into updates\ from {1} (signature {2})" -f $rel.Version, $rel.Source, $(if ($rel.Signature) { 'checked here' } else { 'not checked here: the devices check it' }))
  } finally { Remove-Item -LiteralPath $rel.Dir -Recurse -Force -ErrorAction SilentlyContinue }
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
      if ($k -in 'WIFI_PSK', 'SETTINGS_PIN_SHA256') { $a = $a -replace '^[0-9a-f]{64}$', '(hash)'; $b = $b -replace '^[0-9a-f]{64}$', '(new hash)' }
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
# =============================================================================================
[System.Windows.Forms.Application]::EnableVisualStyles()
function Show-Message($title, $text, $icon = 'Warning') { [void][System.Windows.Forms.MessageBox]::Show($text, $title, 'OK', $icon) }
function Confirm-Action($title, $text, $default = 'Button1') {
  [System.Windows.Forms.MessageBox]::Show($text, $title, 'YesNo', 'Question', $default) -eq 'Yes'
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

$fontBase = New-Object System.Drawing.Font('Segoe UI', 9)
$fontMono = New-Object System.Drawing.Font('Consolas', 9)
$fontBold = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

# Sizes from the texts, so that longer translations fit: a column is never narrower than its title or
# than the samples given (labels, placeholders), a button never narrower than its text.
function Get-TextWidth($text, $font = $fontBase) { [System.Windows.Forms.TextRenderer]::MeasureText([string]$text, $font).Width }
function Get-FitWidth($width, $texts, $font = $fontBase, $pad = 16) {
  foreach ($t in @($texts)) { $width = [Math]::Max($width, (Get-TextWidth $t $font) + $pad) }
  $width
}
function New-Button($textKey, $minWidth, $height) {
  $b = New-Object System.Windows.Forms.Button; $b.Text = Get-Text $textKey; $b.Font = $fontBase
  $b.Size = New-Object System.Drawing.Size((Get-FitWidth $minWidth $b.Text -pad 20), $height)
  $b
}
function Measure-Note($text, $width) {
  [System.Windows.Forms.TextRenderer]::MeasureText([string]$text, $fontBase, (New-Object System.Drawing.Size([Math]::Max(50, $width), 0)), [System.Windows.Forms.TextFormatFlags]::WordBreak).Height
}
# a row of buttons and a note after them: the note takes the rest of the width and wraps, and the panel
# grows when the note needs more lines than its usual height holds
function Set-ButtonRow($panel, $buttons, $note, $top) {
  $note.AutoSize = $false; $note.Font = $fontBase
  $x = 8; foreach ($b in $buttons) { $b.Location = New-Object System.Drawing.Point($x, $top); $x = $b.Right + 6 }; $x += 6
  $panel.Tag = @{ Buttons = $buttons; Note = $note; Top = $top; X = $x; MinHeight = $panel.Height }
  $panel.Controls.AddRange(@($buttons + $note))
  $panel.add_Resize({ param($p, $e) Update-ButtonRow $p })
  # the height is set from the Layout event of the container: it runs before the container arranges its
  # docked children. A height changed later (e.g. in Resize) is not applied to the neighbours.
  $panel.add_ParentChanged({ param($p, $e)
    if ($p.Parent) { $p.Parent.add_Layout({ param($c, $e)
      foreach ($q in $c.Controls) { if ($q.Tag -is [hashtable] -and $q.Tag.ContainsKey('Note')) { Set-ButtonRowHeight $q $c.DisplayRectangle.Width } } }) } })
  Update-ButtonRow $panel
}
function Set-ButtonRowHeight($p, $width) {
  $t = $p.Tag; $h = Measure-Note $t.Note.Text ($width - $t.X - 8)
  $need = if ($h -gt $t.Buttons[0].Height) { [Math]::Max($t.MinHeight, $t.Top - 1 + $h + 2 + $t.Top) } else { $t.MinHeight }
  if ($p.Height -ne $need) { $p.Height = $need }
}
function Update-ButtonRow($p) {
  $t = $p.Tag; $w = [Math]::Max(100, $p.ClientSize.Width - $t.X - 8)
  $h = Measure-Note $t.Note.Text $w; $bh = $t.Buttons[0].Height
  # one line: centred on the buttons, as before; more lines: from the top of the buttons
  $y = if ($h -le $bh) { $t.Top + [int][Math]::Floor(($bh - $h) / 2) } else { $t.Top - 1 }
  $t.Note.SetBounds($t.X, $y, $w, [Math]::Max($h + 2, $p.ClientSize.Height - $y))
}

$form = New-Object System.Windows.Forms.Form
$form.Text = Get-Text 'WindowTitle' $script:Folder
$form.Size = New-Object System.Drawing.Size(1280, 820)
$form.MinimumSize = New-Object System.Drawing.Size(1000, 640)
$form.StartPosition = 'CenterScreen'
$form.Font = $fontBase

$bar = New-Object System.Windows.Forms.StatusStrip
$barText = New-Object System.Windows.Forms.ToolStripStatusLabel
$barText.Spring = $true; $barText.TextAlign = 'MiddleLeft'
[void]$bar.Items.Add($barText)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabDevices = New-Object System.Windows.Forms.TabPage (Get-Text 'TabDevices')
$tabCommon = New-Object System.Windows.Forms.TabPage (Get-Text 'TabCommon')
$tabKeys = New-Object System.Windows.Forms.TabPage (Get-Text 'TabKeys')
$tabs.TabPages.AddRange(@($tabDevices, $tabCommon, $tabKeys))

# ---------------- Devices tab ----------------
$topPanel = New-Object System.Windows.Forms.Panel
$topPanel.Dock = 'Top'; $topPanel.Height = 38
$btnRefresh = New-Button 'BtnRefresh' 120 26
$btnOpen = New-Button 'BtnOpenFolder' 110 26
$btnRelease = New-Button 'BtnImportRelease' 150 26
$lblNote = New-Object System.Windows.Forms.Label
$lblNote.Text = Get-Text 'NoteDevices'
Set-ButtonRow $topPanel @($btnRefresh, $btnOpen, $btnRelease) $lblNote 6

$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'; $split.Orientation = 'Horizontal'

$list = New-Object System.Windows.Forms.ListView
$list.Dock = 'Fill'; $list.View = 'Details'; $list.FullRowSelect = $true; $list.MultiSelect = $false; $list.HideSelection = $false; $list.GridLines = $true
foreach ($c in @(@('ColState', 160), @('ColHostname', 110), @('ColSoftware', 95), @('ColWebButton', 125), @('ColIp', 120), @('ColDefaultUser', 105), @('ColSession', 140),
                 @('ColLastReport', 115), @('ColTransport', 150), @('ColShareUpdate', 200), @('ColWifi', 210), @('ColMac', 125), @('ColUptime', 120), @('ColNetwork', 60),
                 @('ColFreeRdp', 150), @('ColCentralConfig', 220), @('ColSecurityUpdates', 210))) {
  # room for the sort arrow too
  $title = Get-Text $c[0]
  [void]$list.Columns.Add($title, (Get-FitWidth $c[1] "$title $([char]0x25B2)" -pad 14))
}
# click on a header = sort by that column, second click = reverse; the arrow shows which.
# The chosen order stays when the list refreshes by itself.
$script:Sorter = New-Object OtrColumnSorter
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
$split.Panel1.Controls.Add($list)

$detail = New-Object System.Windows.Forms.TabControl
$detail.Dock = 'Fill'
$tabStatus = New-Object System.Windows.Forms.TabPage (Get-Text 'TabStatus')
$tabEvents = New-Object System.Windows.Forms.TabPage (Get-Text 'TabEvents')
$tabDevSettings = New-Object System.Windows.Forms.TabPage (Get-Text 'TabDeviceSettings')
$detail.TabPages.AddRange(@($tabDevSettings, $tabStatus, $tabEvents))
function New-TextView { $t = New-Object System.Windows.Forms.TextBox; $t.Multiline = $true; $t.ReadOnly = $true; $t.ScrollBars = 'Both'; $t.WordWrap = $false; $t.Dock = 'Fill'; $t.Font = $fontMono; $t.BackColor = [System.Drawing.Color]::White; $t }
$txtStatus = New-TextView; $tabStatus.Controls.Add($txtStatus)
$txtEvents = New-TextView; $tabEvents.Controls.Add($txtEvents)

function New-Grid {
  $g = New-Object System.Windows.Forms.DataGridView
  $g.Dock = 'Fill'; $g.AllowUserToAddRows = $false; $g.AllowUserToDeleteRows = $false; $g.RowHeadersVisible = $false
  $g.SelectionMode = 'CellSelect'; $g.AutoSizeRowsMode = 'None'; $g.EditMode = 'EditOnEnter'; $g.BackgroundColor = [System.Drawing.Color]::White
  $g.add_DataError({ param($s, $e) $e.ThrowException = $false })
  $g
}
function Add-TextColumn($g, $titleKey, $width, $readOnly, $samples = @(), $boldSamples = @()) {
  $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $col.HeaderText = Get-Text $titleKey; $col.ReadOnly = $readOnly; $col.SortMode = 'NotSortable'
  if ($width) { $col.Width = Get-FitWidth (Get-FitWidth (Get-FitWidth $width $col.HeaderText) $samples $fontBase 10) $boldSamples $fontBold 12 } else { $col.AutoSizeMode = 'Fill' }
  [void]$g.Columns.Add($col)
}
function Add-CheckColumn($g, $titleKey, $width) {
  $col = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn; $col.HeaderText = Get-Text $titleKey
  $col.Width = Get-FitWidth $width $col.HeaderText $fontBase 14; [void]$g.Columns.Add($col)
}
# the first column holds the setting names and the group titles (bold)
$labels = @($script:Settings | ForEach-Object { $_.Label })
$sections = @($script:Settings | ForEach-Object { $_.Section } | Select-Object -Unique)
# exceptions grid of the selected device
$gridDev = New-Grid
Add-TextColumn $gridDev 'ColSetting' 175 $true $labels $sections; Add-TextColumn $gridDev 'ColOnDevice' 210 $true
Add-TextColumn $gridDev 'ColFromCommon' 200 $true @((Get-Text 'ValDeviceDecides'), (Get-Text 'ValDeviceOnly'))
Add-TextColumn $gridDev 'ColException' 230 $false
Add-CheckColumn $gridDev 'ColUseException' 95
Add-TextColumn $gridDev 'ColHelp' $null $true
$devPanel = New-Object System.Windows.Forms.Panel; $devPanel.Dock = 'Bottom'; $devPanel.Height = 40
$btnSaveDev = New-Button 'BtnSaveExceptions' 130 27
$btnReloadDev = New-Button 'BtnUndo' 130 27
$btnClearDev = New-Button 'BtnRemoveExceptions' 160 27
$btnBrandDev = New-Button 'BtnBranding' 150 27
$lblDev = New-Object System.Windows.Forms.Label
$lblDev.Text = Get-Text 'NoteDevice' (Get-Text 'ColUseException')
Set-ButtonRow $devPanel @($btnSaveDev, $btnReloadDev, $btnClearDev, $btnBrandDev) $lblDev 7
$tabDevSettings.Controls.Add($gridDev); $tabDevSettings.Controls.Add($devPanel)
$split.Panel2.Controls.Add($detail)
$tabDevices.Controls.Add($split); $tabDevices.Controls.Add($topPanel)

# ---------------- Common settings tab ----------------
$gridCom = New-Grid
Add-TextColumn $gridCom 'ColSetting' 190 $true $labels $sections;Add-TextColumn $gridCom 'ColValueAll' 300 $false
Add-CheckColumn $gridCom 'ColManagedHere' 100
Add-TextColumn $gridCom 'ColHelp' $null $true
$comPanel = New-Object System.Windows.Forms.Panel; $comPanel.Dock = 'Bottom'; $comPanel.Height = 58
$btnSaveCom = New-Button 'BtnSaveCommon' 140 27
$btnReloadCom = New-Button 'BtnUndo' 130 27
$btnBrandCom = New-Button 'BtnBranding' 150 27
$lblCom = New-Object System.Windows.Forms.Label
$lblCom.Text = Get-Text 'NoteCommon' (Get-Text 'ColManagedHere') (Get-Text 'TabDevices')
Set-ButtonRow $comPanel @($btnSaveCom, $btnReloadCom, $btnBrandCom) $lblCom 7
$tabCommon.Controls.Add($gridCom); $tabCommon.Controls.Add($comPanel)

# ---------------- SSH keys tab ----------------
$txtKeys = New-Object System.Windows.Forms.TextBox
$txtKeys.Multiline = $true; $txtKeys.ScrollBars = 'Both'; $txtKeys.WordWrap = $false; $txtKeys.Dock = 'Fill'; $txtKeys.Font = $fontMono; $txtKeys.AcceptsReturn = $true
$keysPanel = New-Object System.Windows.Forms.Panel; $keysPanel.Dock = 'Bottom'; $keysPanel.Height = 58
$btnSaveKeys = New-Button 'BtnSaveKeys' 150 27
$btnReloadKeys = New-Button 'BtnUndo' 130 27
$lblKeys = New-Object System.Windows.Forms.Label
$lblKeys.Text = Get-Text 'NoteKeys'
Set-ButtonRow $keysPanel @($btnSaveKeys, $btnReloadKeys) $lblKeys 7
$tabKeys.Controls.Add($txtKeys); $tabKeys.Controls.Add($keysPanel)

$form.Controls.Add($tabs); $form.Controls.Add($bar)

# ---------------------------------------------------------------------------------------------
# Behaviour
# ---------------------------------------------------------------------------------------------
$script:Devices = @(); $script:Selected = $null; $script:Loading = $false

function Set-Cell($row, $col, $s, $value) {
  if ($s.Type -eq 'choice') {
    $cb = New-Object System.Windows.Forms.DataGridViewComboBoxCell
    foreach ($c in $s.Choices) { [void]$cb.Items.Add($c) }
    $cb.FlatStyle = 'Flat'; $row.Cells[$col] = $cb
    $cb.Value = if ($null -ne $value -and $value -ne '') { ConvertTo-Canonical $s.Key $value } else { $s.Choices[0] }
  } else { $row.Cells[$col].Value = [string]$value }
}
function Get-Cell($row, $col) { $v = $row.Cells[$col].Value; if ($null -eq $v) { '' } else { ([string]$v).Trim() } }
# the settings are many: a grey title row per group (Tag = $null, skipped when saving)
function Add-SectionRow($g, $title, $checkCol) {
  $i = $g.Rows.Add(); $r = $g.Rows[$i]
  $r.Cells[$checkCol] = New-Object System.Windows.Forms.DataGridViewTextBoxCell
  $r.Cells[0].Value = $title; $r.ReadOnly = $true; $r.Tag = $null
  $r.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(235, 235, 235); $r.DefaultCellStyle.Font = $fontBold
}
# Managed values of a grid: KEY -> value, or $null when the tick is off
function Get-GridValues($g, $valueCol, $checkCol) {
  $m = [ordered]@{}
  foreach ($r in $g.Rows) { if ($null -eq $r.Tag) { continue }; $m[$r.Tag.Key] = if ($r.Cells[$checkCol].Value -eq $true) { Get-Cell $r $valueCol } else { $null } }
  $m
}

function Update-DeviceList {
  try {
    $renamed = @(Complete-Renames)
    $script:Devices = @(Get-Devices)
  } catch { $barText.Text = Get-Text 'ErrReadFolder' $script:Folder $_.Exception.Message; return }
  $sel = if ($script:Selected) { $script:Selected.File } else { $null }
  $list.BeginUpdate(); $list.Items.Clear()
  foreach ($d in $script:Devices) {
    $s = $d.S
    $it = New-Object System.Windows.Forms.ListViewItem($d.State)
    $web = [string]$s['CFG_WEB_BUTTON']
    # schedule "07:30-19:00" (power on - power off) next to the web button mode
    if ($s['CFG_POWER_ON_TIME'] -or $s['CFG_POWER_OFF_TIME']) { $web += " $($s['CFG_POWER_ON_TIME'])-$($s['CFG_POWER_OFF_TIME'])" }
    $sec = [string]$s['SECURITY_UPDATES']; if ($s['LAST_UPDATE']) { $sec = Get-Text 'LastUpdate' $sec $s['LAST_UPDATE'] }
    foreach ($v in @($d.Name, ([string]$s['SOFTWARE']).Trim(), $web, $s['IP'], $s['DEFAULT_USER'], $s['SESSION'], ('{0:yyyy-MM-dd HH:mm}' -f $d.When), $s['TRANSPORT'],
                     $s['SHARE_UPDATE'], $s['WIFI_STATUS'], $s['MAC'], $s['UPTIME'], $s['NETWORK'], $s['FREERDP'], $s['CENTRAL_CONFIG'], $sec)) { [void]$it.SubItems.Add([string]$v) }
    $it.BackColor = $d.Color; $it.Tag = $d
    [void]$list.Items.Add($it)
    if ($d.File -eq $sel) { $it.Selected = $true }
  }
  $list.Sort()
  $list.EndUpdate()
  if ($list.SelectedItems.Count) { $list.SelectedItems[0].EnsureVisible() }
  $on = @($script:Devices | Where-Object { $_.Minutes -le $script:StaleMinutes }).Count
  $upd = try { Get-PublishedUpdate } catch { '?' }
  $barText.Text = Get-Text 'StatusBar' $script:Folder $script:Devices.Count $on $upd (Get-Date) $(if ($renamed.Count) { Get-Text 'StatusRenamed' ($renamed -join ', ') } else { '' })
}

function Show-Device($d) {
  $script:Selected = $d
  $txtStatus.Text = (Read-Lines (Join-Path $script:StatusDir "$($d.File).txt")) -join "`r`n"
  $ev = @(Read-Lines (Join-Path $script:StatusDir "$($d.File)-events.log") | Where-Object { $_ })
  $txtEvents.Text = ($ev | Select-Object -Last 400) -join "`r`n"
  $txtEvents.SelectionStart = $txtEvents.Text.Length; $txtEvents.ScrollToCaret()
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
  foreach ($s in $script:Settings) {
    if ($s.Section -ne $section) { $section = $s.Section; Add-SectionRow $gridDev $section 4 }
    $now = Get-ReportedValue $d $s
    $nowText = if ($null -eq $now) { Get-Text 'ValNotReported' } else { $now }
    $fromCommon = if ($s.HostOnly) { Get-Text 'ValDeviceOnly' } elseif ($common.Contains($s.Key)) { $common[$s.Key] } else { Get-Text 'ValDeviceDecides' }
    if ($s.Key -eq 'WIFI_PSK' -and $common.Contains($s.Key)) { $fromCommon = $script:MarkSaved }
    if ($s.Key -eq 'SETTINGS_PIN_SHA256' -and $common.Contains($s.Key)) { $fromCommon = if ($common[$s.Key]) { $script:MarkSet } else { Get-Text 'ValNoPin' } }
    $i = $gridDev.Rows.Add(); $r = $gridDev.Rows[$i]
    $r.Cells[0].Value = $s.Label; $r.Cells[1].Value = [string]$nowText; $r.Cells[2].Value = [string]$fromCommon; $r.Tag = $s
    $use = $exc.Contains($s.Key)
    # without an exception the cell proposes the current value: ticking the box alone pins it
    $init = if ($use) { $exc[$s.Key] } elseif ($null -ne $now -and $s.Key -ne 'SETTINGS_PIN_SHA256') { $now } else { '' }
    if ($s.Key -eq 'WIFI_PSK') { $init = if ($use) { $script:MarkSaved } else { '' } }
    if ($s.Key -eq 'SETTINGS_PIN_SHA256' -and $use) { $init = if ($exc[$s.Key]) { $script:MarkSet } else { '' } }
    Set-Cell $r 3 $s $init
    $r.Cells[4].Value = $use; $r.Cells[5].Value = $s.Help
    if ($use) { $r.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255, 250, 215) }
  }
  $ign = @(Get-IgnoredKeys $exc)
  $tabDevSettings.Text = Get-Text 'TabDeviceSettingsOf' $d.Name
  if ($ign.Count) { $barText.Text = Get-Text 'IgnoredKeysDevice' $d.Name ($ign -join ', ') }
  $gridDev.CurrentCell = $null
  $script:Loading = $false
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
    $r.Cells[2].Value = $common.Contains($s.Key); $r.Cells[3].Value = $s.Help
    if ($common.Contains($s.Key)) { $r.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(225, 240, 255) }
  }
  $ign = @(Get-IgnoredKeys $common -Common)
  if ($ign.Count) { $barText.Text = Get-Text 'IgnoredKeysCommon' ($ign -join ', ') }
  $gridCom.CurrentCell = $null
  $script:Loading = $false
}

function Update-KeysView {
  $txtKeys.Text = if (Test-Path -LiteralPath $script:KeysFile) { (Read-Lines $script:KeysFile) -join "`r`n" } else { '' }
  $txtKeys.SelectionStart = 0; $txtKeys.SelectionLength = 0     # all selected, one key press would erase the list
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
  $barText.Text = Get-Text 'SavedDevice' $plan.File (Get-Text 'ColCentralConfig')
  Update-DeviceGrid
}

function Clear-Device {
  $d = $script:Selected; if (-not $d) { return }
  $f = Get-HostFile $d.Name
  if (-not (Test-Path -LiteralPath $f)) { Show-Message (Get-Text 'MsgNoExceptionsTitle') (Get-Text 'MsgNoExceptions' $d.Name) 'Information'; return }
  if (-not (Confirm-Action (Get-Text 'ConfirmRemoveTitle') (Get-Text 'ConfirmRemove' $d.Name))) { return }
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
  $barText.Text = Get-Text 'SavedCommon' $plan.File (Get-Text 'ColCentralConfig')
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
  Update-KeysView
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

# changing a value ticks "Use exception" / "Managed here" by itself
$gridDev.add_CellValueChanged({ param($s, $e) if (-not $script:Loading -and $e.RowIndex -ge 0 -and $e.ColumnIndex -eq 3 -and $null -ne $gridDev.Rows[$e.RowIndex].Tag) { $gridDev.Rows[$e.RowIndex].Cells[4].Value = $true } })
$gridCom.add_CellValueChanged({ param($s, $e) if (-not $script:Loading -and $e.RowIndex -ge 0 -and $e.ColumnIndex -eq 1 -and $null -ne $gridCom.Rows[$e.RowIndex].Tag) { $gridCom.Rows[$e.RowIndex].Cells[2].Value = $true } })
foreach ($g in @($gridDev, $gridCom)) { $g.add_CurrentCellDirtyStateChanged({ param($s, $e) if ($s.IsCurrentCellDirty) { [void]$s.CommitEdit('CurrentCellChange') } }) }

$list.add_SelectedIndexChanged({ if ($list.SelectedItems.Count -eq 1) { Show-Device $list.SelectedItems[0].Tag } })
$btnRefresh.add_Click({ Update-DeviceList; if ($script:Selected) { $n = $script:Selected.File; $q = $script:Devices | Where-Object File -eq $n | Select-Object -First 1; if ($q) { Show-Device $q } } })
$btnOpen.add_Click({ Start-Process explorer.exe $script:Folder })
$btnRelease.add_Click({
  $form.Cursor = 'WaitCursor'
  try { $rel = Get-Release } catch { $rel = [pscustomobject]@{ Ok = $false; Message = $_.Exception.Message } } finally { $form.Cursor = 'Default' }
  if (-not $rel.Ok) { Show-Message (Get-Text 'RelTitle') $rel.Message 'Information'; return }
  $sigText = if ($rel.Signature) { Get-Text 'RelSigChecked' } else { Get-Text 'RelSigNotChecked' }
  if (-not (Confirm-Action (Get-Text 'RelTitle') (Get-Text 'RelConfirm' $rel.Version (Get-PublishedUpdate) $sigText) 'Button2')) {
    Remove-Item -LiteralPath $rel.Dir -Recurse -Force -ErrorAction SilentlyContinue; return }
  try { Publish-Release $rel; Show-Message (Get-Text 'RelTitle') (Get-Text 'RelDone' $rel.Version) 'Information' }
  catch { Show-Message (Get-Text 'RelTitle') (Get-Text 'RelCopyFailed' $_.Exception.Message) 'Error' }
  Update-DeviceList
})
$btnSaveDev.add_Click({ Save-Device })
$btnReloadDev.add_Click({ Update-DeviceGrid })
$btnClearDev.add_Click({ Clear-Device })
$btnSaveCom.add_Click({ Save-Common })
$btnReloadCom.add_Click({ Update-CommonGrid })
$btnBrandDev.add_Click({ if ($script:Selected) { Show-BrandingDialog $script:Selected } })
$btnBrandCom.add_Click({ Show-BrandingDialog $null })
$btnSaveKeys.add_Click({ Save-Keys })
$btnReloadKeys.add_Click({ Update-KeysView })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 60000
$timer.add_Tick({ Update-DeviceList })      # only the list: grids being edited are left alone

$form.add_Shown({
  $split.SplitterDistance = 250
  Update-DeviceList; Update-CommonGrid; Update-KeysView
  if ($list.Items.Count) { $list.Items[0].Selected = $true }
  $timer.Start()
})
if ($env:OTR_MANAGER_BRANDING_SHOT) {   # test: the logo dialog (of OTR_MANAGER_BRANDING_HOST, or common) into a PNG
  $form.add_Shown({ Show-BrandingDialog ($script:Devices | Where-Object Name -eq $env:OTR_MANAGER_BRANDING_HOST | Select-Object -First 1); $form.Close() })
}
if ($env:OTR_MANAGER_SCREENSHOT) {   # test: draws the window into a PNG instead of leaving it open
  # an error must close the window and be reported: nobody is there to close it
  $form.add_Shown({ try {
    if ($env:OTR_MANAGER_TAB) { $tabs.SelectedIndex = [int]$env:OTR_MANAGER_TAB }
    if ($form.Width -ge 1280) {
      $form.Refresh()
      $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
      $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    } else {
      # Windows clamps a window to the screen: on a small test session the contents are drawn at the
      # intended size instead (child controls are not clamped), without the title bar
      $w = 1264; $h = 781; $bh = $bar.Height; $th = $h - $bh
      $tabs.Dock = 'None'; $tabs.SetBounds(0, 0, $w, $th); $bar.Dock = 'None'; $bar.SetBounds(0, $th, $w, $bh)
      $split.SplitterDistance = 250; $form.Refresh(); [System.Windows.Forms.Application]::DoEvents()
      $bmp = New-Object System.Drawing.Bitmap($w, $h)
      $tabs.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $w, $th)))
      $bar.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, $th, $w, $bh)))
    }
    $bmp.Save($env:OTR_MANAGER_SCREENSHOT, [System.Drawing.Imaging.ImageFormat]::Png)
  } catch { [Console]::Error.WriteLine("screenshot failed: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))") } finally { $form.Close() } })
}
[void]$form.ShowDialog()
