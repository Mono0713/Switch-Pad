# 載入 nxn-app.ps1 的 XAML（樣式、主視窗、遊戲格子），放幾格假遊戲，畫成 PNG：
# 確認 XAML 在 WPF 讀得進去（StaticResource、樣式都找得到），也讓沒有 Windows 的人看得到介面長怎樣。
param([string]$Out = 'ui-preview.png')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$src = Get-Content (Join-Path $PSScriptRoot '..\app\nxn-app.ps1') -Raw -Encoding UTF8
function Here($name) { if ($src -match "(?s)\`$$name = @'\r?\n(.*?)\r?\n'@") { return $Matches[1] }; throw "找不到 `$$name" }
$styles = Here 'styles'; $xamlText = Here 'xamlText'; $cardXaml = Here 'cardXaml'
function Brush($c) { New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($c)) }
# 介面用到的小函式直接從 nxn-app.ps1 拿，畫出來的和程式一樣
foreach ($f in 'Head-Count', 'Add-Badge', 'State-Badges') {
    if ($src -match "(?s)(function $f\(.*?\r?\n\})") { . ([scriptblock]::Create($Matches[1])) } else { throw "找不到 $f" }
}
$win = [Windows.Markup.XamlReader]::Parse($xamlText.Replace('__RES__', $styles))
$win.Width = 1220; $win.Height = 820
$win.FindName('Library').Columns = 5; $win.FindName('Others').Columns = 5
$fake = @(@('All You Need Is Help', 'v1.2.0 · 1 DLC', '● 在 iPad 上', '#30D158', $true), @('ANIMAL WELL', 'v1.0.7', '● 在 iPad 上', '#30D158', $true),
          @('Balatro', 'v1.1.3', '● 等裝到 iPad', '#0A84FF', $true), @('Boomerang Fu', 'v1.3.6 · 2 DLC', '● 要重新轉換', '#FF9F0A', $true),
          @('CloverPit', 'v1.4.2', '● 轉換失敗', '#FF453A', $true), @('gang beasts', 'v1.26.0', '● 在 iPad 上', '#30D158', $true),
          @('Heave Ho', '', '', '#8E8E93', $false), @('Lethal League Blaze', 'v1.23 · 12 DLC', '● 轉換過了，加入就能裝', '#8E8E93', $false))
$colors = '#5E5CE6', '#0A84FF', '#FF375F', '#30D158', '#FF9F0A', '#BF5AF2', '#64D2FF', '#FFD60A'
$i = 0
foreach ($f in $fake) {
    $c = [Windows.Markup.XamlReader]::Parse($cardXaml)
    $c.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Parse($styles))
    $c.FindName('Title').Text = $f[0]; $c.FindName('Detail').Text = $f[1]
    $st = $c.FindName('State'); $st.Text = $f[2]; $st.Foreground = Brush $f[3]
    $c.FindName('Icon').Background = Brush $colors[$i % $colors.Count]; $c.FindName('Letter').Text = $f[0].Substring(0, 1)
    $act = $c.FindName('Act')
    if ($f[4]) { $act.Content = '移除'; $act.Style = $win.FindResource('Pill') } else { $act.Content = '加入'; $act.Style = $win.FindResource('Get') }
    if ($i -eq 2) { $c.Background = Brush '#1F1F22' }
    if ($i -eq 4 -or $i -eq 7) { Add-Badge $c '要注意' '#33FF9F0A' '#FF9F0A' 'x' }
    if (-not $f[4]) { Add-Badge $c '未驗證' '#33FFD60A' '#FFD60A' 'x' }
    State-Badges $c @($f[1] -split ' · ')
    [void]$(if ($f[4]) { $win.FindName('Library') } else { $win.FindName('Others') }).Children.Add($c)
    $i++
}
Head-Count $win.FindName('GamesHead') '遊戲庫' 6; Head-Count $win.FindName('OutHead') '還沒加入' 2
$win.FindName('Account').Text = 'someone@example.com'; $win.FindName('AcctDot').Fill = Brush '#30D158'; $win.FindName('Login').Content = '換帳號'
$win.FindName('SelCount').Text = '遊戲庫 6 款'; $win.FindName('SelSub').Text = '裝到 iPad 時會拿回 iPad 記下的著色器'; $win.FindName('SelSub').Visibility = 'Visible'
$r = $win.FindName('RenewBtn'); $r.Content = '重簽（剩 7 天）'; $r.Visibility = 'Visible'
$ico = Join-Path $PSScriptRoot '..\app\SwitchPad.ico'
$fs = [IO.File]::OpenRead($ico); try { $win.FindName('AppLogo').Source = [Windows.Media.Imaging.BitmapDecoder]::Create($fs, 'None', 'OnLoad').Frames | Sort-Object { $_.PixelWidth } -Descending | Select-Object -First 1 } finally { $fs.Dispose() }
# 不顯示視窗，直接量版面畫出來
$root = $win.Content; $win.Content = $null
$host2 = New-Object Windows.Controls.Border; $host2.Background = $win.Background; $host2.Child = $root
$host2.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Parse($styles))
foreach ($k in 'FontFamily', 'FontSize', 'Foreground') { $host2.SetValue([Windows.Documents.TextElement]::"$($k)Property", $win.$k) }
$size = New-Object Windows.Size 1220, 820
$host2.Measure($size); $host2.Arrange((New-Object Windows.Rect $size)); $host2.UpdateLayout()
$bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap 1220, 820, 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
$bmp.Render($host2)
$enc = New-Object Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
$o = [IO.File]::Create($Out); try { $enc.Save($o) } finally { $o.Dispose() }
Write-Host "畫好了：$Out"
