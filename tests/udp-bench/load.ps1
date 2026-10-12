# Heavy graphics load for the bench, run IN the Windows session of the test user (full screen): coloured noise
# in 8x8 blocks renewed about 30 times a second, plus a clock, the worst case for the codec and the line.
# Closes by itself after -Seconds, or with the Q key.
param([int]$Seconds = 900)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$f = New-Object Windows.Forms.Form
$f.Text = 'openthinrdp-udp-bench'; $f.FormBorderStyle = 'None'; $f.WindowState = 'Maximized'; $f.TopMost = $true; $f.KeyPreview = $true
$prop = [Windows.Forms.Control].GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance'); $prop.SetValue($f, $true, $null)
$bw = 240; $bh = 135
$bmp = New-Object Drawing.Bitmap $bw, $bh, ([Drawing.Imaging.PixelFormat]::Format32bppRgb)
$buf = New-Object byte[] ($bw * $bh * 4); $rnd = New-Object Random
$font = New-Object Drawing.Font('Consolas', 28); $end = (Get-Date).AddSeconds($Seconds)
$timer = New-Object Windows.Forms.Timer; $timer.Interval = 33
$timer.Add_Tick({
  if ((Get-Date) -gt $end) { $f.Close(); return }
  $rnd.NextBytes($buf)
  $d = $bmp.LockBits((New-Object Drawing.Rectangle 0, 0, $bw, $bh), 'WriteOnly', $bmp.PixelFormat)
  [Runtime.InteropServices.Marshal]::Copy($buf, 0, $d.Scan0, $buf.Length); $bmp.UnlockBits($d)
  $f.Invalidate() })
$f.Add_Paint({ param($s, $e)
  $e.Graphics.InterpolationMode = 'NearestNeighbor'; $e.Graphics.PixelOffsetMode = 'Half'
  $e.Graphics.DrawImage($bmp, 0, 0, $f.ClientSize.Width, $f.ClientSize.Height)
  $e.Graphics.FillRectangle([Drawing.Brushes]::Black, 280, 10, 330, 50)
  $e.Graphics.DrawString((Get-Date -Format 'HH:mm:ss.fff'), $font, [Drawing.Brushes]::White, 290, 14) })
$f.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Q') { $f.Close() } })
$f.Add_Shown({ $timer.Start() })
[Windows.Forms.Application]::Run($f)
