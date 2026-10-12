# What the session host sees of the bench session: one line every -Interval seconds with the RemoteFX counters
# (UDP bandwidth and send rate, round trip, loss and retransmission rate, frames per second, frames skipped for
# lack of network resources). Run on any machine with PowerShell remoting to the session host, or on it.
# Counter names are localized: the defaults are English; on an Italian Windows use
#   -Graphics 'Grafica RemoteFX' -Network 'Rete RemoteFX' -Names it
param([string]$ComputerName = 'localhost', [int]$Samples = 30, [int]$Interval = 10,
      [string]$Graphics = 'RemoteFX Graphics', [string]$Network = 'RemoteFX Network', [ValidateSet('en', 'it')][string]$Names = 'en')
$n = @{
  en = @('Current UDP Bandwidth', 'UDP Sent Rate', 'Current UDP RTT', 'Loss Rate', 'Retransmission Rate', 'Output Frames/Second', 'Frames Skipped/Second - Insufficient Network Resources')
  it = @('Larghezza di banda UDP corrente', 'Frequenza invio UDP', 'RTT UDP corrente', 'Tasso di perdita', 'Tasso di ritrasmissione', 'Frame di output/secondo', 'Frame ignorati/secondo - Risorse di rete insufficienti')
}[$Names]
$paths = @(0..4 | ForEach-Object { "\$Network(*)\$($n[$_])" }) + @(5..6 | ForEach-Object { "\$Graphics(*)\$($n[$_])" })
$sb = { param($paths, $samples, $interval)
  for ($k = 0; $k -lt $samples; $k++) {
    $s = (Get-Counter -Counter $paths -SampleInterval $interval -MaxSamples 1 -ErrorAction SilentlyContinue).CounterSamples | Where-Object InstanceName -notmatch '_total'
    $v = @(foreach ($p in $paths) { $x = $s | Where-Object { $_.Path -like "*$(($p -split '\\')[-1])" } | Select-Object -First 1; if ($x) { [math]::Round($x.CookedValue, 1) } else { '-' } })
    '{0:HH:mm:ss}  UDP {1} kbps  sent {2}  RTT {3} ms  loss {4}%  retransmitted {5}%  fps {6}  skipped (network) {7}' -f (Get-Date), $v[0], $v[1], $v[2], $v[3], $v[4], $v[5], $v[6] } }
if ($ComputerName -in 'localhost', '.', $env:COMPUTERNAME) { & $sb $paths $Samples $Interval }
else { Invoke-Command -ComputerName $ComputerName -ScriptBlock $sb -ArgumentList $paths, $Samples, $Interval }
