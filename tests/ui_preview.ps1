# 載入 nxn-app.ps1 的 XAML（樣式、主視窗、遊戲格子），放幾格假遊戲，畫成 PNG：
# 確認 XAML 在 WPF 讀得進去（StaticResource、樣式都找得到），也讓沒有 Windows 的人看得到介面長怎樣。
param([string]$Out = 'ui-preview.png', [switch]$NoBg)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$src = Get-Content (Join-Path $PSScriptRoot '..\app\nxn-app.ps1') -Raw -Encoding UTF8
function Here($name) { if ($src -match "(?s)\`$$name = @'\r?\n(.*?)\r?\n'@") { return $Matches[1] }; throw "找不到 `$$name" }
$styles = Here 'styles'; $xamlText = Here 'xamlText'; $cardXaml = Here 'cardXaml'
function Brush($c) { New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($c)) }
# 介面用到的小函式直接從 nxn-app.ps1 拿，畫出來的和程式一樣
foreach ($f in 'Head-Count', 'Add-Badge', 'State-Badges', 'Fmt-Size', 'Set-Bar', 'Legend', 'Fmt-Dur') {
    if ($src -match "(?s)(function $f\(.*?\r?\n\})") { . ([scriptblock]::Create($Matches[1])) } else { throw "找不到 $f" }
}
$win = [Windows.Markup.XamlReader]::Parse($xamlText.Replace('__RES__', $styles))
$win.Width = 1220; $win.Height = 820
$win.FindName('Library').Columns = 5; $win.FindName('Others').Columns = 5
$fake = @(@('All You Need Is Help', 'v1.2.0 · 1 DLC', '● 在 iPad 上', '#30D158', $true), @('ANIMAL WELL', 'v1.0.7', '● 在 iPad 上', '#30D158', $true),
          @('Balatro', 'v1.1.3', '● 轉好了，等同步', '#0A84FF', $true), @('Boomerang Fu', 'v1.3.6 · 2 DLC', '● 要重新轉換', '#FF9F0A', $true),
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
    if ($i -eq 2 -or $i -eq 3) { $c.Background = Brush '#2A0A84FF'; $c.FindName('Check').Visibility = 'Visible' }   # 點選起來的（給「轉檔」）
    if ($i -eq 1) { $c.FindName('InsR').Visibility = 'Visible' }   # 拖曳時插入的位置
    if ($i -eq 4 -or $i -eq 7) { Add-Badge $c '要注意' '#33FF9F0A' '#FF9F0A' 'x' }
    if (-not $f[4]) { Add-Badge $c '未驗證' '#33FFD60A' '#FFD60A' 'x' }
    State-Badges $c @($f[1] -split ' · ')
    Add-Badge $c (Fmt-Size ((1 + $i * 1.7) * 1GB)) '#1C1C1E' '#8E8E93' 'x'
    [void]$(if ($f[4]) { $win.FindName('Library') } else { $win.FindName('Others') }).Children.Add($c)
    $i++
}
Head-Count $win.FindName('GamesHead') '遊戲庫' 6; Head-Count $win.FindName('OutHead') '還沒加入' 2
$win.FindName('Account').Text = 'someone@example.com'; $win.FindName('AcctDot').Fill = Brush '#30D158'; $win.FindName('Login').Content = '換帳號'
$win.FindName('SelCount').Text = '已選 2 款：Balatro、Boomerang Fu'; $win.FindName('SelSub').Text = '按「轉檔」只在電腦上轉好這幾款（不用接 iPad）；拖曳可以一起搬。按 Esc 取消選取'; $win.FindName('SelSub').Visibility = 'Visible'
$win.FindName('Start').Content = '轉檔（2 款）'
# 空間圖
$win.FindName('PcL').Text = '電腦（C:）'; $win.FindName('PcR').Text = '剩 337.2 GB / 共 931.5 GB'
Set-Bar $win.FindName('PcBar') @(@{ Bytes = 410GB; Color = '#0A84FF' }, @{ Bytes = 184GB; Color = '#636366' }, @{ Bytes = 337GB; Color = $null })
Legend $win.FindName('PcLegend') @(@{ Color = '#0A84FF'; Text = '遊戲 410.0 GB' }, @{ Color = '#636366'; Text = '其他 184.3 GB' }, @{ Color = '#3A3A3C'; Text = '可用 337.2 GB' })
$win.FindName('IpadL').Text = 'iPad（立安的 iPad）'; $win.FindName('IpadR').Text = '剩 56.6 GB / 共 238.4 GB · 5 分鐘前'
Set-Bar $win.FindName('IpadBar') @(@{ Bytes = 60GB; Color = '#636366' }, @{ Bytes = 113GB; Color = '#0A84FF' }, @{ Bytes = 9GB; Color = '#FF9F0A' }, @{ Bytes = 15GB; Color = '#30D158' }, @{ Bytes = 50GB; Color = $null })
Legend $win.FindName('IpadLegend') @(@{ Color = '#636366'; Text = '其他 59.8 GB' }, @{ Color = '#0A84FF'; Text = '遊戲庫 122.0 GB' }, @{ Color = '#FF9F0A'; Text = '拿掉 1 款 −9.0 GB' }, @{ Color = '#30D158'; Text = '加入 2 款 +15.2 GB' }, @{ Color = '#3A3A3C'; Text = '同步後剩 50.4 GB ✓ 放得下'; Fg = '#30D158' })
# 背景工作卡片：佇列跑到一半、正在傳到 iPad（-NoBg 不畫）
if (-not $NoBg) {
    $win.FindName('Bg').Visibility = 'Visible'
    $win.FindName('BgTitle').Text = '第 3 / 9 款：Kirby Forgotten Land · 打包 · 翻譯著色器（12 分）'
    $win.FindName('BgSub').Text = '佇列 art57 · 09:12 開始，已經 48 分'
    $win.FindName('BgDisk').Text = 'C: 剩 214.3 GB'
    $win.FindName('BgMore').Visibility = 'Visible'
    $tags = $win.FindName('BgTags')
    foreach ($t in @(@('✓ 完成 2', '#30D158', '#1E3A26'), @('✕ 失敗 1', '#FF453A', '#3A1E1E'), @('排隊 5', '#C7C7CC', '#2C2C2E'), @('預估還要 2 小時 10 分（約 12:10 完成）', '#C7C7CC', '#2C2C2E'))) {
        $b = New-Object Windows.Controls.Border; $b.CornerRadius = '7'; $b.Padding = '9,3'; $b.Margin = '0,0,6,4'; $b.Background = Brush $t[2]
        $tb = New-Object Windows.Controls.TextBlock; $tb.Text = $t[0]; $tb.FontSize = 12; $tb.Foreground = Brush $t[1]; $b.Child = $tb; [void]$tags.Children.Add($b)
    }
    $win.FindName('BgPush').Visibility = 'Visible'
    $win.FindName('BgPushL').Text = '傳到 iPad 45% · 12.3 GB / 27.0 GB'; $win.FindName('BgPushR').Text = '剩約 8 分 · 31 MB/s'
    $win.FindName('BgFill').Width = 520
    $n = $win.FindName('BgNote'); $n.Text = '全部打包好會一次傳到 iPad'; $n.Visibility = 'Visible'
}
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

# 第二張：同步中的進度頁（整體進度、每一步、傳到 iPad 的每一款、著色器紀錄）
$jobXaml = Here 'jobXaml'
$win2 = [Windows.Markup.XamlReader]::Parse($xamlText.Replace('__RES__', $styles))
$win2.FindName('LibraryView').Visibility = 'Collapsed'; $win2.FindName('ProgressView').Visibility = 'Visible'; $win2.FindName('Space').Visibility = 'Collapsed'
$win2.FindName('ProgTitle').Text = '同步中'; $win2.FindName('ProgTotal').Text = '已經 12 分'
$win2.FindName('AllFill').Width = 1156 * 0.62
$win2.FindName('AllPct').Text = '第 4 / 5 步：同步到 iPad · 62%'; $win2.FindName('AllEta').Text = '剩約 9 分（約 15:42 完成）'
$steps = @(@('轉檔：Kirby Star Allies', @('解包', '轉換程式', '著色器', '準備合包'), 4, '轉檔完成，隨時可以同步到 iPad', '花了 14 分'),
           @('合成遊戲庫', @('合成'), 1, '遊戲庫合成好了', '花了 1 分'),
           @('同步到 iPad', @('連接 iPad', '備份存檔', '重簽', '傳資料', '存檔同步', '著色器紀錄'), 3, '傳送遊戲資料 46%（3420 / 7410 MB）', '已 4 分 · 剩約 6 分'))
foreach ($st in $steps) {
    $row = [Windows.Markup.XamlReader]::Parse($jobXaml); $row.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Parse($styles))
    $row.FindName('Title').Text = $st[0]; $row.FindName('Msg').Text = $st[3]; $row.FindName('Time').Text = $st[4]; $row.FindName('Drop').Visibility = 'Collapsed'
    $k = 0
    foreach ($n in $st[1]) {
        $p = New-Object Windows.Controls.Border; $p.CornerRadius = '10'; $p.Padding = '11,4'; $p.Margin = '0,0,6,6'
        $t = New-Object Windows.Controls.TextBlock; $t.FontSize = 12; $p.Child = $t
        if ($k -lt $st[2]) { $p.Background = Brush '#1E3A26'; $t.Foreground = Brush '#30D158'; $t.Text = "✓ $n" } elseif ($k -eq $st[2]) { $p.Background = Brush '#0A84FF'; $t.Foreground = Brush '#FFFFFF'; $t.Text = "● $n" } else { $p.Background = Brush '#2C2C2E'; $t.Foreground = Brush '#8E8E93'; $t.Text = $n }
        [void]$row.FindName('Steps').Children.Add($p); $k++
    }
    $row.FindName('JTrack').Visibility = 'Visible'
    $row.FindName('JFill').Width = if ($st[0] -eq '同步到 iPad') { 470 } else { 1040 }
    if ($st[0] -eq '同步到 iPad') {
        $lv = $row.FindName('Live'); $lv.Text = '傳到 iPad 46% · 3.3 GB / 7.2 GB · 31 MB/s · 正在傳 Kirby Star Allies 遊戲資料'; $lv.Visibility = 'Visible'
        $box = $row.FindName('Items'); $box.Visibility = 'Visible'
        foreach ($it in @(@('−', '#FF9F0A', '先刪掉 Tricky Towers，騰出空間', ''), @('✓', '#30D158', 'Super Mario Galaxy 遊戲資料', '2.1 GB'), @('●', '#0A84FF', 'Kirby Star Allies 遊戲資料', '1.2 GB / 4.6 GB'), @('○', '#8E8E93', 'Kirby Star Allies 著色器', '0.5 GB'))) {
            $d = New-Object Windows.Controls.DockPanel; $d.Margin = '0,0,0,3'
            $r = New-Object Windows.Controls.TextBlock; $r.Text = $it[3]; $r.FontSize = 12; $r.Foreground = Brush '#8E8E93'; [Windows.Controls.DockPanel]::SetDock($r, 'Right'); [void]$d.Children.Add($r)
            $g = New-Object Windows.Controls.TextBlock; $g.Text = $it[0]; $g.Width = 18; $g.FontSize = 12; $g.Foreground = Brush $it[1]; [Windows.Controls.DockPanel]::SetDock($g, 'Left'); [void]$d.Children.Add($g)
            $t = New-Object Windows.Controls.TextBlock; $t.Text = $it[2]; $t.FontSize = 12.5; [void]$d.Children.Add($t)
            [void]$box.Children.Add($d)
        }
    }
    [void]$win2.FindName('Jobs').Children.Add($row)
}
$root = $win2.Content; $win2.Content = $null
$h3 = New-Object Windows.Controls.Border; $h3.Background = $win2.Background; $h3.Child = $root
$h3.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Parse($styles))
foreach ($k in 'FontFamily', 'FontSize', 'Foreground') { $h3.SetValue([Windows.Documents.TextElement]::"$($k)Property", $win2.$k) }
$h3.Measure($size); $h3.Arrange((New-Object Windows.Rect $size)); $h3.UpdateLayout()
$bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap 1220, 820, 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
$bmp.Render($h3)
$enc = New-Object Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
$Out2 = $Out -replace '\.png$', '-progress.png'
$o = [IO.File]::Create($Out2); try { $enc.Save($o) } finally { $o.Dispose() }
Write-Host "畫好了：$Out2"
