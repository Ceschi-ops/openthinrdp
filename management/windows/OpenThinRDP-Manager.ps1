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
  Tests:  . .\OpenThinRDP-Manager.ps1 -Folder <path> -FunctionsOnly     (loads the functions, no window)
          $env:OTR_MANAGER_SCREENSHOT = <file.png> (+ $env:OTR_MANAGER_TAB = 0, 1 or 2): draws the window into
          the PNG instead of showing it, then exits
#>
param(
  [string]$Folder,
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
    public static string Durations(string s) {
        return RxDuration.Replace(s, delegate(Match u) {
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
# proposed in common.conf when no device reports the key yet.
# ---------------------------------------------------------------------------------------------
$script:Section = ''
function Set-Section($name) { $script:Section = $name }
function New-Setting($key, $label, $type, $default, $help, $choices = $null) {
  [pscustomobject]@{ Key = $key; Label = $label; Type = $type; Default = $default; Help = $help; Choices = $choices
                     HostOnly = ($script:HostOnly -contains $key); Section = $script:Section }
}
$script:Settings = @(
  (Set-Section 'Remote desktop')
  (New-Setting 'HOSTNAME'          'Hostname'                    'host'      ''  'Letters, digits and hyphen, not only digits (e.g. thinclient21). When the device reports with the new name, this tool moves its exceptions to the new file.')
  (New-Setting 'DEFAULT_USER'      'Default user'                'user'      ''  'User name pre-filled in the login form (e.g. jdoe or EXAMPLE\jdoe).')
  (New-Setting 'BROKER'            'Broker'                      'name'      ''  'RD Connection Broker (or a single session host), name or IP. Used from the next connection.')
  (New-Setting 'BROKER_FALLBACK'   'Fallback brokers'            'names'     ''  'Space separated: tried in turn when the broker does not answer after 2 attempts.')
  (New-Setting 'DOMAIN'            'Domain'                      'name'      ''  'Windows domain of the users. Used from the next connection.')
  (New-Setting 'LOAD_BALANCE_INFO' 'RDS collection'              'collection' '' 'As in the .rdp file (loadbalanceinfo), e.g. tsv://VMResource.1.MY_COLLECTION')
  (New-Setting 'TRANSPORT'         'Transport'                   'choice'    'tcp' 'tcp or udp. udp needs a FreeRDP built with WITH_RDPEUDP=ON (still experimental upstream).' @('tcp', 'udp'))
  (New-Setting 'RDP_AUTH'          'Authentication'              'choice'    'negotiate' 'negotiate = Kerberos then NTLM; ntlm = NTLM only (when Kerberos breaks on the broker redirect, "Ticket/authenticator don''t match").' @('negotiate', 'ntlm'))
  (New-Setting 'RDP_CERT'          'Server certificate'          'choice'    'tofu' 'tofu = trust on first use; ignore = accept any; verify = must be trusted.' @('tofu', 'ignore', 'verify'))
  (New-Setting 'RDP_GFX'           'Graphics pipeline (/gfx)'    'gfx'       'progressive,AVC420:off,AVC444:off' 'Options for /gfx. Without a server GPU, progressive without H.264 keeps text pixel exact.')
  (New-Setting 'RDP_KEYBOARD'      'RDP keyboard layout'         'rdpkbd'    ''  'Layout sent to Windows (/kbd:layout), e.g. 0x00000409. Empty = derived from Keyboard.')
  (New-Setting 'RDP_EXTRA'         'Extra FreeRDP options'       'extra'     ''  'Appended to xfreerdp3 as they are (advanced). Letters, digits, space and / : + , . _ = # - only.')
  (New-Setting 'SESSION_THRESHOLD' 'Session threshold (s)'       'threshold' '10' '5-120: a session that ends within these seconds from sign-in counts as a failed attempt and is retried.')
  (New-Setting 'SHUTDOWN_SECS'     'Shutdown (s)'                'shutdown'  '10' 'Seconds before switching off after the user disconnects (0 = never, max 3600).')
  (Set-Section 'USB')
  (New-Setting 'USB_MODE'          'USB mode'                    'choice'    'all' 'all = every USB device except keyboards, mice, touch screens, hubs, network adapters and smart card readers goes to Windows whole; disks = USB sticks as network drives, smart cards through /smartcard.' @('all', 'disks'))
  (New-Setting 'USB_REDIRECT'      'USB devices passed whole'    'usb'       ''  'VID:PID, space separated (e.g. 1eaf:0009): always passed whole, also in disks mode.')
  (Set-Section 'Network')
  (New-Setting 'NETMODE'           'Network'                     'choice'    'dhcp' 'dhcp or static. IP address, netmask and gateway are used only with static.' @('dhcp', 'static'))
  (New-Setting 'IPADDR'            'IP address'                  'ip'        ''  'Only with Network = static.')
  (New-Setting 'NETMASK'           'Netmask'                     'mask'      '255.255.255.0' 'e.g. 255.255.255.0 (used only with a static address).')
  (New-Setting 'GATEWAY'           'Gateway'                     'ip'        ''  'Used only with a static address; must be in the same network as the IP address.')
  (New-Setting 'DNS1'              'Primary DNS'                 'ip'        ''  'Empty = the ones from DHCP. Required with a static address.')
  (New-Setting 'DNS2'              'Secondary DNS'               'ip'        ''  'Optional.')
  (New-Setting 'NTP'               'Time servers (NTP)'          'names'     ''  'Space separated. Empty = the Debian pool.')
  (New-Setting 'WIFI'              'Wi-Fi'                       'choice'    'off' 'on = use Wi-Fi when no cable is connected. A device without a Wi-Fi adapter REJECTS a configuration with Wi-Fi on.' @('off', 'on'))
  (New-Setting 'WIFI_SSID'         'Wi-Fi network (SSID)'        'ssid'      ''  '1 to 32 characters, no quotes, | or backslash.')
  (New-Setting 'WIFI_COUNTRY'      'Wi-Fi country'               'country'   ''  'Two letters (e.g. US) or empty.')
  (New-Setting 'WIFI_PSK'          'Wi-Fi password'              'psk'       ''  'Type the password (8-63 characters) or a 64 hex digit key: only the WPA key computed for the SSID goes to the file, never the password. (saved) = keep the current key.')
  (Set-Section 'Management')
  (New-Setting 'MGMT_SHARE'        'Management folder'           'share'     ''  'Where the devices report and read this configuration (\\server\share). A wrong value cuts the devices off from this tool.')
  (New-Setting 'SECURITY_UPDATES'  'Security updates'            'choice'    'on' 'Debian security updates (FreeRDP is never updated automatically).' @('off', 'on'))
  (New-Setting 'SSH'               'SSH'                         'choice'    'off' 'Remote administration: login as admin only with the keys of the SSH keys tab.' @('off', 'on'))
  (Set-Section 'Web button and kiosk page')
  (New-Setting 'WEB_BUTTON'        'Web button'                  'choice'    'none' 'none = no button; app = web address as an app window, only allowed sites; browser = free browsing, web address as home page; kiosk = kiosk page full screen at power on (5 s to stop it from the login form).' @('none', 'app', 'browser', 'kiosk'))
  (New-Setting 'WEB_LABEL'         'Web button label'            'text'      'Web' 'Text of the button. No angle brackets, &, |, quotes, dollar or backslash.')
  (New-Setting 'WEB_URL'           'Web address'                 'url'       ''  'http(s) address for app and browser (e.g. https://intranet.example.com/).')
  (New-Setting 'WEB_ALLOW'         'Allowed sites (app)'         'urls'      ''  'URL prefixes, space separated, that can be opened in app mode. The web address is always allowed.')
  (New-Setting 'KIOSK_URL'         'Kiosk page'                  'url'       ''  'http(s) page shown full screen in kiosk mode (e.g. https://www.example.com/page).')
  (New-Setting 'KIOSK_RELOAD_MIN'  'Reload kiosk page (min)'     'reload'    '10' 'Reload the kiosk page every N minutes when nobody is using it (0 = never, max 1440).')
  (Set-Section 'Power schedule')
  (New-Setting 'POWER_ON_TIME'     'Power on at (hh:mm)'         'time'      ''  'Empty = never. Uses the RTC wake alarm: the firmware must let it through (some BIOSes need a deep sleep option disabled).')
  (New-Setting 'POWER_OFF_TIME'    'Power off at (hh:mm)'        'time'      ''  'Empty = never. 60 s warning with Cancel; with an open remote session the device waits for it to end.')
  (New-Setting 'POWER_ON_DAYS'     'Power on days'               'days'      '1234567' 'Digits of the days: 1 = Monday ... 7 = Sunday (e.g. 12345 = Monday to Friday).')
  (Set-Section 'Look and language')
  (New-Setting 'LANGUAGE'          'Language'                    'lang'      'en' 'Two letters: en or it, or any language file added to the image.')
  (New-Setting 'KEYBOARD'          'Keyboard'                    'kbd'       'us' 'Keyboard layout (X11/console), e.g. us, it, de, fr.')
  (New-Setting 'TITLE'             'Title'                       'text'      'Remote desktop' 'Window titles and login form heading.')
  (New-Setting 'LOGO'              'Logo'                        'logo'      '/opt/openthinrdp/branding/logo.png' 'Full path of a PNG on the device, about 200 px wide.')
  (New-Setting 'BG_TOP'            'Background top color'        'color'     '#1b2733' '#rrggbb, gradient behind the splash logo.')
  (New-Setting 'BG_BOTTOM'         'Background bottom color'     'color'     '#000000' '#rrggbb, gradient behind the splash logo.')
  (New-Setting 'SUPPORT_TEXT'      'Support text'                'text'      ''  'Extra line in error messages, e.g. Call the IT desk, ext. 123. Empty = a generic sentence.')
  (New-Setting 'SETTINGS_PIN_SHA256' 'Settings PIN'              'pin'       ''  'Protects the settings dialog. Type the PIN (only its SHA-256 goes to the file) or a 64 hex digit hash; empty = no PIN. (set) = keep the current one.')
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
  if (-not $s) { return "Unknown setting $key" }
  $L = $s.Label
  # a line break would put a second KEY= line in the file, read by the device as a separate setting
  if ($v -match '[\x00-\x1f\x7f]') { return "${L}: line breaks and control characters are not allowed" }
  switch ($s.Type) {
    'host'       { if ($v -cnotmatch $script:Rx.Host -or $v -cmatch '^[0-9]+$') { return 'Hostname not valid (letters, digits and hyphen; not only digits)' } }
    'user'       { if ($v -ne '' -and $v -cnotmatch $script:Rx.User) { return 'Default user not valid' } }
    'name'       { if ($v -ne '' -and $v -cnotmatch $script:Rx.Name) { return "$L not valid" } }
    'names'      { foreach ($t in (Split-List $v)) { if (-not (Test-Ip $t) -and $t -cnotmatch $script:Rx.Name) { return "${L}: value not valid '$t'" } } }
    'collection' { if ($v -cnotmatch $script:Rx.Collection) { return 'RDS collection not valid (e.g. tsv://VMResource.1.MY_COLLECTION)' } }
    'choice'     { if ($s.Choices -notcontains $v) { return "${L}: choose one of $($s.Choices -join ', ')" } }
    'gfx'        { if ($v -cnotmatch $script:Rx.Gfx) { return "${L}: letters, digits, : and , only" } }
    'rdpkbd'     { if ($v -cnotmatch $script:Rx.RdpKbd) { return "${L} not valid (e.g. 0x00000409)" } }
    'extra'      { if ($v -cnotmatch $script:Rx.Extra) { return "$L contain characters that are not allowed" } }
    'threshold'  { if ($v -cnotmatch '^[0-9]{1,3}$' -or [int]$v -lt 5 -or [int]$v -gt 120) { return 'Session threshold: seconds from 5 to 120' } }
    'shutdown'   { if ($v -cnotmatch '^[0-9]{1,4}$' -or [int]$v -gt 3600) { return 'Shutdown: seconds from 0 (never) to 3600' } }
    'usb'        { if (((Split-List $v) -join ' ').ToLower() -cnotmatch $script:Rx.Usb) { return 'USB devices: VID:PID separated by spaces (e.g. 1eaf:0009)' } }
    'ip'         { if ($v -ne '' -and -not (Test-Ip $v)) { return "$L not valid" } }
    'mask'       { if ($v -ne '' -and -not (Test-Mask $v)) { return 'Netmask not valid (e.g. 255.255.255.0)' } }
    'ssid'       { if ($v.Length -gt 32 -or $v -match '["|\\]') { return 'Wi-Fi network (SSID) not valid (max 32 characters, no quotes, | or backslash)' } }
    'country'    { if ($v.ToUpper() -cnotmatch '^([A-Z]{2})?$') { return 'Wi-Fi country: two letters (e.g. US) or empty' } }
    'psk'        { if ($v -ne '(saved)' -and $v -cnotmatch $script:Rx.Hex64 -and ($v.Length -lt 8 -or $v.Length -gt 63)) { return 'Wi-Fi password: 8 to 63 characters' } }
    'share'      { if ($v -ne '' -and $v -cnotmatch $script:Rx.Share) { return 'Management folder not valid (e.g. \\fileserver\thinclients)' } }
    'text'       { if (-not (Test-Text $v)) { return "$L contains characters that are not allowed (angle brackets, &, |, quotes, dollar, backslash) or is over 200 characters" } }
    'url'        { if ($v -ne '' -and $v -cnotmatch $script:Rx.Url) { return "$L not valid (e.g. https://www.example.com/page)" } }
    'urls'       { foreach ($t in (Split-List $v)) { if ($t -cnotmatch $script:Rx.Url) { return "Allowed site not valid: $t" } } }
    'reload'     { if ($v -cnotmatch '^[0-9]{1,4}$' -or [int]$v -gt 1440) { return 'Kiosk page reload: minutes from 0 (never) to 1440' } }
    'time'       { if ($v -ne '' -and $v -cnotmatch $script:Rx.Time) { return "${L}: time hh:mm (e.g. 07:30) or empty" } }
    'days'       { if ($v -cnotmatch '^[1-7 ,;]*$') { return 'Power on days: digits 1 (Monday) to 7 (Sunday), e.g. 12345' } }
    'lang'       { if ($v.ToLower() -cnotmatch '^[a-z]{2}$') { return 'Language: two letters (e.g. en)' } }
    'kbd'        { if ($v -cnotmatch $script:Rx.Kbd) { return 'Keyboard layout not valid (e.g. us, it, de)' } }
    'logo'       { if ($v -cnotmatch $script:Rx.Logo) { return 'Logo: full path of a .png file' } }
    'color'      { if ($v -cnotmatch $script:Rx.Color) { return "$L not valid (#rrggbb)" } }
    'pin'        { if ($v.Length -gt 64) { return 'Settings PIN: at most 64 characters' } }
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
    if (-not (Test-Ip $r['IPADDR'])) { $e += 'With a static address a valid IP address is required' }
    if (-not (Test-Mask $r['NETMASK'])) { $e += 'With a static address a valid netmask is required (e.g. 255.255.255.0)' }
    if (-not (Test-Ip $r['GATEWAY'])) { $e += 'With a static address a valid gateway is required' }
    if ((Test-Ip $r['IPADDR']) -and (Test-Mask $r['NETMASK']) -and (Test-Ip $r['GATEWAY'])) {
      $m = ConvertTo-IpNumber $r['NETMASK']
      if (((ConvertTo-IpNumber $r['IPADDR']) -band $m) -ne ((ConvertTo-IpNumber $r['GATEWAY']) -band $m)) { $e += "The gateway $($r['GATEWAY']) is not in the same network as the IP address $($r['IPADDR'])" }
    }
    if (-not (Test-Ip $r['DNS1'])) { $e += 'With a static address the primary DNS is required' }
  }
  if ($r['WEB_BUTTON'] -in 'app', 'browser' -and -not $r['WEB_URL']) { $e += "Web button = $($r['WEB_BUTTON']) needs a web address" }
  if ($r['WEB_BUTTON'] -eq 'kiosk' -and -not $r['KIOSK_URL']) { $e += 'Web button = kiosk needs a kiosk page' }
  if ($r['WIFI'] -eq 'on') {
    if (-not $r['WIFI_SSID'] -or (Test-SettingValue 'WIFI_SSID' $r['WIFI_SSID'])) { $e += 'Wi-Fi on needs a valid network name (SSID)' }
    if ($status -and $status['WIFI_STATUS'] -eq 'no adapter') { $e += 'Wi-Fi on, but this device has no Wi-Fi adapter' }
  }
  $e
}

function Get-WpaKey([string]$passphrase, [string]$ssid) { [OtrCrypto]::WpaPsk($passphrase, $ssid) }
function Get-PinHash([string]$pin) { [OtrCrypto]::Sha256($pin) }
# what the user typed in a secret cell -> what goes to the file ("(saved)"/"(set)" = keep the previous one)
function ConvertTo-WpaKey($v, $ssid) { if ($v -cmatch $script:Rx.Hex64) { $v.ToLower() } else { Get-WpaKey $v $ssid } }
function ConvertTo-PinHash($v) { if ($v -eq '') { '' } elseif ($v -cmatch $script:Rx.Hex64) { $v.ToLower() } else { Get-PinHash $v } }
function Format-Value($k, $v) {
  if ($null -eq $v) { '(not managed)' }
  elseif ($k -eq 'WIFI_PSK') { '(WPA key)' }
  elseif ($k -eq 'SETTINGS_PIN_SHA256') { if ($v) { '(PIN set)' } else { '(no PIN)' } }
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
function Format-Minutes($m) { if ($m -lt 120) { "$m min" } elseif ($m -lt 2880) { "$([int]($m / 60)) hours" } else { "$([int]($m / 1440)) days" } }

function Get-Devices {
  $list = @()
  if (-not (Test-Path -LiteralPath $script:StatusDir)) { return @() }
  # Extension check: "*.txt" alone also matches longer extensions on Windows
  foreach ($f in @(Get-ChildItem -LiteralPath $script:StatusDir -Filter '*.txt' -File -ErrorAction SilentlyContinue | Where-Object Extension -eq '.txt')) {
    $s = Read-StatusFile $f.FullName
    if (-not $s['HOSTNAME']) { continue }
    $when = Get-ReportTime $s; if (-not $when) { $when = $f.LastWriteTime }
    $min = [int]((Get-Date) - $when).TotalMinutes
    $state = 'ok'; $color = [System.Drawing.Color]::FromArgb(220, 245, 220)
    if ($min -gt $script:StaleMinutes) { $state = "off or offline ($(Format-Minutes $min))"; $color = [System.Drawing.Color]::FromArgb(230, 230, 230) }
    elseif ($s['FAILED_UNITS'] -and $s['FAILED_UNITS'] -ne 'none') { $state = 'FAILED units'; $color = [System.Drawing.Color]::FromArgb(255, 205, 205) }
    elseif ($s['CENTRAL_CONFIG'] -like 'REJECTED*') { $state = 'config REJECTED'; $color = [System.Drawing.Color]::FromArgb(255, 225, 190) }
    elseif ($s['SHARE_UPDATE'] -like 'ERROR*' -or $s['SHARE_UPDATE'] -like 'IGNORED*') { $state = 'update ERROR'; $color = [System.Drawing.Color]::FromArgb(255, 225, 190) }
    elseif ($s['REBOOT_REQUIRED'] -eq 'yes') { $state = 'reboot recommended'; $color = [System.Drawing.Color]::FromArgb(255, 245, 190) }
    $list += [pscustomobject]@{ Name = $s['HOSTNAME']; File = $f.BaseName; State = $state; Color = $color; Minutes = $min; When = $when; S = $s }
  }
  # same MAC under two names = the old name left behind by a rename (normally the device removes it itself)
  foreach ($g in @($list | Where-Object { $_.S['MAC'] } | Group-Object { $_.S['MAC'] } | Where-Object Count -gt 1)) {
    $sorted = @($g.Group | Sort-Object When -Descending)
    $sorted | Select-Object -Skip 1 | ForEach-Object { $_.State = "old name (now $($sorted[0].Name))" }
  }
  @($list | Sort-Object Name)
}

# updates\LATEST.txt, read only: the devices install only what is signed (management/publish)
function Get-PublishedUpdate {
  $f = Join-Path $script:Folder 'updates\LATEST.txt'
  if (-not (Test-Path -LiteralPath $f)) { return 'none published' }
  $v = (Read-Lines $f | Where-Object { $_ -match '^version=' } | Select-Object -First 1) -replace '^version=', ''
  if (-not $v) { return 'LATEST.txt without version' }
  if (Test-Path -LiteralPath "$f.sig") { "$v" } else { "$v (NOT signed: the devices ignore it)" }
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
      elseif (-not $ssid) { $err += 'The Wi-Fi password needs the network name (SSID)' }
      elseif ($v -eq '(saved)') {
        # the saved key was computed for the SSID in force when it was written: this file, else common.conf,
        # else the device's own
        $oldSsid = if ($before.Contains('WIFI_SSID')) { $before['WIFI_SSID'] } elseif ($common.Contains('WIFI_SSID')) { $common['WIFI_SSID'] } else { $dev.S['CFG_WIFI_SSID'] }
        if (-not $before['WIFI_PSK']) { $err += 'Wi-Fi password: type it (no key is saved for this device)' }
        elseif ($oldSsid -cne $ssid) { $err += "Wi-Fi password: type it again, the saved key belongs to network '$oldSsid'" }
        else { $final[$k] = $before['WIFI_PSK'] }
      } else { $final[$k] = ConvertTo-WpaKey $v $ssid }
    }
    elseif ($k -eq 'SETTINGS_PIN_SHA256') {
      if ($v -eq '(set)') { if ($before.Contains($k)) { $final[$k] = $before[$k] } else { $err += 'Settings PIN: type it (none is saved for this device)' } }
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
    $notes += "The device takes the name $($final['HOSTNAME']) within 5 minutes. When it reports with the new name this tool moves these exceptions to $($final['HOSTNAME']).conf by itself."
  }
  if ($null -ne $final['NETMODE'] -or $null -ne $final['IPADDR']) { $notes += 'Network changes: the device changes address right after reading them (an open session may drop and reconnect).' }
  [pscustomobject]@{ File = $f; Errors = $err; Values = $final; Changes = $changes; Notes = $notes; RenameMac = $mac }
}

function Get-CommonSavePlan($managed, $devices) {
  $err = @(); $warn = @(); $notes = @()
  foreach ($k in @($managed.Keys)) {
    if ($script:HostOnly -contains $k -and $null -ne $managed[$k]) { $err += "$k can only be set for a single device"; continue }
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
      if (-not $ssid) { $err += 'The Wi-Fi password in common.conf needs the network name (SSID) managed in common.conf too' }
      elseif ($v -eq '(saved)') {
        if (-not $before['WIFI_PSK']) { $err += 'Wi-Fi password: type it (no key is saved in common.conf)' }
        elseif ($before['WIFI_SSID'] -cne $ssid) { $err += "Wi-Fi password: type it again, the saved key belongs to network '$($before['WIFI_SSID'])'" }
        else { $final[$k] = $before['WIFI_PSK'] }
      } else { $final[$k] = ConvertTo-WpaKey $v $ssid }
    }
    elseif ($k -eq 'SETTINGS_PIN_SHA256') {
      if ($v -eq '(set)') { if ($before.Contains($k)) { $final[$k] = $before[$k] } else { $err += 'Settings PIN: type it (none is saved in common.conf)' } }
      else { $final[$k] = ConvertTo-PinHash $v }
    }
    else { $final[$k] = ConvertTo-Canonical $k $v }
  }
  # combinations that every device would reject, whatever it has of its own
  if ($final['WEB_BUTTON'] -in 'app', 'browser' -and $final['WEB_URL'] -eq '') { $err += "Web button = $($final['WEB_BUTTON']) for every device with an empty web address" }
  if ($final['WEB_BUTTON'] -eq 'kiosk' -and $final['KIOSK_URL'] -eq '') { $err += 'Web button = kiosk for every device with an empty kiosk page' }
  if ($final['WIFI'] -eq 'on' -and $final['WIFI_SSID'] -eq '') { $err += 'Wi-Fi on for every device with an empty network name (SSID)' }
  if (-not $err.Count) {
    # each known device as it will be: a device that rejects keeps its previous configuration (all of it)
    $commonVals = @{}; foreach ($k in @($final.Keys)) { if ($null -ne $final[$k]) { $commonVals[$k] = $final[$k] } }
    foreach ($d in @($devices | Where-Object { $_.State -notlike 'old name*' })) {
      $hc = Read-ConfFile (Get-HostFile $d.Name)
      foreach ($e in @(Test-EffectiveConfig (Get-EffectiveConfig $d.S $commonVals $hc) $d.S)) { $warn += "$($d.Name): $e" }
      # a key of its own computed with the SSID of common.conf goes wrong when that SSID changes
      if ($hc.Contains('WIFI_PSK') -and -not $hc.Contains('WIFI_SSID') -and $null -ne $final['WIFI_SSID'] -and $final['WIFI_SSID'] -cne $before['WIFI_SSID']) {
        $warn += "$($d.Name): its own Wi-Fi key was computed for network '$($before['WIFI_SSID'])': type its password again in its exceptions"
      }
    }
  }
  $changes = @(); foreach ($k in @($final.Keys)) {
    $a = if ($before.Contains($k)) { $before[$k] } else { $null }
    if ($a -cne $final[$k]) { $changes += "$((Get-Setting $k).Label): $(Format-Value $k $a) -> $(Format-Value $k $final[$k])" }
  }
  $risky = @($final.Keys | Where-Object { $_ -in 'BROKER', 'DOMAIN', 'LOAD_BALANCE_INFO', 'MGMT_SHARE', 'NETMASK', 'GATEWAY', 'DNS1', 'WIFI', 'SSH', 'SETTINGS_PIN_SHA256' } |
             Where-Object { $(if ($before.Contains($_)) { $before[$_] } else { $null }) -cne $final[$_] })
  if ($risky.Count) { $notes += "ATTENTION: $($risky -join ', ') changed for EVERY device. A wrong broker, domain or management folder leaves all devices without a connection or without this tool. Check twice." }
  [pscustomobject]@{ File = $script:CommonFile; Errors = $err; Warnings = $warn; Values = $final; Changes = $changes; Notes = $notes }
}

# keys in a .conf that the devices ignore: unknown, or device-only keys in common.conf
function Get-IgnoredKeys($conf, [switch]$Common) {
  @($conf.Keys | Where-Object { -not (Get-Setting $_) -or ($Common -and $script:HostOnly -contains $_) })
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
    if ($t -cnotmatch $script:Rx.SshKey) { $err += "Line ${n}: not a public key in OpenSSH format (type, ONE space, key, optional comment)" }
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
    Add-ChangeLog ("rename completed: {0} -> {1} ({0}.conf becomes {1}.conf)" -f $old, $new)
    $done += "$old -> $new"
  }
  $done
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
  $dlg.Description = 'Management folder of the thin clients (the one that contains status\ and config\)'
  $dlg.ShowNewFolderButton = $false
  $last = Get-LastFolder; if ($last) { $dlg.SelectedPath = $last }
  if ($dlg.ShowDialog() -ne 'OK' -or -not $dlg.SelectedPath) { return }
  $Folder = $dlg.SelectedPath
  Set-ManagementFolder $Folder
}
if (-not (Test-Path -LiteralPath $script:Folder)) {
  Show-Message 'Folder not found' "Cannot reach $($script:Folder).`r`nCheck the network and the permissions on the folder." 'Error'
  return
}
if (-not (Test-Path -LiteralPath $script:StatusDir) -and -not (Test-Path -LiteralPath $script:ConfigDir)) {
  if (-not (Confirm-Action 'Management folder' "$($script:Folder) has no status\ or config\ folder yet: no device has reported here.`r`n`r`nUse it anyway?" 'Button2')) { return }
}
if (-not $env:OTR_MANAGER_SCREENSHOT) { Save-LastFolder $script:Folder }

$fontBase = New-Object System.Drawing.Font('Segoe UI', 9)
$fontMono = New-Object System.Drawing.Font('Consolas', 9)
$fontBold = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$form = New-Object System.Windows.Forms.Form
$form.Text = 'OpenThinRDP Manager - ' + $script:Folder
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
$tabDevices = New-Object System.Windows.Forms.TabPage 'Devices'
$tabCommon = New-Object System.Windows.Forms.TabPage 'Common settings (all devices)'
$tabKeys = New-Object System.Windows.Forms.TabPage 'SSH keys'
$tabs.TabPages.AddRange(@($tabDevices, $tabCommon, $tabKeys))

# ---------------- Devices tab ----------------
$topPanel = New-Object System.Windows.Forms.Panel
$topPanel.Dock = 'Top'; $topPanel.Height = 38
$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = 'Refresh list'; $btnRefresh.Location = '8,6'; $btnRefresh.Size = '120,26'
$btnOpen = New-Object System.Windows.Forms.Button
$btnOpen.Text = 'Open folder'; $btnOpen.Location = '134,6'; $btnOpen.Size = '110,26'
$lblNote = New-Object System.Windows.Forms.Label
$lblNote.AutoSize = $true; $lblNote.Location = '256,11'
$lblNote.Text = 'Devices send their status and read the central configuration every 5 minutes (and at boot). The list refreshes by itself every minute.'
$topPanel.Controls.AddRange(@($btnRefresh, $btnOpen, $lblNote))

$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'; $split.Orientation = 'Horizontal'

$list = New-Object System.Windows.Forms.ListView
$list.Dock = 'Fill'; $list.View = 'Details'; $list.FullRowSelect = $true; $list.MultiSelect = $false; $list.HideSelection = $false; $list.GridLines = $true
foreach ($c in @(@('State', 160), @('Hostname', 110), @('Software', 95), @('Web button', 125), @('IP', 120), @('Default user', 105), @('Session', 140),
                 @('Last report', 115), @('Transport', 150), @('Share update', 200), @('Wi-Fi', 210), @('MAC', 125), @('Uptime', 120), @('Network', 60),
                 @('FreeRDP', 150), @('Central config', 220), @('Security updates', 210))) {
  [void]$list.Columns.Add($c[0], $c[1])
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
$tabStatus = New-Object System.Windows.Forms.TabPage 'Status'
$tabEvents = New-Object System.Windows.Forms.TabPage 'Events'
$tabDevSettings = New-Object System.Windows.Forms.TabPage 'Settings of this device'
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
function Add-TextColumn($g, $title, $width, $readOnly) {
  $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $col.HeaderText = $title; $col.ReadOnly = $readOnly; $col.SortMode = 'NotSortable'
  if ($width) { $col.Width = $width } else { $col.AutoSizeMode = 'Fill' }
  [void]$g.Columns.Add($col)
}
# exceptions grid of the selected device
$gridDev = New-Grid
Add-TextColumn $gridDev 'Setting' 175 $true; Add-TextColumn $gridDev 'On the device now' 210 $true; Add-TextColumn $gridDev 'From common.conf' 200 $true
Add-TextColumn $gridDev 'Exception for this device' 230 $false
$colUse = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn; $colUse.HeaderText = 'Use exception'; $colUse.Width = 95; [void]$gridDev.Columns.Add($colUse)
Add-TextColumn $gridDev 'Help' $null $true
$devPanel = New-Object System.Windows.Forms.Panel; $devPanel.Dock = 'Bottom'; $devPanel.Height = 40
$btnSaveDev = New-Object System.Windows.Forms.Button; $btnSaveDev.Text = 'Save exceptions'; $btnSaveDev.Location = '8,7'; $btnSaveDev.Size = '130,27'
$btnReloadDev = New-Object System.Windows.Forms.Button; $btnReloadDev.Text = 'Undo changes'; $btnReloadDev.Location = '144,7'; $btnReloadDev.Size = '130,27'
$btnClearDev = New-Object System.Windows.Forms.Button; $btnClearDev.Text = 'Remove all exceptions'; $btnClearDev.Location = '280,7'; $btnClearDev.Size = '160,27'
$lblDev = New-Object System.Windows.Forms.Label; $lblDev.AutoSize = $true; $lblDev.Location = '452,13'
$lblDev.Text = 'Tick "Use exception" to decide the value for this device only; without the tick common.conf or the device itself decide.'
$devPanel.Controls.AddRange(@($btnSaveDev, $btnReloadDev, $btnClearDev, $lblDev))
$tabDevSettings.Controls.Add($gridDev); $tabDevSettings.Controls.Add($devPanel)
$split.Panel2.Controls.Add($detail)
$tabDevices.Controls.Add($split); $tabDevices.Controls.Add($topPanel)

# ---------------- Common settings tab ----------------
$gridCom = New-Grid
Add-TextColumn $gridCom 'Setting' 190 $true; Add-TextColumn $gridCom 'Value for every device' 300 $false
$colManaged = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn; $colManaged.HeaderText = 'Managed here'; $colManaged.Width = 100; [void]$gridCom.Columns.Add($colManaged)
Add-TextColumn $gridCom 'Help' $null $true
$comPanel = New-Object System.Windows.Forms.Panel; $comPanel.Dock = 'Bottom'; $comPanel.Height = 58
$btnSaveCom = New-Object System.Windows.Forms.Button; $btnSaveCom.Text = 'Save common.conf'; $btnSaveCom.Location = '8,7'; $btnSaveCom.Size = '140,27'
$btnReloadCom = New-Object System.Windows.Forms.Button; $btnReloadCom.Text = 'Undo changes'; $btnReloadCom.Location = '154,7'; $btnReloadCom.Size = '130,27'
$lblCom = New-Object System.Windows.Forms.Label; $lblCom.AutoSize = $true; $lblCom.Location = '296,6'
$lblCom.Text = "Applies to EVERY device within 5 minutes. A key ""Managed here"" WINS over the settings dialog of each device (changed on the device, it comes back).`r`nWithout the tick each device decides. Exceptions of a single device (Devices tab) win over these. One wrong value = the device rejects the whole configuration."
$comPanel.Controls.AddRange(@($btnSaveCom, $btnReloadCom, $lblCom))
$tabCommon.Controls.Add($gridCom); $tabCommon.Controls.Add($comPanel)

# ---------------- SSH keys tab ----------------
$txtKeys = New-Object System.Windows.Forms.TextBox
$txtKeys.Multiline = $true; $txtKeys.ScrollBars = 'Both'; $txtKeys.WordWrap = $false; $txtKeys.Dock = 'Fill'; $txtKeys.Font = $fontMono; $txtKeys.AcceptsReturn = $true
$keysPanel = New-Object System.Windows.Forms.Panel; $keysPanel.Dock = 'Bottom'; $keysPanel.Height = 58
$btnSaveKeys = New-Object System.Windows.Forms.Button; $btnSaveKeys.Text = 'Save authorized_keys'; $btnSaveKeys.Location = '8,7'; $btnSaveKeys.Size = '150,27'
$btnReloadKeys = New-Object System.Windows.Forms.Button; $btnReloadKeys.Text = 'Undo changes'; $btnReloadKeys.Location = '164,7'; $btnReloadKeys.Size = '130,27'
$lblKeys = New-Object System.Windows.Forms.Label; $lblKeys.AutoSize = $true; $lblKeys.Location = '306,6'
$lblKeys.Text = "One public key per line (ssh-ed25519, ssh-rsa, ecdsa-sha2-nistp256/384/521, sk-ssh-ed25519@openssh.com); lines starting with # are notes.`r`nDevices with SSH = on accept the user admin only with these keys, within 5 minutes. An empty list removes every key from the devices."
$keysPanel.Controls.AddRange(@($btnSaveKeys, $btnReloadKeys, $lblKeys))
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
  } catch { $barText.Text = "ERROR reading $($script:Folder): $($_.Exception.Message)"; return }
  $sel = if ($script:Selected) { $script:Selected.File } else { $null }
  $list.BeginUpdate(); $list.Items.Clear()
  foreach ($d in $script:Devices) {
    $s = $d.S
    $it = New-Object System.Windows.Forms.ListViewItem($d.State)
    $web = [string]$s['CFG_WEB_BUTTON']
    # schedule "07:30-19:00" (power on - power off) next to the web button mode
    if ($s['CFG_POWER_ON_TIME'] -or $s['CFG_POWER_OFF_TIME']) { $web += " $($s['CFG_POWER_ON_TIME'])-$($s['CFG_POWER_OFF_TIME'])" }
    $sec = [string]$s['SECURITY_UPDATES']; if ($s['LAST_UPDATE']) { $sec += ", last: $($s['LAST_UPDATE'])" }
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
  $barText.Text = "{0}   -   {1} devices, {2} reporting   -   published update: {3}   -   refreshed at {4:HH:mm:ss}{5}" -f $script:Folder, $script:Devices.Count, $on, $upd, (Get-Date), $(if ($renamed.Count) { "   -   rename completed: $($renamed -join ', ')" } else { '' })
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
  if ($s.Key -eq 'WIFI_PSK') { return '(never read back)' }
  $v = if ($s.Key -eq 'HOSTNAME') { $d.S['HOSTNAME'] } else { $d.S["CFG_$($s.Key)"] }
  if ($null -eq $v) { return $null }
  if ($s.Key -eq 'SETTINGS_PIN_SHA256') { if ($v) { return '(set)' } else { return '(no PIN)' } }
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
    $nowText = if ($null -eq $now) { '(not reported)' } else { $now }
    $fromCommon = if ($s.HostOnly) { '(device only)' } elseif ($common.Contains($s.Key)) { $common[$s.Key] } else { '(not managed: the device decides)' }
    if ($s.Key -eq 'WIFI_PSK' -and $common.Contains($s.Key)) { $fromCommon = '(saved)' }
    if ($s.Key -eq 'SETTINGS_PIN_SHA256' -and $common.Contains($s.Key)) { $fromCommon = if ($common[$s.Key]) { '(set)' } else { '(no PIN)' } }
    $i = $gridDev.Rows.Add(); $r = $gridDev.Rows[$i]
    $r.Cells[0].Value = $s.Label; $r.Cells[1].Value = [string]$nowText; $r.Cells[2].Value = [string]$fromCommon; $r.Tag = $s
    $use = $exc.Contains($s.Key)
    # without an exception the cell proposes the current value: ticking the box alone pins it
    $init = if ($use) { $exc[$s.Key] } elseif ($null -ne $now -and $s.Key -ne 'SETTINGS_PIN_SHA256') { $now } else { '' }
    if ($s.Key -eq 'WIFI_PSK') { $init = if ($use) { '(saved)' } else { '' } }
    if ($s.Key -eq 'SETTINGS_PIN_SHA256' -and $use) { $init = if ($exc[$s.Key]) { '(set)' } else { '' } }
    Set-Cell $r 3 $s $init
    $r.Cells[4].Value = $use; $r.Cells[5].Value = $s.Help
    if ($use) { $r.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255, 250, 215) }
  }
  $ign = @(Get-IgnoredKeys $exc)
  $tabDevSettings.Text = "Settings of this device ($($d.Name))"
  if ($ign.Count) { $barText.Text = "$($d.Name).conf contains keys the devices ignore: $($ign -join ', ')" }
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
    if ($s.Key -eq 'WIFI_PSK') { $v = if ($common.Contains('WIFI_PSK')) { '(saved)' } else { '' } }
    if ($s.Key -eq 'SETTINGS_PIN_SHA256') { $v = if ($common[$s.Key]) { '(set)' } else { '' } }
    Set-Cell $r 1 $s $v
    $r.Cells[2].Value = $common.Contains($s.Key); $r.Cells[3].Value = $s.Help
    if ($common.Contains($s.Key)) { $r.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(225, 240, 255) }
  }
  $ign = @(Get-IgnoredKeys $common -Common)
  if ($ign.Count) { $barText.Text = "common.conf contains keys the devices ignore there: $($ign -join ', ')" }
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
  if ($plan.Errors.Count) { Show-Message 'Values not valid' ("Not saved, to fix:`r`n`r`n- " + ($plan.Errors -join "`r`n- ")); return }
  if (-not $plan.Changes.Count) { Show-Message 'No changes' 'There are no changes to save.' 'Information'; return }
  $extra = if ($plan.Notes.Count) { "`r`n`r`n" + ($plan.Notes -join "`r`n`r`n") } else { '' }
  if (-not (Confirm-Action "Save the exceptions of $($d.Name)?" ("Changes for $($d.Name):`r`n`r`n- " + ($plan.Changes -join "`r`n- ") + $extra))) { return }
  try { [void](Write-ConfFile $plan.File $plan.Values $script:HostHeader $plan.RenameMac) } catch { Show-Message 'Error' "Save failed: $($_.Exception.Message)" 'Error'; return }
  $barText.Text = "Saved $($plan.File) - the device applies it within 5 minutes (result in the Central config column)."
  Update-DeviceGrid
}

function Clear-Device {
  $d = $script:Selected; if (-not $d) { return }
  $f = Get-HostFile $d.Name
  if (-not (Test-Path -LiteralPath $f)) { Show-Message 'No exceptions' "$($d.Name) has no exceptions." 'Information'; return }
  if (-not (Confirm-Action 'Remove the exceptions?' "Remove every exception of $($d.Name)?`r`nThe device keeps its current values; from now on common.conf and the device itself decide.`r`n(The file is kept in config\backup.)")) { return }
  Move-Item -LiteralPath $f -Destination (Get-BackupPath $f)
  Add-ChangeLog "$($d.Name).conf: all exceptions removed"
  Update-DeviceGrid
}

function Save-Common {
  [void]$gridCom.EndEdit()
  $plan = Get-CommonSavePlan (Get-GridValues $gridCom 1 2) $script:Devices
  if ($plan.Errors.Count) { Show-Message 'Values not valid' ("Not saved, to fix:`r`n`r`n- " + ($plan.Errors -join "`r`n- ")); return }
  if (-not $plan.Changes.Count) { Show-Message 'No changes' 'There are no changes to save.' 'Information'; return }
  $extra = ''
  if ($plan.Warnings.Count) {
    $w = @($plan.Warnings | Select-Object -First 15); if ($plan.Warnings.Count -gt 15) { $w += "... and $($plan.Warnings.Count - 15) more" }
    $extra += "`r`n`r`nThese devices will REJECT the whole central configuration (they keep the previous one):`r`n- " + ($w -join "`r`n- ")
  }
  if ($plan.Notes.Count) { $extra += "`r`n`r`n" + ($plan.Notes -join "`r`n`r`n") }
  # with problems the safe answer is No
  $def = if ($plan.Warnings.Count -or $plan.Notes.Count) { 'Button2' } else { 'Button1' }
  if (-not (Confirm-Action 'Save common.conf?' ("Changes for EVERY device (within 5 minutes):`r`n`r`n- " + ($plan.Changes -join "`r`n- ") + $extra) $def)) { return }
  try { [void](Write-ConfFile $plan.File $plan.Values $script:CommonHeader) } catch { Show-Message 'Error' "Save failed: $($_.Exception.Message)" 'Error'; return }
  $barText.Text = "Saved $($plan.File) - the devices apply it within 5 minutes (result in the Central config column)."
  Update-CommonGrid
  if ($script:Selected) { Update-DeviceGrid }
}

function Save-Keys {
  $err = @(Test-AuthorizedKeys $txtKeys.Text)
  if ($err.Count) { Show-Message 'Keys not valid' ("Not saved: the devices would drop these lines.`r`n`r`n- " + ($err -join "`r`n- ")); return }
  $n = @(Get-KeyLines $txtKeys.Text).Count
  $msg = if ($n) { "Save $n key(s)? Devices with SSH = on use them within 5 minutes." } else { 'The list is EMPTY: every device removes all SSH keys and nobody can log in over SSH. Save anyway?' }
  if (-not (Confirm-Action 'Save authorized_keys?' $msg $(if ($n) { 'Button1' } else { 'Button2' }))) { return }
  try { $r = Save-AuthorizedKeys $txtKeys.Text } catch { Show-Message 'Error' "Save failed: $($_.Exception.Message)" 'Error'; return }
  $barText.Text = "Saved $($script:KeysFile): $($r.Before) -> $($r.After) keys."
  Update-KeysView
}

# changing a value ticks "Use exception" / "Managed here" by itself
$gridDev.add_CellValueChanged({ param($s, $e) if (-not $script:Loading -and $e.RowIndex -ge 0 -and $e.ColumnIndex -eq 3 -and $null -ne $gridDev.Rows[$e.RowIndex].Tag) { $gridDev.Rows[$e.RowIndex].Cells[4].Value = $true } })
$gridCom.add_CellValueChanged({ param($s, $e) if (-not $script:Loading -and $e.RowIndex -ge 0 -and $e.ColumnIndex -eq 1 -and $null -ne $gridCom.Rows[$e.RowIndex].Tag) { $gridCom.Rows[$e.RowIndex].Cells[2].Value = $true } })
foreach ($g in @($gridDev, $gridCom)) { $g.add_CurrentCellDirtyStateChanged({ param($s, $e) if ($s.IsCurrentCellDirty) { [void]$s.CommitEdit('CurrentCellChange') } }) }

$list.add_SelectedIndexChanged({ if ($list.SelectedItems.Count -eq 1) { Show-Device $list.SelectedItems[0].Tag } })
$btnRefresh.add_Click({ Update-DeviceList; if ($script:Selected) { $n = $script:Selected.File; $q = $script:Devices | Where-Object File -eq $n | Select-Object -First 1; if ($q) { Show-Device $q } } })
$btnOpen.add_Click({ Start-Process explorer.exe $script:Folder })
$btnSaveDev.add_Click({ Save-Device })
$btnReloadDev.add_Click({ Update-DeviceGrid })
$btnClearDev.add_Click({ Clear-Device })
$btnSaveCom.add_Click({ Save-Common })
$btnReloadCom.add_Click({ Update-CommonGrid })
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
