# nxn-app.ps1 - PadSwitch：Switch 遊戲打包到 iPad 的正式版視窗：遊戲用卡片選單挑，選好按「開始」就自動打包、簽章、裝到 iPad。
# 真正做事的是 nxn.ps1（每款一個 powershell 子程序），這裡只負責畫面、排隊和讀進度。
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.IO.Compression.FileSystem
# 從 .cmd 開時命令列視窗是隱藏的，出錯要用對話框才看得到
trap { [void][Windows.MessageBox]::Show($_.ToString(), 'PadSwitch 出錯'); break }

$here = $PSScriptRoot
# 開啟各步驟花多久（寫在 work\gui-logs\startup.log，2026-11-20 使用者說開啟很慢：視窗 11 秒才出來、之後 15 秒都很卡）
$startSw = [Diagnostics.Stopwatch]::StartNew()
$startMarks = New-Object System.Collections.Generic.List[string]
$startLast = 0L
try { $startMarks.Add(('PowerShell 啟動和讀程式 {0:N1}s' -f ((Get-Date) - (Get-Process -Id $PID).StartTime).TotalSeconds)) } catch { }
function Mark($what) {
    $ms = $startSw.ElapsedMilliseconds
    $startMarks.Add(('{0} {1:N1}s' -f $what, (($ms - $script:startLast) / 1000.0)))
    $script:startLast = $ms
}
function Flush-Marks($title) {
    try {
        $line = '{0:yyyy-MM-dd HH:mm:ss} {1}（共 {2:N1}s）：{3}' -f (Get-Date), $title, ($startSw.ElapsedMilliseconds / 1000.0), ($startMarks -join '／')
        Add-Content -LiteralPath (Join-Path $logDir 'startup.log') -Value $line -Encoding UTF8
    } catch { }
    $startMarks.Clear()
}
# 程式檔都在 nxn\程式\，遊戲、合包和 PadSwitch.exe 在上一層 nxn\（舊版全部攤在 nxn\ 最上層，開起來會自己搬）
$appDirName = '程式'
$packDirName = '遊戲庫'   # 合成好的遊戲庫.ipa 和其他合包（舊版叫 合包\，pc_layout.py 會搬）
$base = if ((Split-Path $here -Leaf) -eq $appDirName) { Split-Path $here -Parent } else { $here }
# 用 Start-Process 開 powershell 會走 ShellExecute：Windows 11 的預設主控台是 Windows Terminal，-WindowStyle Hidden 藏不住，
# 會留下一個標題「powershell」的視窗。跟 PadSwitch.exe 一樣用 CreateNoWindow 開就沒有視窗
function Start-HiddenPs($ps1, [string[]]$more = @()) {
    $psi = New-Object Diagnostics.ProcessStartInfo (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    $psi.Arguments = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$ps1`"") + $more) -join ' '
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WorkingDirectory = Split-Path $ps1
    [void][Diagnostics.Process]::Start($psi)
}

# ---------------------------------------------------------------- 搬家：最上層只留 PadSwitch.exe、遊戲、合包，其他收進 程式\
# 搬到一半失敗也沒關係：每次開都會把還留在最上層的搬過去。正在打包或安裝（另一個 PadSwitch 在跑）就等下次再搬。
function Build-Launcher($exe, $ico) {
    # PadSwitch.exe：只是用隱藏視窗的 PowerShell 開 程式\nxn-app.ps1，讓最上層有一個帶圖示的程式可以點
    $src = @'
using System; using System.Diagnostics; using System.IO; using System.Runtime.InteropServices;
static class SwitchPadLauncher {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int MessageBoxW(IntPtr h, string text, string caption, uint type);
    static int Main() {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string ps1 = Path.Combine(Path.Combine(dir, "程式"), "nxn-app.ps1");
        if (!File.Exists(ps1)) ps1 = Path.Combine(dir, "nxn-app.ps1");
        if (!File.Exists(ps1)) { MessageBoxW(IntPtr.Zero, "找不到 " + ps1, "PadSwitch", 0x10); return 1; }
        var psi = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"),
            "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + ps1 + "\"");
        psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.WorkingDirectory = Path.GetDirectoryName(ps1);
        Process.Start(psi);
        return 0;
    }
}
'@
    # 編譯器的命令列不一定認得中文路徑，先在暫存資料夾用英文檔名做好再搬過去
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "switchpad-$PID"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $cp = New-Object CodeDom.Compiler.CompilerParameters
        $cp.GenerateExecutable = $true
        $cp.OutputAssembly = Join-Path $tmp 'SwitchPad.exe'
        $cp.CompilerOptions = '/target:winexe /optimize'
        if (Test-Path -LiteralPath $ico) {
            Copy-Item -LiteralPath $ico -Destination (Join-Path $tmp 'icon.ico')
            $cp.CompilerOptions += " /win32icon:`"$(Join-Path $tmp 'icon.ico')`""
        }
        [void]$cp.ReferencedAssemblies.Add('System.dll')
        $r = (New-Object Microsoft.CSharp.CSharpCodeProvider).CompileAssemblyFromSource($cp, $src)
        if ($r.Errors.HasErrors) { throw "做不出 PadSwitch.exe：$(@($r.Errors | ForEach-Object { $_.ErrorText }) -join '; ')" }
        Move-Item -LiteralPath $cp.OutputAssembly -Destination $exe -Force
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
function Move-ToAppDir {
    $appDir = Join-Path $base $appDirName
    $others = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'nxn[\w-]*\.ps1' })
    $plain = @('nxn*.ps1', 'nxn_*.py', 'fix_empty_romfs.py', 'make_provisional.py', 'romfs_data.py', 'keys_check.py', 'icon_read.py', 'icon_hd.py', 'saves_data.py', 'ipad_layout.py', 'pc_layout.py', 'NOTICE.txt', 'LibraryIcon.png', 'SwitchPad.ico', 'PadSwitch.cmd', 'Switch Pad.cmd', '打包安裝視窗.cmd', '一鍵打包安裝.cmd', '首次登入AppleID.cmd') |
        ForEach-Object { Get-ChildItem -LiteralPath $base -File -Filter $_ -ErrorAction SilentlyContinue }
    $dirs = @('work', '工具') | ForEach-Object { Join-Path $base $_ } | Where-Object { Test-Path -LiteralPath $_ }
    if (-not ($plain.Count + @($dirs).Count)) { return }
    # 剛按完「更新」時舊的視窗還在關，等它一下
    for ($i = 0; $others.Count -and $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        $others = @($others | Where-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
    }
    if ($others.Count) { return }
    New-Item -ItemType Directory -Force -Path $appDir | Out-Null
    foreach ($d in $dirs) {
        $dst = Join-Path $appDir (Split-Path $d -Leaf)
        if (Test-Path -LiteralPath $dst) { throw "$dst 已經存在，$d 沒辦法搬過去" }
        Move-Item -LiteralPath $d -Destination $dst
    }
    foreach ($f in $plain) {
        $dst = Join-Path $appDir $f.Name
        # 兩邊都有：留新的（舊版的「更新」會把新檔放在最上層）
        if ((Test-Path -LiteralPath $dst) -and (Get-Item -LiteralPath $dst).LastWriteTime -gt $f.LastWriteTime) { Remove-Item -LiteralPath $f.FullName; continue }
        Move-Item -LiteralPath $f.FullName -Destination $dst -Force
    }
    # 設定裡的殼是完整路徑，跟著 work\ 搬
    $sf = Join-Path $appDir 'work\app-settings.json'
    if (Test-Path $sf) {
        $old = (Join-Path $base 'work\').ToLower(); $new = Join-Path $appDir 'work\'
        $j = Get-Content $sf -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.Shell -and ([string]$j.Shell).ToLower().StartsWith($old)) {
            $j.Shell = $new + ([string]$j.Shell).Substring($old.Length)
            $j | ConvertTo-Json | Set-Content $sf -Encoding UTF8
        }
    }
    # 舊版放在最上層的捷徑指向舊位置，PadSwitch.exe 取代它
    $lnk = Join-Path $base 'Switch Pad.lnk'
    if (Test-Path -LiteralPath $lnk) {
        try { if ((New-Object -ComObject WScript.Shell).CreateShortcut($lnk).Arguments -like '*nxn-app.ps1*') { Remove-Item -LiteralPath $lnk } } catch { }
    }
}
# 電腦資料夾統一成跟 iPad 一樣的名稱（pc_layout.py，docs/FOLDERS）：合包→遊戲庫、GL著色器→各遊戲的 著色器紀錄、iPad記錄 和
# 問題回報→記錄\、合包\存檔備份→備份\、遊戲資料夾改成遊戲本身的名字。正在轉檔或傳送時它自己會等下次
# 視窗出來之後才在背景跑（掃每個遊戲資料夾要幾秒，不能卡住開啟）；搬了東西就重畫遊戲庫（$tidyJob，bgTimer 看它結束）
$tidyJob = @{ Proc = $null; Out = '' }
function Tidy-Folders {
    $tool = Join-Path (Join-Path $base $appDirName) 'pc_layout.py'
    $tpf = Join-Path (Join-Path (Join-Path $base $appDirName) 'work') 'python-transfer.txt'
    $py = if (Test-Path $tpf) { (Get-Content $tpf -Raw).Trim() } else { '' }
    if (-not (Test-Path -LiteralPath $tool) -or -not $py -or -not (Test-Path -LiteralPath $py)) { return }
    try {
        $tidyJob.Out = Join-Path (Join-Path (Join-Path $base $appDirName) 'work') 'status\tidy-out.txt'
        $psi = New-Object Diagnostics.ProcessStartInfo $py
        $psi.Arguments = "-I `"$tool`" migrate `"$base`""
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.EnvironmentVariables['PYTHONUTF8'] = '1'
        $tidyJob.Proc = [Diagnostics.Process]::Start($psi)
        $tidyJob.Task = $tidyJob.Proc.StandardOutput.ReadToEndAsync(); $tidyJob.ErrTask = $tidyJob.Proc.StandardError.ReadToEndAsync()
    } catch { $tidyJob.Proc = $null }
}
function End-Tidy {
    if (-not $tidyJob.Proc -or -not $tidyJob.Proc.HasExited) { return $false }
    $out = try { "$($tidyJob.Task.Result)$($tidyJob.ErrTask.Result)" } catch { '' }
    $tidyJob.Proc = $null
    if ($out -match '已經是新的樣子' -or -not $out.Trim()) { return $false }
    try { Add-Content -LiteralPath (Join-Path $work '資料夾搬家.log') -Value ("== " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "`r`n" + $out) -Encoding UTF8 } catch { }
    return $true
}
try {
    Move-ToAppDir
    $appDir = Join-Path $base $appDirName
    $exe = Join-Path $base 'PadSwitch.exe'
    $ico = Join-Path $appDir '工具\SwitchPad.ico'
    if (-not (Test-Path $ico)) { $ico = Join-Path $appDir 'SwitchPad.ico' }
    # 換了圖示（SwitchPad.ico 比 PadSwitch.exe 新）也要重做，不然桌面上一直是舊圖示
    $stale = (Test-Path -LiteralPath $exe) -and (Test-Path -LiteralPath $ico) -and (Get-Item -LiteralPath $ico).LastWriteTime -gt (Get-Item -LiteralPath $exe).LastWriteTime
    if ((Test-Path (Join-Path $appDir 'nxn-app.ps1')) -and (-not (Test-Path -LiteralPath $exe) -or $stale)) {
        try { Build-Launcher $exe $ico } catch { if (-not $stale) { throw } }
    }
    # 2026-11 改名 Switch Pad → PadSwitch（不跟 iPad 上的 SwitchPad App 同名）：舊的 Switch Pad.exe、Switch Pad.cmd 拿掉，桌面捷徑改指向新的
    if (Test-Path -LiteralPath $exe) {
        foreach ($old in (Join-Path $base 'Switch Pad.exe'), (Join-Path $appDir 'Switch Pad.cmd')) {
            if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue }
        }
        try {
            $desk = [Environment]::GetFolderPath('Desktop')
            $oldLnk = Join-Path $desk 'Switch Pad.lnk'; $newLnk = Join-Path $desk 'PadSwitch.lnk'
            if ((Test-Path -LiteralPath $oldLnk) -and -not (Test-Path -LiteralPath $newLnk)) {
                $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($oldLnk)
                if ($sc.TargetPath -like '*Switch Pad.exe' -or $sc.Arguments -like '*nxn-app.ps1*') {
                    $n = (New-Object -ComObject WScript.Shell).CreateShortcut($newLnk)
                    $n.TargetPath = $exe; $n.Arguments = ''; $n.WorkingDirectory = $base; $n.IconLocation = "$exe,0"; $n.Save()
                    Remove-Item -LiteralPath $oldLnk -Force -ErrorAction SilentlyContinue
                }
            }
        } catch { }
    }
    # 這次是從最上層開的，搬好了就從 程式\ 重開
    if ($here -eq $base -and (Test-Path (Join-Path $appDir 'nxn-app.ps1')) -and -not (Test-Path (Join-Path $base 'nxn-app.ps1'))) {
        if (Test-Path -LiteralPath $exe) { Start-Process -FilePath $exe }
        else { Start-HiddenPs (Join-Path $appDir 'nxn-app.ps1') }
        exit
    }
} catch {
    [void][Windows.MessageBox]::Show("整理資料夾沒完成，下次打開會再試一次：`n$($_.Exception.Message)", 'PadSwitch')
    if ($here -eq $base -and -not (Test-Path (Join-Path $base 'work'))) { exit }   # work\ 已經搬走，從這裡跑不起來
}

# 只開一個：已經開著就把那個視窗叫到前面。PadSwitch 自己重開（更新後）時舊的還沒關，等它幾秒
Mark '搬檔檢查'
$appMutex = New-Object Threading.Mutex($false, 'Local\SwitchPadApp')
$owned = $false
try { $owned = $appMutex.WaitOne($(if ($args -contains '-Restart') { 15000 } else { 0 })) } catch [Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) {
    Add-Type -Namespace SwitchPad -Name Win -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr h, int cmd);'
    $other = Get-Process -Name powershell -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID -and $_.MainWindowTitle -in 'PadSwitch', 'Switch Pad' } | Select-Object -First 1
    if ($other) { [void][SwitchPad.Win]::ShowWindowAsync($other.MainWindowHandle, 9); [void][SwitchPad.Win]::SetForegroundWindow($other.MainWindowHandle) }
    else { [void][Windows.MessageBox]::Show('PadSwitch 已經在開啟中，等幾秒視窗就會出來。', 'PadSwitch') }
    exit
}

$gamesDir = Join-Path $base '遊戲'
$script = Join-Path $here 'nxn.ps1'
$work = Join-Path $here 'work'
$logDir = Join-Path $work 'gui-logs'
$coverDir = Join-Path $work 'covers'
$settingsFile = Join-Path $work 'app-settings.json'
$installedDb = Join-Path $work 'installed.json'
$plume = Join-Path $here '工具\plumesign.exe'
$updater = Join-Path $here 'nxn-update.ps1'
# 圖示：更新後放在 工具\，剛解壓的下載檔在最上層
$appIcon = Join-Path $here '工具\SwitchPad.ico'
if (-not (Test-Path $appIcon)) { $appIcon = Join-Path $here 'SwitchPad.ico' }
$repo = 'Mono0713/ns2ios-shell'      # 殼和打包器的新版從這個 repo 的 release 拿
$appRepo = 'Mono0713/Switch-Pad'     # PadSwitch 自己的新版從這個 repo 的 release 拿
New-Item -ItemType Directory -Force -Path $logDir, $coverDir, $gamesDir | Out-Null

# ---------------------------------------------------------------- 設定（殼、UDID、要不要蓋舊 IPA），存在 work\app-settings.json
$cfg = @{ Shell = ''; Udid = ''; Overwrite = $false; Mode = 'both'; Library = $true }
try { (Get-Content $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $cfg[$_.Name] = $_.Value } } catch { }
function Save-Settings { try { [pscustomobject]$cfg | ConvertTo-Json | Set-Content $settingsFile -Encoding UTF8 } catch { } }

# ---------------------------------------------------------------- 樣式：Apple 簡約風（深色、圓角方形按鈕、沒有外框的遊戲格子、小色點狀態、左上角小標籤）
$styles = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <SolidColorBrush x:Key="Bg" Color="#000000"/>
  <SolidColorBrush x:Key="Card" Color="#1C1C1E"/>
  <SolidColorBrush x:Key="Card2" Color="#2C2C2E"/>
  <SolidColorBrush x:Key="Sub" Color="#8E8E93"/>
  <SolidColorBrush x:Key="Accent" Color="#0A84FF"/>
  <Style TargetType="Button">
    <Setter Property="Foreground" Value="#F5F5F7"/>
    <Setter Property="Background" Value="#2A2A2D"/>
    <Setter Property="Padding" Value="16,8"/>
    <Setter Property="FontSize" Value="14"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <!-- 按下去會微縮、放開彈回（docs/DESIGN.zh-TW.md 的「按下」） -->
          <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="9" Padding="{TemplateBinding Padding}" RenderTransformOrigin="0.5,0.5">
            <Border.RenderTransform><ScaleTransform/></Border.RenderTransform>
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.82"/></Trigger>
            <Trigger Property="IsPressed" Value="True">
              <Setter TargetName="b" Property="Opacity" Value="0.7"/>
              <Trigger.EnterActions><BeginStoryboard><Storyboard>
                <DoubleAnimation Storyboard.TargetName="b" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="0.95" Duration="0:0:0.08"/>
                <DoubleAnimation Storyboard.TargetName="b" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="0.95" Duration="0:0:0.08"/>
              </Storyboard></BeginStoryboard></Trigger.EnterActions>
              <Trigger.ExitActions><BeginStoryboard><Storyboard>
                <DoubleAnimation Storyboard.TargetName="b" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1" Duration="0:0:0.25"><DoubleAnimation.EasingFunction><BackEase EasingMode="EaseOut" Amplitude="0.5"/></DoubleAnimation.EasingFunction></DoubleAnimation>
                <DoubleAnimation Storyboard.TargetName="b" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1" Duration="0:0:0.25"><DoubleAnimation.EasingFunction><BackEase EasingMode="EaseOut" Amplitude="0.5"/></DoubleAnimation.EasingFunction></DoubleAnimation>
              </Storyboard></BeginStoryboard></Trigger.ExitActions>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.35"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
    <Setter Property="Background" Value="#0A84FF"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Foreground" Value="White"/>
    <Setter Property="FontSize" Value="15"/>
    <Setter Property="Padding" Value="26,10"/>
  </Style>
  <!-- 遊戲格子上的小按鈕：像 App Store 的「取得」，灰底圓角 -->
  <Style x:Key="Pill" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
    <Setter Property="FontSize" Value="12.5"/>
    <Setter Property="Padding" Value="20,5"/>
    <Setter Property="Foreground" Value="#EBEBF5"/>
  </Style>
  <Style x:Key="Get" TargetType="Button" BasedOn="{StaticResource Pill}">
    <Setter Property="Foreground" Value="#0A84FF"/>
    <Setter Property="FontWeight" Value="Bold"/>
  </Style>
  <!-- 標題列的圓形小按鈕 -->
  <Style x:Key="Round" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
    <Setter Property="Width" Value="34"/>
    <Setter Property="Height" Value="34"/>
    <Setter Property="Padding" Value="0"/>
    <Setter Property="FontWeight" Value="Normal"/>
    <Setter Property="Foreground" Value="#C7C7CC"/>
  </Style>
  <!-- 分段選擇（像 iOS 的 segmented control） -->
  <Style x:Key="Seg" TargetType="RadioButton">
    <Setter Property="Foreground" Value="#C7C7CC"/>
    <Setter Property="FontSize" Value="13"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Border x:Name="b" Background="Transparent" CornerRadius="8" Padding="14,6" Margin="2">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="b" Property="Background" Value="#636366"/>
              <Setter Property="Foreground" Value="White"/>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.35"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style TargetType="ContextMenu">
    <Setter Property="Foreground" Value="White"/>
    <Setter Property="FontSize" Value="14"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ContextMenu">
          <Border Background="#2C2C2E" CornerRadius="12" Padding="6" BorderBrush="#3A3A3C" BorderThickness="1">
            <StackPanel IsItemsHost="True"/>
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style TargetType="MenuItem">
    <Setter Property="Foreground" Value="White"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="MenuItem">
          <Border x:Name="b" Background="Transparent" CornerRadius="7" Padding="12,7" MinWidth="220">
            <ContentPresenter ContentSource="Header"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="b" Property="Background" Value="#0A84FF"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.35"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style TargetType="Separator">
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Separator"><Border Height="1" Background="#3A3A3C" Margin="4,5"/></ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <!-- 細的深色捲軸（像 iOS 的捲動指示），沒有上下箭頭 -->
  <ControlTemplate x:Key="VBar" TargetType="ScrollBar">
    <Track x:Name="PART_Track" IsDirectionReversed="True">
      <Track.Thumb>
        <Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border CornerRadius="4" Background="#48484A" Margin="2,0"/></ControlTemplate></Thumb.Template></Thumb>
      </Track.Thumb>
    </Track>
  </ControlTemplate>
  <ControlTemplate x:Key="HBar" TargetType="ScrollBar">
    <Track x:Name="PART_Track" IsDirectionReversed="False">
      <Track.Thumb>
        <Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border CornerRadius="4" Background="#48484A" Margin="0,2"/></ControlTemplate></Thumb.Template></Thumb>
      </Track.Thumb>
    </Track>
  </ControlTemplate>
  <Style TargetType="ScrollBar">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Width" Value="10"/>
    <Setter Property="MinWidth" Value="10"/>
    <Setter Property="Template" Value="{StaticResource VBar}"/>
    <Style.Triggers>
      <Trigger Property="Orientation" Value="Horizontal">
        <Setter Property="Width" Value="Auto"/>
        <Setter Property="MinWidth" Value="0"/>
        <Setter Property="Height" Value="10"/>
        <Setter Property="MinHeight" Value="10"/>
        <Setter Property="Template" Value="{StaticResource HBar}"/>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style TargetType="ToolTip">
    <Setter Property="Background" Value="#2C2C2E"/><Setter Property="Foreground" Value="#F5F5F7"/><Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="10,6"/>
  </Style>
</ResourceDictionary>
'@

$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PadSwitch" Width="1220" Height="820" MinWidth="820" MinHeight="560"
        Background="#141416" Foreground="#F5F5F7" AllowDrop="True"
        FontFamily="Segoe UI, Microsoft JhengHei UI" FontSize="14" WindowStartupLocation="CenterScreen">
  <Window.Resources>__RES__</Window.Resources>
  <Grid Margin="32,20,32,0">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- 標題列 -->
    <DockPanel Grid.Row="0" Margin="0,0,0,14">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
        <Border Background="#232326" CornerRadius="9" Padding="14,7" Margin="0,0,8,0" VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal">
            <Ellipse x:Name="AcctDot" Width="7" Height="7" Fill="#8E8E93" Margin="0,0,8,0" VerticalAlignment="Center"/>
            <TextBlock x:Name="Account" Text="…" Foreground="#C7C7CC" FontSize="13" VerticalAlignment="Center"/>
          </StackPanel>
        </Border>
        <Button x:Name="Login" Content="登入 Apple ID" Margin="0,0,8,0" FontSize="13" Padding="14,7"/>
        <Button x:Name="Refresh" Content="⟳" ToolTip="重新整理" Margin="0,0,8,0" Style="{StaticResource Round}"/>
        <Button x:Name="Settings" Content="⚙" ToolTip="設定" Style="{StaticResource Round}"/>
      </StackPanel>
      <StackPanel>
        <StackPanel Orientation="Horizontal">
          <Image x:Name="AppLogo" Width="34" Height="34" Margin="0,0,12,0" VerticalAlignment="Center" RenderOptions.BitmapScalingMode="HighQuality"/>
          <TextBlock Text="PadSwitch" FontSize="25" FontWeight="SemiBold" VerticalAlignment="Center" ToolTip="iPad 接上後按「同步」，該做的事會自己排好；點遊戲可以多選、按「轉檔」先在電腦上轉好。拖曳遊戲排順序、拖到「還沒加入」拿掉"/>
          <Border Background="#1C1C1E" CornerRadius="10" Margin="24,0,0,0" VerticalAlignment="Center" Visibility="Collapsed">
            <StackPanel Orientation="Horizontal">
              <RadioButton x:Name="TabGames" GroupName="tab" Style="{StaticResource Seg}" Content="遊戲" IsChecked="True"/>
              <RadioButton x:Name="TabPacks" GroupName="tab" Style="{StaticResource Seg}" Content="合包"/>
            </StackPanel>
          </Border>
        </StackPanel>
        <TextBlock x:Name="Subtitle" Foreground="#8E8E93" Margin="0,2,0,0" Visibility="Collapsed"/>
      </StackPanel>
    </DockPanel>

    <StackPanel Grid.Row="1">
      <!-- 第一次安裝、找不到 prod.keys（更新和續期是標題列的小按鈕） -->
      <Border x:Name="Notice" Background="#1C1C1E" CornerRadius="14" Padding="16,12" Margin="0,0,0,14" Visibility="Collapsed">
        <DockPanel>
          <Button x:Name="NoticeBtn" DockPanel.Dock="Right" Background="#0A84FF" FontWeight="SemiBold"/>
          <TextBlock x:Name="NoticeText" VerticalAlignment="Center" TextWrapping="Wrap" Margin="0,0,12,0"/>
        </DockPanel>
      </Border>
      <!-- 空間：電腦硬碟、iPad，和同步後放不放得下 -->
      <Border x:Name="Space" Background="#1C1C1E" CornerRadius="14" Padding="16,12" Margin="0,0,0,14" BorderBrush="#14FFFFFF" BorderThickness="1">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="28"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <StackPanel Grid.Column="0">
            <DockPanel>
              <TextBlock x:Name="PcR" DockPanel.Dock="Right" FontSize="12" Foreground="#8E8E93" VerticalAlignment="Bottom"/>
              <TextBlock x:Name="PcL" FontSize="13" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
            </DockPanel>
            <Border Background="#2C2C2E" CornerRadius="4" Height="8" Margin="0,7,0,7"><Grid x:Name="PcBar"/></Border>
            <WrapPanel x:Name="PcLegend"/>
          </StackPanel>
          <StackPanel Grid.Column="2">
            <DockPanel>
              <Button x:Name="IpadRefresh" DockPanel.Dock="Right" Content="⟳" FontSize="11" Padding="7,1" Margin="8,0,0,0" ToolTip="重新讀 iPad 的空間（iPad 要用 USB 接著）"/>
              <TextBlock x:Name="IpadR" DockPanel.Dock="Right" FontSize="12" Foreground="#8E8E93" VerticalAlignment="Bottom"/>
              <TextBlock x:Name="IpadL" FontSize="13" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
            </DockPanel>
            <Border Background="#2C2C2E" CornerRadius="4" Height="8" Margin="0,7,0,7"><Grid x:Name="IpadBar"/></Border>
            <WrapPanel x:Name="IpadLegend"/>
          </StackPanel>
        </Grid>
      </Border>
      <!-- 背景工作：打包、背景佇列、傳到 iPad 的進度（讀 work\status\*.json，有在做或 6 小時內做過才出現） -->
      <Border x:Name="Bg" Background="#1C1C1E" CornerRadius="14" Padding="16,12" Margin="0,0,0,14" Visibility="Collapsed"
              BorderBrush="#14FFFFFF" BorderThickness="1">
        <StackPanel>
          <DockPanel>
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
              <Border Background="#2C2C2E" CornerRadius="7" Padding="9,3"><TextBlock x:Name="BgDisk" FontSize="12" Foreground="#C7C7CC"/></Border>
              <Button x:Name="BgMore" Content="清單" FontSize="12" Padding="11,3" Margin="8,0,0,0" Visibility="Collapsed"/>
            </StackPanel>
            <Ellipse x:Name="BgDot" Width="8" Height="8" Fill="#0A84FF" Margin="0,0,10,0" VerticalAlignment="Center"/>
            <TextBlock x:Name="BgTitle" FontSize="15" FontWeight="SemiBold" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
          </DockPanel>
          <TextBlock x:Name="BgSub" FontSize="12" Foreground="#8E8E93" Margin="18,3,0,0" TextTrimming="CharacterEllipsis"/>
          <WrapPanel x:Name="BgTags" Margin="18,8,0,0"/>
          <StackPanel x:Name="BgPush" Margin="18,10,0,0" Visibility="Collapsed">
            <DockPanel>
              <TextBlock x:Name="BgPushR" DockPanel.Dock="Right" FontSize="12" Foreground="#8E8E93"/>
              <TextBlock x:Name="BgPushL" FontSize="12" TextTrimming="CharacterEllipsis"/>
            </DockPanel>
            <Border x:Name="BgTrack" Height="4" CornerRadius="2" Background="#2C2C2E" Margin="0,6,0,0">
              <Border x:Name="BgFill" HorizontalAlignment="Left" Width="0" CornerRadius="2" Background="#0A84FF"/>
            </Border>
          </StackPanel>
          <TextBlock x:Name="BgNote" FontSize="12" Foreground="#C7C7CC" Margin="18,8,0,0" TextWrapping="Wrap" Visibility="Collapsed"/>
          <StackPanel x:Name="BgList" Margin="18,10,0,0" Visibility="Collapsed"/>
        </StackPanel>
      </Border>
    </StackPanel>

    <!-- 遊戲庫 -->
    <ScrollViewer x:Name="LibraryView" Grid.Row="2" VerticalScrollBarVisibility="Auto">
      <StackPanel Margin="0,0,0,24">
        <TextBlock x:Name="GamesHead" Text="遊戲庫" FontSize="26" FontWeight="Bold" Margin="0,4,0,2"/>
        <TextBlock x:Name="InHint" Foreground="#8E8E93" FontSize="13" Margin="0,0,0,10" TextWrapping="Wrap" Text=""/>
        <UniformGrid x:Name="Library" Columns="5" VerticalAlignment="Top" Margin="-6,0,8,16" Background="Transparent" AllowDrop="True" MinHeight="60"/>
        <TextBlock x:Name="OutHead" Text="還沒加入" FontSize="26" FontWeight="Bold" Margin="0,18,0,2"/>
        <TextBlock x:Name="OutHint" Foreground="#8E8E93" FontSize="13" Margin="0,0,0,10" TextWrapping="Wrap" Text="把 NSP / XCI / NSZ 拖進視窗就能新增遊戲；把遊戲拖到這裡就是從遊戲庫拿掉"/>
        <UniformGrid x:Name="Others" Columns="5" VerticalAlignment="Top" Margin="-6,0,8,16" Background="Transparent" AllowDrop="True" MinHeight="60"/>
        <TextBlock x:Name="PacksHead" Text="合包" FontSize="20" FontWeight="SemiBold" Margin="0,8,0,4" Visibility="Collapsed"
                   ToolTip="好幾款遊戲合成的一個 App。點一下看裡面有哪些遊戲"/>
        <UniformGrid x:Name="Packs" Visibility="Collapsed" Columns="5" VerticalAlignment="Top" Margin="-8,0,4,12"/>
      </StackPanel>
    </ScrollViewer>

    <!-- 進度 -->
    <DockPanel x:Name="ProgressView" Grid.Row="2" Visibility="Collapsed">
      <DockPanel DockPanel.Dock="Top" Margin="0,0,0,10">
        <TextBlock x:Name="ProgTotal" DockPanel.Dock="Right" Foreground="#8E8E93" VerticalAlignment="Bottom" FontSize="13"/>
        <TextBlock x:Name="ProgTitle" Text="執行中" FontSize="20" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
      </DockPanel>
      <!-- 整體進度：每一步都有預估時間（上次做同樣的事花多久），正在做的那步看它的進度狀態檔 -->
      <StackPanel x:Name="Busy" DockPanel.Dock="Top" Margin="0,0,0,14">
        <Border x:Name="AllTrack" Height="8" CornerRadius="4" Background="#2C2C2E">
          <Border x:Name="AllFill" HorizontalAlignment="Left" Width="0" CornerRadius="4" Background="#0A84FF"/>
        </Border>
        <DockPanel Margin="0,7,0,0">
          <TextBlock x:Name="AllEta" DockPanel.Dock="Right" FontSize="13" Foreground="#F5F5F7" FontWeight="SemiBold"/>
          <TextBlock x:Name="AllPct" FontSize="13" Foreground="#8E8E93" TextTrimming="CharacterEllipsis"/>
        </DockPanel>
      </StackPanel>
      <ScrollViewer VerticalScrollBarVisibility="Auto">
        <StackPanel>
          <StackPanel x:Name="Jobs" Margin="0,0,0,12"/>
          <Expander x:Name="DoneBox" Header="已完成" Foreground="#8E8E93" Visibility="Collapsed" Margin="0,0,0,12">
            <StackPanel x:Name="DoneJobs" Margin="0,8,0,0"/>
          </Expander>
        </StackPanel>
      </ScrollViewer>
    </DockPanel>

    <!-- 底部列 -->
    <Border Grid.Row="3" Background="#1C1C1E" BorderBrush="#2A2A2D" BorderThickness="0,1,0,0" Padding="32,14" Margin="-32,0,-32,0">
      <DockPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
          <Button x:Name="ShowProg" Content="查看進度" Margin="0,0,10,0" Visibility="Collapsed"/>
          <Button x:Name="Stop" Content="停止" Margin="0,0,10,0" Visibility="Collapsed"/>
          <Button x:Name="Back" Content="返回" Margin="0,0,10,0" Visibility="Collapsed"/>
          <Button x:Name="RenewBtn" Margin="0,0,10,0" Visibility="Collapsed"/>
          <Button x:Name="Start" Content="轉檔" ToolTipService.ShowOnDisabled="True"
                  ToolTip="只在電腦上轉好，先不傳到 iPad（不用接 iPad），之後隨時按「同步」就傳。點遊戲可以多選要轉哪幾款；沒選就轉遊戲庫裡還沒轉的"/>
          <Button x:Name="Sync" Content="同步" Style="{StaticResource Primary}" Margin="10,0,0,0" ToolTipService.ShowOnDisabled="True"
                  ToolTip="iPad 接著電腦時按：自己看要做什麼、排好順序做完（先刪拿掉的遊戲騰空間、轉檔、合成遊戲庫、要的話重簽、傳新遊戲和更新、傳存檔和雙向同步、拿回著色器紀錄）"/>
        </StackPanel>
        <StackPanel x:Name="Options" VerticalAlignment="Center" Margin="0,0,16,0">
          <TextBlock x:Name="SelCount" Text="" FontSize="14" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
          <TextBlock x:Name="SelSub" Text="" FontSize="12" Foreground="#8E8E93" Margin="0,2,0,0" TextTrimming="CharacterEllipsis" Visibility="Collapsed"/>
          <!-- 只剩遊戲庫一種做法：舊的模式切換留著不顯示，程式裡還認得它們 -->
          <Border Background="#2C2C2E" CornerRadius="10" Margin="8,0,0,0" Visibility="Collapsed">
            <StackPanel Orientation="Horizontal">
              <RadioButton x:Name="ModeBoth" GroupName="mode" Style="{StaticResource Seg}" Content="打包並安裝" IsChecked="True"/>
              <RadioButton x:Name="ModePack" GroupName="mode" Style="{StaticResource Seg}" Content="只打包"/>
              <RadioButton x:Name="ModeInstall" GroupName="mode" Style="{StaticResource Seg}" Content="只安裝" ToolTip="把現有的 IPA 重新簽章裝到 iPad"/>
            </StackPanel>
          </Border>
          <Border Background="#2C2C2E" CornerRadius="10" Margin="12,0,0,0" Visibility="Collapsed">
            <StackPanel Orientation="Horizontal">
              <RadioButton x:Name="Separate" GroupName="pack" Style="{StaticResource Seg}" Content="各自安裝" ToolTip="每款遊戲各是一個 App"/>
              <RadioButton x:Name="Merge" GroupName="pack" Style="{StaticResource Seg}" Content="遊戲庫" IsEnabled="False" IsChecked="True"
                           ToolTipService.ShowOnDisabled="True" ToolTip="iPad 上只放一個 App：勾的遊戲都在裡面（要有多遊戲殼）"/>
            </StackPanel>
          </Border>
          <TextBlock x:Name="ShellLabel" Visibility="Collapsed"/>
        </StackPanel>
      </DockPanel>
    </Border>
  </Grid>
</Window>
'@
# 樣式要在載入前就放進 Window.Resources，StaticResource 才找得到
# Windows 的標題列也用深色（Windows 10 1809 以後；舊版不支援就照舊）
try { Add-Type -Namespace SwitchPad -Name Dwm -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size); [DllImport("shell32.dll")] public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string id);' } catch { }   # 一次編譯（每個 Add-Type 都要跑一次 C# 編譯器，約一秒）
function Dark-TitleBar($w) {
    $w.Add_SourceInitialized({ param($s, $e)
        try {
            $h = (New-Object Windows.Interop.WindowInteropHelper $s).Handle; $on = 1
            if ([SwitchPad.Dwm]::DwmSetWindowAttribute($h, 20, [ref]$on, 4) -ne 0) { [void][SwitchPad.Dwm]::DwmSetWindowAttribute($h, 19, [ref]$on, 4) }
        } catch { } })
}
# 換畫面（遊戲庫 ↔ 進度）時淡入、從下面滑上來一點（docs/DESIGN.zh-TW.md 的動畫）
function Fade-In($el) {
    try {
        $ease = New-Object Windows.Media.Animation.QuadraticEase; $ease.EasingMode = 'EaseOut'
        $t = New-Object Windows.Media.TranslateTransform 0, 14; $el.RenderTransform = $t
        $a = New-Object Windows.Media.Animation.DoubleAnimation 0, 1, ([Windows.Duration][TimeSpan]::FromMilliseconds(220)); $a.EasingFunction = $ease
        $m = New-Object Windows.Media.Animation.DoubleAnimation 14, 0, ([Windows.Duration][TimeSpan]::FromMilliseconds(280)); $m.EasingFunction = $ease
        $el.BeginAnimation([Windows.UIElement]::OpacityProperty, $a)
        $t.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $m)
    } catch { $el.BeginAnimation([Windows.UIElement]::OpacityProperty, $null); $el.Opacity = 1 }
}
function Load-Window([string]$text) { $w = [Windows.Markup.XamlReader]::Parse($text.Replace('__RES__', $styles)); if ($w -is [Windows.Window]) { Dark-TitleBar $w }; $w }
# 自己的工作列身分，工作列才會用 PadSwitch 的圖示，不是 PowerShell 的
try {
    [void][SwitchPad.Dwm]::SetCurrentProcessExplicitAppUserModelID('PadSwitch.App')
} catch { }
Mark '載入程式'
$win = Load-Window $xamlText
Mark '建立視窗'
if (Test-Path $appIcon) {
    # 讀進記憶體再用：BitmapFrame::Create(Uri) 會一直鎖住檔案，更新時就蓋不過去（"另一個處理程序正在使用檔案 ...\SwitchPad.ico"）
    try {
        $fs = [IO.File]::OpenRead($appIcon)
        try { $win.Icon = [Windows.Media.Imaging.BitmapFrame]::Create($fs, 'None', 'OnLoad') } finally { $fs.Dispose() }
    } catch { }
    # 標題旁的小圖示：用 .ico 裡最大的那張，縮小才清楚
    try {
        $fs = [IO.File]::OpenRead($appIcon)
        try {
            $dec = [Windows.Media.Imaging.BitmapDecoder]::Create($fs, 'None', 'OnLoad')
            $win.FindName('AppLogo').Source = $dec.Frames | Sort-Object { $_.PixelWidth } -Descending | Select-Object -First 1
        } finally { $fs.Dispose() }
    } catch { }
    # 不自己建桌面捷徑（使用者不要）；只把舊版建的「PowerShell 開 nxn-app.ps1」捷徑改指向 PadSwitch.exe
    try {
        $exe = Join-Path $base 'PadSwitch.exe'
        $lnkPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'PadSwitch.lnk'
        if ((Test-Path -LiteralPath $exe) -and (Test-Path -LiteralPath $lnkPath)) {
            $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($lnkPath)
            if ($lnk.Arguments -like '*nxn-app.ps1*') {
                $lnk.TargetPath = $exe
                $lnk.Arguments = ''
                $lnk.WorkingDirectory = $base
                $lnk.IconLocation = "$exe,0"
                $lnk.Save()
            }
        }
    } catch { }
}
$ui = @{}
foreach ($n in 'AppLogo','AcctDot','Account','Login','Refresh','Settings','Subtitle','RenewBtn','LibraryView','Library','Notice','NoticeText','NoticeBtn','GamesHead','PacksHead','Packs','TabGames','TabPacks','InHint','OutHead','OutHint','Others',
               'ProgressView','ProgTitle','ProgTotal','Busy','Jobs','Stop','Back','Start','Sync','Options','SelCount',
               'ModeBoth','ModePack','ModeInstall','Separate','Merge','ShellLabel','SelSub','ShowProg','DoneBox','DoneJobs',
               'Bg','BgDisk','BgMore','BgDot','BgTitle','BgSub','BgTags','BgPush','BgPushL','BgPushR','BgTrack','BgFill','BgNote','BgList',
               'Space','PcL','PcR','PcBar','PcLegend','IpadL','IpadR','IpadBar','IpadLegend','IpadRefresh','AllTrack','AllFill','AllEta','AllPct') { $ui[$n] = $win.FindName($n) }

function Brush($hex) { New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex)) }
function Esc($s) { [Security.SecurityElement]::Escape([string]$s) }

# ---------------------------------------------------------------- 殼：預設正式殼 work\shell.zip，設定裡可以換
# 殼只會放在 work\<sub> 或下一層（multigame\art<N>\）：不往下鑽，旁邊的打包器原始碼（src-*）有上萬個檔案，整棵掃一次要好幾秒
function Find-Shallow($root, $filter) {
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    @(Get-ChildItem -LiteralPath $root -File -Filter $filter -ErrorAction SilentlyContinue) +
    @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike 'src-*' } |
        ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -File -Filter $filter -ErrorAction SilentlyContinue })
}
function Get-Shells {
    $list = @()
    $main = Join-Path $work 'shell.zip'
    if (Test-Path $main) {
        $rel = Join-Path $work 'release.txt'
        $tag = if (Test-Path $rel) { (Get-Content $rel -Raw).Trim() } else { '' }
        $id = if ($tag -match 'shell-\d+-([0-9a-f]+)') { $Matches[1] } else { '' }
        $list += [pscustomobject]@{ Path = $main; Label = "正式殼 $id"; Tag = $tag }
    }
    foreach ($sub in 'multigame', 'phonepads', 'dl') {
        Find-Shallow (Join-Path $work $sub) 'shell-*.zip' |
            Sort-Object LastWriteTime -Descending | ForEach-Object {
                $f = $_
                if ($list | Where-Object { $_.Tag -eq $f.BaseName }) { return }   # 跟正式殼同一個版本的下載檔不重複列
                $id = if ($f.Name -match 'shell-\d+-([0-9a-f]+)') { $Matches[1] } else { $f.BaseName }
                $kind = @{ multigame = '多遊戲測試殼'; phonepads = '手機搖桿測試殼'; dl = '舊殼' }[$sub]
                $list += [pscustomobject]@{ Path = $f.FullName; Label = "$kind $id（$($f.LastWriteTime.ToString('MM/dd HH:mm'))）"; Tag = $f.BaseName }
            }
    }
    return $list
}
function Current-Shell {
    $all = @(Get-Shells)
    $pick = $all | Where-Object { $_.Path -eq $cfg.Shell } | Select-Object -First 1
    if (-not $pick) { $pick = $all | Select-Object -First 1 }
    return $pick
}
function Update-ShellLabel {
    if ($ui.Merge.IsChecked) {
        # 合成一包用 work\multigame 裡最新的多遊戲殼，設定裡退回或鎖定過就用那一版
        $ms = Get-MultiShell
        $id = if ($ms -and $ms.Name -match 'shell-\d+-([0-9a-f]+)') { $Matches[1] } else { '' }
        $ui.ShellLabel.Text = "多遊戲殼 $id"
        $ui.ShellLabel.ToolTip = if ($ms) { "合成一包用的殼：$($ms.FullName)" } else { '' }
        return
    }
    $s = Current-Shell
    $ui.ShellLabel.Text = if ($s) { ($s.Label -replace '（.*$', '') } else { '找不到殼' }
    $ui.ShellLabel.ToolTip = if ($s) { "打包用的殼：$($s.Label)（在設定裡換）" } else { '請先執行 nxn-setup.ps1 -SetupOnly' }
}

# ---------------------------------------------------------------- 安裝紀錄（nxn.ps1 每次裝好會寫 work\installed.json）
function Get-Installed {
    if (-not (Test-Path $installedDb)) { return @() }
    try {
        $j = Get-Content $installedDb -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($j.PSObject.Properties | ForEach-Object {
            $t = [datetime]$_.Value.time
            [pscustomobject]@{ Dir = $_.Name; Ipa = $_.Value.ipa; Time = $t; Left = 7 - [int][math]::Floor(((Get-Date) - $t).TotalDays) }
        })
    } catch { return @() }
}

# ---------------------------------------------------------------- 掃遊戲資料夾：從檔名看出本體、更新、DLC（打包器自己也會挑最新的）
function Scan-Game($dir) {
    $g = [pscustomobject]@{ Dir = $dir.FullName; Name = $dir.Name; Base = $false; BaseFile = ''; Update = ''; UpdateN = -1; Dlc = 0; Ipas = @(); Stray = 0; Tid = ''; SourceBytes = 0L; LocalBytes = 0L; NewestSourceWrite = [datetime]::MinValue; PackageKey = ''; HasPendingSave = $false }
    foreach ($f in Get-ChildItem -LiteralPath $dir.FullName -File -ErrorAction SilentlyContinue) {
        $g.LocalBytes += [long]$f.Length
        if ($f.Extension -eq '.ipa') { if ($f.Name -notlike '*-multi-*') { $g.Ipas += $f }; continue }   # -multi- 是合包的半成品，不能單獨裝
        if ($f.Extension -notin '.nsp', '.xci', '.nsz', '.xcz') { continue }   # NSZ / XCZ 打包時會先解壓（nxn.ps1）
        $g.SourceBytes += [long]$f.Length
        if ($f.LastWriteTime -gt $g.NewestSourceWrite) { $g.NewestSourceWrite = $f.LastWriteTime }
        $tid = if ($f.Name -match '(?<![0-9A-Fa-f])(01[0-9A-Fa-f]{14})(?![0-9A-Fa-f])') { $Matches[1].ToUpper() } else { '' }
        $low = if ($tid) { [Convert]::ToInt32($tid.Substring(13), 16) } else { 0 }
        if (-not $tid -or $low -eq 0) { $g.Base = $true; $g.BaseFile = $f.FullName; if ($tid) { $g.Tid = $tid } }
        elseif ($low -eq 0x800) {
            $n = if ($f.Name -match '\[v(\d+)\]') { [int64]$Matches[1] } else { 0 }
            if ($n -ge $g.UpdateN) {
                $g.UpdateN = $n
                $g.Update = if ($f.Name -match '(?:^|[\s\[v])(\d+\.\d+(?:\.\d+)?)(?=[\s\]\[]|$)') { $Matches[1] } else { "#$($n -shr 16)" }
            }
        }
        else { $g.Dlc++ }
    }
    # 打包器只看資料夾第一層，子資料夾裡的檔案不會被用到
    $g.Stray = @(Get-ChildItem -LiteralPath $dir.FullName -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Get-ChildItem -LiteralPath $_.FullName -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.nsp', '.xci' } }).Count
    $g.Ipas = @($g.Ipas | Sort-Object LastWriteTime -Descending)
    # 檔名裡沒有 [0100…] 的本體（例如「Tricky Towers.nsp」）：打包器讀檔案內容認出的編號，留在它的工作資料夾 <編號>_pack
    if ($g.Base -and -not $g.Tid) {
        $pk = Get-ChildItem -LiteralPath $dir.FullName -Directory -Filter '01*_pack' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(01[0-9A-Fa-f]{14})_pack$' } | Select-Object -First 1
        if ($pk -and $pk.Name -match '^(01[0-9A-Fa-f]{14})_pack$') { $g.Tid = $Matches[1].ToUpper() }
    }
    return $g
}

# ---------------------------------------------------------------- 支援狀態：殼附的 supported.tsv（上游驗證過的遊戲和版本）＋打包器裡的設定檔
$supported = @{}
function Load-Supported {
    $supported.Clear()
    $supTsv = @(Find-Shallow $work '*supported.tsv') + @(Find-Shallow (Join-Path $work 'multigame') '*supported.tsv') + @(Find-Shallow (Join-Path $work 'dl') '*supported.tsv') |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $supTsv) { return }
    foreach ($line in (Get-Content -LiteralPath $supTsv.FullName -Encoding UTF8 | Select-Object -Skip 1)) {
        $c = $line -split "`t"
        if ($c.Count -ge 3 -and $c[0] -match '^[0-9A-Fa-f]{16}$') { $supported[$c[0].ToUpper()] = $c[2] }
    }
}
Load-Supported
Mark '讀支援清單'
function Precheck-Of($g) {
    $f = Join-Path $g.Dir 'precheck.json'
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    try { @((Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json).items) } catch { @() }
}
$provCache = @{ At = [datetime]::MinValue; Set = $null }
function Provisional-Tids {
    if (-not $provCache.Set -or ((Get-Date) - $provCache.At).TotalMinutes -gt 5) {
        $set = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($d in @(Get-ChildItem -Path (Join-Path $work 'multigame\*\src-*\dm\games') -Directory -ErrorAction SilentlyContinue)) {
            foreach ($t in [IO.Directory]::GetDirectories($d.FullName)) { if ([IO.File]::Exists((Join-Path $t 'game.tsv'))) { [void]$set.Add((Split-Path $t -Leaf).ToUpper()) } }
        }
        $provCache.Set = $set; $provCache.At = Get-Date
    }
    $provCache.Set
}
function Support-Of($g) {
    if (-not $g.Tid) { return @{ Text = ''; Color = '#8E8E93' } }
    $mine = if ($g.Update -and $g.Update -notlike '#*') { $g.Update } elseif (-not $g.Update) { '1.0.0' } else { '' }
    if ($supported.ContainsKey($g.Tid)) {
        $v = $supported[$g.Tid]
        $vv = ($v -split '[（( ]')[0]
        $same = $false
        try { $same = ([version]$mine) -eq ([version]$vv) } catch { $same = ($mine -eq $vv) }
        if ($mine -and ($same -or $v -match [regex]::Escape($mine))) { return @{ Text = '● 已驗證'; Color = '#30D158'; Tip = "上游驗證過這個版本（$mine）" } }
        $have = if ($mine) { "你的是 $mine" } else { '你的版本看不出來' }
        return @{ Text = '● 版本不同'; Color = '#FF9F0A'; Tip = "上游驗證過的是 $vv，$have。版本不同時可能對不上，最好換成驗證過的版本" }
    }
    if (Test-Path (Join-Path $work "src\dm\games\$($g.Tid)\game.tsv")) { return @{ Text = '● 自訂設定'; Color = '#64D2FF'; Tip = '用本機的設定檔打包（非官方支援）' } }
    # 打包器自動推導的暫定設定檔放在多遊戲殼那版的打包器裡（work\multigame\art*\src-<sha>\dm\games）
    if ((Provisional-Tids).Contains("$($g.Tid)".ToUpper())) { return @{ Text = '● 暫定設定'; Color = '#64D2FF'; Tip = '不在上游的支援清單，用打包器自動推導的設定檔：轉換過了，能不能玩要在 iPad 上試' } }
    return @{ Text = '● 不支援'; Color = '#FF453A'; Tip = '不在上游的支援清單，打包器會試著自動推導，但大多需要在 Mac 上調整才打得開' }
}

# ---------------------------------------------------------------- 遊戲圖示：一律用遊戲檔案裡的圖示（自己換的 cover.* 優先）
# 快取在 work\covers\<名稱>.png：先從資料夾裡的 IPA 拿（就是遊戲圖示），沒有 IPA 就在背景用 icon_read.py 直接從本體讀出來
# （NSP / XCI / NSZ / XCZ 都行，只讀 Control NCA，一兩秒），讀不到才退回用 nx_extract 解
# 讀過的圖示留在記憶體（跟著檔案的修改時間）：每次重畫卡片都從磁碟解一次 PNG 會卡
$bmpCache = @{}
function Load-Bitmap($path) {
    $fi = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    $key = if ($fi) { "$path|$($fi.LastWriteTimeUtc.Ticks)" } else { '' }
    if ($key -and $bmpCache.ContainsKey($key)) { return $bmpCache[$key] }
    $b = Load-Bitmap-Disk $path
    if ($key -and $b) { $bmpCache[$key] = $b }
    $b
}
function Load-Bitmap-Disk($path) {
    try {
        $fs = [IO.File]::OpenRead($path)
        try {
            $dec = [Windows.Media.Imaging.BitmapDecoder]::Create($fs, 'PreservePixelFormat', 'OnLoad')
            $best = $dec.Frames | Sort-Object PixelWidth -Descending | Select-Object -First 1
            $best.Freeze(); return $best
        } finally { $fs.Dispose() }
    } catch { return $null }
}
function Cover-For($g) {
    if ($g.PSObject.Properties['Icon'] -and $g.Icon) { return Load-Bitmap $g.Icon }
    $key = ($g.Name -replace '[^\w.-]', '_')
    $cache = Join-Path $coverDir "$key.png"
    foreach ($n in 'cover.png', 'cover.jpg', 'cover.jpeg', 'cover.ico') { $p = Join-Path $g.Dir $n; if (Test-Path -LiteralPath $p) { return Load-Bitmap $p } }
    if (Test-Path -LiteralPath $cache) { return Load-Bitmap $cache }
    $jpg = Join-Path $coverDir "$key.jpg"
    if (Test-Path -LiteralPath $jpg) { return Load-Bitmap $jpg }
    foreach ($ipa in $g.Ipas) {
        try {
            $z = [IO.Compression.ZipFile]::OpenRead($ipa.FullName)
            try {
                $e = $z.Entries | Where-Object { $_.FullName -match '^Payload/[^/]+\.app/AppIcon60x60@3x\.png$' } | Select-Object -First 1
                if ($e) { [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $cache, $true); return Load-Bitmap $cache }
            } finally { $z.Dispose() }
        } catch { }
    }
    if ($g.BaseFile -and (Icon-Sig $g.BaseFile) -ne (Get-Content -LiteralPath (Join-Path $coverDir "$key.none") -Raw -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() })) { Queue-Icon $g $jpg }
    return $null
}
# .none 記下當時讀的本體檔（路徑、大小、時間）：本體換了（例如 NSZ 解壓成 NSP）就再試一次
function Icon-Sig($file) {
    $i = Get-Item -LiteralPath $file -ErrorAction SilentlyContinue
    if (-not $i) { return '' }
    # 開頭的 3：改成 icon_read.py 直接讀之後，舊的 .none 都要再試一次
    "3|$($i.FullName)|$($i.Length)|$($i.LastWriteTimeUtc.Ticks)"
}

# 從本體讀圖示：先用 icon_read.py 直接讀；讀不到再用 nx_extract（它會先寫 control.nacp 和 icon.jpg 再解程式，看到 icon.jpg 就把它停掉，--manifest 不解 RomFS）
$iconQueue = New-Object System.Collections.Queue
$iconJob = $null
$nxExtract = Join-Path $work 'tools\nx_extract.exe'
$iconRead = Join-Path $here 'icon_read.py'
# prod.keys：PadSwitch 自己的（拖進視窗的會放在 work\）→ Ryujinx → yuzu 系的模擬器（跟 nxn.ps1 的 Find-Keys 一樣）
function Find-Keys {
    $c = @((Join-Path $work 'prod.keys'), (Join-Path $base 'prod.keys'), "$env:APPDATA\Ryujinx\system\prod.keys")
    foreach ($emu in 'yuzu', 'suyu', 'sudachi', 'citron', 'eden', 'torzu') { $c += "$env:APPDATA\$emu\keys\prod.keys" }
    foreach ($p in $c) { if (Test-Path -LiteralPath $p) { return $p } }
    return ''
}
function Queue-Icon($g, $dest) {
    $prodKeys = Find-Keys
    # 還沒下載打包工具也能讀（icon_read.py 只要 Python）
    if (-not $prodKeys -or -not ((Test-Path $iconRead) -or (Test-Path $nxExtract))) { return }
    if ($iconJob -and $iconJob.Dest -eq $dest) { return }
    foreach ($q in $iconQueue) { if ($q.Dest -eq $dest) { return } }
    $iconQueue.Enqueue(@{ Dir = $g.Dir; File = $g.BaseFile; Dest = $dest; Keys = $prodKeys })
    $iconTimer.Start()
}
$iconTimer = New-Object Windows.Threading.DispatcherTimer
$iconTimer.Interval = [TimeSpan]::FromMilliseconds(500)
function Start-Hidden($exe, $argLine, $dir = '') {
    $psi = New-Object Diagnostics.ProcessStartInfo $exe
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    if ($dir) { $psi.WorkingDirectory = $dir }
    $p = [Diagnostics.Process]::Start($psi)
    $p.BeginOutputReadLine(); $p.BeginErrorReadLine()   # 不讀會塞住
    return $p
}
function Start-IconExtract($j, $file) {
    $j.Out = Join-Path $j.Tmp 'icon'
    $j.Proc = Start-Hidden $nxExtract "`"$($j.Keys)`" `"$file`" - `"$($j.Out)`" --manifest"
    $j.Stage = 'icon'; $j.Start = Get-Date
}
function End-IconJob($j, $ok) {
    if (-not $j.Proc.HasExited) { try { $j.Proc.Kill() } catch { } }
    $got = Join-Path $j.Out 'icon.jpg'
    if ($ok -and (Test-Path $got)) {
        Copy-Item -LiteralPath $got -Destination $j.Dest -Force
        $card = $cards[$j.Dir]
        if ($card) { Paint-Icon $card.FindName('Icon') $card.FindName('Letter') $card.Tag (Load-Bitmap $j.Dest) }
    } else {
        # 讀不到（缺金鑰、檔案壞了）就記下當時的本體檔，本體沒換就不要每次開都重試
        Set-Content -LiteralPath ([IO.Path]::ChangeExtension($j.Dest, '.none')) -Value (Icon-Sig $j.File)
    }
    Start-Sleep -Milliseconds 200
    Remove-Item -LiteralPath $j.Tmp -Recurse -Force -ErrorAction SilentlyContinue
    $script:iconJob = $null
}
$iconTimer.Add_Tick({
    if ($script:iconJob) {
        $j = $script:iconJob
        if ($j.Stage -eq 'py') {
            if ($j.Proc.HasExited -or ((Get-Date) - $j.Start).TotalSeconds -gt 60) {
                if (-not $j.Proc.HasExited) { try { $j.Proc.Kill() } catch { } }
                $got = Join-Path $j.Out 'icon.jpg'
                if (Test-Path -LiteralPath $got) { End-IconJob $j $true }
                elseif (Test-Path $nxExtract) { try { Start-OldIcon $j } catch { End-IconJob $j $false } }
                else { End-IconJob $j $false }
            }
            return
        }
        if ($j.Stage -eq 'nsz') {
            # 只有 NSZ / XCZ：nx_extract 讀不了壓縮過的 NCA，先解到暫存資料夾（不動遊戲資料夾），再從解好的檔抓圖示
            if ($j.Proc.HasExited) {
                $made = @(Get-ChildItem -LiteralPath (Join-Path $j.Tmp 'out') -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(nsp|xci)$' }) | Select-Object -First 1
                Remove-Item -LiteralPath (Join-Path $j.Tmp 'keys.txt') -Force -ErrorAction SilentlyContinue
                if ($made) { try { Start-IconExtract $j $made.FullName } catch { End-IconJob $j $false } } else { End-IconJob $j $false }
            } elseif (((Get-Date) - $j.Start).TotalMinutes -gt 15) { End-IconJob $j $false }
            return
        }
        $got = Join-Path $j.Out 'icon.jpg'
        if ((Test-Path $got) -or $j.Proc.HasExited -or ((Get-Date) - $j.Start).TotalSeconds -gt 120) {
            Start-Sleep -Milliseconds 300   # 等它寫完
            End-IconJob $j $true
        }
        return
    }
    if ($iconQueue.Count -eq 0) { $iconTimer.Stop(); return }
    $q = $iconQueue.Dequeue()
    $tmp = Join-Path $env:TEMP ('switchpad-icon-' + [guid]::NewGuid().ToString('N'))
    $j = @{ Proc = $null; Tmp = $tmp; Out = $tmp; Dest = $q.Dest; Dir = $q.Dir; File = $q.File; Keys = $q.Keys; Stage = ''; Start = Get-Date }
    if (Test-Path $iconRead) {
        # 先直接從本體讀（不解包、NSZ 也不用先解壓）
        try {
            New-Item -ItemType Directory -Force -Path $tmp | Out-Null
            $j.Proc = Start-Hidden (Get-Python) "-I `"$iconRead`" `"$($q.Keys)`" `"$($q.File)`" `"$(Join-Path $tmp 'icon.jpg')`""
            $j.Stage = 'py'; $j.Out = $tmp
            $script:iconJob = $j; return
        } catch { }   # 找不到 Python 之類的：改用舊的讀法
    }
    if (Test-Path $nxExtract) {
        try { Start-OldIcon $j; $script:iconJob = $j; return } catch { }
    }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
})
# 舊的讀法（icon_read.py 讀不到時）：nx_extract 解出 icon.jpg；NSZ / XCZ 要先用 nsz 解壓
function Start-OldIcon($j) {
    $j.Start = Get-Date
    if ($j.File -match '\.(nsz|xcz)$') {
        # nsz 讀工作資料夾裡的 keys.txt（跟 nxn.ps1 解壓 NSZ 一樣），解完就刪
        New-Item -ItemType Directory -Force -Path $j.Tmp | Out-Null
        Copy-Item -LiteralPath $j.Keys -Destination (Join-Path $j.Tmp 'keys.txt')
        $j.Proc = Start-Hidden (Get-Python) "-c `"import sys; sys.argv[0] = 'nsz'; from nsz import main; main()`" -D -o `"$(Join-Path $j.Tmp 'out')`" `"$($j.File)`"" $j.Tmp
        $j.Stage = 'nsz'
    } else { Start-IconExtract $j $j.File }
}
$tileColors = '#FF453A', '#FF9F0A', '#30D158', '#0A84FF', '#BF5AF2', '#FF375F', '#64D2FF', '#FFD60A'
function Paint-Icon($border, $letterBlock, $g, $bmp) {
    if ($bmp) {
        $b = New-Object Windows.Media.ImageBrush $bmp
        $b.Stretch = 'UniformToFill'
        $border.Background = $b
        $letterBlock.Text = ''
    } else {
        $i = [math]::Abs($g.Name.GetHashCode()) % $tileColors.Count
        $border.Background = Brush $tileColors[$i]
        $letterBlock.Text = $g.Name.Substring(0, 1).ToUpper()
    }
}

# ---------------------------------------------------------------- 遊戲卡
$cardXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Margin="4" CornerRadius="16" Background="Transparent" BorderThickness="0" BorderBrush="Transparent"
        AllowDrop="True">
  <!-- 滑鼠移上去，圖示輕輕浮起來 -->
  <Border.Triggers>
    <EventTrigger RoutedEvent="MouseEnter"><BeginStoryboard><Storyboard>
          <DoubleAnimation Storyboard.TargetName="IconBox" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1.05" Duration="0:0:0.22"><DoubleAnimation.EasingFunction><BackEase EasingMode="EaseOut" Amplitude="0.4"/></DoubleAnimation.EasingFunction></DoubleAnimation>
          <DoubleAnimation Storyboard.TargetName="IconBox" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1.05" Duration="0:0:0.22"><DoubleAnimation.EasingFunction><BackEase EasingMode="EaseOut" Amplitude="0.4"/></DoubleAnimation.EasingFunction></DoubleAnimation>
    </Storyboard></BeginStoryboard></EventTrigger>
    <EventTrigger RoutedEvent="MouseLeave"><BeginStoryboard><Storyboard>
          <DoubleAnimation Storyboard.TargetName="IconBox" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1" Duration="0:0:0.18"><DoubleAnimation.EasingFunction><QuadraticEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction></DoubleAnimation>
          <DoubleAnimation Storyboard.TargetName="IconBox" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1" Duration="0:0:0.18"><DoubleAnimation.EasingFunction><QuadraticEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction></DoubleAnimation>
    </Storyboard></BeginStoryboard></EventTrigger>
  </Border.Triggers>
  <Grid>
    <!-- 左邊窄窄一欄小框框（狀態、版本、DLC、要注意…），右邊是圖示，名字和按鈕對齊圖示；整組置中，格子不用很寬 -->
    <Grid Margin="6,12,6,14" HorizontalAlignment="Center" VerticalAlignment="Top">
      <Grid.ColumnDefinitions><ColumnDefinition Width="58"/><ColumnDefinition Width="8"/><ColumnDefinition Width="140"/></Grid.ColumnDefinitions>
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
      <StackPanel x:Name="Badges" Grid.Row="0" Grid.Column="0" HorizontalAlignment="Right" VerticalAlignment="Center"/>
      <Border x:Name="IconBox" Grid.Row="0" Grid.Column="2" Width="108" Height="108" HorizontalAlignment="Center" RenderTransformOrigin="0.5,0.5">
        <Border.RenderTransform><ScaleTransform/></Border.RenderTransform>
        <Border.Effect><DropShadowEffect BlurRadius="14" ShadowDepth="4" Direction="270" Opacity="0.45" Color="Black"/></Border.Effect>
        <Border x:Name="Icon" CornerRadius="24" Background="#2C2C2E" BorderBrush="#14FFFFFF" BorderThickness="1">
          <TextBlock x:Name="Letter" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="46" FontWeight="SemiBold" Foreground="#F5F5F7"/>
        </Border>
      </Border>
      <StackPanel Grid.Row="1" Grid.Column="2">
        <TextBlock x:Name="Title" Margin="0,10,0,0" FontSize="13.5" FontWeight="SemiBold" Foreground="#F5F5F7" TextWrapping="Wrap"
                   TextAlignment="Center" MaxHeight="38" TextTrimming="CharacterEllipsis"/>
        <TextBlock x:Name="Detail" Margin="0,2,0,0" FontSize="12" Foreground="#8E8E93" TextAlignment="Center" TextTrimming="CharacterEllipsis"/>
        <TextBlock x:Name="State" Margin="0,5,0,0" FontSize="12" TextAlignment="Center" TextTrimming="CharacterEllipsis"/>
        <TextBlock x:Name="Support" Margin="0,4,0,0" FontSize="12" TextAlignment="Center" TextTrimming="CharacterEllipsis" Visibility="Collapsed"/>
        <Button x:Name="Act" HorizontalAlignment="Center" Margin="0,9,0,0" FontSize="12.5" Padding="20,5"/>
      </StackPanel>
    </Grid>
    <Border x:Name="Pending" CornerRadius="9" Padding="10,3" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="10,10,0,0" Visibility="Collapsed">
      <TextBlock x:Name="PendingText" Foreground="White" FontSize="12" FontWeight="SemiBold"/>
    </Border>
    <Border x:Name="Check" Width="26" Height="26" CornerRadius="13" Background="#0A84FF" HorizontalAlignment="Right"
            VerticalAlignment="Top" Margin="0,10,10,0" Visibility="Collapsed">
      <TextBlock Text="✓" Foreground="White" FontSize="17" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <!-- 拖曳排序：放開會插在這條線的位置 -->
    <Border x:Name="InsL" Width="4" CornerRadius="2" Background="#0A84FF" HorizontalAlignment="Left" Margin="-2,10,0,10" Visibility="Collapsed"/>
    <Border x:Name="InsR" Width="4" CornerRadius="2" Background="#0A84FF" HorizontalAlignment="Right" Margin="0,10,-2,10" Visibility="Collapsed"/>
    <Border x:Name="DropHint" CornerRadius="16" Background="#D90A84FF" Visibility="Collapsed">
      <TextBlock Text="放開就加進這款（遊戲檔或存檔）" Foreground="White" FontSize="16" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
  </Grid>
</Border>
'@
$cards = @{}          # 資料夾路徑 → 卡片
$selected = New-Object System.Collections.Generic.List[string]   # 遊戲庫裡的遊戲，照使用者排的順序（同步後 iPad 也照這個順序）
$picked = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)   # 點一下選起來的遊戲：「轉檔」只轉這些

# 卡片：在遊戲庫的按「移除」、不在的按「＋ 加入」，左上角標還要做的那一步（待轉換、待裝到 iPad、裝到 iPad 時拿掉）
function Card-Paint($card) {
    $g = $card.Tag; $in = $selected.Contains($g.Dir)
    $act = $card.FindName('Act'); $pend = $card.FindName('Pending'); $pt = $card.FindName('PendingText')
    $act.Style = $win.FindResource('Pill')
    $pend.Visibility = 'Collapsed'; $card.BorderBrush = [Windows.Media.Brushes]::Transparent   # 狀態只看卡片上那一行「●」
    if ($in) { $act.Content = '移除' } else { $act.Content = '加入'; $act.Style = $win.FindResource('Get') }
    $pk = $picked.Contains($g.Dir)
    $card.FindName('Check').Visibility = if ($pk) { 'Visible' } else { 'Collapsed' }
    $card.Background = if ($pk) { Brush '#2A0A84FF' } else { [Windows.Media.Brushes]::Transparent }
    $act.IsEnabled = [bool]($in -or $g.Base -or $g.Ready)
    $act.ToolTip = if (-not $in -and -not $g.Base -and -not $g.Ready) { '資料夾裡沒有遊戲本體（NSP / XCI / NSZ）' } else { $null }
}
# ---------------------------------------------------------------- 點一下＝選起來（給「轉檔」用），按住拖＝排順序、加入或拿掉
# 拖超過系統的拖曳距離才算拖；沒拖就放開才算點。按在卡片上的按鈕（加入／移除）兩樣都不算。
# 拖一張已經選起來的卡，會把選起來的幾款一起搬（多選和拖曳不衝突）。
$dragFmt = 'PadSwitchGames'
$drag = @{ Card = $null; Start = $null; Moved = $false; OnBtn = $false }
function Find-Up($el, [type]$t) {
    while ($el) {
        if ($el -is $t) { return $el }
        $el = if ($el -is [Windows.Media.Visual] -or $el -is [Windows.Media.Media3D.Visual3D]) { [Windows.Media.VisualTreeHelper]::GetParent($el) } else { $el.Parent }
    }
    return $null
}
function Toggle-Pick($dir) {
    if (-not $picked.Remove($dir)) { [void]$picked.Add($dir) }
    if ($cards[$dir]) { Card-Paint $cards[$dir] }
    Update-SelCount
}
# 選起來的照畫面上的順序（遊戲庫在前，照排好的順序；再來是還沒加入的）
function Picked-Dirs {
    @(@($ui.Library.Children) + @($ui.Others.Children) | Where-Object { $_.Tag -and $_.Tag.PSObject.Properties['Dir'] -and $picked.Contains($_.Tag.Dir) } | ForEach-Object { $_.Tag.Dir })
}
function Wire-CardDrag($card) {
    $card.Add_PreviewMouseLeftButtonDown({ param($s, $e)
        $drag.Card = $s; $drag.Start = $e.GetPosition($win); $drag.Moved = $false
        $drag.OnBtn = [bool](Find-Up $e.OriginalSource ([Windows.Controls.Primitives.ButtonBase])) })
    $card.Add_PreviewMouseMove({ param($s, $e)
        if ($e.LeftButton -ne 'Pressed' -or $drag.Card -ne $s -or $drag.OnBtn -or $drag.Moved) { return }
        $p = $e.GetPosition($win)
        if ([math]::Abs($p.X - $drag.Start.X) -lt [Windows.SystemParameters]::MinimumHorizontalDragDistance -and
            [math]::Abs($p.Y - $drag.Start.Y) -lt [Windows.SystemParameters]::MinimumVerticalDragDistance) { return }
        $drag.Moved = $true
        $dirs = if ($picked.Contains($s.Tag.Dir) -and $picked.Count -gt 1) { @(Picked-Dirs) } else { @($s.Tag.Dir) }
        $data = New-Object Windows.DataObject
        $data.SetData($dragFmt, ($dirs -join "`n"))
        $s.Opacity = 0.45
        $script:dragChanged = $false
        try { [void][Windows.DragDrop]::DoDragDrop($s, $data, [Windows.DragDropEffects]::Move) } catch { }
        $s.Opacity = 1; $drag.Card = $null
        # 放開時（Drop-Games）只改清單，卡片等拖曳整個結束才重畫：拖曳中把來源卡片拿掉，WPF 會出錯
        if ($script:dragChanged) { Save-Want; Build-Library }
    })
    $card.Add_MouseLeftButtonUp({ param($s, $e)
        if ($drag.Card -eq $s -and -not $drag.Moved -and -not $drag.OnBtn) { Toggle-Pick $s.Tag.Dir }
        $drag.Card = $null })
    $card.Add_DragOver({ param($s, $e)
        if (-not $e.Data.GetDataPresent($dragFmt)) { return }
        $e.Effects = [Windows.DragDropEffects]::Move; $e.Handled = $true
        $after = $e.GetPosition($s).X -gt ($s.ActualWidth / 2)
        $show = [bool]$s.Tag.InLib
        $s.FindName('InsL').Visibility = if ($show -and -not $after) { 'Visible' } else { 'Collapsed' }
        $s.FindName('InsR').Visibility = if ($show -and $after) { 'Visible' } else { 'Collapsed' } })
    $card.Add_DragLeave({ param($s, $e) $s.FindName('InsL').Visibility = 'Collapsed'; $s.FindName('InsR').Visibility = 'Collapsed' })
}
# 放開：放在遊戲庫的某款上 → 插在它前面或後面；放在遊戲庫空白處 → 排最後；放在「還沒加入」→ 從遊戲庫拿掉
function Drop-Games($e, $targetCard) {
    $e.Handled = $true
    $dirs = @(([string]$e.Data.GetData($dragFmt)) -split "`n" | Where-Object { $_ -and $cards.ContainsKey($_) })
    if (-not $dirs.Count) { return }
    if ($targetCard) { $targetCard.FindName('InsL').Visibility = 'Collapsed'; $targetCard.FindName('InsR').Visibility = 'Collapsed' }
    $toLib = if ($targetCard) { [bool]$targetCard.Tag.InLib } else { $e.Source -eq $ui.Library -or (Find-Up $e.OriginalSource ([Windows.Controls.Primitives.UniformGrid])) -eq $ui.Library }
    if (-not $toLib) {
        foreach ($d in $dirs) {
            if ($selected.Remove($d) -and $state.Running) { foreach ($q in @($state.Queue | Where-Object { $_.Game.Dir -eq $d -and -not $_.PSObject.Properties['Lib'] })) { Drop-Queued $q } }
        }
        $script:dragChanged = $true; return
    }
    $tgt = if ($targetCard) { $targetCard.Tag.Dir } else { '' }
    if ($tgt -and $dirs -contains $tgt) { return }   # 放回自己身上：不動
    $rest = New-Object System.Collections.Generic.List[string]
    foreach ($d in $selected) { if ($dirs -notcontains $d) { $rest.Add($d) } }
    $at = $rest.Count
    if ($tgt) { $i = $rest.IndexOf($tgt); if ($i -ge 0) { $at = $i + $(if ($e.GetPosition($targetCard).X -gt ($targetCard.ActualWidth / 2)) { 1 } else { 0 }) } }
    $rest.InsertRange($at, [string[]]$dirs)
    $selected.Clear(); foreach ($d in $rest) { $selected.Add($d) }
    $script:dragChanged = $true
}
$script:dragChanged = $false
foreach ($pn in $ui.Library, $ui.Others) {
    $pn.Add_DragOver({ param($s, $e) if ($e.Data.GetDataPresent($dragFmt)) { $e.Effects = [Windows.DragDropEffects]::Move; $e.Handled = $true } })
    $pn.Add_Drop({ param($s, $e) if ($e.Data.GetDataPresent($dragFmt)) { $toLib = $s -eq $ui.Library
        $dirs = @(([string]$e.Data.GetData($dragFmt)) -split "`n" | Where-Object { $_ -and $cards.ContainsKey($_) })
        $e.Handled = $true
        if ($toLib) { foreach ($d in $dirs) { if (-not $selected.Contains($d)) { $selected.Add($d) } else { [void]$selected.Remove($d); $selected.Add($d) } } }
        else { foreach ($d in $dirs) { if ($selected.Remove($d) -and $state.Running) { foreach ($q in @($state.Queue | Where-Object { $_.Game.Dir -eq $d -and -not $_.PSObject.Properties['Lib'] })) { Drop-Queued $q } } } }
        $script:dragChanged = $true } })
}
# Esc：取消全部選取
$win.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape' -and $picked.Count) { $picked.Clear(); foreach ($c in $cards.Values) { Card-Paint $c }; Update-SelCount } })

# ---------------------------------------------------------------- 大小：每款在 iPad 上佔多少（遊戲包 + 留在 NSP 裡的 RomFS），電腦上佔多少
# 遊戲包的大小要開 zip 讀（romfs_data.py sizes），在背景算好存 work\status\sizes.json（遊戲包路徑|修改時間 → bytes），不卡畫面
$sizesFile = Join-Path $work 'status\sizes.json'
$sizes = @{}
try { ([IO.File]::ReadAllText($sizesFile) | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $sizes[$_.Name] = [int64]$_.Value } } catch { }
$sizeJob = @{ Proc = $null; Out = (Join-Path $work 'status\sizes-new.json'); Keys = @{} }
function Fmt-Size($b) { $b = [double]$b; if ($b -ge 1GB) { '{0:N1} GB' -f ($b / 1GB) } elseif ($b -ge 1MB) { '{0:N0} MB' -f ($b / 1MB) } else { '{0:N0} KB' -f ($b / 1KB) } }
function Size-Key($f) { "$($f.FullName)|$($f.LastWriteTimeUtc.Ticks)" }
# 一款在 iPad 上的大小：轉好的遊戲包算得出來就用它，不然用遊戲檔（本體＋更新＋DLC）的大小估
$partMissing = New-Object System.Collections.Generic.List[string]
$sizeTried = New-Object 'System.Collections.Generic.HashSet[string]'   # 這次開著時算過（算不出來的也不再算）
function Game-Bytes($g) {
    if ($g.PackageKey -and $sizes.ContainsKey($g.PackageKey)) { return $sizes[$g.PackageKey] }
    $g.SourceBytes
}
function Start-Sizes {
    if ($sizeJob.Proc) { return }
    if (-not $partMissing.Count) { return }
    $py = Get-Python; $tool = Join-Path $here 'romfs_data.py'
    if (-not (Test-Path $tool) -or -not (Select-String -LiteralPath $tool -SimpleMatch -Quiet -Pattern "add_parser('sizes')")) { return }
    $list = @($partMissing | Select-Object -First 60)
    foreach ($p in $list) { [void]$partMissing.Remove($p) }
    $sizeJob.Keys = @{}
    foreach ($p in $list) {
        $f = Get-Item -LiteralPath $p -ErrorAction SilentlyContinue
        if ($f) { $sizeJob.Keys[$p] = Size-Key $f; [void]$sizeTried.Add($sizeJob.Keys[$p]) }
    }
    if (-not $sizeJob.Keys.Count) { return }
    $request = $sizeJob.Out + '.request'
    try {
        [IO.File]::WriteAllText($request, (ConvertTo-Json -InputObject @($sizeJob.Keys.Keys) -Compress), (New-Object Text.UTF8Encoding $false))
        $q = [char]34
        $argsLine = '-I ' + $q + $tool + $q + ' sizes --request ' + $q + $request + $q + ' --output ' + $q + $sizeJob.Out + $q
        $sizeJob.Proc = Start-Hidden $py $argsLine $here
    } catch { }
}
function End-Sizes {
    if (-not $sizeJob.Proc -or -not $sizeJob.Proc.HasExited) { return $false }
    $exitCode = $sizeJob.Proc.ExitCode
    $sizeJob.Proc.Dispose()
    $sizeJob.Proc = $null
    try {
        if ($exitCode -ne 0) { throw 'size scan failed' }
        $j = [IO.File]::ReadAllText($sizeJob.Out) | ConvertFrom-Json
        foreach ($pr in $j.PSObject.Properties) { if ([int64]$pr.Value -gt 0 -and $sizeJob.Keys[$pr.Name]) { $sizes[$sizeJob.Keys[$pr.Name]] = [int64]$pr.Value } }
        # 只留現在還在的遊戲包
        $keep = [ordered]@{}; foreach ($k in $sizes.Keys) { if (Test-Path -LiteralPath ($k -split '\|')[0]) { $keep[$k] = $sizes[$k] } }
        [IO.File]::WriteAllText($sizesFile, ($keep | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding $false))
    } catch { }
    Remove-Item -LiteralPath $sizeJob.Out, ($sizeJob.Out + '.request') -ErrorAction SilentlyContinue
    return $true
}

# ---------------------------------------------------------------- 空間圖：電腦硬碟（遊戲、其他、剩下）、iPad（其他 App、遊戲庫、這次同步要加的和要拿掉的、剩下）
# iPad 的空間每次同步時記下（romfs_data.py 寫 work\status\ipad-space.json），按 ⟳ 或打開 PadSwitch 時 iPad 接著也會在背景讀一次
$spaceFile = Join-Path $work 'status\ipad-space.json'
$spaceJob = @{ Proc = $null; Started = [datetime]::MinValue; Failed = $false; SyncPending = $false }
function Set-Bar($grid, $segs) {
    $grid.ColumnDefinitions.Clear(); $grid.Children.Clear()
    $segs = @($segs | Where-Object { $_.Bytes -gt 0 })
    $i = 0
    foreach ($sg in $segs) {
        $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = New-Object Windows.GridLength ([double]$sg.Bytes), 'Star'
        $grid.ColumnDefinitions.Add($cd)
        if ($sg.Color) {
            $b = New-Object Windows.Controls.Border; $b.Background = Brush $sg.Color; $b.ToolTip = $sg.Tip
            $l = if ($i -eq 0) { 4 } else { 0 }; $r = if ($i -eq $segs.Count - 1) { 4 } else { 0 }
            $b.CornerRadius = New-Object Windows.CornerRadius $l, $r, $r, $l
            if ($i) { $b.Margin = '1,0,0,0' }
            [Windows.Controls.Grid]::SetColumn($b, $i); [void]$grid.Children.Add($b)
        }
        $i++
    }
}
function Legend($panel, $items) {
    $panel.Children.Clear()
    foreach ($it in $items) {
        $sp = New-Object Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'; $sp.Margin = '0,0,14,2'
        $d = New-Object Windows.Controls.Border; $d.Width = 8; $d.Height = 8; $d.CornerRadius = '2'; $d.Background = Brush $it.Color; $d.Margin = '0,0,6,0'; $d.VerticalAlignment = 'Center'
        $t = New-Object Windows.Controls.TextBlock; $t.Text = $it.Text; $t.FontSize = 12; $t.Foreground = Brush $(if ($it.Fg) { $it.Fg } else { '#AEAEB2' })
        [void]$sp.Children.Add($d); [void]$sp.Children.Add($t)
        if ($it.Tip) { $sp.ToolTip = $it.Tip }
        [void]$panel.Children.Add($sp)
    }
}
$spaceCache = @{ T = -1L; V = $null }
function Read-IpadSpace {
    try {
        $t = if (Test-Path -LiteralPath $spaceFile) { [IO.File]::GetLastWriteTimeUtc($spaceFile).Ticks } else { 0L }
        if ($t -ne $spaceCache.T) { $spaceCache.V = if ($t) { [IO.File]::ReadAllText($spaceFile) | ConvertFrom-Json } else { $null }; $spaceCache.T = $t }
        $spaceCache.V
    } catch { $null }
}
function Start-SpaceProbe([switch]$Force) {
    if ($state.Running) { return }
    if ($spaceJob.Proc -and -not $spaceJob.Proc.HasExited) { return }
    if (-not $Force -and ((Get-Date) - $spaceJob.Started).TotalMinutes -lt 10) { return }
    $lib = Library-Ipa; $tool = Join-Path $here 'romfs_data.py'
    if (-not (Test-Path -LiteralPath $lib) -or -not (Test-Path $tool) -or -not (Select-String -LiteralPath $tool -SimpleMatch -Quiet -Pattern "add_parser('space')")) { return }
    $tpf = Join-Path $work 'python-transfer.txt'
    $tpy = if (Test-Path $tpf) { (Get-Content $tpf -Raw).Trim() } else { '' }
    if (-not $tpy -or -not (Test-Path -LiteralPath $tpy)) { return }
    $spaceJob.Started = Get-Date
    $spaceJob.Failed = $false
    $psi = New-Object Diagnostics.ProcessStartInfo $tpy
    $psi.Arguments = "-I `"$tool`" space `"$lib`"" + $(if ($cfg.Udid) { " --udid `"$($cfg.Udid)`"" } else { '' })
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['NXN_STATUS_DIR'] = $statusDir; $psi.EnvironmentVariables['PYTHONUTF8'] = '1'
    try {
        $spaceJob.Proc = [Diagnostics.Process]::Start($psi)
        $spaceJob.Proc.BeginOutputReadLine(); $spaceJob.Proc.BeginErrorReadLine()
        $ui.IpadR.Text = '讀取中…'
    } catch { $spaceJob.Failed = $true }
}
# 顯示已量到的空間與新增遊戲估算。同步時才檢查實際檔案差額。
function Fit-Info {
    $sp = Read-IpadSpace
    $have = @{}; $recorded = @{}; $wanted = @{}
    foreach ($pr in $sp.have.PSObject.Properties) {
        if ($pr.Name -match '^games/([0-9a-f]{16})/') {
            $tid = $Matches[1].ToUpper()
            $have[$tid] = 1 + [int]$have[$tid]
        }
    }
    $knownBytes = 0L
    foreach ($pr in $sp.data.PSObject.Properties) {
        if ($pr.Name -match '^games/([0-9a-f]{16})/') {
            $tid = $Matches[1].ToUpper(); $b = [long]$pr.Value
            $recorded[$tid] = [long]$recorded[$tid] + $b
            $knownBytes += $b
        }
    }
    $knownInventory = $sp -and ($sp.PSObject.Properties['have'] -or $sp.installed -eq $false)
    $sel = 0L; $send = 0L; $pending = 0; $unknownTid = $false
    foreach ($dir in $selected) {
        if (-not $cards.ContainsKey($dir)) { $unknownTid = $true; continue }
        $g = $cards[$dir].Tag
        $b = [long](Game-Bytes $g)
        $sel += $b
        $tid = Game-Tid $g
        if (-not $tid) { $unknownTid = $true; $pending++; continue }
        $wanted[$tid] = $true
        if (-not $knownInventory -or -not $g.Ready -or $g.Newer -or ($have.ContainsKey($tid) -and $have[$tid] -lt 2)) {
            $pending++
        } elseif (-not $have.ContainsKey($tid)) {
            if ($g.PackageKey -and $sizes.ContainsKey($g.PackageKey)) { $send += $b } else { $pending++ }
        }
    }
    $freed = 0L
    if (-not $unknownTid) {
        foreach ($tid in $recorded.Keys) {
            if ($have.ContainsKey($tid) -and -not $wanted.ContainsKey($tid)) { $freed += $recorded[$tid] }
        }
    }
    @{
        Sel = $sel; Send = $send; Pending = $pending; Freed = $freed; Data = $knownBytes; Snapshot = $sp
        Known = [bool]($sp -and [long]$sp.total -gt 0); Free = [long]$sp.free; Total = [long]$sp.total
    }
}
function Update-Space($fi = $null) {
    # 遊戲大小用掃描遊戲庫時取得的快照。
    try {
        $drv = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($base))
        $games = $script:pcGameBytes
        $used = $drv.TotalSize - $drv.AvailableFreeSpace
        $ui.PcL.Text = "電腦（$($drv.Name.TrimEnd('\'))）"
        $ui.PcR.Text = "剩 $(Fmt-Size $drv.AvailableFreeSpace) / 共 $(Fmt-Size $drv.TotalSize)"
        $ui.PcR.Foreground = Brush $(if ($drv.AvailableFreeSpace -lt 30GB) { '#FF453A' } else { '#8E8E93' })
        Set-Bar $ui.PcBar @(@{ Bytes = $games; Color = '#0A84FF'; Tip = "遊戲 $(Fmt-Size $games)（遊戲檔和轉好的遊戲包）" },
                            @{ Bytes = [math]::Max([int64]0, $used - $games); Color = '#636366'; Tip = "其他 $(Fmt-Size ($used - $games))" },
                            @{ Bytes = $drv.AvailableFreeSpace; Color = $null })
        Legend $ui.PcLegend @(@{ Color = '#0A84FF'; Text = "遊戲 $(Fmt-Size $games)" }, @{ Color = '#636366'; Text = "其他 $(Fmt-Size ([math]::Max([int64]0, $used - $games)))" },
                              @{ Color = '#3A3A3C'; Text = "可用 $(Fmt-Size $drv.AvailableFreeSpace)" })
    } catch { }
    # iPad
    if (-not $fi) { $fi = Fit-Info }
    $sp = $fi.Snapshot
    $leg = @()
    if ($fi.Known) {
        $total = $fi.Total; $free = $fi.Free
        $lib = [math]::Min([long]$fi.Data, [math]::Max(0L, $total - $free))
        $other = [math]::Max(0L, $total - $free - $lib)
        $ui.IpadL.Text = if ($sp.device) { "iPad（$($sp.device)）" } else { 'iPad' }
        if (-not ($spaceJob.Proc -and -not $spaceJob.Proc.HasExited)) {
            $ui.IpadR.Text = "剩 $(Fmt-Size $free) / 共 $(Fmt-Size $total)"
            $at = To-Date $sp.at
            if ($at) { $ui.IpadR.Text += (' · ' + $at.ToString('HH:mm')) }
            if ($spaceJob.Failed) { $ui.IpadR.Text += '（上次讀取）' }
        }
        Set-Bar $ui.IpadBar @(@{ Bytes = $other; Color = '#636366'; Tip = '系統、其他 App 與未量到的遊戲資料' },
                              @{ Bytes = $lib; Color = '#0A84FF'; Tip = 'iPad 已有檔案清單的遊戲資料' },
                              @{ Bytes = $free; Color = $null })
        if ($lib) { $leg += @{ Color = '#0A84FF'; Text = "已量到的遊戲資料 $(Fmt-Size $lib)" } }
        $leg += @{ Color = '#636366'; Text = "其他及未量到 $(Fmt-Size $other)" }
    } else {
        $ui.IpadL.Text = 'iPad'
        if (-not ($spaceJob.Proc -and -not $spaceJob.Proc.HasExited)) { $ui.IpadR.Text = '還沒讀到，接上 iPad 按 ⟳' }
        Set-Bar $ui.IpadBar @()
    }
    if ($fi.Send) { $leg += @{ Color = '#30D158'; Text = "新增遊戲約 $(Fmt-Size $fi.Send)"; Tip = '用已轉檔的遊戲包估算。同步會檢查實際差額。' } }
    if ($fi.Freed) { $leg += @{ Color = '#FF9F0A'; Text = "移除已知可回收 $(Fmt-Size $fi.Freed)" } }
    if ($fi.Pending) { $leg += @{ Color = '#AEAEB2'; Text = "$($fi.Pending) 款待核對"; Tip = '尚未轉檔、更新或 iPad 資料待確認。' } }
    Legend $ui.IpadLegend $leg
}
$ui.IpadRefresh.Add_Click({ Start-SpaceProbe -Force; Update-Space })

# 狀態那行「● 在 iPad 上」：只有點是彩色的，字用灰色（失敗的紅字照舊，要看得到）
function Dot-State($st) {
    $t = "$($st.Text)"
    if (-not $t.StartsWith('● ') -or "$($st.Foreground)" -eq '#FFFF453A') { return }
    $c = $st.Foreground
    $st.Inlines.Clear()
    $d = New-Object Windows.Documents.Run '●  '; $d.Foreground = $c; $d.FontSize = 9; $d.BaselineAlignment = 'Center'
    $r = New-Object Windows.Documents.Run $t.Substring(2); $r.Foreground = Brush '#AEAEB2'
    $st.Inlines.Add($d); $st.Inlines.Add($r)
}
# 遊戲格子左上角的小標籤（圓角小框，淡色底配同色字）
function Add-Badge($card, $text, $bg, $fg, $tip, $dot = $null, $at = -1) {
    $b = New-Object Windows.Controls.Border
    $b.CornerRadius = '5'; $b.Padding = '7,2'; $b.Margin = '0,0,0,4'; $b.Background = Brush $bg; $b.HorizontalAlignment = 'Right'
    $t = New-Object Windows.Controls.TextBlock
    $t.FontSize = 11; $t.FontWeight = 'SemiBold'; $t.Foreground = Brush $fg; $t.TextTrimming = 'CharacterEllipsis'
    if ($dot) { $d = New-Object Windows.Documents.Run '● '; $d.Foreground = $dot; $d.FontSize = 8; $d.BaselineAlignment = 'Center'; $t.Inlines.Add($d) }
    $t.Inlines.Add((New-Object Windows.Documents.Run $text))
    $b.Child = $t
    $b.ToolTip = if ($tip) { $tip } else { $text }   # 框框太窄被截掉時也看得到全文
    $p = $card.FindName('Badges')
    if ($at -ge 0 -and $at -le $p.Children.Count) { [void]$p.Children.Insert($at, $b) } else { [void]$p.Children.Add($b) }
}
function Update-GameSizeBadge($card) {
    $panel = $card.FindName('Badges')
    $badge = $null
    $at = -1
    foreach ($child in $panel.Children) { if ($child.Tag.Kind -eq 'game-size') { $badge = $child; $at = $panel.Children.IndexOf($child); break } }
    $g = $card.Tag
    $bytes = Game-Bytes $g
    if ($bytes -le 0) { if ($badge) { $panel.Children.Remove($badge) }; return }
    $packed = [bool]($g.PackageKey -and $sizes.ContainsKey($g.PackageKey))
    $tip = if ($packed) { '轉檔後的估計大小，含遊戲資料與程式' } else { '原始遊戲檔大小，轉檔後可能不同' }
    $label = Fmt-Size $bytes
    if ($badge -and $badge.Tag.Bytes -eq $bytes -and $badge.Tag.Packed -eq $packed) { return }
    if ($badge) { $panel.Children.Remove($badge) }
    Add-Badge $card $label '#1C1C1E' '#8E8E93' $tip $null $at
    $index = if ($at -lt 0) { $panel.Children.Count - 1 } else { $at }
    $panel.Children[$index].Tag = @{ Kind = 'game-size'; Bytes = $bytes; Packed = $packed }
}
# 狀態那行（State）和版本（Detail）改成左邊的小框框：狀態第一個（帶彩色小點），版本、DLC 接著；原本的兩行不顯示
function State-Badges($card, $parts) {
    $st = $card.FindName('State'); $t = "$($st.Text)"
    $at = 0
    if ($t -and $t -ne '● 在 iPad 上') {   # 在 iPad 上是正常狀態，不用標
        $red = "$($st.Foreground)" -eq '#FFFF453A'
        $txt = if ($t.StartsWith('● ')) { $t.Substring(2) } else { $t }
        Add-Badge $card $txt $(if ($red) { '#33FF453A' } else { '#232326' }) $(if ($red) { '#FF6961' } else { '#D1D1D6' }) $st.ToolTip $(if ($red) { $null } else { $st.Foreground }) $at
        $at++
    }
    foreach ($x in @($parts)) { if ($x) { Add-Badge $card $x '#232326' '#AEAEB2' $null $null $at; $at++ } }
    $card.FindName('State').Visibility = 'Collapsed'; $card.FindName('Detail').Visibility = 'Collapsed'
}
# 標題：名字白色粗體，數量灰色
function Head-Count($tb, $name, $n) {
    $tb.Inlines.Clear()
    $tb.Inlines.Add((New-Object Windows.Documents.Run $name))
    $c = New-Object Windows.Documents.Run "  $n"; $c.Foreground = Brush '#8E8E93'; $c.FontWeight = 'Medium'
    $tb.Inlines.Add($c)
}
# 遊戲庫清單（電腦上的）存在設定裡；第一次用的時候從 iPad 上那份遊戲庫讀
function Save-Want { $cfg.Want = @($selected); $cfg.WantSet = $true; Save-Settings }
$addTo = $null      # 合包卡片選「加入遊戲」時：要加進去的那包，勾好按開始就合進它
# 底下那行：遊戲庫幾款、還有幾款要轉換、裝到 iPad 會加入和拿掉哪些
function Update-SelCount {
    if (-not $ui.Merge.IsEnabled) {
        $ui.SelCount.Text = '還沒有多遊戲殼，遊戲庫還不能用'; $ui.SelCount.ToolTip = $ui.Merge.ToolTip; $ui.SelSub.Visibility = 'Collapsed'; $ui.Start.IsEnabled = $false; $ui.Sync.IsEnabled = $false; return
    }
    $mine = @($cards.Values | Where-Object { $selected.Contains($_.Tag.Dir) } | ForEach-Object { $_.Tag })
    $conv = @($mine | Where-Object { -not $_.Ready -and $_.Base })
    $add = @($mine | Where-Object { -not $_.OnPad -and ($_.Ready -or $_.Base) } | ForEach-Object { $_.Name })
    $del = @($cards.Values | Where-Object { $_.Tag.OnPad -and -not $selected.Contains($_.Tag.Dir) } | ForEach-Object { $_.Tag.Name })
    $upd = @($mine | Where-Object { $_.OnPad -and ($_.Newer -or (-not $_.Ready -and $_.Base)) } | ForEach-Object { $_.Name })
    $saves = @($mine | Where-Object { $_.HasPendingSave } | ForEach-Object { $_.Name })
    $names = { param($l) (@($l | Select-Object -First 3) -join '、') + $(if ($l.Count -gt 3) { " 等 $($l.Count) 款" } else { '' }) }
    $sign = Sign-Left
    $fi = Fit-Info
    $t = @("遊戲庫 $($mine.Count) 款，估計總大小 $(Fmt-Size $fi.Sel)" + $(if ($fi.Send) { "，新增遊戲約 $(Fmt-Size $fi.Send)" } else { '' }))
    if ($conv.Count) { $t += "$($conv.Count) 款還沒轉檔" }
    if ($sign) { $t += $sign.Text }
    # 同步會做的事（照順序）
    $do = @()
    if ($del.Count) { $do += "先拿掉 $(& $names $del)" }
    if ($conv.Count) { $do += "轉檔 $($conv.Count) 款" }
    if ($add.Count) { $do += "加入 $(& $names $add)" }
    if ($upd.Count) { $do += "更新 $(& $names $upd)" }
    if ($saves.Count) { $do += "傳 $($saves.Count) 份存檔" }
    $do += '存檔雙向同步'
    if ($sign -and $sign.Need) { $do += '重簽' }
    $sub = '同步會：' + ($do -join ' → ')
    if ($picked.Count) {
        $pd = @(Picked-Dirs | ForEach-Object { $cards[$_].Tag })
        $pb = [int64](@($pd | ForEach-Object { Game-Bytes $_ }) | Measure-Object -Sum).Sum
        $t = @("已選 $($picked.Count) 款（$(Fmt-Size $pb)）：$(& $names @($pd | ForEach-Object { $_.Name }))")
        $sub = '按「轉檔」只在電腦上轉好這幾款（不用接 iPad）；拖曳可以一起搬。按 Esc 取消選取'
    }
    $ui.SelCount.Text = $t -join ' · '; $ui.SelCount.ToolTip = $null
    $ui.SelCount.Foreground = Brush '#F5F5F7'
    $ui.SelSub.Text = $sub; $ui.SelSub.ToolTip = $sub; $ui.SelSub.Visibility = 'Visible'
    # 轉檔：選了就轉選的（轉好過的也重轉），沒選就轉遊戲庫裡還沒轉的
    $pickConv = @(Picked-Dirs | Where-Object { $cards[$_].Tag.Base })
    $ui.Start.Content = if ($picked.Count) { "轉檔（$($pickConv.Count) 款）" } elseif ($conv.Count) { "轉檔（$($conv.Count) 款）" } else { '轉檔' }
    $ui.Start.IsEnabled = [bool]$(if ($picked.Count) { $pickConv.Count } else { $conv.Count })
    $ui.Sync.IsEnabled = [bool]($mine.Count -or (Test-Path -LiteralPath (Library-Ipa)))
    $ui.Sync.Content = '同步'
    if (-not @($mine | Where-Object { $_.Ready -or $_.OnPad -or $_.Base }).Count -and $del.Count) { $ui.SelSub.Text = '遊戲庫至少要留一款，才能同步' ; $ui.Sync.IsEnabled = $false }
    if ($state.Running) {
        $busy = @(Busy-Dirs)
        $more = @($(if ($picked.Count) { $pickConv } else { $conv | ForEach-Object { $_.Dir } }) | Where-Object { $busy -notcontains $_ })
        $ui.Start.Content = if ($more.Count) { "轉檔（排入 $($more.Count) 款）" } else { '轉檔' }
        $ui.Start.IsEnabled = [bool]$more.Count
        $syncQueued = [bool]@($state.Queue | Where-Object { $_.Mode -eq 'sync' }).Count -or ($state.Job -and $state.Job.Mode -eq 'sync')
        $ui.Sync.IsEnabled = -not $syncQueued
        $ui.Sync.Content = if ($syncQueued) { '同步已排好' } else { '同步（轉完接著做）' }
        if (-not $picked.Count) {
            $ui.SelSub.Text = "還有 $(@($busy | Where-Object { $_ -ne (Split-Path (Library-Ipa) -Parent) }).Count) 款在轉檔或排隊" + $(if ($syncQueued) { '，跑完會接著同步（iPad 要接著）' } else { '' })
        }
        $ui.ShowProg.Content = "查看進度（$($busy.Count)）"
    }
    try { Update-Space $fi } catch { }
}
# 重簽：遊戲庫上次簽是什麼時候、還剩幾天（免費 Apple ID 7 天）。同步時一天內簽過、App 沒換就不重簽
function Sign-Left {
    $lib = Library-Ipa
    if (-not (Test-Path -LiteralPath $lib)) { return $null }
    $mine = @(Get-Installed) | Where-Object { $_.Ipa -eq $lib } | Select-Object -First 1
    if (-not $mine) { return @{ Text = '還沒裝到 iPad'; Need = $true; Days = $null } }
    $left = 7 - ((Get-Date) - $mine.Time).TotalDays
    $changed = (Get-Item -LiteralPath $lib).LastWriteTime -gt $mine.Time.AddMinutes(1)
    $need = $changed -or ((Get-Date) - $mine.Time).TotalHours -ge 24
    $txt = if ($left -le 0) { '簽章已過期' } elseif ($left -lt 1) { "簽章剩 $([int]($left * 24)) 小時" } else { "簽章剩 $([math]::Floor($left)) 天" }
    @{ Text = $txt; Need = $need; Days = $left }
}

# ---------------------------------------------------------------- 右鍵選單
function Open-Folder($p) { New-Item -ItemType Directory -Force -Path $p | Out-Null; Start-Process explorer.exe "`"$p`"" }
# 選單文字「圖示  文字」：圖示放固定寬度的欄，文字才會對齊
function Menu-Header($text) {
    $icon, $label = $text -split '  ', 2
    $sp = New-Object Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
    $i = New-Object Windows.Controls.TextBlock; $i.Text = $icon.Trim(); $i.Width = 28; $i.TextAlignment = 'Center'
    $i.FontFamily = 'Segoe UI Emoji'; $i.Margin = '0,0,8,0'
    $t = New-Object Windows.Controls.TextBlock; $t.Text = $label
    [void]$sp.Children.Add($i); [void]$sp.Children.Add($t)
    $sp
}
# ContextMenu 裡的分隔線會用系統的選單樣式（左邊縮排），要自己指定
function New-Sep { $sp = New-Object Windows.Controls.Separator; $sp.Style = $win.FindResource([Windows.Controls.Separator]); $sp }
function Menu-Item($cm, $text, $tag, $action, $enabled = $true) {
    $mi = New-Object Windows.Controls.MenuItem
    $mi.Header = Menu-Header $text; $mi.Tag = @{ Dir = $tag; Action = $action }; $mi.IsEnabled = $enabled
    $mi.Add_Click({ param($s, $e) Card-Action $s.Tag.Action $s.Tag.Dir })
    [void]$cm.Items.Add($mi)
}
# 選單在按右鍵時才填（每張卡都先查記錄、殼、遊戲包會拖慢重畫）
function New-CardMenu($g) {
    $cm = New-Object Windows.Controls.ContextMenu
    # 選單是另一個彈出視窗，吃不到主視窗的樣式，要自己帶
    $cm.Style = $win.FindResource([Windows.Controls.ContextMenu])
    $cm.Resources.Add([Windows.Controls.MenuItem], $win.FindResource([Windows.Controls.MenuItem]))
    $cm.Resources.Add([Windows.Controls.Separator], $win.FindResource([Windows.Controls.Separator]))
    [void]$cm.Items.Add((New-Object Windows.Controls.MenuItem))   # 空的選單打不開，先放一個，要打開時（卡片的 ContextMenuOpening）換成真的
    return $cm
}
function Fill-CardMenu($cm, $g) {
    $hasLog = [bool](Latest-Log $g)
    $ms = Get-MultiShell
    Menu-Item $cm '📂  遊戲資料夾' $g.Dir 'folder'
    Menu-Item $cm '📄  最近的記錄' $g.Dir 'log' $hasLog
    Menu-Item $cm '💾  存檔資料夾（和 iPad 雙向同步）' $g.Dir 'savesync'
    Menu-Item $cm '📦  匯出問題回報（閃退、打不開時）' $g.Dir 'report' ([bool]$g.Tid -and (Test-Path -LiteralPath (Library-Ipa)) -and -not $state.Running)
    if (Test-Path -LiteralPath (Join-Path $g.Dir '存檔待傳')) { Menu-Item $cm '↩  取消待傳的存檔' $g.Dir 'unsave' }
    $part = if ($ms) { (Part-For $g (Multi-Id $ms)).Path }
    if ($part -and (Test-Path -LiteralPath "$part.repack")) { Menu-Item $cm '↩  取消重新打包' $g.Dir 'unrepack' (-not $state.Running) }
    else { Menu-Item $cm '🔁  下次更新時重新打包' $g.Dir 'repack' ($part -and (Test-Path -LiteralPath $part) -and -not $state.Running) }
    [void]$cm.Items.Add((New-Sep))
    Menu-Item $cm '🖼  換圖示…' $g.Dir 'cover'
    Menu-Item $cm '🔄  用遊戲原本的圖示' $g.Dir 'uncover' ([bool](Get-ChildItem -LiteralPath $g.Dir -Filter 'cover.*' -File -ErrorAction SilentlyContinue))
    [void]$cm.Items.Add((New-Sep))
    Menu-Item $cm '🗑  刪除…' $g.Dir 'delete' (-not $state.Running)
}
# ---------------------------------------------------------------- iPad 存檔：備份、還原都由 nxn.ps1 做（saves_data.py 經 App 的 Documents 讀寫）
# 備份在 <遊戲資料夾>\存檔備份\<時間>\；遊戲庫的整包快照在 備份\iPad存檔\<時間 原因>\（其他合包 備份\<合包名稱>\）；每次動 iPad 存檔前都會自動備份
function Save-Root($ipa) {
    $d = Split-Path $ipa -Parent
    if ((Split-Path $d -Leaf) -in $packDirName, '合包') {
        $n = [IO.Path]::GetFileNameWithoutExtension($ipa)
        Join-Path (Join-Path $base '備份') $(if ($n -eq '遊戲庫') { 'iPad存檔' } else { $n })
    } else { Join-Path $d '存檔備份' }
}
# 備份資料夾名稱有新舊兩種：2026-11-20 11.30.05 同步前、20261101-012757-before-sync
function Backup-Time($name) {
    if ($name -match '^(\d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2})') { return [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH.mm.ss', $null) }
    if ($name -match '^(\d{8}-\d{6})') { return [datetime]::ParseExact($Matches[1], 'yyyyMMdd-HHmmss', $null) }
    return $null
}
function Save-Backups($root) {
    @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { (Backup-Time $_.Name) -and $_.Name -notmatch '\.part$' } | Sort-Object { Backup-Time $_.Name } -Descending)
}
# iPad 上裝的是哪個 IPA：安裝紀錄裡的那個，沒有就用資料夾裡最新的（同一款的 IPA bundle ID 都一樣）
function Save-Ipa($g) {
    $rec = Get-Installed | Where-Object { $_.Dir -eq $g.Dir -and (Test-Path -LiteralPath $_.Ipa) } | Select-Object -First 1
    if ($rec) { return $rec.Ipa }
    if ($g.Ipas.Count) { return $g.Ipas[0].FullName }
    return ''
}
function Pick-Backup($title, $list) {
    $bx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="460" SizeToContent="Height" Background="#141416" Foreground="#F5F5F7" ResizeMode="NoResize"
        FontFamily="Segoe UI, Microsoft JhengHei UI" FontSize="14" WindowStartupLocation="CenterOwner">
  <Window.Resources>__RES__</Window.Resources>
  <StackPanel Margin="22">
    <TextBlock Foreground="#8E8E93" TextWrapping="Wrap" Margin="0,0,0,10"
               Text="選一份備份還原回 iPad。iPad 上現在的存檔會先另外備份一份（名稱有「還原前」），選錯也救得回來。還原前先在 iPad 上把遊戲關掉。"/>
    <ListBox x:Name="List" Height="260" Background="#1C1C1E" Foreground="White" BorderThickness="0" Padding="4"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
      <Button x:Name="Cancel" Content="取消" IsCancel="True" Margin="0,0,8,0"/>
      <Button x:Name="Ok" Content="還原" Style="{StaticResource Primary}" IsDefault="True"/>
    </StackPanel>
  </StackPanel>
</Window>
'@
    $bw = Load-Window $bx
    $bw.Owner = $win; $bw.Title = $title
    $lb = $bw.FindName('List')
    foreach ($b in $list) {
        $it = New-Object Windows.Controls.ListBoxItem
        $when = Backup-Time $b.Name
        $why = if ($b.Name -match 'before-restore|還原前') { '（還原前自動備份）' } elseif ($b.Name -match 'before-sync|同步前') { '（同步前自動備份）' } elseif ($b.Name -match 'before-import|匯入前') { '（匯入前自動備份）' } else { '' }
        $it.Content = $when.ToString('yyyy/MM/dd HH:mm:ss') + $why
        $it.Tag = $b.FullName; $it.Padding = '8,6'
        [void]$lb.Items.Add($it)
    }
    $lb.SelectedIndex = 0
    $bw.FindName('Ok').Add_Click({ if ($lb.SelectedItem) { $bw.DialogResult = $true } })
    $lb.Add_MouseDoubleClick({ if ($lb.SelectedItem) { $bw.DialogResult = $true } })
    if ($bw.ShowDialog() -and $lb.SelectedItem) { return $lb.SelectedItem.Tag }
    return $null
}
function Run-Saves($g, $ipa, $restore) {
    if ($state.Running -or -not $ipa) { return }
    if (-not $restore) { Start-Run @(@{ Game = $g; Mode = 'savebackup'; Ipa = $ipa }); return }
    $list = Save-Backups (Save-Root $ipa)
    if (-not $list.Count) { [void][Windows.MessageBox]::Show($win, '還沒有存檔備份：先用「備份 iPad 存檔」，或安裝一次（安裝前會自動備份）。', '還原存檔'); return }
    $pick = Pick-Backup "還原 $($g.Name) 的存檔" $list
    if ($pick) { Start-Run @(@{ Game = $g; Mode = 'saverestore'; Ipa = $ipa; Out = $pick }) }
}
function Latest-Log($g) {
    $key = ($g.Name -replace '[^\w.-]', '_')
    Get-ChildItem -Path $logDir -Filter "*-$key.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
# 刪除都是丟到資源回收筒，按錯還救得回來
function Recycle($path, $isDir) {
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic
        if ($isDir) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($path, 'OnlyErrorDialogs', 'SendToRecycleBin') }
        else { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($path, 'OnlyErrorDialogs', 'SendToRecycleBin') }
        return $true
    } catch [OperationCanceledException] { return $false }
    catch { [void][Windows.MessageBox]::Show($win, "刪不掉：$($_.Exception.Message)", '刪除'); return $false }
}
# 從安裝紀錄拿掉符合的項目（續期才不會去找已經刪掉的 IPA）
function Forget-Installed($match) {
    if (-not (Test-Path $installedDb)) { return }
    try {
        $j = Get-Content $installedDb -Raw -Encoding UTF8 | ConvertFrom-Json
        $map = [ordered]@{}
        foreach ($pr in $j.PSObject.Properties) { if (-not (& $match $pr.Name $pr.Value)) { $map[$pr.Name] = $pr.Value } }
        $map | ConvertTo-Json -Depth 3 | Set-Content $installedDb -Encoding UTF8
    } catch { }
}
function Card-Action($action, $dir) {
    $card = $cards[$dir]; if (-not $card) { return }
    $g = $card.Tag
    switch ($action) {
        'folder' { Open-Folder $g.Dir }
        'save'   { Open-Folder (Join-Path $g.Dir '存檔備份') }
        'savesync' { Open-Folder (Join-Path $g.Dir '存檔') }
        'unsave' {
            $ok = [Windows.MessageBox]::Show($win, "不把拖進來的存檔放進 iPad 了？`n`n那份存檔會移到資源回收筒，iPad 上的存檔不會動。", '取消待傳的存檔', 'YesNo', 'Question')
            if ($ok -ne 'Yes') { return }
            if (Recycle (Join-Path $g.Dir '存檔待傳') $true) { Remove-Item -LiteralPath (Join-Path $g.Dir '存檔待傳.txt') -ErrorAction SilentlyContinue; Build-Library }
        }
        'savebackup'  { Run-Saves $g (Save-Ipa $g) $false }
        'saverestore' { Run-Saves $g (Save-Ipa $g) $true }
        'log'    { $l = Latest-Log $g; if ($l) { Start-Process notepad.exe "`"$($l.FullName)`"" } }
        'report' { Start-Report $g }
        # 遊戲包是快取：刪掉，下次按「轉檔」就從遊戲檔重新轉換這款
        # 不直接刪：先改名成 .repack，按錯了還能「取消重新打包」換回來；重新打包好之後 Part-For 會把它清掉
        'repack' { $ms = Get-MultiShell; if ($ms) { $p = (Part-For $g (Multi-Id $ms)).Path; Move-Item -LiteralPath $p -Destination "$p.repack" -Force -ErrorAction SilentlyContinue }; Build-Library }
        'unrepack' {
            $ms = Get-MultiShell
            if ($ms) {
                $p = (Part-For $g (Multi-Id $ms)).Path
                if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath "$p.repack" -ErrorAction SilentlyContinue }
                else { Move-Item -LiteralPath "$p.repack" -Destination $p -ErrorAction SilentlyContinue }
            }
            Build-Library
        }
        'cover'  {
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Title = "選 $($g.Name) 的圖示"
            $dlg.Filter = '圖片|*.png;*.jpg;*.jpeg;*.ico'
            if ($dlg.ShowDialog($win)) {
                foreach ($old in Get-ChildItem -LiteralPath $g.Dir -Filter 'cover.*' -File -ErrorAction SilentlyContinue) { Remove-Item -LiteralPath $old.FullName -ErrorAction SilentlyContinue }
                Copy-Item -LiteralPath $dlg.FileName -Destination (Join-Path $g.Dir ('cover' + [IO.Path]::GetExtension($dlg.FileName).ToLower()))
                Build-Library
            }
        }
        'uncover' {
            foreach ($old in Get-ChildItem -LiteralPath $g.Dir -Filter 'cover.*' -File -ErrorAction SilentlyContinue) { Remove-Item -LiteralPath $old.FullName -ErrorAction SilentlyContinue }
            Build-Library
        }
        'delete' {
            $ok = [Windows.MessageBox]::Show($win, "把「$($g.Name)」整個資料夾（遊戲檔和打包好的 IPA）移到資源回收筒？`n`n要救回可以從資源回收筒還原。iPad 上已經裝好的不會被刪。", '刪除遊戲', 'YesNo', 'Warning')
            if ($ok -ne 'Yes') { return }
            if (Recycle $g.Dir $true) { Forget-Installed { param($k, $v) $k -eq $g.Dir }; Build-Library }
        }
    }
}

# 會影響卡片的東西有沒有變：遊戲資料夾（加減檔案會改資料夾時間）、遊戲庫、殼、安裝紀錄
function Library-Stamp {
    $t = @(Get-ChildItem -LiteralPath $gamesDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name)|$($_.LastWriteTimeUtc.Ticks)" })
    foreach ($f in (Library-Ipa), $installedDb, $settingsFile) { $i = Get-Item -LiteralPath $f -ErrorAction SilentlyContinue; $t += "$($i.LastWriteTimeUtc.Ticks)" }
    $t += @(Get-MultiShells | ForEach-Object { $_.Name }); $t += "$($cfg.ShellPin)"
    $t -join ';'
}
# 重畫遊戲庫各部分花多久（加總，寫進 startup.log；之後每次重畫超過 1 秒也記一行）
$blTimes = [ordered]@{}
$blSw = New-Object Diagnostics.Stopwatch
function BL($what) { $blTimes[$what] = [int64]$blTimes[$what] + $blSw.ElapsedMilliseconds; $blSw.Restart() }
function Build-Library {
    $blAll = [Diagnostics.Stopwatch]::StartNew(); $blTimes.Clear(); $blSw.Restart()
    $script:libStamp = Library-Stamp
    $ui.Library.Children.Clear(); $ui.Others.Children.Clear(); $cards.Clear()
    $inst = @(Get-Installed)
    $libTids = @(Library-Tids)
    $ms = Get-MultiShell; $partId = if ($ms) { Multi-Id $ms } else { '' }
    $libTime = (Get-Item -LiteralPath (Library-Ipa) -ErrorAction SilentlyContinue).LastWriteTime
    $newShell = if ($ms) { Shell-Changed $ms.FullName } else { $false }
    $dirs = @(Get-ChildItem -LiteralPath $gamesDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
    BL '讀遊戲庫和安裝紀錄'
    $script:pcGameBytes = 0L
    foreach ($d in $dirs) {
        $g = Scan-Game $d
        $script:pcGameBytes += $g.LocalBytes
        if (-not $g.Base -and -not $g.Ipas.Count) { continue }   # 不是遊戲資料夾
        $g | Add-Member -NotePropertyName InLib -NotePropertyValue $selected.Contains($g.Dir) -Force
        $g | Add-Member -NotePropertyName OnPad -NotePropertyValue ([bool](Game-Tid $g) -and $libTids -contains (Game-Tid $g)) -Force
        $pf = if ($partId) { Part-For $g $partId -UseScan }
        if ($pf.File) {
            $g.PackageKey = Size-Key $pf.File
            if (-not $sizes.ContainsKey($g.PackageKey) -and -not $sizeTried.Contains($g.PackageKey) -and -not $partMissing.Contains($pf.Path)) { $partMissing.Add($pf.Path) }
        }
        $g | Add-Member -NotePropertyName Ready -NotePropertyValue ([bool]$pf -and $pf.Fresh) -Force
        # iPad 上的是舊的：遊戲包比上次合成的遊戲庫新（換了殼或重新轉換過），裝到 iPad 時會換掉
        $g | Add-Member -NotePropertyName Newer -NotePropertyValue ([bool]($g.Ready -and $g.OnPad -and $libTime -and ($newShell -or $pf.File.LastWriteTime -gt $libTime))) -Force
        BL '掃遊戲資料夾'
        $card = [Windows.Markup.XamlReader]::Parse($cardXaml)
        BL '建卡片'
        $card.Tag = $g
        $card.FindName('Title').Text = $g.Name
        $parts = @()
        if (-not $g.Base) { $parts += '缺本體' }
        if ($g.Update -and $g.Update -notlike '#*') { $parts += "v$($g.Update)" } elseif ($g.Update) { $parts += '已更新' }   # 沒有更新檔就不寫版本，本體的版本號看不出來
        if ($g.Dlc) { $parts += "$($g.Dlc) DLC" }
        $card.FindName('Detail').Text = $parts -join ' · '
        $st = $card.FindName('State')
        $glRec = Gl-Rec $g
        $glN = if ((Game-Tid $g) -and [IO.Directory]::Exists($glRec)) { try { [IO.Directory]::GetFiles($glRec).Length } catch { 0 } } else { -1 }
        $green = Brush '#30D158'; $blue = Brush '#0A84FF'; $gray = Brush '#8E8E93'; $st.ToolTip = $null
        $red = Brush '#FF453A'; $orange = Brush '#FF9F0A'
        $why = if ($addFail.ContainsKey($g.Dir)) { $addFail[$g.Dir] } else { '' }
        # 體檢（打包器解包完先看一下，寫在遊戲資料夾的 precheck.json）：不能玩的原因，和要注意的事
        $pre = Precheck-Of $g
        $preBad = @($pre | Where-Object { $_.level -eq 'bad' } | ForEach-Object { $_.text })
        $preWarn = @($pre | Where-Object { $_.level -eq 'warn' } | ForEach-Object { $_.text })
        if (-not $why -and $preBad.Count -and -not $g.Ready) { $why = $preBad -join '；' }
        $g | Add-Member -NotePropertyName Order -NotePropertyValue 9 -Force
        if ($state.Job -and $state.Job.Game.Dir -eq $g.Dir) { $st.Text = '● 轉換中'; $st.Foreground = $blue; $g.Order = 0 }
        elseif ($state.Running -and @(Busy-Dirs) -contains $g.Dir) { $st.Text = '● 排隊中'; $st.Foreground = $gray; $g.Order = 0 }
        elseif ($g.InLib -and -not $g.Ready -and $why) { $st.Text = '● 轉換失敗'; $st.Foreground = $red; $st.ToolTip = "$why。右上角選單「最近的記錄」看完整記錄；其他遊戲不受影響"; $g.Order = 0 }
        elseif ($g.InLib -and $g.OnPad -and $glN -eq 0) { $st.Text = '● 到 iPad 上玩一下'; $st.Foreground = $orange; $st.ToolTip = '著色器要在 iPad 上記下來的遊戲（OpenGL、執行時才編譯著色器，或著色器太多只放用到的那些）：玩一下讓 iPad 記下它用的著色器（第一次可能沒有畫面或少了一些東西），再接著電腦按「轉檔」或「同步」補上'; $g.Order = 1 }
        elseif ($g.InLib -and $g.OnPad -and -not $g.Ready) { $st.Text = '● 要重新轉換'; $st.Foreground = $orange; $st.ToolTip = '換了新的殼或遊戲檔有更新：按「轉檔」重新轉換，iPad 上的這款先照舊能玩'; $g.Order = 1 }
        elseif ($g.InLib -and $g.Newer) { $st.Text = '● 同步時更新'; $st.Foreground = $blue; $st.ToolTip = 'iPad 上的是舊的版本（換了殼或重新轉換過），按「同步」換成新的，存檔都留著'; $g.Order = 2 }
        elseif ($g.InLib -and $g.OnPad) { $st.Text = '● 在 iPad 上'; $st.Foreground = $green; if ($glN -gt 0) { $st.ToolTip = "iPad 記下的著色器 $glN 個" }; $g.Order = 4 }
        elseif ($g.InLib -and $g.Ready) { $st.Text = '● 轉好了，等同步'; $st.Foreground = $blue; $st.ToolTip = '轉好了，iPad 接上後按「同步」就傳過去'; $g.Order = 2 }
        elseif ($g.InLib) { $st.Text = '● 還沒轉檔'; $st.Foreground = $gray; $st.ToolTip = '按「同步」會先轉好再傳；也可以點選它按「轉檔」先在電腦上轉好'; $g.Order = 3 }
        elseif ($g.OnPad) { $st.Text = '● 同步時從 iPad 拿掉'; $st.Foreground = $red; $g.Order = 0 }
        elseif ($why) { $st.Text = '● 上次轉換失敗'; $st.Foreground = $red; $st.ToolTip = $why; $g.Order = 1 }
        elseif ($g.Ready) { $st.Text = '● 轉換過了，加入就能裝'; $st.Foreground = $gray; $g.Order = 2 }
        else { $st.Text = '' }
        $g.HasPendingSave = Test-Path -LiteralPath (Join-Path $g.Dir '存檔待傳')
        if ($g.HasPendingSave) {
            Add-Badge $card '存檔待傳' '#330A84FF' '#64D2FF' $(if ((Get-Content -LiteralPath (Join-Path $g.Dir '存檔待傳.txt') -ErrorAction SilentlyContinue) -match '^slot=') { '💾 下次「同步」時把拖進來的存檔另存成一份新存檔（iPad 上開遊戲前的「存檔」裡切換）；右鍵可以取消' } else { '💾 下次「同步」時用拖進來的存檔取代 iPad 上這款的（原本的先備份到電腦）；右鍵可以取消' })
        }
        $warn = @()
        if ($g.Stray) { $warn += "子資料夾裡有 $($g.Stray) 個檔案不會用到（打包器只讀第一層），要用的話把檔案移到外面" }
        if ($preWarn.Count -and -not $why) { $warn += $preWarn }
        if ($warn.Count) { Add-Badge $card '要注意' '#33FF9F0A' '#FF9F0A' (($warn | ForEach-Object { "⚠ $_" }) -join "`n") }
        State-Badges $card $parts
        Update-GameSizeBadge $card
        # 支援程度只在「還沒加入」顯示，幫你挑：左上角的小標籤；已經在遊戲庫的看狀態那行就好
        if (-not $g.InLib) {
            $sup = Support-Of $g
            if ($sup.Text -eq '● 已驗證') { Add-Badge $card '已驗證' '#2630D158' '#30D158' $sup.Tip }
            elseif ($sup.Text) { Add-Badge $card '未驗證' '#33FFD60A' '#FFD60A' $(if ($sup.Tip) { $sup.Tip } else { '還沒有人確認這款能玩，可能打不開' }) }
        }
        BL '狀態和標籤'
        Paint-Icon $card.FindName('Icon') $card.FindName('Letter') $g (Cover-For $g)
        BL '圖示'

        $card.Add_MouseEnter({ param($s, $e) if (-not $picked.Contains($s.Tag.Dir)) { $s.Background = Brush '#1F1F22' } })
        $card.Add_MouseLeave({ param($s, $e) $s.Background = if ($picked.Contains($s.Tag.Dir)) { Brush '#2A0A84FF' } else { [Windows.Media.Brushes]::Transparent }
                                             $s.FindName('InsL').Visibility = 'Collapsed'; $s.FindName('InsR').Visibility = 'Collapsed' })
        Wire-CardDrag $card
        $act = $card.FindName('Act'); $act.Tag = $card
        $act.Add_Click({ param($s, $e)
            $c = $s.Tag; $dir = $c.Tag.Dir
            if ($selected.Contains($dir)) {
                [void]$selected.Remove($dir)
                # 排隊等轉換的遊戲從遊戲庫拿掉：也不用轉了
                if ($state.Running) { foreach ($q in @($state.Queue | Where-Object { $_.Game.Dir -eq $dir -and -not $_.PSObject.Properties['Lib'] })) { Drop-Queued $q } }
            } else { $selected.Add($dir) }
            [void]$picked.Remove($dir)
            Save-Want; Build-Library })
        $card.Add_DragEnter({ param($s, $e) if ($e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { $s.FindName('DropHint').Visibility = 'Visible' } })
        $card.Add_DragLeave({ param($s, $e) $s.FindName('DropHint').Visibility = 'Collapsed' })
        $card.Add_Drop({ param($s, $e)
            $s.FindName('DropHint').Visibility = 'Collapsed'
            if ($e.Data.GetDataPresent($dragFmt)) { Drop-Games $e $s; return }
            $all = @($e.Data.GetData([Windows.DataFormats]::FileDrop))
            $e.Handled = $true
            foreach ($k in @($all | Where-Object { $_ -match '\.keys$' })) { Set-Keys $k }
            $games = @($all | Where-Object { $_ -match '\.(nsp|xci|nsz|xcz)$' })
            $rest = @($all | Where-Object { $_ -notmatch '\.(nsp|xci|nsz|xcz|keys)$' })
            if ($games.Count) { Add-Files $s.Tag.Dir $games }
            # 其他的（資料夾、zip、散的檔案）當成這款的存檔
            if ($rest.Count) { Import-Save $s.Tag $rest } })
        $card.ContextMenu = New-CardMenu $g
        $card.Add_ContextMenuOpening({ param($s, $e) $m = $s.ContextMenu; $m.Items.Clear(); Fill-CardMenu $m $s.Tag })
        $panel = if ($g.InLib) { $ui.Library } else { $ui.Others }
        if ($g.InLib) {
            # 遊戲庫照使用者拖好的順序（存在設定的 Want），同步後 iPad 上也是這個順序
            $mine = $selected.IndexOf($g.Dir)
            $at = 0; foreach ($c in $panel.Children) { if ($selected.IndexOf($c.Tag.Dir) -lt $mine) { $at++ } }
        } else {
            $at = 0; foreach ($c in $panel.Children) { if ($c.Tag.Order -le $g.Order) { $at++ } }   # 要你處理的排前面
        }
        [void]$panel.Children.Insert($at, $card)
        $cards[$g.Dir] = $card
        Card-Paint $card
        BL '事件和排版'
    }
    $nIn = $ui.Library.Children.Count; $nOut = $ui.Others.Children.Count
    $onPad = @($ui.Library.Children | Where-Object { $_.Tag.OnPad }).Count
    Head-Count $ui.GamesHead '遊戲庫' $nIn; Head-Count $ui.OutHead '還沒加入' $nOut
    if (-not $nIn) { $ui.InHint.Text = '把下面的遊戲拖上來，或按「加入」，再按「同步」' }
    else { $ui.InHint.Text = "iPad 上 $onPad 款" + $(if ($nIn - $onPad) { " · $($nIn - $onPad) 款等同步" } else { '' }) + ' · 拖曳排順序，iPad 上也照這個順序' }
    if (-not $nOut) {
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = if ($cards.Count) { '電腦上的遊戲都在遊戲庫裡了。把 NSP / XCI / NSZ 拖進視窗新增遊戲。' } else { '把 NSP / XCI / NSZ 拖進來新增遊戲' }
        $t.ToolTip = "遊戲會放在 $gamesDir"
        $t.Foreground = Brush '#8E8E93'; $t.Margin = '8,16,8,0'; $t.FontSize = 15; $t.TextWrapping = 'Wrap'
        [void]$ui.Others.Children.Add($t)
    }
    Build-Packs $inst
    BL '合包'
    Start-Sizes
    Update-SelCount
    BL '空間和底部'
    Update-Banner $inst
    Update-MergeOption
    Update-Notice
    BL '其他'
    if ($blAll.ElapsedMilliseconds -gt 1000 -and $script:startMarks.Count -eq 0) {
        $startMarks.Add(('{0} 款' -f $cards.Count))
        foreach ($k in @($blTimes.Keys)) { $startMarks.Add(('{0} {1:N1}s' -f $k, ($blTimes[$k] / 1000.0))) }
        try { Add-Content -LiteralPath (Join-Path $logDir 'startup.log') -Value ('{0:yyyy-MM-dd HH:mm:ss} 重畫遊戲庫（共 {1:N1}s）：{2}' -f (Get-Date), ($blAll.ElapsedMilliseconds / 1000.0), ($startMarks -join '／')) -Encoding UTF8 } catch { }
        $startMarks.Clear()
    }
}

# ---------------------------------------------------------------- 合包：nxn\合包 裡每個 IPA 一張卡，點進去看裡面的遊戲
# 合包裡每款在 Payload/<App>.app/games/<title ID>/：game.json（id、name、version…）和 icon.png
$packCache = @{}      # IPA 路徑|修改時間 → 讀到的遊戲清單（讀 zip 目錄要一點時間，不要每次重畫都讀）
function Read-Pack($ipa) {
    $key = "$($ipa.FullName)|$($ipa.LastWriteTimeUtc.Ticks)|$($ipa.Length)"
    if ($packCache.ContainsKey($key)) { return $packCache[$key] }
    # 讀過的遊戲庫清單存在 work\covers\packindex-<雜湊>.json：遊戲庫幾萬個檔，每次開 PadSwitch 都整個掃一遍要好幾秒，畫面會卡住「沒有回應」
    $md5 = [Security.Cryptography.MD5]::Create()
    $h = -join ($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($key))[0..7] | ForEach-Object { $_.ToString('x2') })
    $idx = Join-Path $coverDir "packindex-$h.json"
    if (Test-Path -LiteralPath $idx) {
        try {
            $arr = ConvertFrom-Json (Get-Content -LiteralPath $idx -Raw -Encoding UTF8)   # PowerShell 5.1 用管線接會把整個陣列當成一筆
            $games = @(foreach ($x in @($arr)) {
                $icon = Join-Path $coverDir "pack-$($x.Tid).png"
                [pscustomobject]@{ Tid = [string]$x.Tid; Name = [string]$x.Name; Version = [string]$x.Version; Icon = $(if (Test-Path -LiteralPath $icon) { $icon } else { '' }) } })
            $packCache[$key] = $games
            return $games
        } catch { }
    }
    $games = @()
    $ok = $false
    try {
        $z = [IO.Compression.ZipFile]::OpenRead($ipa.FullName)
        try {
            # 先一次拿出全部檔名再用 -match 篩（在 .NET 裡跑），不要在 PowerShell 裡一個一個看
            $names = @([string[]]@($z.Entries.FullName) -match '^Payload/[^/]+\.app/games/[0-9A-Fa-f]{16}/game\.json$')
            foreach ($n in $names) {
                $e = $z.GetEntry($n); if (-not $e) { continue }
                $tid = ($n -split '/')[3].ToUpper()
                $sr = New-Object IO.StreamReader($e.Open(), [Text.Encoding]::UTF8)
                try { $j = $sr.ReadToEnd() | ConvertFrom-Json } finally { $sr.Dispose() }
                $icon = Join-Path $coverDir "pack-$tid.png"
                $ie = $z.GetEntry(($n -replace 'game\.json$', 'icon.png'))
                if ($ie -and -not (Test-Path -LiteralPath $icon)) { [IO.Compression.ZipFileExtensions]::ExtractToFile($ie, $icon, $true) }
                $games += [pscustomobject]@{ Tid = $tid; Name = $(if ($j.name) { $j.name } else { $tid }); Version = [string]$j.version
                                            Icon = $(if (Test-Path -LiteralPath $icon) { $icon } else { '' }) }
            }
            $ok = $true
        } finally { $z.Dispose() }
    } catch { }
    $games = @($games | Sort-Object Name)
    $packCache[$key] = $games
    if ($ok) {
        try {
            # 合成新的遊戲庫後舊清單就用不到，放超過 30 天的清掉
            Get-ChildItem -LiteralPath $coverDir -Filter 'packindex-*.json' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | Remove-Item -ErrorAction SilentlyContinue
            ConvertTo-Json -InputObject @($games | ForEach-Object { [pscustomobject]@{ Tid = $_.Tid; Name = $_.Name; Version = $_.Version } }) -Depth 3 |
                Set-Content -LiteralPath $idx -Encoding UTF8
        } catch { }
    }
    return $games
}
# 合包在 iPad 上的圖示（nxn_merge.py 把幾款的圖示拼成一張），跟著檔案的修改時間快取
function Pack-Icon($ipa) {
    $md5 = [Security.Cryptography.MD5]::Create()
    $h = -join ($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes("$($ipa.FullName)|$($ipa.LastWriteTimeUtc.Ticks)"))[0..5] | ForEach-Object { $_.ToString('x2') })
    $out = Join-Path $coverDir "packapp-$h.png"
    if (Test-Path -LiteralPath $out) { return $out }
    try {
        $z = [IO.Compression.ZipFile]::OpenRead($ipa.FullName)
        try {
            $e = $z.Entries | Where-Object { $_.FullName -match '^Payload/[^/]+\.app/AppIcon60x60@3x\.png$' } | Select-Object -First 1
            if ($e) { [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $out, $true); return $out }
        } finally { $z.Dispose() }
    } catch { }
    return ''
}
function Build-Packs($inst) {
    $ui.Packs.Children.Clear()
    $mdir = (Pack-Dir)
    $ipas = @(Get-ChildItem -LiteralPath $mdir -Filter '*.ipa' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        if (-not $ipas.Count) {
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = '還沒有遊戲庫：在「還沒加入」按「＋ 加入」，按「轉檔」，再按「同步」'
        $t.Foreground = Brush '#8E8E93'; $t.Margin = '8,40,8,0'; $t.FontSize = 16
        [void]$ui.Packs.Children.Add($t)
    }
    foreach ($ipa in $ipas) {
        $mine = $inst | Where-Object { $_.Ipa -eq $ipa.FullName } | Select-Object -First 1
        $games = @(Read-Pack $ipa)
        $p = [pscustomobject]@{ Dir = $mdir; Name = $ipa.BaseName; Ipas = @($ipa); Base = $false; BaseFile = ''; Games = $games
                               Icon = $(if ($pi = Pack-Icon $ipa) { $pi } elseif ($games.Count -and $games[0].Icon) { $games[0].Icon } else { $appIcon }) }
        $card = [Windows.Markup.XamlReader]::Parse($cardXaml)
        $card.Tag = $p
        $card.FindName('Title').Text = $p.Name
        $card.FindName('Detail').Text = if ($games.Count) { "$($games.Count) 款 · $($ipa.LastWriteTime.ToString('MM/dd'))" } else { $ipa.LastWriteTime.ToString('MM/dd') }
        $card.FindName('Detail').ToolTip = ($games | ForEach-Object { $_.Name }) -join "`n"
        $st = $card.FindName('State')
        if ($mine) {
            $st.Text = if ($mine.Left -le 0) { '已過期' } else { "已安裝 · 剩 $($mine.Left) 天" }
            $st.Foreground = Brush $(if ($mine.Left -le 2) { '#FF9F0A' } else { '#30D158' })
        }
        Paint-Icon $card.FindName('Icon') $card.FindName('Letter') $p (Cover-For $p)
        $card.Add_MouseEnter({ param($s, $e) $s.Background = Brush '#1F1F22' })
        $card.Add_MouseLeave({ param($s, $e) $s.Background = [Windows.Media.Brushes]::Transparent })
        $card.Add_MouseLeftButtonUp({ param($s, $e) Show-Pack $s.Tag })
        $cm = New-Object Windows.Controls.ContextMenu
        $cm.Style = $win.FindResource([Windows.Controls.ContextMenu])
        $cm.Resources.Add([Windows.Controls.MenuItem], $win.FindResource([Windows.Controls.MenuItem]))
        foreach ($it in @(@('🎮  看裡面的遊戲', 'show'), @('➕  加入遊戲…', 'add'), @('➖  移除遊戲…', 'show'), @('📲  安裝到 iPad', 'install'), @('⬆  備份 iPad 存檔', 'savebackup'), @('⬇  還原存檔…', 'saverestore'), @('✏  改名…', 'rename'), @('📂  打開資料夾', 'folder'), @('🗑  刪除…', 'delete'))) {
            $mi = New-Object Windows.Controls.MenuItem
            $mi.Header = Menu-Header $it[0]; $mi.Tag = @{ Pack = $p; Action = $it[1] }
            $mi.Add_Click({ param($s, $e) Pack-Action $s.Tag.Pack $s.Tag.Action })
            [void]$cm.Items.Add($mi)
        }
        $card.ContextMenu = $cm
        [void]$ui.Packs.Children.Add($card)
    }
}
function Pack-Action($p, $action) {
    switch ($action) {
        'show'    { Show-Pack $p }
        'add'     {
            if ($state.Running) { return }
            if (-not $ui.Merge.IsEnabled) { [void][Windows.MessageBox]::Show($ui.Merge.ToolTip, '加入遊戲'); return }
            # 換到遊戲頁、切成合成一包，勾好要加的遊戲按開始；切回「各自安裝」就取消
            $script:addTo = $p
            $selected.Clear(); foreach ($c in $cards.Values) { Card-Paint $c }
            $ui.Merge.IsChecked = $true; $ui.TabGames.IsChecked = $true
            Update-SelCount
        }
        'install' { Start-Run @(@{ Game = $p; Mode = 'install'; Ipa = $p.Ipas[0].FullName }) }
        'savebackup'  { Run-Saves $p $p.Ipas[0].FullName $false }
        'saverestore' { Run-Saves $p $p.Ipas[0].FullName $true }
        'folder'  { Start-Process explorer.exe "/select,`"$($p.Ipas[0].FullName)`"" }
        'delete'  {
            if ($state.Running) { return }
            $f = $p.Ipas[0].FullName
            $ok = [Windows.MessageBox]::Show($win, "把合包「$($p.Name)」移到資源回收筒？`n`n裡面的遊戲在「遊戲」分頁的資料夾還在，不受影響。iPad 上已經裝好的不會被刪。", '刪除合包', 'YesNo', 'Warning')
            if ($ok -ne 'Yes') { return }
            if (Recycle $f $false) { Forget-Installed { param($k, $v) $v.ipa -eq $f }; Build-Library }
        }
        'rename'  {
            if ($p.Name -eq $libName) { [void][Windows.MessageBox]::Show("「$libName」的名稱是固定的，PadSwitch 靠它找到遊戲庫。", '合包改名'); return }
            $n = Ask-Text '合包改名' 'iPad 主畫面上顯示的名稱（也是檔名）。iPad 上要重新安裝才會變。' $p.Name
            if ($n -and $n -ne $p.Name) { Rename-Pack $p $n }
        }
    }
}
# 合包的名稱就是它的檔名，也是 iPad 主畫面上的名稱（nxn_merge.py --name）
function Pack-Path($name) {
    $safe = ($name -replace '[\\/:*?"<>|]', '_').Trim()
    if (-not $safe) { $safe = '遊戲合包' }
    $p = Join-Path ((Pack-Dir)) "$safe.ipa"
    if (Test-Path -LiteralPath $p) { $p = Join-Path ((Pack-Dir)) ("$safe-" + (Get-Date -Format 'MMdd-HHmm') + '.ipa') }
    return $p
}
# 改名：用 nxn_merge.py 拿舊的合包當輸入重新寫一份（原樣複製壓縮資料，很快），成功才刪掉舊的
function Rename-Pack($p, $name) {
    $mg = Get-MergeScript
    if (-not $mg) { [void][Windows.MessageBox]::Show('找不到 nxn_merge.py，沒辦法改 iPad 上的名稱。', '改名'); return }
    $old = $p.Ipas[0].FullName
    $new = Pack-Path $name
    $db = $installedDb
    $call = "Write-Host '==> 合成一包：改名成 $($name -replace "'", "''")'; & $(Quote (Get-Python)) $(Quote $mg) -o $(Quote $new) --name $(Quote $name) $(Quote $old); " +
            "if (`$LASTEXITCODE) { Write-Host '出錯了：改名失敗'; `$global:LASTEXITCODE = 1; return }; Remove-Item -LiteralPath $(Quote $old); " +
            # 安裝紀錄指向舊檔名的話跟著改，續期才找得到
            "if (Test-Path $(Quote $db)) { `$t = Get-Content $(Quote $db) -Raw -Encoding UTF8; `$t.Replace($(Quote ($old -replace '\\', '\\')), $(Quote ($new -replace '\\', '\\'))) | Set-Content $(Quote $db) -Encoding UTF8 }; " +
            "Write-Host '改好了'"
    $g = [pscustomobject]@{ Dir = $p.Dir; Name = "改名：$name"; Ipas = @(); Base = $false; BaseFile = ''; Icon = $p.Icon }
    Start-Run @(@{ Game = $g; Mode = 'merge'; Ipa = ''; Call = $call })
}
# 問一行字的小視窗：取消回傳 $null
function Ask-Text($title, $prompt, $default) {
    $ax = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="440" SizeToContent="Height" Background="#141416" Foreground="#F5F5F7" ResizeMode="NoResize"
        FontFamily="Segoe UI, Microsoft JhengHei UI" FontSize="14" WindowStartupLocation="CenterOwner">
  <Window.Resources>__RES__</Window.Resources>
  <StackPanel Margin="22">
    <TextBlock x:Name="Prompt" Foreground="#8E8E93" TextWrapping="Wrap" Margin="0,0,0,10"/>
    <TextBox x:Name="Text" Background="#2C2C2E" Foreground="White" BorderThickness="0" Padding="8,6" FontSize="16" CaretBrush="White"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
      <Button x:Name="Cancel" Content="取消" IsCancel="True" Margin="0,0,8,0"/>
      <Button x:Name="Ok" Content="好" Style="{StaticResource Primary}" IsDefault="True"/>
    </StackPanel>
  </StackPanel>
</Window>
'@
    $aw = Load-Window $ax
    $aw.Owner = $win; $aw.Title = $title
    $aw.FindName('Prompt').Text = $prompt
    $tb = $aw.FindName('Text'); $tb.Text = $default
    $aw.FindName('Ok').Add_Click({ $aw.DialogResult = $true })
    $aw.Add_ContentRendered({ $tb.Focus(); $tb.SelectAll() })
    if ($aw.ShowDialog()) { return $tb.Text.Trim() }
    return $null
}
function Show-Pack($p) {
    $px = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="520" SizeToContent="Height" MaxHeight="760" Background="#141416" Foreground="#F5F5F7" ResizeMode="NoResize"
        FontFamily="Segoe UI, Microsoft JhengHei UI" FontSize="14" WindowStartupLocation="CenterOwner">
  <Window.Resources>__RES__</Window.Resources>
  <DockPanel Margin="22">
    <TextBlock x:Name="Head" DockPanel.Dock="Top" FontSize="22" FontWeight="Bold"/>
    <TextBlock x:Name="Sub" DockPanel.Dock="Top" Foreground="#8E8E93" Margin="0,4,0,14"/>
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
      <Button x:Name="Rename" Content="改名" Margin="0,0,8,0"/>
      <Button x:Name="Folder" Content="打開資料夾" Margin="0,0,8,0"/>
      <Button x:Name="Install" Content="安裝到 iPad" Style="{StaticResource Primary}" Margin="0,0,8,0"/>
      <Button x:Name="Close" Content="關閉" IsCancel="True"/>
    </StackPanel>
    <Border Background="#1C1C1E" CornerRadius="12" Padding="6">
      <ScrollViewer VerticalScrollBarVisibility="Auto">
        <StackPanel x:Name="List"/>
      </ScrollViewer>
    </Border>
  </DockPanel>
</Window>
'@
    $pw = Load-Window $px
    $pw.Owner = $win
    $pw.Title = $p.Name
    $pw.FindName('Head').Text = $p.Name
    $ipa = $p.Ipas[0]
    $pw.FindName('Sub').Text = "$($p.Games.Count) 款遊戲 · $([math]::Round($ipa.Length / 1GB, 2)) GB · $($ipa.LastWriteTime.ToString('yyyy/MM/dd HH:mm'))"
    $list = $pw.FindName('List')
    if (-not $p.Games.Count) {
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = '讀不到這包裡的遊戲清單（可能不是合包，或是舊格式）'; $t.Foreground = Brush '#8E8E93'; $t.Margin = '10'
        [void]$list.Children.Add($t)
    }
    foreach ($gm in $p.Games) {
        $row = New-Object Windows.Controls.DockPanel
        $row.Margin = '8,6'
        $ic = New-Object Windows.Controls.Border
        $ic.Width = 48; $ic.Height = 48; $ic.CornerRadius = '11'; $ic.Margin = '0,0,12,0'; $ic.Background = Brush '#2C2C2E'
        $bmp = if ($gm.Icon) { Load-Bitmap $gm.Icon } else { $null }
        if ($bmp) { $b = New-Object Windows.Media.ImageBrush $bmp; $b.Stretch = 'UniformToFill'; $ic.Background = $b }
        [Windows.Controls.DockPanel]::SetDock($ic, 'Left')
        [void]$row.Children.Add($ic)
        $sp = New-Object Windows.Controls.StackPanel; $sp.VerticalAlignment = 'Center'
        $n = New-Object Windows.Controls.TextBlock; $n.Text = $gm.Name; $n.FontSize = 15; $n.FontWeight = 'SemiBold'
        $v = New-Object Windows.Controls.TextBlock; $v.Foreground = Brush '#8E8E93'; $v.FontSize = 12
        $v.Text = (@($(if ($gm.Version) { "v$($gm.Version)" }), $gm.Tid) | Where-Object { $_ }) -join ' · '
        [void]$sp.Children.Add($n); [void]$sp.Children.Add($v)
        if ($p.Games.Count -gt 1 -and -not $state.Running) {
            $rm = New-Object Windows.Controls.Button
            $rm.Content = '移除'; $rm.VerticalAlignment = 'Center'; $rm.Tag = $gm
            [Windows.Controls.DockPanel]::SetDock($rm, 'Right')
            $rm.Add_Click({ param($s, $e)
                $ok = [Windows.MessageBox]::Show($pw, "從「$($p.Name)」拿掉「$($s.Tag.Name)」？`n`n遊戲資料夾裡的檔案不受影響，之後還能再加回來。要重新安裝到 iPad 才會生效。", '移除遊戲', 'YesNo', 'Question')
                if ($ok -eq 'Yes') { $pw.DialogResult = $false; Remove-FromPack $p $s.Tag } })
            [void]$row.Children.Add($rm)
        }
        [void]$row.Children.Add($sp)
        [void]$list.Children.Add($row)
    }
    $pw.FindName('Folder').Add_Click({ Pack-Action $p 'folder' })
    $pw.FindName('Rename').Add_Click({ $pw.DialogResult = $false; Pack-Action $p 'rename' })
    $pw.FindName('Install').Add_Click({ $pw.DialogResult = $true })
    $pw.FindName('Close').Add_Click({ $pw.DialogResult = $false })
    if ($pw.ShowDialog()) { Pack-Action $p 'install' }
}

# ---------------------------------------------------------------- 安裝和更新（nxn-update.ps1 做事；這裡只看缺什麼、問 GitHub 有沒有新版）
$latest = $null       # GitHub 上最新的殼 release（背景問到之後才有）
$latestApp = $null    # PadSwitch 最新的 release
function Setup-Missing {
    $m = @()
    if (-not (Test-Path (Join-Path $work 'shell.zip'))) { $m += '殼' }
    if (-not (Test-Path (Join-Path $work 'tools\nx_extract.exe'))) { $m += '打包工具' }
    if (-not (Test-Path (Join-Path $work 'src\scripts\nxn_pack.py'))) { $m += '打包器' }
    if (-not (Test-Path $plume)) { $m += '簽章工具' }
    return $m
}
function Update-Available {
    if (-not $latest) { return '' }
    $rel = Join-Path $work 'release.txt'
    $have = if (Test-Path $rel) { (Get-Content $rel -Raw).Trim() } else { '' }
    $what = @()
    if ($have -and $have -ne $latest.tag_name) { $what += '殼和打包器' }
    $app = $null
    if ($latestApp) { $app = $latestApp.assets | Where-Object { $_.name -eq 'SwitchPad.zip' } | Select-Object -First 1 }
    if (-not $app) { $app = $latest.assets | Where-Object { $_.name -eq 'SwitchPad.zip' } | Select-Object -First 1 }
    $ver = Join-Path $work 'app-version.txt'
    $appHave = if (Test-Path $ver) { (Get-Content $ver -Raw).Trim() } else { '' }
    if ($app -and $appHave -ne $app.updated_at) { $what += 'PadSwitch' }
    return ($what -join '、')
}
function Update-Notice {
    if (-not (Test-Path $updater)) { $ui.Notice.Visibility = 'Collapsed'; return }
    $miss = @(Setup-Missing)
    $ui.NoticeBtn.Visibility = 'Visible'
    if ($miss.Count) {
        $ui.NoticeText.Text = '第一次使用，要先下載打包和簽章工具'
        $ui.NoticeText.ToolTip = "缺：$($miss -join '、')。會自動安裝 Python（沒有的話）、Python 套件、殼、打包器和 plumesign。"
        $ui.NoticeBtn.Content = '安裝'; $ui.NoticeBtn.Tag = 'setup'
    } elseif (-not (Find-Keys)) {
        $ui.NoticeText.Text = '找不到 prod.keys，把它拖進這個視窗'
        $ui.NoticeText.ToolTip = '打包要用你自己 Switch 的 prod.keys。拖進來會複製一份到 work 資料夾，只留在這台電腦。'
        $ui.NoticeBtn.Content = '選擇檔案…'; $ui.NoticeBtn.Tag = 'keys'
    } else { $ui.Notice.Visibility = 'Collapsed'; Update-UpdateBtn; return }
    $ui.Notice.Visibility = 'Visible'
}
# 程式更新放在設定裡；有新版時齒輪變藍色提醒
function Update-UpdateBtn {
    $upd = Update-Available
    $ui.Settings.Foreground = Brush $(if ($upd) { '#0A84FF' } else { '#C7C7CC' })
    $ui.Settings.ToolTip = if ($upd) { "設定（有新版本：$upd）" } else { '設定' }
}
# 背景問 GitHub（不卡住畫面）；問不到就算了，下次開再問
$checkTask = $null
$checkAppTask = $null
function Check-Updates {
    try {
        $wc = New-Object Net.WebClient
        $wc.Headers.Add('User-Agent', 'SwitchPad')
        $wc.Encoding = [Text.Encoding]::UTF8
        $script:checkTask = $wc.DownloadStringTaskAsync("https://api.github.com/repos/$repo/releases/latest")
        # 一個 WebClient 同時只能下載一個，PadSwitch 自己的 release 另開一個問
        $wa = New-Object Net.WebClient
        $wa.Headers.Add('User-Agent', 'SwitchPad')
        $wa.Encoding = [Text.Encoding]::UTF8
        $script:checkAppTask = $wa.DownloadStringTaskAsync("https://api.github.com/repos/$appRepo/releases/latest")
        $checkTimer.Start()
    } catch { }
}
$checkTimer = New-Object Windows.Threading.DispatcherTimer
$checkTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$checkTimer.Add_Tick({
    if (-not $checkTask -or -not $checkTask.IsCompleted) { return }
    if ($checkAppTask -and -not $checkAppTask.IsCompleted) { return }
    $checkTimer.Stop()
    if ($checkTask.Status -eq 'RanToCompletion') { try { $script:latest = $checkTask.Result | ConvertFrom-Json } catch { } }
    if ($checkAppTask -and $checkAppTask.Status -eq 'RanToCompletion') { try { $script:latestApp = $checkAppTask.Result | ConvertFrom-Json } catch { } }
    $script:checkTask = $null
    $script:checkAppTask = $null
    if (-not $state.Running) { Update-Notice }
})
function Set-Keys($path) {
    $dst = Join-Path $work 'prod.keys'
    if ((Resolve-Path -LiteralPath $path).Path -ne $dst) { Copy-Item -LiteralPath $path -Destination $dst -Force }
    Get-ChildItem -Path $coverDir -Filter '*.none' -ErrorAction SilentlyContinue | Remove-Item -ErrorAction SilentlyContinue
    Build-Library
}
function Run-Setup {
    $g = [pscustomobject]@{ Dir = $here; Name = 'PadSwitch'; Ipas = @(); Base = $false; BaseFile = ''; Icon = $appIcon }
    Start-Run @(@{ Game = $g; Mode = 'setup'; Call = "& $(Quote $updater)" })
}
$ui.NoticeBtn.Add_Click({
    switch ($ui.NoticeBtn.Tag) {
        'setup' { Run-Setup }
        'keys'  {
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Title = '選擇 prod.keys'; $dlg.Filter = 'prod.keys|*.keys|所有檔案|*.*'
            if ($dlg.ShowDialog($win)) { Set-Keys $dlg.FileName }
        }
    } })

# ---------------------------------------------------------------- 合成一包：要有多遊戲殼（work\multigame）和 nxn_merge.py
# nxn-update.ps1 記下的 Python，沒有就用 PATH 上的
function Get-Python {
    $saved = Join-Path $work 'python.txt'
    if (Test-Path $saved) { $p = (Get-Content $saved -Raw).Trim(); if ($p) { return $p } }
    return 'python'
}
# 多遊戲殼：預設用最新的；設定裡「退回上一版」或「鎖定這一版」會記在 ShellPin，新殼出了問題可以一鍵退回，換回來也不用重轉
function Get-MultiShells { @(Find-Shallow (Join-Path $work 'multigame') 'shell-*.zip' | Sort-Object LastWriteTime -Descending) }
function Get-MultiShell {
    if ($cfg.ShellPin -and (Test-Path -LiteralPath $cfg.ShellPin)) { return Get-Item -LiteralPath $cfg.ShellPin }
    Get-MultiShells | Select-Object -First 1
}
# 清理空間時留著的殼：正在用的，加上可以退回的另一個（最新的或上一版）
function Keep-Shells { $cur = Get-MultiShell; @(@($cur) + @(Get-MultiShells | Where-Object { -not $cur -or $_.FullName -ne $cur.FullName } | Select-Object -First 1) | Where-Object { $_ }) }
function Get-MergeScript {
    foreach ($p in (Join-Path $here 'nxn_merge.py'), (Join-Path $work 'multigame\nxn_merge.py'), (Join-Path $work 'src\scripts\nxn_merge.py')) { if (Test-Path $p) { return $p } }
    # 殼旁邊那版打包器的（multigame\art<N>\src-<版本>\scripts），先找正在用的那個殼的
    $ms = Get-MultiShell
    $dirs = @($(if ($ms) { $ms.Directory.FullName })) + @(Get-ChildItem -LiteralPath (Join-Path $work 'multigame') -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | ForEach-Object { $_.FullName })
    foreach ($d in $dirs) {
        $f = Get-ChildItem -Path (Join-Path $d 'src-*\scripts\nxn_merge.py') -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { return $f.FullName }
    }
    return $null
}
function Update-MergeOption {
    $ms = Get-MultiShell; $mg = Get-MergeScript
    $ui.Merge.IsEnabled = [bool]($ms -and $mg)
    $ui.Merge.ToolTip = if ($ms -and $mg) { "iPad 上只放一個「$libName」App：勾的遊戲都在裡面，取消勾選就拿掉（多遊戲殼 $($ms.BaseName)）" }
                        elseif (-not $ms) { '還沒有多遊戲殼：做好後放進 work\multigame 就能用' }
                        else { '找不到 nxn_merge.py：放在 nxn 資料夾或 work\multigame' }
    Update-ShellLabel
    Update-SelCount
}
# 上面的分頁：遊戲 / 合包。合包頁沒有底下的選項，動作都在卡片上
function Set-Tab {
    $packs = [bool]$ui.TabPacks.IsChecked
    $ui.Library.Visibility = if ($packs) { 'Collapsed' } else { 'Visible' }
    $ui.Packs.Visibility = if ($packs) { 'Visible' } else { 'Collapsed' }
    if (-not $state.Running -and $ui.ProgressView.Visibility -ne 'Visible') {
        $ui.Options.Visibility = if ($packs) { 'Hidden' } else { 'Visible' }
        $ui.Start.Visibility = if ($packs) { 'Collapsed' } else { 'Visible' }; $ui.Sync.Visibility = $ui.Start.Visibility
    }
}

# 續期：標題列的小按鈕，顯示最快幾天到期；3 天內變橘色。滑鼠移上去列出每一個
# 重簽：只簽遊戲庫一個 App，遊戲資料已經在 iPad 上，不會重傳
function Update-Banner($inst) {
    $ui.RenewBtn.Visibility = 'Collapsed'; return   # 重簽併進「同步」（App 換了或超過一天就順便重簽），剩幾天寫在底下那行
    $lib = Library-Ipa
    if (-not (Test-Path -LiteralPath $lib)) { $ui.RenewBtn.Visibility = 'Collapsed'; return }
    $mine = $inst | Where-Object { $_.Ipa -eq $lib } | Select-Object -First 1
    $ui.RenewBtn.Content = if (-not $mine) { '重簽' } elseif ($mine.Left -le 0) { '重簽（已過期）' } else { "重簽（剩 $($mine.Left) 天）" }
    $ui.RenewBtn.Foreground = Brush $(if ($mine -and $mine.Left -le 3) { '#FF9F0A' } else { '#EBEBF5' })
    $ui.RenewBtn.ToolTip = "免費 Apple ID 簽的 App 7 天後就打不開。按這裡把 iPad 上的遊戲庫重簽一次，遊戲和存檔都不動。"
    $ms = Get-MultiShell
    if ($ms -and (Shell-Changed $ms.FullName)) { $ui.RenewBtn.ToolTip += "`n換了新殼，這次會先用新殼重新合成遊戲庫再裝。" }
    elseif (Look-Changed) { $ui.RenewBtn.ToolTip += "`nApp 的名字或圖示換了，這次會先重新合成遊戲庫再裝。" }
    $ui.RenewBtn.Visibility = 'Visible'
}

# ---------------------------------------------------------------- 丟新檔：用 Windows 自己的複製（有進度視窗、不會卡住這裡），原檔不動
function Add-Files($dir, $paths) {
    $files = @($paths | Where-Object { $_ -match '\.(nsp|xci|nsz|xcz)$' -and (Test-Path -LiteralPath $_ -PathType Leaf) })
    if (-not $files.Count) { [void][Windows.MessageBox]::Show('只能加 .nsp、.xci、.nsz 或 .xcz 檔。', '加入遊戲檔'); return }
    $shell = New-Object -ComObject Shell.Application
    $ns = $shell.Namespace($dir)
    foreach ($f in $files) {
        if (Test-Path -LiteralPath (Join-Path $dir (Split-Path $f -Leaf))) { continue }
        $ns.CopyHere($f, 0)
    }
}
# ---------------------------------------------------------------- 存檔拖到遊戲卡
# 放進 <遊戲資料夾>\存檔待傳\（title ID 在 存檔待傳.txt），下次「同步」時 nxn.ps1 用 saves_data.py put 放進 iPad 上那款的存檔。
# 模擬器、JKSV、Checkpoint 匯出的存檔都是一般的檔案樹，殼原樣讀，只要找到真正的那一層：
#   Ryujinx  bis\user\save\<編號>\ 裡有 0\（存好的）、1\（暫存）和 ExtraData：用 0\
#   yuzu 系  nand\user\save\0000000000000000\<使用者>\<title ID>\：拖哪一層都行，有這款 title ID 的資料夾就往裡走
#   JKSV     JKSV\<遊戲名稱>\<使用者 - 日期>\；Checkpoint  saves\0x<title ID> <名稱>\<日期>\：好幾份就用最新的
function Import-SaveRoot($dir, $tid) {
    for ($i = 0; $i -lt 8; $i++) {
        $files = @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue)
        $subs = @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)
        $mine = if ($tid) { @($subs | Where-Object { $_.Name -match "(?i)(^|0x)$tid" }) } else { @() }
        if ($mine.Count -eq 1) { $dir = $mine[0].FullName; continue }
        $zero = @($subs | Where-Object { $_.Name -eq '0' })
        if ($zero.Count -and -not @($subs | Where-Object { $_.Name -notin '0', '1', '_' }).Count -and -not @($files | Where-Object { $_.Name -notmatch '^(ExtraData\d*|\.lock)$' }).Count) {
            $dir = $zero[0].FullName; $script:saveFrom = 'Ryujinx'; continue
        }
        if ($files.Count) { break }
        $dated = @($subs | Where-Object { $_.Name -match '\d{4}[-._]?\d{2}[-._]?\d{2}' })
        if ($subs.Count -gt 1 -and $dated.Count -eq $subs.Count) { $dir = ($subs | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName; $script:saveNewest = $true; continue }
        if ($subs.Count -ne 1 -or $subs[0].Name -notmatch '^(\d+|0x[0-9A-Fa-f]+.*|[0-9A-Fa-f]{16,32})$|\d{4}[-._]?\d{2}[-._]?\d{2}') { break }
        $dir = $subs[0].FullName
    }
    return $dir
}
function Import-Save($g, $paths) {
    $paths = @($paths | Where-Object { Test-Path -LiteralPath $_ })
    if (-not $paths.Count) { return }
    $tid = Game-Tid $g
    $script:saveNewest = $false; $script:saveFrom = ''
    $tmp = Join-Path $g.Dir ('.匯入存檔-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        if ($paths.Count -eq 1 -and $paths[0] -match '\.zip$') {
            $x = Join-Path $tmp 'x'
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [IO.Compression.ZipFile]::ExtractToDirectory($paths[0], $x)
            $src = Import-SaveRoot $x $tid
        } elseif ($paths.Count -eq 1 -and (Test-Path -LiteralPath $paths[0] -PathType Container)) {
            $src = Import-SaveRoot $paths[0] $tid
        } else {
            # 散的檔案（或好幾個資料夾）：拖進來的東西就是存檔的最上層
            $src = Join-Path $tmp 'x'
            New-Item -ItemType Directory -Force -Path $src | Out-Null
            foreach ($p in $paths) { Copy-Item -LiteralPath $p -Destination $src -Recurse -Force }
        }
        $all = @(Get-ChildItem -LiteralPath $src -Force)
        $files = @(Get-ChildItem -LiteralPath $src -File -Recurse -Force -ErrorAction SilentlyContinue)
        if (-not $files.Count) { [void][Windows.MessageBox]::Show($win, '拖進來的東西裡沒有檔案，不像存檔。', '匯入存檔'); return }
        # 好幾款遊戲的存檔資料夾（裡面全是 title ID）卻沒有這款：多半拖錯了
        if ($all.Count -gt 1 -and -not @($all | Where-Object { $_.Name -notmatch '^(0x)?[0-9A-Fa-f]{16}\b' }).Count) {
            [void][Windows.MessageBox]::Show($win, "這像是好幾款遊戲的存檔資料夾，裡面找不到「$($g.Name)」$(if ($tid) { "（$tid）" })的。`n`n請直接拖這款遊戲的那一個資料夾。", '匯入存檔'); return
        }
        $kb = [math]::Ceiling((($files | Measure-Object Length -Sum).Sum) / 1KB)
        $top = @($all | Select-Object -First 8 | ForEach-Object { if ($_.PSIsContainer) { "$($_.Name)\" } else { $_.Name } })
        $more = if ($all.Count -gt 8) { '、…' } else { '' }
        $notes = @()
        if ($script:saveFrom) { $notes += "（看起來是 $($script:saveFrom) 的存檔，用 0\ 那份）" }
        if ($script:saveNewest) { $notes += "（裡面有好幾份，用最新的：$(Split-Path $src -Leaf)）" }
        # 放進這款的「存檔」資料夾（和 iPad 雙向同步，saves_data.py sync）：下次「同步」時變成 iPad 上新的一份存檔，什麼都不蓋掉
        $syncDir = Join-Path $g.Dir '存檔'
        $label = '匯入' + $(if ($script:saveFrom) { " $($script:saveFrom)" } else { '' }) + ' ' + (Get-Date).ToString('MMdd-HHmm')
        $dest = Join-Path $syncDir $label; $k = 1
        while (Test-Path -LiteralPath $dest) { $k++; $dest = Join-Path $syncDir "$label ($k)" }
        $msg = "把這份存檔放進「$($g.Name)」？`n`n$($files.Count) 個檔案，共 $kb KB`n最上層：$($top -join '、')$more`n" + $(if ($notes.Count) { ($notes -join "`n") + "`n" } else { '' }) + "`n" +
               "會放進這款的「存檔」資料夾，叫「$(Split-Path $dest -Leaf)」。下次「同步」時，它會變成 iPad 上新的一份存檔（開遊戲前的「存檔」裡切換），iPad 上原本的存檔不會被蓋掉。"
        if ([Windows.MessageBox]::Show($win, $msg, '匯入存檔', 'OKCancel', 'Question') -ne 'OK') { return }
        # 先整份複製到暫存，再搬進去（拖進來的可能就是存檔資料夾裡的東西）
        $stage = Join-Path $tmp 'stage'
        New-Item -ItemType Directory -Force -Path $stage | Out-Null
        foreach ($c in $all) { Copy-Item -LiteralPath $c.FullName -Destination $stage -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $syncDir | Out-Null
        Move-Item -LiteralPath $stage -Destination $dest
        Build-Library
    } catch {
        [void][Windows.MessageBox]::Show($win, "匯入存檔失敗：$($_.Exception.Message)", '匯入存檔')
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
function New-GameFolder($file) {
    $leaf = [IO.Path]::GetFileNameWithoutExtension($file)
    $name = ($leaf -replace '\[[^\]]*\]', '' -replace '\([^)]*\)', '' -replace '\s+v?\d+(\.\d+)+.*$', '' -replace '[-_]+', ' ').Trim()
    if (-not $name) { $name = $leaf }
    $d = Join-Path $gamesDir $name
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}
# 拖到空白處：同一款（看檔名裡的 title ID）就放進原本的資料夾，不然新開一款
$win.Add_Drop({ param($s, $e)
    if (-not $e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { return }
    $byDir = @{}
    foreach ($f in @($e.Data.GetData([Windows.DataFormats]::FileDrop))) {
        if ($f -match '\.keys$') { Set-Keys $f; continue }
        if ($f -notmatch '\.(nsp|xci|nsz|xcz)$') { continue }
        $tid = if ((Split-Path $f -Leaf) -match '(?<![0-9A-Fa-f])(01[0-9A-Fa-f]{14})(?![0-9A-Fa-f])') { $Matches[1].ToUpper() } else { '' }
        $base = if ($tid) { $tid.Substring(0, 12) } else { '' }
        $target = $null
        if ($base) { foreach ($c in $cards.Values) { if ($c.Tag.Tid -and $c.Tag.Tid.Substring(0, 12) -eq $base) { $target = $c.Tag.Dir } } }
        if (-not $target) { $target = New-GameFolder $f }
        if (-not $byDir[$target]) { $byDir[$target] = @() }
        $byDir[$target] += $f
    }
    foreach ($k in $byDir.Keys) { Add-Files $k $byDir[$k] }
    Build-Library })
# 切回視窗時只有遊戲資料夾、遊戲庫或殼有變才重畫（每次都重畫一次要好幾秒，點視窗會像卡住）
# 兩秒內只看一次（在 PadSwitch 和別的視窗之間切來切去時不要每次都掃）
$lastActive = [datetime]::MinValue
$win.Add_Activated({
    if (((Get-Date) - $script:lastActive).TotalSeconds -lt 2) { return }
    $script:lastActive = Get-Date
    if (-not $state.Running -and $script:libStamp -and (Library-Stamp) -ne $script:libStamp) { Build-Library } })

# ---------------------------------------------------------------- Apple ID
# plumesign 在背景問，答案回來才更新右上角（直接跑會讓畫面停一兩秒）
$acctJob = @{ Proc = $null }
function Update-Account {
    if (-not (Test-Path $plume)) { $ui.Account.Text = '找不到 plumesign.exe'; return }
    if ($acctJob.Proc -and -not $acctJob.Proc.HasExited) { return }
    try {
        $psi = New-Object Diagnostics.ProcessStartInfo $plume
        $psi.Arguments = 'account list'
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $acctJob.Proc = [Diagnostics.Process]::Start($psi)
        $acctJob.Out = $acctJob.Proc.StandardOutput.ReadToEndAsync(); $acctJob.Err = $acctJob.Proc.StandardError.ReadToEndAsync()
        if ($ui.Account.Text -eq '' -or $ui.Account.Text -eq '…') { $ui.Account.Text = '…' }
        $acctTimer.Start()
    } catch { $ui.Account.Text = '無法確認 Apple ID' }
}
$acctTimer = New-Object Windows.Threading.DispatcherTimer
$acctTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$acctTimer.Add_Tick({
    if ($acctJob.Proc -and -not $acctJob.Proc.HasExited) { return }
    $acctTimer.Stop()
    if (-not $acctJob.Proc) { return }
    $acctJob.Proc = $null
    try { Show-Account ("$($acctJob.Out.Result)`n$($acctJob.Err.Result)") } catch { $ui.Account.Text = '無法確認 Apple ID' } })
function Show-Account($out) {
    try {
        $mail = [regex]::Match($out, '[\w.+-]+@[\w-]+(\.[\w-]+)+').Value
        if ($mail) { $ui.Account.Text = $mail; $ui.Account.Foreground = Brush '#C7C7CC'; $ui.AcctDot.Fill = Brush '#30D158'; $ui.Login.Content = '換帳號' }
        else { $ui.Account.Text = '還沒登入 Apple ID'; $ui.AcctDot.Fill = Brush '#FF453A'; $ui.Login.Content = '登入 Apple ID' }
    } catch { $ui.Account.Text = '無法確認 Apple ID' }
}
# 在 app 裡登入：plumesign 在背景跑，密碼和雙重驗證碼從它的標準輸入餵進去（不放在命令列上），輸出寫進檔案再輪詢
function Show-Login {
    $lx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="420" SizeToContent="Height" Background="#141416" Foreground="#F5F5F7" ResizeMode="NoResize"
        FontFamily="Segoe UI, Microsoft JhengHei UI" FontSize="14" WindowStartupLocation="CenterOwner" Title="Apple ID">
  <Window.Resources>__RES__</Window.Resources>
  <StackPanel Margin="22">
    <TextBlock Text="登入 Apple ID" FontSize="22" FontWeight="Bold" Margin="0,0,0,14"/>
    <TextBlock x:Name="UserLbl" Text="Apple ID" Foreground="#8E8E93" Margin="0,0,0,4"/>
    <TextBox x:Name="User" Background="#2C2C2E" Foreground="White" BorderThickness="0" Padding="8,6" FontSize="16" CaretBrush="White"/>
    <TextBlock x:Name="PassLbl" Text="密碼" Foreground="#8E8E93" Margin="0,12,0,4"/>
    <PasswordBox x:Name="Pass" Background="#2C2C2E" Foreground="White" BorderThickness="0" Padding="8,6" FontSize="16" CaretBrush="White"/>
    <TextBlock x:Name="CodeLbl" Text="驗證碼（看 iPad 或 iPhone 上跳出的 6 位數）" Foreground="#8E8E93" Margin="0,12,0,4" Visibility="Collapsed"/>
    <TextBox x:Name="Code" Background="#2C2C2E" Foreground="White" BorderThickness="0" Padding="8,6" FontSize="20" CaretBrush="White" Visibility="Collapsed"/>
    <TextBlock x:Name="Status" Foreground="#8E8E93" TextWrapping="Wrap" Margin="0,12,0,0"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
      <Button x:Name="Cancel" Content="取消" IsCancel="True" Margin="0,0,8,0"/>
      <Button x:Name="Ok" Content="登入" Style="{StaticResource Primary}" IsDefault="True"/>
    </StackPanel>
  </StackPanel>
</Window>
'@
    $lw = Load-Window $lx
    $lw.Owner = $win
    $f = @{}; foreach ($n in 'User','Pass','UserLbl','PassLbl','CodeLbl','Code','Status','Ok','Cancel') { $f[$n] = $lw.FindName($n) }
    $st = @{ Proc = $null; Log = Join-Path $work 'login.log'; Asked = $false; Done = $false }
    $send = { param($line)
        $b = [Text.Encoding]::UTF8.GetBytes($line + "`n")
        $st.Proc.StandardInput.BaseStream.Write($b, 0, $b.Length); $st.Proc.StandardInput.BaseStream.Flush() }
    $lt = New-Object Windows.Threading.DispatcherTimer
    $lt.Interval = [TimeSpan]::FromMilliseconds(400)
    $lt.Add_Tick({
        $txt = ''
        try { $fs = New-Object IO.FileStream($st.Log, 'Open', 'Read', 'ReadWrite'); $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8); $txt = $sr.ReadToEnd(); $sr.Dispose() } catch { }
        if (-not $st.Asked -and $txt -match '(?i)enter (the )?(2fa )?code') {
            $st.Asked = $true
            $f.CodeLbl.Visibility = 'Visible'; $f.Code.Visibility = 'Visible'; $f.Code.Text = ''
            $f.Ok.Content = '送出'; $f.Ok.IsEnabled = $true
            $f.Status.Text = ''
            $f.Code.Focus() | Out-Null
        }
        if ($st.Proc.HasExited) {
            $lt.Stop()
            if ($st.Proc.ExitCode -eq 0) { $st.Done = $true; $lw.DialogResult = $true; return }
            $last = @($txt -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 3
            $f.Status.Text = "登入失敗：$(($last -join ' ').Trim())"
            $f.Status.Foreground = Brush '#FF453A'
            $f.User.IsEnabled = $true; $f.Pass.IsEnabled = $true
            $f.CodeLbl.Visibility = 'Collapsed'; $f.Code.Visibility = 'Collapsed'
            $f.Ok.Content = '登入'; $f.Ok.IsEnabled = $true; $st.Proc = $null; $st.Asked = $false
        }
    })
    $f.Ok.Add_Click({
        if ($st.Proc -and $st.Asked) {
            $c = $f.Code.Text.Trim()
            if (-not $c) { return }
            & $send $c
            $f.Ok.IsEnabled = $false; $f.Status.Foreground = Brush '#8E8E93'; $f.Status.Text = '確認驗證碼…'
            return
        }
        $u = $f.User.Text.Trim(); $pw = $f.Pass.Password
        if (-not $u -or -not $pw) { $f.Status.Text = '請輸入 Apple ID 和密碼'; return }
        Remove-Item -LiteralPath $st.Log -ErrorAction SilentlyContinue
        $psi = New-Object Diagnostics.ProcessStartInfo 'cmd.exe'
        $psi.Arguments = "/d /c `"`"$plume`" account login --username `"$($u -replace '"', '')`" > `"$($st.Log)`" 2>&1`""
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardInput = $true
        $psi.EnvironmentVariables['RUST_LOG'] = 'info'
        $st.Proc = [Diagnostics.Process]::Start($psi)
        # plumesign 先問密碼（沒給 --password 時從標準輸入讀一行）
        & $send $pw
        $f.User.IsEnabled = $false; $f.Pass.IsEnabled = $false; $f.Ok.IsEnabled = $false
        $f.Status.Foreground = Brush '#8E8E93'; $f.Status.Text = '登入中…'
        $lt.Start()
    })
    $lw.Add_Closed({ $lt.Stop(); if ($st.Proc -and -not $st.Proc.HasExited) { try { $st.Proc.Kill() } catch { } }
                     Remove-Item -LiteralPath $st.Log -ErrorAction SilentlyContinue })
    $lw.Add_ContentRendered({ $f.User.Focus() | Out-Null })
    [void]$lw.ShowDialog()
    if ($st.Done) { Update-Account }
}
$ui.Login.Add_Click({ Show-Login })
# 一打開就勾好遊戲庫裡現有的遊戲（Select-Library 會畫卡片）
$win.Add_ContentRendered({
    Mark '視窗出現'
    # 先讓「載入遊戲中…」畫出來，再排卡片
    [void]$win.Dispatcher.BeginInvoke([Action]{
        try { Select-Library } catch { }
        Mark '畫遊戲庫'
        foreach ($k in @($blTimes.Keys)) { $startMarks.Add(('  {0} {1:N1}s' -f $k, ($blTimes[$k] / 1000.0))) }
        Update-Account; Check-Updates; Tidy-Folders
        Mark '其他'
        Flush-Marks '開啟'
    }, [Windows.Threading.DispatcherPriority]::Background) })

# ---------------------------------------------------------------- 執行：一次一款，每款一個進度列
$jobXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        CornerRadius="16" Background="#1C1C1E" Margin="0,0,0,10" Padding="16">
  <DockPanel>
    <Border x:Name="Icon" DockPanel.Dock="Left" Width="60" Height="60" CornerRadius="14" Background="#2C2C2E" VerticalAlignment="Top">
      <TextBlock x:Name="Letter" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="28" FontWeight="Bold" Foreground="White"/>
    </Border>
    <StackPanel Margin="16,0,0,0">
      <DockPanel>
        <TextBlock x:Name="Time" DockPanel.Dock="Right" Foreground="#8E8E93" FontSize="12.5"/>
        <Button x:Name="Drop" DockPanel.Dock="Right" Content="取消排隊" Padding="10,2" Margin="0,0,10,0" FontSize="12" VerticalAlignment="Center" ToolTip="還沒輪到它：從隊伍拿掉，不轉這一款"/>
        <TextBlock x:Name="Title" FontSize="17" FontWeight="SemiBold" Foreground="White" TextTrimming="CharacterEllipsis"/>
      </DockPanel>
      <WrapPanel x:Name="Steps" Margin="0,10,0,0"/>
      <Border x:Name="JTrack" Height="4" CornerRadius="2" Background="#2C2C2E" Margin="0,4,0,0" Visibility="Collapsed">
        <Border x:Name="JFill" HorizontalAlignment="Left" Width="0" CornerRadius="2" Background="#0A84FF"/>
      </Border>
      <TextBlock x:Name="Live" FontSize="12.5" Foreground="#C7C7CC" Margin="0,6,0,0" TextTrimming="CharacterEllipsis" Visibility="Collapsed"/>
      <TextBlock x:Name="Msg" Foreground="#8E8E93" FontSize="12" Margin="0,8,0,0" TextTrimming="CharacterEllipsis"/>
      <StackPanel x:Name="Items" Margin="0,8,0,0" Visibility="Collapsed"/>
      <Expander x:Name="Exp" Header="記錄" Foreground="#8E8E93" Margin="0,6,0,0">
        <TextBox x:Name="Log" Height="240" IsReadOnly="True" FontFamily="Consolas, Microsoft JhengHei UI" FontSize="12"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap"
                 Background="#000000" Foreground="#D1D1D6" BorderThickness="0" Margin="0,6,0,0"/>
      </Expander>
    </StackPanel>
  </DockPanel>
</Border>
'@
# 每一步看記錄裡的哪句話算開始
$stepDefs = @(
    @{ Name = '檢查帳號'; Re = '==> 檢查 Apple ID' },
    @{ Name = '解包';     Re = 'extracting v|reusing the extracted' },
    @{ Name = '轉換程式'; Re = 'rewriting main|rewritten modules already' },
    @{ Name = '著色器';   Re = 'translating shaders|shader split|shader libraries|no shader library|Vulkan shaders|GL shaders' },
    @{ Name = '打包';     Re = 'packing the IPA' },
    @{ Name = '準備合包'; Re = 'packing the IPA' },
    @{ Name = '簽章安裝'; Re = '==> 簽章並安裝' },
    @{ Name = '傳資料';   Re = '==> 傳遊戲資料' },
    @{ Name = '存檔';     Re = '==> (備份 iPad|還原 iPad|搬舊 App) 存檔' },
    @{ Name = '記錄';     Re = '==> 讀 iPad 記錄' },
    @{ Name = '拿回著色器'; Re = '==> 拿回 iPad 記下的著色器' },
    @{ Name = '連接 iPad'; Re = '==> 連接 iPad' },
    @{ Name = '備份存檔'; Re = '==> 備份 iPad 存檔' },
    @{ Name = '騰出空間'; Re = '==> 先刪掉 iPad 上拿掉的遊戲' },
    @{ Name = '重簽';     Re = '==> (簽章並安裝|重簽)' },
    @{ Name = '存檔同步'; Re = '==> (把存檔放進 iPad|和電腦的存檔資料夾)' },
    @{ Name = '著色器紀錄'; Re = '==> 拿回 iPad 記下的著色器' },
    @{ Name = '合成';     Re = '==> 合成一包' },
    @{ Name = 'Python';   Re = '==> 檢查 Python' },
    @{ Name = '套件';     Re = '==> 安裝 Python 套件' },
    @{ Name = '打包器';   Re = '==> 檢查打包器' },
    @{ Name = '簽章工具'; Re = '==> 檢查簽章工具' },
    @{ Name = 'PadSwitch'; Re = '==> 檢查 PadSwitch' }
)
function Set-Step($job, $idx, $how) {
    for ($i = 0; $i -lt $job.Steps.Count; $i++) {
        $pill = $job.Steps[$i]; $tb = $pill.Child; $name = $job.StepNames[$i]
        $s = if ($i -lt $idx) { 'done' } elseif ($i -eq $idx) { $how } else { 'todo' }
        switch ($s) {
            'done'   { $pill.Background = Brush '#1E3A26'; $tb.Foreground = Brush '#30D158'; $tb.Text = "✓ $name" }
            'active' { $pill.Background = Brush '#0A84FF'; $tb.Foreground = Brush '#FFFFFF'; $tb.Text = "● $name" }
            'fail'   { $pill.Background = Brush '#3A1E1E'; $tb.Foreground = Brush '#FF453A'; $tb.Text = "✕ $name" }
            default  { $pill.Background = Brush '#2C2C2E'; $tb.Foreground = Brush '#8E8E93'; $tb.Text = $name }
        }
    }
    $job.Cur = $idx
}

$addFail = @{}   # 這次開著時打包失敗的遊戲 → 原因，卡片上標紅字
$state = @{ Queue = New-Object System.Collections.Queue; Job = $null; Proc = $null; Running = $false; Ok = 0; Fail = @(); Started = $null; All = @(); Title = '' }
# ---------------------------------------------------------------- 進度和剩餘時間
# 每一步排進來時先估要多久（Job-Est）：轉檔用這款上次花的時間（nxn.ps1 記在 work\status\pack-times.json），合成、同步用上次做同樣的事花多久
# （work\status\step-times.json），傳資料用要傳的大小除以上次的速度。做的時候看那一步的進度狀態檔（run-/push-*.json，用 NXN_JOB 認出是哪一步）
# 修正：傳 iPad 時用真的百分比和速度，轉檔用已經花的時間對上次花的時間。整體百分比＝每步的預估時間加權
$stepTimesFile = Join-Path $work 'status\step-times.json'
function Step-Time($k, $def) {
    try { $v = ([IO.File]::ReadAllText($stepTimesFile) | ConvertFrom-Json).$k; if ($v -and [double]$v -gt 0) { return [double]$v } } catch { }
    return [double]$def
}
function Set-StepTime($k, $v) {
    try {
        $t = [ordered]@{}
        try { ([IO.File]::ReadAllText($stepTimesFile) | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $t[$_.Name] = $_.Value } } catch { }
        $old = if ($t.Contains($k)) { [double]$t[$k] } else { 0 }
        $t[$k] = if ($old -gt 0) { [math]::Round($old * 0.4 + [double]$v * 0.6, 1) } else { [math]::Round([double]$v, 1) }   # 偏向最近一次
        New-Item -ItemType Directory -Force -Path (Split-Path $stepTimesFile) | Out-Null
        [IO.File]::WriteAllText($stepTimesFile, ($t | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding $false))
    } catch { }
}
function Job-Est($g, $mode, $ipa) {
    switch ($mode) {
        'mergepart' {
            $t = Pack-Times
            if ($g -and $t.ContainsKey($g.Name)) { return [double]$t[$g.Name] }
            $known = @($t.Values | Where-Object { $_ -gt 60 })
            if ($known.Count) { return [double](($known | Measure-Object -Average).Average) }
            return 900.0
        }
        'mergepart-reuse' { return 60.0 }
        'merge'  { return Step-Time 'merge' 90 }
        'sync'   { return Step-Time 'syncBase' 150 }
        'glsync' { return Step-Time 'glsync' 40 }
        'setup'  { return 180.0 }
        default  { return 60.0 }
    }
}
function Save-StepTime($job) {
    if (-not $job.Started) { return }
    $dur = ((Get-Date) - $job.Started).TotalSeconds
    switch ($job.Mode) {
        'merge'  { Set-StepTime 'merge' $dur }
        'glsync' { Set-StepTime 'glsync' $dur }
        'sync' {
            $p = $job.Push
            $pd = 0
            if ($p -and [double]$p.total -gt 0 -and $p.started -and $p.ended) {
                $pd = ((To-Date $p.ended) - (To-Date $p.started)).TotalSeconds
                if ($p.rate -and [double]$p.rate -gt 0) { Set-StepTime 'pushRate' ([double]$p.rate) }
                elseif ($pd -gt 5) { Set-StepTime 'pushRate' ([double]$p.total / $pd) }
            }
            Set-StepTime 'syncBase' ([math]::Max(30, $dur - $pd))
        }
    }
}
# 找這一步的進度狀態檔（兩秒找一次，找到就記著）
function Find-JobStatus($job, $kind) {
    $now = Get-Date
    if (($now - $job.PushSeen).TotalSeconds -lt 2) { return }
    $job.PushSeen = $now
    foreach ($f in Get-ChildItem -LiteralPath $statusDir -Filter "$kind-*.json" -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $job.Started.AddSeconds(-5) }) {
        try { $j = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json } catch { continue }
        if ($j.job -eq $job.Id) { if ($kind -eq 'run') { $job.RunFile = $f.FullName } else { $job.PushFile = $f.FullName }; return }
    }
}
function Read-Json($f) { if (-not $f) { return $null }; try { [IO.File]::ReadAllText($f) | ConvertFrom-Json } catch { $null } }
function Update-JobProgress($job) {
    $now = Get-Date
    $el = ($now - $job.Started).TotalSeconds
    if (-not $job.RunFile) { Find-JobStatus $job 'run' }
    if ($job.Mode -eq 'sync' -and -not $job.PushFile) { $job.PushSeen = [datetime]::MinValue; Find-JobStatus $job 'push' }
    $r = Read-Json $job.RunFile; if ($r) { $job.RunSt = $r }
    $p = Read-Json $job.PushFile; if ($p) { $job.Push = $p }
    $est = [math]::Max(10, $job.Est)
    $left = if ($el -lt $est * 0.9) { $est - $el } else { [math]::Max(20, $est * 0.1) }   # 超過上次的時間：說「快好了」，不倒數成負的
    $extra = ''
    if ($job.Mode -eq 'sync' -and $p -and $p.state -eq 'running') {
        $tot = [double]$p.total; $sent = [double]$p.sent
        if ($tot -gt 0) {
            $rate = if ($p.rate) { [double]$p.rate } else { Step-Time 'pushRate' (12MB) }
            $pl = if ($p.eta) { [double]$p.eta } else { ($tot - $sent) / [math]::Max(1, $rate) }
            $left = $pl + 40   # 傳完還有存檔和著色器
            $extra = "傳到 iPad $([math]::Floor($sent * 100 / $tot))% · $(Fmt-Size $sent) / $(Fmt-Size $tot)" + $(if ($p.rate) { ' · {0:N0} MB/s' -f ([double]$p.rate / 1MB) })
            if ("$($p.phase)" -like '從 NSP*') { $extra += " · $($p.phase)" } elseif ($p.game) { $extra += " · 正在傳 $($p.game)" }
        } else { $extra = [string]$p.phase }
    } elseif ($job.Mode -eq 'sync' -and $p -and $p.state -eq 'done') { $left = [math]::Max(15, [math]::Min($left, 60)) }
    elseif ($job.RunSt -and $job.RunSt.phase -and $job.Mode -like 'mergepart*') { $extra = "$($job.RunSt.phase)" }
    $job.Left = $left
    $job.Frac = [math]::Min(0.99, $el / [math]::Max(1, $el + $left))
    $tr = $job.Row.FindName('JTrack'); $fill = $job.Row.FindName('JFill')
    $fill.Width = [math]::Max(0, $tr.ActualWidth * $job.Frac)
    $job.Time.Text = "已 $(Fmt-Dur $el) · 剩約 $(Fmt-Dur $left)"
    $lv = $job.Row.FindName('Live'); $lv.Text = $extra; $lv.Visibility = if ($extra) { 'Visible' } else { 'Collapsed' }
    if ($job.Mode -eq 'sync' -and $p -and (($now - $job.ItemsAt).TotalMilliseconds -ge 900)) { $job.ItemsAt = $now; Show-PushItems $job $p }
}
# 傳到 iPad 的每一款：已先刪掉的、傳好的、正在傳的（GB）、還沒輪到的
function Show-PushItems($job, $p) {
    $box = $job.Row.FindName('Items'); $box.Children.Clear()
    $add = { param($glyph, $color, $text, $right)
        $d = New-Object Windows.Controls.DockPanel; $d.Margin = '0,0,0,3'
        $r = New-Object Windows.Controls.TextBlock; $r.Text = $right; $r.FontSize = 12; $r.Foreground = Brush '#8E8E93'; [Windows.Controls.DockPanel]::SetDock($r, 'Right'); [void]$d.Children.Add($r)
        $g = New-Object Windows.Controls.TextBlock; $g.Text = $glyph; $g.Width = 18; $g.FontSize = 12; $g.Foreground = Brush $color; [Windows.Controls.DockPanel]::SetDock($g, 'Left'); [void]$d.Children.Add($g)
        $t = New-Object Windows.Controls.TextBlock; $t.Text = $text; $t.FontSize = 12.5; $t.TextTrimming = 'CharacterEllipsis'; [void]$d.Children.Add($t)
        [void]$box.Children.Add($d) }
    $gone = @($p.removed | ForEach-Object { $t = if ("$_" -match 'games/([0-9A-Fa-f]{16})') { $Matches[1].ToUpper() } else { "$_" }; $c = @($cards.Values | Where-Object { (Game-Tid $_.Tag) -eq $t }) | Select-Object -First 1; if ($c) { $c.Tag.Name } else { $t } } | Select-Object -Unique)
    if ($gone.Count) { & $add '−' '#FF9F0A' "先刪掉 $($gone -join '、')，騰出空間" '' }
    foreach ($it in @($p.items)) {
        $b = [double]$it.bytes; $sn = [double]$it.sent
        switch ($it.state) {
            'done'    { & $add '✓' '#30D158' $it.name (Fmt-Size $b) }
            'running' { & $add '●' '#0A84FF' $it.name "$(Fmt-Size $sn) / $(Fmt-Size $b)" }
            default   { & $add '○' '#8E8E93' $it.name (Fmt-Size $b) }
        }
    }
    $box.Visibility = if ($box.Children.Count) { 'Visible' } else { 'Collapsed' }
}
# 整體：上面那條和「剩約 X 分（約 HH:mm 完成）」
function Update-Overall {
    $all = @($state.All)
    if (-not $all.Count) { return }
    $tot = 0.0; $done = 0.0; $left = 0.0; $i = 0; $curName = ''
    foreach ($j in $all) {
        $e = [math]::Max(10, [double]$j.Est); $tot += $e
        if ($j.Done) { $done += $e }
        elseif ($state.Job -eq $j) { $done += $e * $j.Frac; $left += $(if ($null -ne $j.Left) { $j.Left } else { $e }); $i = [array]::IndexOf($all, $j) + 1; $curName = $j.Row.FindName('Title').Text }
        else { $left += $e }
    }
    $pct = if (-not $state.Running) { 1.0 } elseif ($tot -gt 0) { [math]::Min(0.99, $done / $tot) } else { 0 }
    $ui.AllFill.Width = [math]::Max(0, $ui.AllTrack.ActualWidth * $pct)
    $ui.AllFill.Background = Brush $(if (-not $state.Running -and $state.Fail.Count) { '#FF9F0A' } elseif (-not $state.Running) { '#30D158' } else { '#0A84FF' })
    if ($state.Running) {
        $ui.AllPct.Text = "第 $i / $($all.Count) 步：$curName · $([math]::Floor($pct * 100))%"
        $ui.AllEta.Text = "剩約 $(Fmt-Dur $left)（約 $((Get-Date).AddSeconds($left).ToString('HH:mm')) 完成）"
        $ui.ProgTotal.Text = "已經 $(Fmt-Dur ((Get-Date) - $state.Started).TotalSeconds)"
    } else {
        $ui.AllPct.Text = "$($all.Count) 步做完了" + $(if ($state.Fail.Count) { "，$($state.Fail.Count) 步失敗" } else { '' })
        $ui.AllEta.Text = "共花了 $(Fmt-Dur ((Get-Date) - $state.Started).TotalSeconds)"
        $ui.ProgTotal.Text = ''
    }
    foreach ($j in $all) { if ($j.Done) { $tr = $j.Row.FindName('JTrack'); $f = $j.Row.FindName('JFill'); $f.Width = $tr.ActualWidth; $j.Row.FindName('Live').Visibility = 'Collapsed'
        if ($j.Started -and $j.Ended) { $j.Time.Text = "花了 $(Fmt-Dur ($j.Ended - $j.Started).TotalSeconds)" } } }
}
# 同步做完的摘要（從記錄和傳資料的狀態檔）
function Sync-Summary($job) {
    $log = $job.Text.Text
    $parts = @()
    $p = $job.Push
    if ($p -and @($p.removed).Count) { $parts += "先刪掉 $(@($p.removed | ForEach-Object { if ("$_" -match 'games/([0-9A-Fa-f]{16})') { $Matches[1] } } | Select-Object -Unique).Count) 款" }
    if ($p -and [double]$p.total -gt 0) { $parts += "傳了 $(@($p.items | ForEach-Object { if ("$($_.dir)" -match 'games/([0-9A-Fa-f]{16})') { $Matches[1] } } | Select-Object -Unique).Count) 款 $(Fmt-Size $p.total)" }
    elseif ($p) { $parts += '遊戲資料本來就在 iPad 上' }
    $sv = ([regex]::Matches($log, '存檔放好了')).Count
    if ($sv) { $parts += "放進 $sv 份存檔" }
    $parts += '存檔雙向同步'
    $sh = ([regex]::Matches($log, '著色器紀錄｜[^\r\n]*新拿回')).Count
    if ($sh) { $parts += "$sh 款拿回新的著色器紀錄" }
    $m = [regex]::Match($log, '還能用 ([\d.]+) 天')
    if ($log -match '==> 簽章並安裝') { $parts += '重簽好了（7 天）' } elseif ($m.Success) { $parts += "不用重簽（還能用 $($m.Groups[1].Value) 天）" }
    if ($log -match '存檔同步沒做完|存檔沒放進去') { $parts += '有存檔沒同步完，看記錄' }
    Show-ShaderLines $job
    '同步好了：' + ($parts -join '、')
}
function Gl-Summary($job) {
    Show-ShaderLines $job
    $n = ([regex]::Matches($job.Text.Text, '著色器紀錄｜[^\r\n]*新拿回')).Count
    if ($n) { "$n 款拿回新的著色器紀錄，接著重新轉檔把它們加進去" } else { '著色器紀錄拿回來了（沒有新的）' }
}
# 著色器紀錄：每款一行，寫清楚是哪款、哪種著色器、記下幾個、這次拿回幾個
function Show-ShaderLines($job) {
    $box = $job.Row.FindName('Items')
    foreach ($m in [regex]::Matches($job.Text.Text, '著色器紀錄｜([^｜\r\n]+)｜([^\r\n]+)')) {
        $who = $m.Groups[1].Value.Trim() -replace '（[0-9A-Fa-f]{16}）$', ''
        $what = $m.Groups[2].Value.Trim()
        $new = $what -match '新拿回'
        $d = New-Object Windows.Controls.DockPanel; $d.Margin = '0,0,0,3'
        $g = New-Object Windows.Controls.TextBlock; $g.Text = '◆'; $g.Width = 18; $g.FontSize = 11; $g.Foreground = Brush $(if ($new) { '#BF5AF2' } else { '#8E8E93' }); [Windows.Controls.DockPanel]::SetDock($g, 'Left'); [void]$d.Children.Add($g)
        $t = New-Object Windows.Controls.TextBlock; $t.FontSize = 12.5; $t.TextWrapping = 'Wrap'
        $r1 = New-Object Windows.Documents.Run $who; $r1.FontWeight = 'SemiBold'
        $r2 = New-Object Windows.Documents.Run "  $what"; $r2.Foreground = Brush '#AEAEB2'
        $t.Inlines.Add($r1); $t.Inlines.Add($r2); [void]$d.Children.Add($t)
        [void]$box.Children.Add($d)
    }
    if ($box.Children.Count) { $box.Visibility = 'Visible' }
}


function Quote($s) { "'" + ($s -replace "'", "''") + "'" }

function New-Job($g, $mode, $ipa, $out = '', $shellPath = '') {
    $row = [Windows.Markup.XamlReader]::Parse($jobXaml)
    $row.FindName('Title').Text = switch ($mode) {
        'glsync' { '拿回 iPad 記下的著色器' + $(if ($g.PSObject.Properties['GlNames'] -and $g.GlNames) { "（$($g.GlNames)）" }) }
        'report' { "$($g.Name) · 匯出問題回報" }
        'sync'   { '同步到 iPad' }
        'merge'  { '合成遊戲庫' }
        { $_ -in 'mergepart', 'mergepart-reuse' } { "轉檔：$($g.Name)" }
        default  { $g.Name } }
    Paint-Icon $row.FindName('Icon') $row.FindName('Letter') $g (Cover-For $g)
    # @(...)：只有一個步驟時 switch 會把陣列攤成一個字串，$names[0] 就只剩第一個字（「同步」變「同」）
    $names = @(switch ($mode) {
        'setup'   { @('Python', '套件', '打包器', '簽章工具', 'PadSwitch') }
        'pack'    { @('解包', '轉換程式', '著色器', '打包') }
        { $_ -in 'mergepart', 'mergepart-reuse' } { @('解包', '轉換程式', '著色器', '準備合包') }
        'glsync'  { @('拿回著色器') }
        'merge'   { @('合成') }
        'sync'    { @('連接 iPad', '備份存檔', '騰出空間', '重簽', '傳資料', '存檔同步', '著色器紀錄') }
        'merge+install' { @('合成', '檢查帳號', '簽章安裝', '傳資料') }
        'install' { @('檢查帳號', '簽章安裝', '傳資料') }
        { $_ -in 'savebackup', 'saverestore', 'savemigrate' } { @('存檔') }
        { $_ -in 'pulllogs', 'report' } { @('記錄') }
        default   { @('檢查帳號', '解包', '轉換程式', '著色器', '打包', '簽章安裝', '傳資料') }
    })
    $pills = @()
    foreach ($n in $names) {
        $p = New-Object Windows.Controls.Border
        $p.CornerRadius = '10'; $p.Padding = '11,4'; $p.Margin = '0,0,6,6'
        $t = New-Object Windows.Controls.TextBlock; $t.FontSize = 12
        $p.Child = $t
        [void]$row.FindName('Steps').Children.Add($p)
        $pills += $p
    }
    $a = @()
    switch ($mode) {
        'install' { $a += @('-Ipa', (Quote $ipa)) }
        'savebackup'  { $a += @('-Ipa', (Quote $ipa), '-SaveBackup') }
        'saverestore' { $a += @('-Ipa', (Quote $ipa), '-SaveRestore', (Quote $out)) }
        'savemigrate' { $a += @('-Ipa', (Quote $ipa), '-SaveMigrate') }
        'pulllogs'    { $a += @('-Ipa', (Quote $ipa), '-PullLogs') }
        'report'      { $a += @('-Ipa', (Quote $ipa), '-PullLogs', '-ReportTid', $g.Tid, '-ReportZip', (Quote $out), '-ReportExtra', (Quote $shellPath)) }   # Shell 欄位這裡放電腦這邊要附上的檔案的資料夾
        'glsync'      { $a += @('-Ipa', (Quote $ipa), '-GlSync') }
        'sync'        { $a += @('-Ipa', (Quote $ipa), '-SignIfNeeded'); if ($out) { $a += @('-OrderFile', (Quote $out)) } }
        { $_ -in 'merge', 'merge+install', 'setup' } { }   # 這幾種只跑 Call；mergepart 是一般打包，要走下面
        default {
            $a += @('-GameDir', (Quote $g.Dir))
            if ($mode -in 'pack', 'mergepart', 'mergepart-reuse') { $a += '-PackOnly' }
            if ($mode -eq 'mergepart-reuse') { $a += '-ReuseIfFresh' }
            if ($cfg.Overwrite) { $a += '-Overwrite' }
            if ($shellPath) { $a += @('-Shell', (Quote $shellPath)) }
            else { $sh = Current-Shell; if ($sh) { $a += @('-Shell', (Quote $sh.Path)) } }
            if ($out) { $a += @('-Out', (Quote $out)) }
        }
    }
    if ($cfg.Udid) { $a += @('-Udid', (Quote $cfg.Udid)) }
    $job = [pscustomobject]@{ Game = $g; Row = $row; Steps = $pills; StepNames = $names; Args = $a; Call = ''; NeedAllOk = $false; Log = ''; Pos = 0L; LogLine = ''; Report = $(if ($mode -eq 'report') { $out } else { '' }); Dec = $null
                             Started = $null; Cur = -1; Text = $row.FindName('Log'); Msg = $row.FindName('Msg'); Time = $row.FindName('Time')
                             Mode = $mode; Id = [guid]::NewGuid().ToString('N').Substring(0, 12); Est = (Job-Est $g $mode $ipa); Done = $false; Ended = $null
                             Frac = 0.0; Left = $null; RunFile = $null; PushFile = $null; PushSeen = [datetime]::MinValue; Push = $null; RunSt = $null; ItemsAt = [datetime]::MinValue }
    Set-Step $job -1 'todo'
    $job.Msg.Text = '排隊中'
    $drop = $row.FindName('Drop'); $drop.Tag = $job
    $drop.Add_Click({ param($s, $e) Drop-Queued $s.Tag })
    [void]$ui.Jobs.Children.Add($row)
    return $job
}

# 還沒輪到的工作從隊伍拿掉（正在做的不能用這個停，要按「停止」）
function Drop-Queued($job) {
    if ($state.Job -eq $job) { return }
    $keep = @($state.Queue | Where-Object { $_ -ne $job })
    if ($keep.Count -eq $state.Queue.Count) { return }
    $state.Queue.Clear(); foreach ($k in $keep) { $state.Queue.Enqueue($k) }
    [void]$ui.Jobs.Children.Remove($job.Row)
    if ($ui.ShowProg.Visibility -eq 'Visible') { $ui.ShowProg.Content = "查看進度（$($state.Queue.Count + 1)）" }
    if ($ui.LibraryView.Visibility -eq 'Visible') { Build-Library }
}
# 正在做和排隊中的遊戲資料夾
function Busy-Dirs { @(@($(if ($state.Job) { $state.Job.Game.Dir })) + @($state.Queue | ForEach-Object { $_.Game.Dir }) | Where-Object { $_ }) }
function Add-Jobs($jobs) {
    foreach ($j in $jobs) {
        $nj = New-Job $j.Game $j.Mode $j.Ipa $j.Out $j.Shell
        if ($j.PushBytes) { $nj.Est += [double]$j.PushBytes / (Step-Time 'pushRate' (12MB)) }
        if ($j.Lib) { $nj | Add-Member -NotePropertyName Lib -NotePropertyValue $j.Lib -Force }
        elseif ($j.Call) { $nj.Call = $j.Call; $nj.NeedAllOk = $true }
        $state.Queue.Enqueue($nj)
        $state.All += $nj
    }
}
function Show-Progress {
    if ($ui.ProgressView.Visibility -ne 'Visible') { Fade-In $ui.ProgressView }
    $ui.LibraryView.Visibility = 'Collapsed'; $ui.ProgressView.Visibility = 'Visible'; $ui.RenewBtn.Visibility = 'Collapsed'; $ui.ShowProg.Visibility = 'Collapsed'
    $ui.Options.Visibility = 'Hidden'; $ui.Start.Visibility = 'Collapsed'; $ui.Sync.Visibility = 'Collapsed'
    $ui.Stop.Visibility = 'Visible'; $ui.Back.Content = '回遊戲庫'; $ui.Back.Visibility = 'Visible'
}
function Start-Run($jobs) {
    if (-not $jobs.Count) { return }
    if ($state.Running) {
        # 跑到一半又按「轉檔」：排到隊伍後面（已經在排或正在做的同一款不重複），留在遊戲庫畫面
        $busy = @(Busy-Dirs)
        Add-Jobs @($jobs | Where-Object { -not ($_.Game.Dir -and $busy -contains $_.Game.Dir) })
        Build-Library
        return
    }
    $ui.Jobs.Children.Clear(); $ui.DoneJobs.Children.Clear(); $ui.DoneBox.Visibility = 'Collapsed'; $ui.DoneBox.IsExpanded = $false
    $state.Queue.Clear(); $state.Ok = 0; $state.Fail = @(); $state.Running = $true; $state.Started = Get-Date; $state.All = @()
    Add-Jobs $jobs
    Show-Progress
    $ui.Login.IsEnabled = $false; $ui.Settings.IsEnabled = $false; $ui.Refresh.IsEnabled = $false
    $ui.Busy.Visibility = 'Visible'
    $ui.ProgTitle.Text = if (@($jobs | Where-Object { $_.Mode -eq 'sync' }).Count) { '同步中' } elseif (@($jobs | Where-Object { $_.Mode -like 'mergepart*' }).Count -eq $jobs.Count) { '轉檔中' } else { '執行中' }
    $state.Title = $ui.ProgTitle.Text
    Start-Next
}

function Start-Next {
    if ($state.Queue.Count -eq 0) {
        $state.Running = $false; $state.Job = $null
        Update-Overall
        if ($ui.Jobs.Children.Count -eq 0) { $ui.DoneBox.IsExpanded = $true }
        $what = if ($state.Title -eq '同步中') { '同步' } elseif ($state.Title -eq '轉檔中') { '轉檔' } else { '' }
        $ui.ProgTitle.Text = if ($state.Fail.Count) { "$($what)做完了，有失敗的：$($state.Fail -join '、')" } elseif ($what) { "$($what)完成" } else { '全部完成' }
        $ui.Stop.Visibility = 'Collapsed'; $ui.ShowProg.Visibility = 'Collapsed'; $ui.Back.Content = '返回'
        $ui.Back.Visibility = if ($ui.ProgressView.Visibility -eq 'Visible') { 'Visible' } else { 'Collapsed' }
        $ui.Login.IsEnabled = $true; $ui.Settings.IsEnabled = $true; $ui.Refresh.IsEnabled = $true
        # 安裝或更新完：PadSwitch 自己換了新版就重開，不然重新讀殼、支援清單和帳號
        $flag = Join-Path $work 'app-restart.flag'
        if (Test-Path $flag) {
            Remove-Item $flag -ErrorAction SilentlyContinue
            Start-HiddenPs (Join-Path $here 'nxn-app.ps1') @('-Restart')
            $win.Close(); return
        }
        Load-Supported; Update-ShellLabel; Update-Account
        # 跑的時候回到遊戲庫在看：直接更新卡片，不用跳回進度頁
        if ($ui.ProgressView.Visibility -ne 'Visible') { Build-Library; return }
        # 全部成功就倒數幾秒自動回遊戲庫；有失敗的留在這頁讓你看記錄
        if (-not $state.Fail.Count) {
            $state.BackIn = 5; $state.DoneTitle = $ui.ProgTitle.Text
            $ui.ProgTitle.Text = "$($state.DoneTitle)，$($state.BackIn) 秒後回到遊戲庫"
            $backTimer.Start()
        }
        return
    }
    $job = $state.Queue.Dequeue()
    if ($job.NeedAllOk -and $state.Fail.Count) {
        # 前面有遊戲打包失敗，就不合包了
        Set-Step $job 0 'fail'; $job.Msg.Text = '前面有遊戲打包失敗，這次沒有合包'; $job.Msg.Foreground = Brush '#FF453A'
        $state.Fail += $job.Game.Name
        Start-Next; return
    }
    if ($job.PSObject.Properties['Lib']) {
        $lc = Library-Call $job.Lib $state.Fail
        if (-not $lc.Call) {
            # 遊戲庫沒有要變的（沒加減遊戲、沒重新轉檔、沒換殼）：不用重新合成，後面的同步照做
            Set-Step $job $job.StepNames.Count 'done'; $job.Done = $true; $job.Ended = Get-Date
            $job.Msg.Text = '遊戲庫不用重新合成（沒有加減或更新遊戲）' + $(if ($lc.Skip.Count) { "；轉檔失敗的先跳過：$($lc.Skip -join '、')" } else { '' })
            $job.Msg.Foreground = Brush $(if ($lc.Skip.Count) { '#FF9F0A' } else { '#30D158' })
            [void]$ui.Jobs.Children.Remove($job.Row); $ui.DoneJobs.Children.Insert(0, $job.Row)
            $ui.DoneBox.Header = "已完成（$($ui.DoneJobs.Children.Count)）"; $ui.DoneBox.Visibility = 'Visible'
            Start-Next; return
        }
        $job.Call = $lc.Call
        if ($lc.Skip.Count) { $job.Msg.Text = "跳過 $($lc.Skip -join '、')，其他照樣放進去" }
    }
    if ($job.Mode -eq 'sync' -and -not (Test-Path -LiteralPath (Library-Ipa))) {
        Set-Step $job 0 'fail'; $job.Msg.Text = '還沒有遊戲庫（前面的轉檔或合成沒成功），這次沒有同步到 iPad'; $job.Msg.Foreground = Brush '#FF453A'
        $state.Fail += '同步'; $job.Done = $true; Start-Next; return
    }
    $state.Job = $job
    $job.Row.FindName('Drop').Visibility = 'Collapsed'
    $job.Log = Join-Path $logDir ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ($job.Game.Name -replace '[^\w.-]', '_') + '.log')
    $job.Pos = 0L; $job.LogLine = ''; $job.Dec = [Text.Encoding]::UTF8.GetDecoder(); $job.Started = Get-Date
    Set-Step $job 0 'active'
    $job.Msg.Text = '開始…'
    # Write-Host 走資訊串流（6），*>&1 才收得到；結束碼交給外層的 exit
    $call = if ($job.Call) { $job.Call } else { "& $(Quote $script) $($job.Args -join ' ') -NoPause" }
    $cmd = "[Console]::OutputEncoding=[Text.Encoding]::UTF8; `$env:PYTHONUTF8='1'; `$global:LASTEXITCODE=0; & { $call } *>&1 | Out-File -Encoding utf8 -Width 400 $(Quote $job.Log); exit `$LASTEXITCODE"
    $psi = New-Object Diagnostics.ProcessStartInfo 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"$($cmd -replace '"', '\"')`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['NXN_JOB'] = $job.Id    # nxn.ps1、romfs_data.py 把它寫進進度狀態檔，這裡才找得到這一步的進度
    $state.Proc = [Diagnostics.Process]::Start($psi)
    $job.Row.FindName('JTrack').Visibility = 'Visible'
    $timer.Start()
}

function Read-Log($job) {
    if (-not $job.Log -or -not (Test-Path -LiteralPath $job.Log)) { return }
    try {
        $fs = New-Object IO.FileStream($job.Log, 'Open', 'Read', 'ReadWrite')
        try {
            if ($fs.Length -le $job.Pos) { return }
            [void]$fs.Seek($job.Pos, 'Begin')
            $buf = New-Object byte[] ([int][math]::Min(64KB, $fs.Length - $job.Pos))
            $n = $fs.Read($buf, 0, $buf.Length)
            $job.Pos += $n
            $chars = New-Object char[] ([Text.Encoding]::UTF8.GetMaxCharCount($n))
            $count = $job.Dec.GetChars($buf, 0, $n, $chars, 0)
            $text = ([string]::new($chars, 0, $count)).Replace([string][char]0xFEFF, '')
            if (-not $text) { return }
            # 畫面只留尾端；完整記錄仍在檔案中。
            if ($job.Text.Text.Length -gt 256KB) {
                $job.Text.Text = $job.Text.Text.Substring($job.Text.Text.Length - 128KB)
            }
            $job.Text.AppendText($text); $job.Text.ScrollToEnd()
            $combined = $job.LogLine + $text
            $end = $combined.LastIndexOf([char]10)
            $job.LogLine = $combined.Substring($end + 1)
            if ($job.LogLine.Length -gt 4KB) { $job.LogLine = '' }
            if ($end -lt 0) { return }
            # 看到哪一步的開頭就把那一步點亮
            foreach ($line in ($combined.Substring(0, $end) -split "`r?`n")) {
                $l = $line.Trim()
                if (-not $l) { continue }
                for ($i = $job.Cur + 1; $i -lt $job.StepNames.Count; $i++) {
                    $def = $stepDefs | Where-Object { $_.Name -eq $job.StepNames[$i] }
                    if ($l -match $def.Re) { Set-Step $job $i 'active'; break }
                }
                # 卡片上只顯示看得懂的一行：略過時間戳開頭的記錄、和工具印出的資料結構片段（有大括號、或只是收尾的符號）
                if ($l -notmatch '^\[?\d{4}-\d\d-\d\dT' -and $l -notmatch '[{}]|^[\]\)\},\s]+$' -and $l.Length -lt 200) { $job.Msg.Text = ($l -replace '^\[\d\d:\d\d:\d\d\]\s*', '') }
            }
        } finally { $fs.Dispose() }
    } catch { }
}

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(400)
$timer.Add_Tick({
    $job = $state.Job
    if (-not $job) { $timer.Stop(); return }
    Read-Log $job
    Update-JobProgress $job
    Update-Overall
    if ($state.Proc -and $state.Proc.HasExited) {
        $timer.Stop()
        Read-Log $job
        $code = $state.Proc.ExitCode
        $state.Proc = $null
        $job.Done = $true; $job.Ended = Get-Date
        if ($code -eq 0) {
            $state.Ok++
            Save-StepTime $job
            if ($job.Mode -eq 'sync') { try { Update-Space; Start-SpaceProbe -Force } catch { } }
            if ($job.Game.Dir) { $addFail.Remove($job.Game.Dir) }
            Set-Step $job $job.StepNames.Count 'done'
            $job.Msg.Text = if ($job.Mode -eq 'sync') { Sync-Summary $job } elseif ($job.Mode -eq 'glsync') { Gl-Summary $job } elseif ($job.StepNames -contains '簽章安裝') { '裝好了，可以在 iPad 上打開' } elseif ($job.StepNames -contains '打包器') { '準備好了' } elseif ($job.StepNames -contains '存檔') { '存檔好了' } elseif ($job.Report) { "問題回報做好了，資料夾已經打開：$(Split-Path $job.Report -Leaf)" } elseif ($job.StepNames -contains '記錄') { '記錄拿回來了，展開「記錄」看紅字清單' } elseif ($job.Mode -eq 'merge') { '遊戲庫合成好了' } else { '轉檔完成，隨時可以同步到 iPad' }
            $job.Msg.Foreground = Brush '#30D158'
            if ($job.StepNames -contains '合成') {
                $freed = Clean-AfterMerge
                if ($freed -gt 100MB) { $job.Msg.Text += '（順便清掉用不到的舊遊戲包 {0:N1} GB）' -f ($freed / 1GB) }
            }
            # 做好的移到下面「已完成」，上面只留正在做、排隊中和失敗的
            [void]$ui.Jobs.Children.Remove($job.Row)
            $ui.DoneJobs.Children.Insert(0, $job.Row)
            $ui.DoneBox.Header = "已完成（$($ui.DoneJobs.Children.Count)）"; $ui.DoneBox.Visibility = 'Visible'
        } else {
            $state.Fail += $job.Game.Name
            if ($job.Game.Dir) { $addFail[$job.Game.Dir] = Fail-Reason $job.Log; $job.Msg.Text = $addFail[$job.Game.Dir] }
            Set-Step $job ([math]::Max($job.Cur, 0)) 'fail'
            $job.Msg.Foreground = Brush '#FF453A'
            $job.Row.FindName('JFill').Background = Brush '#FF453A'
            $job.Row.FindName('Exp').IsExpanded = $true
        }
        Start-Next
    } })

# ---------------------------------------------------------------- 按鈕
# 合包的 bundle ID：加入或移除遊戲後沿用它，iPad 上才是同一個 App
function Pack-BundleId($ipa) {
    try {
        $z = [IO.Compression.ZipFile]::OpenRead($ipa)
        try {
            $e = $z.Entries | Where-Object { $_.FullName -match '^Payload/[^/]+\.app/Info\.plist$' } | Select-Object -First 1
            $sr = New-Object IO.StreamReader($e.Open()); try { $pl = $sr.ReadToEnd() } finally { $sr.Dispose() }
            if ($pl -match '<key>CFBundleIdentifier</key>\s*<string>([^<]+)</string>') { return $Matches[1] }
        } finally { $z.Dispose() }
    } catch { }
    return ''
}
# 從合包拿掉一款：用 nxn_merge_drop.py 把舊包重寫一份（不重新打包，很快），蓋回原檔名。iPad 上重新安裝後，
# 那款傳過去的遊戲資料會在下次傳檔時刪掉（romfs_data.py）；它的存檔留在 App 裡。
function Remove-FromPack($p, $gm) {
    $old = $p.Ipas[0].FullName
    $mg = Get-MergeScript
    $drop = Join-Path $here 'nxn_merge_drop.py'
    if (-not $mg -or -not (Test-Path $drop)) { [void][Windows.MessageBox]::Show('找不到 nxn_merge.py 或 nxn_merge_drop.py。', '移除遊戲'); return }
    $bid = Pack-BundleId $old
    $tmp = "$old.removing"
    $call = "Write-Host '==> 合成一包：從 $($p.Name -replace "'", "''") 移除 $($gm.Name -replace "'", "''")'; " +
            "& $(Quote (Get-Python)) $(Quote $drop) $(Quote $mg) $($gm.Tid) -o $(Quote $tmp) --name $(Quote $p.Name)" + $(if ($bid) { " --bundle-id $(Quote $bid)" } else { '' }) + " $(Quote $old); " +
            "if (`$LASTEXITCODE) { Write-Host '出錯了：移除失敗'; Remove-Item -LiteralPath $(Quote $tmp) -ErrorAction SilentlyContinue; `$global:LASTEXITCODE = 1; return }; " +
            "Move-Item -LiteralPath $(Quote $tmp) -Destination $(Quote $old) -Force; Write-Host '移除好了，重新安裝到 iPad 後才會生效'"
    $g = [pscustomobject]@{ Dir = $p.Dir; Name = "從 $($p.Name) 移除 $($gm.Name)"; Ipas = @(); Base = $false; BaseFile = ''; Icon = $p.Icon }
    Start-Run @(@{ Game = $g; Mode = 'merge'; Ipa = ''; Call = $call })
}
# 加進現有的合包：新選的遊戲各自用多遊戲殼打包，再跟舊的合包一起合成，蓋回原本的檔名。
# bundle ID 和名稱照舊，所以 iPad 上是更新同一個 App（存檔和已經傳過的遊戲資料都留著）。已經在包裡的遊戲跳過。
function Add-ToPack($p, $dirs, $mode) {
    $old = $p.Ipas[0].FullName
    if (-not (Test-Path -LiteralPath $old)) { [void][Windows.MessageBox]::Show("找不到 $old", '加入遊戲'); return }
    $have = @($p.Games | ForEach-Object { $_.Tid })
    $ms = Get-MultiShell; $mg = Get-MergeScript
    $id = if ($ms.Name -match 'shell-\d+-([0-9a-f]+)') { $Matches[1] } else { 'multi' }
    $jobs = @(); $outs = @(); $skip = @()
    foreach ($dir in $dirs) {
        $g = $cards[$dir].Tag
        if (-not $g.Base) { [void][Windows.MessageBox]::Show("$($g.Name) 的資料夾裡沒有遊戲本體（NSP/XCI）。", '缺本體'); return }
        $tid = if ($g.Tid) { "$($g.Tid)".ToUpper() } elseif ("$($g.BaseFile)" -match '(?<![0-9A-Fa-f])(01[0-9A-Fa-f]{14})(?![0-9A-Fa-f])') { $Matches[1].ToUpper() } else { '' }
        if ($tid -and $have -contains $tid) { $skip += $g.Name; continue }
        $o = Join-Path $g.Dir ("$($g.Name)-multi-$id.ipa")
        $outs += $o
        $jobs += @{ Game = $g; Mode = 'mergepart'; Ipa = ''; Out = $o; Shell = $ms.FullName }
    }
    if (-not $outs.Count) { [void][Windows.MessageBox]::Show("選的遊戲都已經在「$($p.Name)」裡了。", '加入遊戲'); return }
    if ($skip.Count) { [void][Windows.MessageBox]::Show("已經在包裡，跳過：$($skip -join '、')", '加入遊戲') }
    $bid = Pack-BundleId $old
    $tmp = "$old.adding"
    $names = ($jobs | ForEach-Object { $_.Game.Name }) -join '、'
    $call = "Write-Host '==> 合成一包：把 $($names -replace "'", "''") 加進 $($p.Name -replace "'", "''")'; " +
            "& $(Quote (Get-Python)) $(Quote $mg) -o $(Quote $tmp) --name $(Quote $p.Name) --shell $(Quote $ms.FullName)" + $(if ($bid) { " --bundle-id $(Quote $bid)" } else { '' }) +
            " $(Quote $old) $(($outs | ForEach-Object { Quote $_ }) -join ' '); " +
            "if (`$LASTEXITCODE) { Write-Host '出錯了：合包失敗'; Remove-Item -LiteralPath $(Quote $tmp) -ErrorAction SilentlyContinue; `$global:LASTEXITCODE = 1; return }; " +
            "Move-Item -LiteralPath $(Quote $tmp) -Destination $(Quote $old) -Force; Write-Host `"合包完成：$($old -replace "'", "''")`""
    if ($mode -eq 'both') { $call += "; & $(Quote $script) -Ipa $(Quote $old) -NoPause" }
    $mg2 = [pscustomobject]@{ Dir = $p.Dir; Name = "加進 $($p.Name)（$($outs.Count) 款）"; Ipas = @(); Base = $true; Icon = $p.Icon }
    $jobs += @{ Game = $mg2; Mode = $(if ($mode -eq 'both') { 'merge+install' } else { 'merge' }); Ipa = ''; Call = $call }
    $script:addTo = $null; Update-SelCount
    Start-Run $jobs
}
# ---------------------------------------------------------------- 遊戲庫：iPad 上只放一個 App，勾的遊戲都在裡面
# 每款遊戲用多遊戲殼打包成 <資料夾>-multi-<殼版本>.ipa（遊戲包，留在遊戲資料夾當快取），按開始時把勾的遊戲包合成
# 合包\遊戲庫.ipa 再安裝。bundle ID 固定，所以加減遊戲都是更新同一個 App，存檔留著；遊戲資料（romfs、著色器）照 romfs_data.py
# 放在 App 的 Documents，只傳新加的遊戲，拿掉的遊戲它的資料會被刪掉（存檔留著）。圖示固定用 LibraryIcon.png。
$libName = '遊戲庫'          # 合包\遊戲庫.ipa 的檔名（電腦上找它用，不改）
$libAppName = 'SwitchPad'    # iPad 主畫面上 App 的名字
$libBid = 'org.nxnative.games.library'
function Library-Ipa {
    $p = Join-Path (Join-Path $base $packDirName) "$libName.ipa"
    if (-not (Test-Path -LiteralPath $p) -and (Test-Path -LiteralPath (Join-Path (Join-Path $base '合包') "$libName.ipa"))) { return (Join-Path (Join-Path $base '合包') "$libName.ipa") }   # 還沒搬（正在轉檔時不搬）
    return $p
}
function Pack-Dir { Split-Path (Library-Ipa) -Parent }
# 遊戲庫上次是用哪個殼合成的（合成好時記在 遊戲庫.ipa.shell）；換了殼，遊戲包沒變也要重新合成，iPad 才用得到新殼
function Shell-Changed($shell) {
    $lib = Library-Ipa; $li = Get-Item -LiteralPath $lib -ErrorAction SilentlyContinue
    if (-not $shell -or -not $li) { return $false }
    $sh = Get-Item -LiteralPath $shell -ErrorAction SilentlyContinue
    $rec = "$lib.shell"
    if (Test-Path -LiteralPath $rec) { return ((Get-Content -LiteralPath $rec -Raw -Encoding UTF8).Trim() -ne $sh.Name) }
    return [bool]($sh -and $sh.LastWriteTime -gt $li.LastWriteTime)   # 還沒有記錄的舊遊戲庫：殼比遊戲庫新就算換過
}
# App 的名字和圖示（合成好時記在 遊戲庫.ipa.look）；換了就要重新合成一次，iPad 上才會換
function Library-Look {
    $icon = Join-Path $here 'LibraryIcon.png'
    $h = if (Test-Path -LiteralPath $icon) { (Get-FileHash -LiteralPath $icon -Algorithm SHA256).Hash.Substring(0, 16) } else { '' }
    # |hd：合成時放進高清遊戲圖示（icon_hd.py）之後的第一次要重新合成一次，舊的遊戲庫才會換上
    "$libAppName|$h|hd"
}
function Look-Changed {
    $lib = Library-Ipa
    if (-not (Test-Path -LiteralPath $lib)) { return $false }
    $rec = "$lib.look"
    if (-not (Test-Path -LiteralPath $rec)) { return $true }   # 改名前合成的遊戲庫
    return ((Get-Content -LiteralPath $rec -Raw -Encoding UTF8).Trim() -ne (Library-Look))
}
function Library-Tids {
    $f = Get-Item -LiteralPath (Library-Ipa) -ErrorAction SilentlyContinue
    if (-not $f) { return @() }
    @(Read-Pack $f | ForEach-Object { $_.Tid })
}
# 從 iPad 收回來的著色器紀錄：遊戲資料夾\著色器紀錄（舊版在 合包\GL著色器\<title ID>，還沒搬就用舊的）
function Gl-Rec($g) {
    $p = Join-Path $g.Dir '著色器紀錄'
    $t = Game-Tid $g
    if (-not (Test-Path -LiteralPath $p) -and $t) { $o = Join-Path $base "合包\GL著色器\$t"; if (Test-Path -LiteralPath $o) { return $o } }
    return $p
}
function Game-Tid($g) {
    if ($g.Tid) { return "$($g.Tid)".ToUpper() }
    if ("$($g.BaseFile)" -match '(?<![0-9A-Fa-f])(01[0-9A-Fa-f]{14})(?![0-9A-Fa-f])') { return $Matches[1].ToUpper() }
    return ''
}
function Shell-Sha($ms) { if ($ms.Name -match 'shell-\d+-([0-9a-f]+)') { $Matches[1] } else { 'multi' } }
# 遊戲包的名字用殼的 PACK_ABI（遊戲包格式，ns2ios-shell dm/tools/pack_abi.py）：只改了殼本身的新殼格式一樣，轉換好的遊戲包照用，
# 換殼不用整個遊戲庫重轉。殼裡沒有 PACK_ABI（舊殼）就退回用殼的版本號
$abiCache = @{}
function Multi-Id($ms) {
    $k = "$($ms.FullName)|$($ms.LastWriteTimeUtc.Ticks)"
    if ($abiCache.ContainsKey($k)) { return $abiCache[$k] }
    $id = Shell-Sha $ms
    try {
        $z = [IO.Compression.ZipFile]::OpenRead($ms.FullName)
        try {
            $e = $z.Entries | Where-Object { $_.FullName -match '^Payload/[^/]+\.app/dm/shell_info\.txt$' } | Select-Object -First 1
            if ($e) { $sr = New-Object IO.StreamReader($e.Open()); try { $t = $sr.ReadToEnd() } finally { $sr.Dispose() }
                      if ($t -match '(?m)^PACK_ABI=([0-9a-f]+)') { $id = "f$($Matches[1])" } }
        } finally { $z.Dispose() }
    } catch { }
    $abiCache[$k] = $id; $id
}
# 遊戲包還能用嗎：同一個多遊戲殼做的，而且比資料夾裡所有遊戲檔都新（加了更新檔或 DLC 就要重做）
function Part-For($g, $id, [switch]$UseScan) {
    $o = Join-Path $g.Dir ("$($g.Name)-multi-$id.ipa")
    $f = Get-Item -LiteralPath $o -ErrorAction SilentlyContinue
    if ($f -and (Test-Path -LiteralPath "$o.repack")) { Remove-Item -LiteralPath "$o.repack" -ErrorAction SilentlyContinue }   # 已經重新打包好了，舊的那份不用留
    $newest = if ($UseScan) { $g.NewestSourceWrite } else {
        (Get-ChildItem -LiteralPath $g.Dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.nsp', '.xci', '.nsz', '.xcz' } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
    }
    [pscustomobject]@{ Path = $o; File = $f; Fresh = [bool]($f -and (-not $newest -or $f.LastWriteTime -ge $newest)) }
}
function Select-Library {
    $selected.Clear()
    if ($cfg.WantSet) { foreach ($d in @($cfg.Want)) { if ($d -and (Test-Path -LiteralPath $d -PathType Container)) { $selected.Add($d) } } }
    else { if (-not $cards.Count) { Build-Library }; $tids = @(Library-Tids); foreach ($c in $cards.Values) { if ($tids -contains (Game-Tid $c.Tag)) { $selected.Add($c.Tag.Dir) } } }   # 第一次：iPad 上那份遊戲庫有的
    Build-Library
}
# mode：both = 做缺的遊戲包、合成、安裝；pack = 勾的遊戲包全部重做再合成，不安裝；install = 把現在的遊戲庫裝到 iPad
function Library-Game { $lib = Library-Ipa; [pscustomobject]@{ Dir = (Split-Path $lib -Parent); Name = $libName; Ipas = @(Get-Item -LiteralPath $lib -ErrorAction SilentlyContinue); Base = $true; BaseFile = ''; Icon = (Join-Path $here 'LibraryIcon.png') } }
# 從舊的單款 App 和合包把存檔搬進遊戲庫（saves_data.py migrate）：只做一次，換到遊戲庫的時候
function Run-Migrate($owner) {
    if ($state.Running) { return }
    $have = Test-Path -LiteralPath (Library-Ipa)
    $ok = [Windows.MessageBox]::Show($owner, "把 iPad 上舊的單款 App 和合包的存檔整份存到電腦；遊戲庫已經裝在 iPad 上的話，接著放進遊戲庫裡同一款遊戲。`n`n" +
        "換到遊戲庫的順序：`n1. 按這裡，把舊 App 的存檔存到電腦`n2. 在 iPad 上刪掉舊 App（免費 Apple ID 最多 3 個 App）`n3. 加入遊戲，按「轉檔」再按「同步」`n4. 再按一次這裡，存檔就放進遊戲庫`n`n" +
        "同一款在好幾個舊 App 裡，用最近玩過的那份；遊戲庫裡已經有存檔的遊戲不會被蓋掉，放進去之前也會先備份遊戲庫。`n`niPad 用 USB 接著並解鎖，遊戲先關掉。要開始嗎？", '搬舊 App 存檔', 'YesNo', 'Question')
    if ($ok -ne 'Yes') { return }
    $owner.DialogResult = $false
    Start-Run @(@{ Game = (Library-Game); Mode = 'savemigrate'; Ipa = (Library-Ipa) })
}
# ---------------------------------------------------------------- 同步：自己看要做什麼，排好順序一次做完（iPad 要接著）
#  1. 騰出電腦空間：舊格式的遊戲包先清掉（Clean-AfterMerge，都做得回來）
#  2. 拿回 iPad 記下的著色器（有要在 iPad 上記著色器的遊戲才做），那幾款有新的就重新轉檔
#  3. 轉檔：遊戲庫裡還沒轉、或遊戲檔有更新（加了更新檔／DLC）、換了殼要重轉的
#  4. 合成遊戲庫：加了、拿掉、更新了遊戲才合成，沒變就跳過
#  5. 同步到 iPad（nxn.ps1 -SignIfNeeded）：連上 iPad → 備份 iPad 存檔 → 要的話重簽（App 換了或超過一天）→
#     先刪掉拿掉的遊戲騰出 iPad 空間、再傳新的和更新的 → 放進拖進來的存檔、和電腦的存檔資料夾雙向同步 → 拿回著色器紀錄、排好遊戲順序
# 沒有新遊戲也照樣做 5（存檔、著色器、順序、要的話重簽），不會因為「遊戲庫沒變」整個不做
$orderFile = Join-Path $work 'game-order.json'
function Write-Order {
    $tids = @($selected | Where-Object { $cards.ContainsKey($_) } | ForEach-Object { Game-Tid $cards[$_].Tag } | Where-Object { $_ })
    try { [IO.File]::WriteAllText($orderFile, (ConvertTo-Json @($tids) -Compress), (New-Object Text.UTF8Encoding $false)) } catch { }
}
function Run-Sync {
    if ($spaceJob.Proc -and -not $spaceJob.Proc.HasExited) {
        $spaceJob.SyncPending = $true
        $ui.Sync.Content = '讀取 iPad 後同步'
        return
    }
    $spaceJob.SyncPending = $false
    $lib = Library-Ipa
    $libGame = Library-Game
    $ms = Get-MultiShell; $mg = Get-MergeScript
    if (-not $ms -or -not $mg) { [void][Windows.MessageBox]::Show($ui.Merge.ToolTip, 'PadSwitch'); return }
    $id = Multi-Id $ms
    $busy = @(Busy-Dirs)
    $dirs = @($selected | Where-Object { $cards.ContainsKey($_) -and ($cards[$_].Tag.Base -or $cards[$_].Tag.Ready -or $cards[$_].Tag.OnPad -or $busy -contains $_) })
    if (-not $dirs.Count -and -not (Test-Path -LiteralPath $lib)) { [void][Windows.MessageBox]::Show('遊戲庫是空的：先把遊戲拖進「遊戲庫」或按「加入」。', 'PadSwitch'); return }
    if (-not $state.Running) { $freed = Clean-AfterMerge; if ($freed -gt 100MB) { $script:freedNote = '先清掉用不到的舊遊戲包 {0:N1} GB' -f ($freed / 1GB) } else { $script:freedNote = '' } }
    $jobs = @(); $outs = @()
    $glGames = @($dirs | Where-Object { $t = Game-Tid $cards[$_].Tag; $t -and (Test-Path -LiteralPath (Gl-Rec $cards[$_].Tag)) })
    if ($glGames.Count -and (Test-Path -LiteralPath $lib) -and -not $state.Running) {
        $gg = Library-Game; $gg | Add-Member -NotePropertyName GlNames -NotePropertyValue (((@($glGames | ForEach-Object { $cards[$_].Tag.Name }) | Select-Object -First 3) -join '、') + $(if ($glGames.Count -gt 3) { " 等 $($glGames.Count) 款" } else { '' })) -Force
        $jobs += @{ Game = $gg; Mode = 'glsync'; Ipa = $lib }
    }
    $pushB = 0L
    foreach ($dir in $dirs) {
        $g = $cards[$dir].Tag
        $part = Part-For $g $id
        if ($state.Running -and $busy -contains $dir) {
            # 已經在轉或排隊：不重複排，合成時用它轉好的遊戲包
        } elseif ($part.Fresh -and $glGames -contains $dir) {
            $jobs += @{ Game = $g; Mode = 'mergepart-reuse'; Ipa = ''; Out = $part.Path; Shell = $ms.FullName }
        } elseif (-not $part.Fresh -and $g.Base) {
            $jobs += @{ Game = $g; Mode = 'mergepart'; Ipa = ''; Out = $part.Path; Shell = $ms.FullName }
        }
        if (-not $g.OnPad -or $g.Newer -or -not $part.Fresh) { $pushB += Game-Bytes $g }
        $outs += [pscustomobject]@{ Path = $part.Path; Name = $g.Name; Dir = $dir; WasIn = [bool]$g.OnPad }
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $lib -Parent) | Out-Null
    $before = @(Library-Tids)
    $now = @($dirs | ForEach-Object { Game-Tid $cards[$_].Tag })
    $gone = @($cards.Values | Where-Object { $t = Game-Tid $_.Tag; $t -and $before -contains $t -and $now -notcontains $t } | ForEach-Object { $_.Tag.Name })
    # 合成那一步等前面跑完才決定（轉檔失敗的那款先跳過，其他照樣放進去；什麼都沒變就不合成）
    if ($dirs.Count) {
        $jobs += @{ Game = $libGame; Mode = 'merge'; Ipa = ''; Call = '-';
                    Lib = [pscustomobject]@{ Parts = $outs; Gone = $gone; Mode = 'merge'; Shell = $ms.FullName; Merge = $mg } }
    }
    Write-Order
    $jobs += @{ Game = $libGame; Mode = 'sync'; Ipa = $lib; Out = $orderFile; PushBytes = $pushB }
    Start-Run $jobs
}
function Run-Library($dirs, $mode) { Run-Sync }   # 舊的呼叫方式（重簽、裝到 iPad）都是同步

# 轉檔：只在電腦上轉好，不用接 iPad，之後按「同步」就傳。選了遊戲就轉選的（轉好過的問要不要重轉），沒選就轉遊戲庫裡還沒轉的；一款失敗其他照做
function Run-Convert($dirs) {
    $ms = Get-MultiShell
    if (-not $ms) { [void][Windows.MessageBox]::Show($ui.Merge.ToolTip, 'PadSwitch'); return }
    $id = Multi-Id $ms
    $jobs = @(foreach ($dir in $dirs) { $g = $cards[$dir].Tag; if ($g.Base) { @{ Game = $g; Mode = 'mergepart'; Ipa = ''; Out = (Part-For $g $id).Path; Shell = $ms.FullName } } })
    Start-Run $jobs
}

# 遊戲庫只放 App 本身（--link）：遊戲資料（romfs、著色器，幾十 GB）留在各遊戲包裡，裝到 iPad 時 romfs_data.py 從那裡直接傳。
# 合成不用再把全部遊戲資料重寫一份（26 款要寫 45 GB、5 分鐘），也不用另外做小 App。打包器帶的舊版 nxn_merge.py 沒有這個選項就照舊
function Merge-CanLink($mg) {
    try { return [bool](Select-String -LiteralPath $mg -Pattern "add_argument\('--link'" -Quiet) } catch { return $false }
}
# 遊戲庫是不是已經是連結式的：zip 的註解（檔案最後面）有 nxn_merge.py 的 NXNLINK 記錄
function Lib-IsLinked($ipa) {
    try {
        $fs = [IO.File]::OpenRead($ipa)
        try {
            $n = [int][Math]::Min($fs.Length, 70000); [void]$fs.Seek(-$n, 'End')
            $b = New-Object byte[] $n; $o = 0; while ($o -lt $n) { $r = $fs.Read($b, $o, $n - $o); if ($r -le 0) { break }; $o += $r }
            return [Text.Encoding]::ASCII.GetString($b).Contains('NXNLINK')
        } finally { $fs.Dispose() }
    } catch { return $false }
}
# 遊戲庫合成的指令：用打包成功的遊戲包，加上本來就在遊戲庫、這次沒重包成功但舊的遊戲包還在的
function Library-Call($lib, $fail) {
    $libIpa = Library-Ipa
    $use = @(); $skip = @()
    foreach ($p in $lib.Parts) {
        $bad = $fail -contains $p.Name
        if ((-not $bad -or $p.WasIn) -and (Test-Path -LiteralPath $p.Path)) { $use += $p } else { $skip += $p.Name }
    }
    $added = @($use | Where-Object { -not $_.WasIn })
    # 遊戲包重新轉換過（比遊戲庫新）或換了殼，也要重新合成
    $libT = (Get-Item -LiteralPath $libIpa -ErrorAction SilentlyContinue).LastWriteTime
    $newer = @($use | Where-Object { $_.WasIn -and (-not $libT -or (Get-Item -LiteralPath $_.Path).LastWriteTime -gt $libT) })
    $newShell = Shell-Changed $lib.Shell
    $newLook = Look-Changed
    # 還是舊式（遊戲資料整份在包裡）的遊戲庫：重新合成一次換成連結式，電腦上少 40 幾 GB，iPad 上的資料對得上不會重傳
    $relink = (Test-Path -LiteralPath $libIpa) -and (Merge-CanLink $lib.Merge) -and -not (Lib-IsLinked $libIpa)
    if (-not $use.Count -or (-not $added.Count -and -not $lib.Gone.Count -and -not $newer.Count -and -not $newShell -and -not $newLook -and -not $relink)) { return @{ Call = ''; Skip = $skip } }   # 遊戲庫沒有要變的，不重包也不重裝
    $what = "$($use.Count) 款" + $(if ($added.Count) { "，加入 $(($added | ForEach-Object { $_.Name }) -join '、')" } else { '' }) +
            $(if ($lib.Gone.Count) { "，拿掉 $($lib.Gone -join '、')" } else { '' }) + $(if ($skip.Count) { "，跳過 $($skip -join '、')" } else { '' }) +
            $(if ($newShell) { '，換新殼' } elseif ($newLook) { "，App 改名 $libAppName、換圖示" } elseif ($newer.Count) { "，更新 $(($newer | ForEach-Object { $_.Name }) -join '、')" } elseif ($relink) { '，改成遊戲資料不重複存一份' } else { '' })
    $tmp = "$libIpa.new"
    $icon = Join-Path $here 'LibraryIcon.png'
    $call = "Write-Host '==> 合成一包：$libName（$($what -replace "'", "''")）'; " +
            "& $(Quote (Get-Python)) $(Quote $lib.Merge) -o $(Quote $tmp) --name $(Quote $libAppName) --bundle-id $libBid --shell $(Quote $lib.Shell)" +
            $(if (Merge-CanLink $lib.Merge) { ' --link' } else { '' }) +
            $(if (Test-Path $icon) { " --icon $(Quote $icon)" } else { '' }) + $(if (Select-String -LiteralPath $lib.Merge -Pattern 'hd-icons' -SimpleMatch -Quiet) { " --hd-icons $(Quote (Join-Path $coverDir 'hd'))" } else { '' }) + " $(($use | ForEach-Object { Quote $_.Path }) -join ' '); " +
            "if (`$LASTEXITCODE) { Write-Host '出錯了：遊戲庫合成失敗'; Remove-Item -LiteralPath $(Quote $tmp) -ErrorAction SilentlyContinue; `$global:LASTEXITCODE = 1; return }; " +
            "Move-Item -LiteralPath $(Quote $tmp) -Destination $(Quote $libIpa) -Force; " +
            "Set-Content -LiteralPath $(Quote "$libIpa.shell") -Value $(Quote (Split-Path $lib.Shell -Leaf)) -Encoding UTF8; " +
            "Set-Content -LiteralPath $(Quote "$libIpa.look") -Value $(Quote (Library-Look)) -Encoding UTF8; Write-Host '遊戲庫合成好了'"
    if ($lib.Mode -eq 'both') { $call += "; & $(Quote $script) -Ipa $(Quote $libIpa) -NoPause" }   # 同步把裝到 iPad 另外排成一步（sync），這裡是 merge
    return @{ Call = $call; Skip = $skip }
}

# 打包失敗的原因：記錄裡認得的錯誤換成白話，說要做什麼；認不得的挑最後一行錯誤原文
# 每條是打包器（nxn_pack.py、shader_split.py）或 nxn.ps1 會印的訊息；越前面越優先（真正的原因通常比後面跟著的「打包失敗」早出現）
$failHints = @(
    @{ Re = 'without type trees';                         Msg = '這款 Unity 遊戲的著色器格式，打包器內建的 Unity 2017～6000 格式都讀不出來。請把「最近的記錄」給 Claude 看' }
    @{ Re = '32-bit|32 位元|aarch32';                     Msg = '32 位元的遊戲，殼還不支援（只能跑 64 位元的 Switch 遊戲）' }
    @{ Re = 'no base game for';                           Msg = '資料夾裡只有更新檔或 DLC，沒有遊戲本體：把本體的 NSP / XCI 拖到這款遊戲上' }
    @{ Re = 'no update for';                              Msg = '這款要搭配特定版本的更新檔，資料夾裡沒有：把更新檔的 NSP 拖到這款遊戲上' }
    @{ Re = 'folder holds \d+ different games';          Msg = '資料夾裡混了不同遊戲的檔案：一個資料夾只放一款（本體、更新、DLC）' }
    @{ Re = 'no game could be identified';                Msg = '認不出資料夾裡的遊戲：XCI 要跟 prod.keys 對得上，可以改用 NSP，或到設定的「金鑰」換新的 prod.keys' }
    @{ Re = 'no \.nsp or \.xci';                        Msg = '資料夾裡沒有 NSP / XCI 檔' }
    @{ Re = 'NSZ file\(s\)';                            Msg = 'NSZ 還沒解壓：再按一次「轉檔」會自動解壓；還是不行的話自己用 nsz -D 解壓後拖進來' }
    @{ Re = 'not enough space on the disk';               Msg = '硬碟空間不夠：轉換時要放三份遊戲資料。清出空間（設定裡的「清理空間」）或把遊戲資料夾移到別顆硬碟' }
    @{ Re = 'cannot dispatch the .* gate|older than this packer|built before the shell route|ignores dm/env\.txt|this is not a shell'; Msg = '殼太舊，跟打包器不合：到設定按「改用最新殼」再轉一次' }
    @{ Re = 'run-time shader capture boots the game in the Mac host|cannot pack .* on Windows|captures them by booting the game on a Mac'; Msg = '這款的著色器是遊戲執行時才產生的（Vulkan / OpenGL），要先在 iPad 上錄：換支援錄著色器的殼再轉' }
    @{ Re = 'no shader libraries were produced|none of the \d+ shaders .* translates|no shader translator'; Msg = '著色器轉成 iPad 格式那一步失敗。請把「最近的記錄」給 Claude 看' }
    @{ Re = 'does not belong to this base dump';            Msg = '更新檔壞了，或跟遊戲本體不是同一套（本體自己檢查沒問題）：重新下載更新檔，最好本體和更新從同一個來源拿，再轉一次' }
    @{ Re = "base NSP's own RomFS fails too";               Msg = '遊戲本體的 NSP 壞了（下載不完整或檔案損毀）：重新下載本體再轉一次' }
    @{ Re = 'the NSP is damaged';                           Msg = '遊戲檔沒通過雜湊檢查（下載不完整或檔案損毀）：重新下載本體和更新檔再轉一次' }
    @{ Re = 'extracting .* failed \(exit|nx_extract did not appear'; Msg = '解包失敗：遊戲檔可能不完整，或 prod.keys 太舊。重新下載遊戲檔，或到設定的「金鑰」換新的 prod.keys' }
    @{ Re = 'rewriting \S+ failed \(exit';                Msg = '改寫遊戲程式那一步失敗。請把「最近的記錄」給 Claude 看' }
    @{ Re = 'no game profile for title ID|做不出暫定設定檔'; Msg = '這款沒有設定檔，自動推導也失敗了。請把「最近的記錄」給 Claude 看' }
    @{ Re = 'zbic package could not be installed';          Msg = '這款用了新的壓縮格式（ZBIC），要的解壓套件裝不起來：確認電腦有網路後再轉一次' }
    @{ Re = 'MemoryError|No space left on device|errno 28'; Msg = '電腦的記憶體或硬碟空間不夠，關掉別的程式、清出空間再試一次' }
)
function Fail-Reason($log) {
    $lines = @(Get-Content -LiteralPath $log -Encoding UTF8 -ErrorAction SilentlyContinue)
    # 打包器自己已經用中文說明的失敗（解包：金鑰太舊、哪個檔案損毀），原樣顯示
    $l = @($lines | Where-Object { $_ -match '\[x\] .*[\u4e00-\u9fff]{2}' }) | Select-Object -Last 1
    if ($l) { return ($l -replace '^.*?\[x\]\s*', '').Trim() }
    foreach ($h in $failHints) { if ($lines -match $h.Re) { return $h.Msg } }
    $l = @($lines | Where-Object { $_ -match '\[x\] precheck: ' }) | Select-Object -Last 1
    if ($l) { return ($l -replace '^.*precheck:\s*', '').Trim() }
    # nxn.ps1 自己的錯誤已經是中文（金鑰、Apple ID、iPad 連線），原樣顯示
    $l = @($lines | Where-Object { $_ -match '出錯了：' -and $_ -notmatch '出錯了：打包失敗' -and $_ -match '[\u4e00-\u9fff]{2}' }) | Select-Object -Last 1
    if ($l) { return ($l -replace '^.*出錯了：', '').Trim() }
    $l = @($lines | Where-Object { $_ -match '\[RED\]|\[x\]|Error|出錯了' -and $_ -notmatch '出錯了：打包失敗' }) | Select-Object -Last 1
    if ($l) { return '沒見過的錯誤：' + ($l -replace '^\[[\d:]+\]\s*', '').Trim() }
    return '打包失敗'
}

# ---------------------------------------------------------------- 背景工作卡片：讀 work\status\*.json（每 3 秒）
# run-<PID>.json：nxn.ps1 每一款（PadSwitch 自己開的、nxn-queue.ps1 開的、命令列直接跑的都有）
# push-<PID>.json：romfs_data.py 傳遊戲資料到 iPad；queue-<名稱>.json：背景佇列（nxn-queue.ps1 或照同樣格式寫的程式）
$statusDir = Join-Path $work 'status'
$bg = @{ Open = $false; Cleaned = [datetime]::MinValue; Frac = 0.0 }
function To-Date($v) { if ($v -is [datetime]) { return $v }; if (-not $v) { return $null }; try { return [datetime]::Parse([string]$v) } catch { return $null } }
function Fmt-Dur($sec) {
    $sec = [math]::Max(0, [double]$sec)
    if ($sec -lt 60) { return '不到 1 分' }
    $m = [math]::Round($sec / 60)
    if ($m -lt 60) { return "$m 分" }
    $h = [math]::Floor($m / 60); $m = $m % 60
    if ($m) { "$h 小時 $m 分" } else { "$h 小時" }
}
function Fmt-GB($b) { '{0:N1} GB' -f ([double]$b / 1GB) }
function Pid-Alive($id) { if (-not $id) { return $false }; [bool](Get-Process -Id ([int]$id) -ErrorAction SilentlyContinue) }
function Read-Status {
    $all = @()
    if (-not (Test-Path -LiteralPath $statusDir)) { return $all }
    $now = Get-Date
    foreach ($f in Get-ChildItem -LiteralPath $statusDir -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        if ($f.Name -in 'pack-times.json', 'step-times.json', 'sizes.json', 'sizes-new.json', 'ipad-space.json') { continue }
        $j = $null
        try { $j = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json } catch { continue }   # 剛好在寫：下次再讀
        if (-not $j -or -not $j.kind) { continue }
        $alive = Pid-Alive $j.pid
        # 跑到一半程式沒了（被停止、關機）：當成中斷
        if ($j.state -eq 'running' -and -not $alive) {
            $j.state = 'failed'
            if (-not $j.message) { $j | Add-Member -NotePropertyName message -NotePropertyValue '中斷了（程式被停止）' -Force }
            if (-not $j.ended) { $j | Add-Member -NotePropertyName ended -NotePropertyValue $f.LastWriteTime.ToString('o') -Force }
            if ($j.kind -eq 'queue') {
                $j.state = 'stopped'
                foreach ($it in @($j.items)) { if ($it.state -in 'running', 'queued') { $it.state = 'skipped'; $it | Add-Member -NotePropertyName message -NotePropertyValue '佇列停了' -Force } }
            }
        }
        $end = To-Date $j.ended; if (-not $end) { $end = $f.LastWriteTime }
        # 一天前結束的拿掉（一小時清一次）；6 小時內結束的還顯示在卡片上
        if ($j.state -ne 'running' -and ($now - $end).TotalHours -gt 24) {
            if (($now - $bg.Cleaned).TotalMinutes -gt 60) { Remove-Item -LiteralPath $f.FullName -ErrorAction SilentlyContinue }
            continue
        }
        if ($j.state -ne 'running' -and ($now - $end).TotalHours -gt 6) { continue }
        $j | Add-Member -NotePropertyName _end -NotePropertyValue $end -Force
        $j | Add-Member -NotePropertyName _start -NotePropertyValue (To-Date $j.started) -Force
        $all += $j
    }
    if (($now - $bg.Cleaned).TotalMinutes -gt 60) {
        $bg.Cleaned = $now
        # 寫到一半留下的暫存檔（.json.tmp）一小時後清掉，不然越積越多
        Get-ChildItem -LiteralPath $statusDir -Filter '*.tmp' -File -ErrorAction SilentlyContinue | Where-Object { ($now - $_.LastWriteTime).TotalHours -gt 1 } | Remove-Item -ErrorAction SilentlyContinue
    }
    return $all
}
function Pack-Times {
    $t = @{}
    try { ([IO.File]::ReadAllText((Join-Path $statusDir 'pack-times.json')) | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $t[$_.Name] = [double]$_.Value } } catch { }
    $t
}
function Bg-Tag($text, $fg, $bgc = '#2C2C2E') {
    $b = New-Object Windows.Controls.Border; $b.CornerRadius = '7'; $b.Padding = '9,3'; $b.Margin = '0,0,6,4'; $b.Background = Brush $bgc
    $t = New-Object Windows.Controls.TextBlock; $t.Text = $text; $t.FontSize = 12; $t.Foreground = Brush $fg
    $b.Child = $t; [void]$ui.BgTags.Children.Add($b)
}
function Bg-Row($glyph, $color, $name, $right, $msg) {
    $sp = New-Object Windows.Controls.StackPanel; $sp.Margin = '0,0,0,6'
    $d = New-Object Windows.Controls.DockPanel
    $r = New-Object Windows.Controls.TextBlock; $r.Text = $right; $r.FontSize = 12; $r.Foreground = Brush '#8E8E93'
    [Windows.Controls.DockPanel]::SetDock($r, 'Right'); [void]$d.Children.Add($r)
    $g = New-Object Windows.Controls.TextBlock; $g.Text = $glyph; $g.Width = 18; $g.FontSize = 12; $g.Foreground = Brush $color
    [Windows.Controls.DockPanel]::SetDock($g, 'Left'); [void]$d.Children.Add($g)
    $n = New-Object Windows.Controls.TextBlock; $n.Text = $name; $n.FontSize = 13; $n.TextTrimming = 'CharacterEllipsis'; [void]$d.Children.Add($n)
    [void]$sp.Children.Add($d)
    if ($msg) {
        $m = New-Object Windows.Controls.TextBlock; $m.Text = $msg; $m.FontSize = 12; $m.Margin = '18,1,0,0'; $m.TextWrapping = 'Wrap'
        $m.Foreground = Brush $(if ($glyph -eq '✕') { '#FF453A' } else { '#8E8E93' })
        [void]$sp.Children.Add($m)
    }
    [void]$ui.BgList.Children.Add($sp)
}
$whatName = @{ pack = '轉檔'; both = '轉檔並安裝'; install = '同步到 iPad'; glsync = '拿回著色器紀錄'; logs = '讀 iPad 記錄'; saves = '存檔'; login = '登入' }
function Update-Bg {
    # PadSwitch 自己的進度頁開著時那頁就有細節，不重複
    if ($ui.ProgressView.Visibility -eq 'Visible') { $ui.Bg.Visibility = 'Collapsed'; return }
    $all = @(Read-Status)
    $runs = @($all | Where-Object { $_.kind -eq 'run' })
    $pushes = @($all | Where-Object { $_.kind -eq 'push' })
    $queues = @($all | Where-Object { $_.kind -eq 'queue' -and $_.items })
    if (-not $all.Count) { $ui.Bg.Visibility = 'Collapsed'; return }
    $now = Get-Date
    try {
        $drv = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($base))
        $ui.BgDisk.Text = "$($drv.Name.TrimEnd('\')) 剩 $(Fmt-GB $drv.AvailableFreeSpace)"
        $ui.BgDisk.Foreground = Brush $(if ($drv.AvailableFreeSpace -lt 30GB) { '#FF453A' } else { '#C7C7CC' })
    } catch { $ui.BgDisk.Text = '' }
    $ui.BgTags.Children.Clear(); $ui.BgList.Children.Clear()

    # 佇列：在跑的優先，再來是最近結束的
    $q = @($queues | Sort-Object @{ e = { $_.state -eq 'running' } ; Descending = $true }, @{ e = { $_._start } ; Descending = $true }) | Select-Object -First 1
    $live = @($runs | Where-Object { $_.state -eq 'running' } | Sort-Object _start -Descending)
    $run = $live | Select-Object -First 1
    $pushNow = @($pushes | Where-Object { $_.state -eq 'running' } | Sort-Object _start -Descending) | Select-Object -First 1
    $pushLast = if ($pushNow) { $pushNow } else { @($pushes | Sort-Object _end -Descending) | Select-Object -First 1 }
    $busy = [bool]($run -or $pushNow -or ($q -and $q.state -eq 'running'))
    $ui.BgDot.Fill = Brush $(if ($busy) { '#0A84FF' } else { '#30D158' })

    # 標題：正在做的那一款和那一步
    $title = ''; $sub = ''
    if ($q) {
        $items = @($q.items)
        $nDone = @($items | Where-Object { $_.state -eq 'done' }).Count
        $nFail = @($items | Where-Object { $_.state -in 'failed', 'skipped' }).Count
        $nWait = @($items | Where-Object { $_.state -eq 'queued' }).Count
        $cur = @($items | Where-Object { $_.state -eq 'running' }) | Select-Object -First 1
        if ($cur) {
            $idx = [array]::IndexOf($items, $cur) + 1
            $r = @($runs | Where-Object { $_.pid -and $cur.pid -and [int]$_.pid -eq [int]$cur.pid }) | Select-Object -First 1
            if (-not $r) { $r = $run }
            $step = if ($r -and $r.phase) { "$($r.step) · $($r.phase)" } elseif ($r -and $r.step) { $r.step } else { '準備中' }
            $title = "第 $idx / $($items.Count) 款：$($cur.name) · $step"
            $cs = To-Date $cur.started
            if ($cs) { $title += "（$(Fmt-Dur ($now - $cs).TotalSeconds)）" }
        } elseif ($q.state -eq 'running') {
            $title = "佇列 $($q.name)：$nDone / $($items.Count) 款"
        } else {
            $title = if ($q.state -eq 'stopped') { "佇列 $($q.name) 停了：完成 $nDone 款、沒做完 $nFail 款" } elseif ($nFail) { "佇列 $($q.name) 跑完了：成功 $nDone 款、失敗 $nFail 款" } else { "佇列 $($q.name) 全部完成（$nDone 款）" }
        }
        $qs = $q._start
        if ($qs) { $sub = "佇列 $($q.name) · $($qs.ToString('HH:mm')) 開始" + $(if ($q.state -eq 'running') { "，已經 $(Fmt-Dur ($now - $qs).TotalSeconds)" } elseif ($q._end) { "，$($q._end.ToString('HH:mm')) 結束" }) }
        if ($nDone) { Bg-Tag "✓ 完成 $nDone" '#30D158' '#1E3A26' }
        if ($nFail) { Bg-Tag "✕ 失敗 $nFail" '#FF453A' '#3A1E1E' }
        if ($nWait) { Bg-Tag "排隊 $nWait" '#C7C7CC' }
        # 預估：這款上次打包花的時間，沒有就用這個佇列已完成的平均
        if ($q.state -eq 'running' -and ($nWait -or $cur)) {
            $times = Pack-Times
            $durs = @($items | Where-Object { $_.state -eq 'done' -and $_.started -and $_.ended } | ForEach-Object { ((To-Date $_.ended) - (To-Date $_.started)).TotalSeconds } | Where-Object { $_ -gt 60 })
            $avg = if ($durs.Count) { ($durs | Measure-Object -Average).Average } else { $null }
            $left = 0; $known = $true
            foreach ($it in @($items | Where-Object { $_.state -in 'queued', 'running' })) {
                $est = if ($times.ContainsKey($it.name)) { $times[$it.name] } elseif ($avg) { $avg } else { $null }
                if ($null -eq $est) { $known = $false; break }
                if ($it.state -eq 'running') { $s0 = To-Date $it.started; $left += [math]::Max(60, $est - $(if ($s0) { ($now - $s0).TotalSeconds } else { 0 })) }
                else { $left += $est }
            }
            if ($known) { Bg-Tag "預估還要 $(Fmt-Dur $left)（約 $($now.AddSeconds($left).ToString('HH:mm')) 完成）" '#C7C7CC' }
        }
        foreach ($it in $items) {
            $s0 = To-Date $it.started; $e0 = To-Date $it.ended
            switch ($it.state) {
                'done'    { Bg-Row '✓' '#30D158' $it.name $(if ($s0 -and $e0) { Fmt-Dur ($e0 - $s0).TotalSeconds }) $it.message }
                'failed'  { Bg-Row '✕' '#FF453A' $it.name $(if ($s0 -and $e0) { Fmt-Dur ($e0 - $s0).TotalSeconds }) $(if ($it.message) { $it.message } else { '失敗了，看記錄' }) }
                'skipped' { Bg-Row '–' '#8E8E93' $it.name '跳過' $it.message }
                'running' { Bg-Row '●' '#0A84FF' $it.name $(if ($s0) { "$($s0.ToString('HH:mm')) 開始" }) '' }
                default   { Bg-Row '○' '#8E8E93' $it.name '排隊' '' }
            }
        }
    }
    # 不在佇列裡的單款（PadSwitch 背景跑的、命令列跑的）
    $qPids = @(if ($q) { @($q.items) | Where-Object { $_.pid } | ForEach-Object { [int]$_.pid } })
    $solo = @($runs | Where-Object { $qPids -notcontains [int]$_.pid } | Sort-Object _start -Descending)
    if (-not $title -and $solo.Count) {
        $r = $solo[0]
        $w = if ($whatName.ContainsKey([string]$r.what)) { $whatName[[string]$r.what] } else { '執行' }
        if ($r.state -eq 'running') {
            $step = if ($r.phase) { "$($r.step) · $($r.phase)" } elseif ($r.step) { $r.step } else { '準備中' }
            $title = "$($r.game) · $step"
            $st = To-Date $r.stepAt
            if ($st) { $title += "（$(Fmt-Dur ($now - $st).TotalSeconds)）" }
            if ($r._start) { $sub = "$w · $($r._start.ToString('HH:mm')) 開始" }
        } else {
            $title = if ($r.state -eq 'failed') { "$($r.game) $w 失敗" } else { "$($r.game) $w 完成" }
            if ($r._end) { $sub = "$($r._end.ToString('HH:mm')) 結束" }
        }
    }
    if ($solo.Count -gt 1 -or ($q -and $solo.Count)) {
        foreach ($r in $solo) {
            $w = if ($whatName.ContainsKey([string]$r.what)) { $whatName[[string]$r.what] } else { '執行' }
            $dur = if ($r._start) { Fmt-Dur ((@($r._end, $now) | Where-Object { $_ } | Select-Object -First 1) - $r._start).TotalSeconds }
            switch ($r.state) {
                'running' { Bg-Row '●' '#0A84FF' "$($r.game) · $w" $dur $(if ($r.step) { $r.step }) }
                'failed'  { Bg-Row '✕' '#FF453A' "$($r.game) · $w" $dur $r.message }
                default   { Bg-Row '✓' '#30D158' "$($r.game) · $w" $dur '' }
            }
        }
    } elseif ($solo.Count -eq 1 -and -not $q -and $solo[0].state -eq 'failed' -and $solo[0].message) { $sub = $solo[0].message }
    if (-not $title -and $pushLast) { $title = if ($pushLast.state -eq 'running') { '傳遊戲資料到 iPad' } elseif ($pushLast.state -eq 'failed') { '傳到 iPad 沒完成' } else { '傳到 iPad 完成' } }
    if (-not $title) { $ui.Bg.Visibility = 'Collapsed'; return }
    $ui.BgTitle.Text = $title
    $ui.BgSub.Text = $sub; $ui.BgSub.Visibility = if ($sub) { 'Visible' } else { 'Collapsed' }
    $ui.BgSub.Foreground = Brush $(if ($sub -and -not $q -and $solo.Count -eq 1 -and $solo[0].state -eq 'failed') { '#FF453A' } else { '#8E8E93' })
    $ui.BgTags.Visibility = if ($ui.BgTags.Children.Count) { 'Visible' } else { 'Collapsed' }

    # 傳到 iPad：百分比、GB、剩多久（結束 30 分鐘內還顯示結果）
    if ($pushLast -and ($pushLast.state -eq 'running' -or ($now - $pushLast._end).TotalMinutes -lt 30)) {
        $tot = [double]$pushLast.total; $sent = [double]$pushLast.sent
        $frac = if ($tot -gt 0) { [math]::Min(1, $sent / $tot) } elseif ($pushLast.state -eq 'done') { 1 } else { 0 }
        $ui.BgPush.Visibility = 'Visible'
        $ui.BgFill.Background = Brush $(if ($pushLast.state -eq 'failed') { '#FF453A' } elseif ($pushLast.state -eq 'done') { '#30D158' } else { '#0A84FF' })
        $bg.Frac = $frac; $ui.BgFill.Width = [math]::Max(0, $ui.BgTrack.ActualWidth * $frac)
        switch ($pushLast.state) {
            'running' {
                $ui.BgPushL.Text = if ($tot -gt 0) { "傳到 iPad $([math]::Floor($frac * 100))% · $(Fmt-GB $sent) / $(Fmt-GB $tot)" } else { "傳到 iPad · $($pushLast.phase)" }
                if ($pushLast.phase -and $pushLast.phase -ne '傳送中' -and $tot -gt 0) { $ui.BgPushL.Text += " · $($pushLast.phase)" }
                elseif ($pushLast.game -and $tot -gt 0) { $ui.BgPushL.Text += " · 正在傳 $($pushLast.game)" }
                $ui.BgPushR.Text = if ($pushLast.eta) { "剩約 $(Fmt-Dur $pushLast.eta)" + $(if ($pushLast.rate) { ' · {0:N0} MB/s' -f ($pushLast.rate / 1MB) }) } else { '' }
                $ui.BgPushL.Foreground = Brush '#F5F5F7'
            }
            'failed' { $ui.BgPushL.Text = "傳到 iPad 沒完成：$($pushLast.message)"; $ui.BgPushR.Text = $pushLast._end.ToString('HH:mm'); $ui.BgPushL.Foreground = Brush '#FF453A' }
            default  { $ui.BgPushL.Text = if ($tot -gt 0) { "傳到 iPad 完成 · $(Fmt-GB $tot)" } else { '傳到 iPad 完成（遊戲資料本來就在 iPad 上）' }; $ui.BgPushR.Text = $pushLast._end.ToString('HH:mm'); $ui.BgPushL.Foreground = Brush '#30D158' }
        }
    } else { $ui.BgPush.Visibility = 'Collapsed' }

    $note = if ($q) { [string]$q.note } else { '' }
    $ui.BgNote.Text = $note; $ui.BgNote.Visibility = if ($note) { 'Visible' } else { 'Collapsed' }
    $hasList = $ui.BgList.Children.Count -gt 0
    $ui.BgMore.Visibility = if ($hasList) { 'Visible' } else { 'Collapsed' }
    $ui.BgMore.Content = if ($bg.Open) { '收起' } else { '清單' }
    $ui.BgList.Visibility = if ($hasList -and $bg.Open) { 'Visible' } else { 'Collapsed' }
    $ui.Bg.Visibility = 'Visible'
}
$ui.BgMore.Add_Click({ $bg.Open = -not $bg.Open; Update-Bg })
$ui.BgTrack.Add_SizeChanged({ param($s, $e) $ui.BgFill.Width = [math]::Max(0, $e.NewSize.Width * $bg.Frac) })
$bgTimer = New-Object Windows.Threading.DispatcherTimer
$bgTimer.Interval = [TimeSpan]::FromSeconds(3)
$spaceSeen = $null
$bgTimer.Add_Tick({
    try { Update-Bg } catch { }
    # 背景算好的遊戲包大小、讀到的 iPad 空間：更新卡片上的大小和空間圖
    try {
        if (End-Sizes) {
            foreach ($card in $cards.Values) { Update-GameSizeBadge $card }
            Update-SelCount
            Start-Sizes
        }
    } catch { }
    try { if ((End-Tidy) -and -not $state.Running -and -not $drag.Card) { Build-Library } } catch { }
    try {
        $sf = Get-Item -LiteralPath $spaceFile -ErrorAction SilentlyContinue
        $sig = if ($sf) { $sf.LastWriteTimeUtc.Ticks } else { 0 }
        if ($spaceJob.Proc -and -not $spaceJob.Proc.HasExited -and ((Get-Date) - $spaceJob.Started).TotalSeconds -gt 45) {
            try { $spaceJob.Proc.Kill() } catch { }
        }
        $probeDone = $spaceJob.Proc -and $spaceJob.Proc.HasExited
        if ($probeDone) {
            $spaceJob.Failed = $spaceJob.Proc.ExitCode -ne 0
            $spaceJob.Proc.Dispose()
            $spaceJob.Proc = $null
        }
        if ($probeDone -or $sig -ne $script:spaceSeen) { $script:spaceSeen = $sig; Update-SelCount }
        if ($probeDone -and $spaceJob.SyncPending) { $spaceJob.SyncPending = $false; Run-Sync }
    } catch { } })

# 跑選的遊戲：mode = both / pack / install；merge = 合成一包
function Run-Games($dirs, $mode, $merge) {
    $jobs = @()
    if ($merge -and $script:addTo) { Add-ToPack $script:addTo $dirs $mode; return }
    if ($merge) { Run-Library $dirs $mode; return }
    if ($merge) {
        if ($mode -ne 'install' -and $dirs.Count -lt 2) { [void][Windows.MessageBox]::Show('合成一包至少要選 2 款。', '合成一包'); return }
        if ($mode -eq 'install') {
            # 只安裝：裝 nxn\合包 裡最新的那包，不管勾了哪些遊戲
            $mdir = (Pack-Dir)
            $last = Get-ChildItem -LiteralPath $mdir -Filter '*.ipa' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $last) { [void][Windows.MessageBox]::Show('還沒有合成好的包，先用「打包並安裝」或「只打包」。', '合成一包'); return }
            $mg2 = [pscustomobject]@{ Dir = $mdir; Name = "合包（$($last.Name)）"; Ipas = @($last); Base = $false }
            Start-Run @(@{ Game = $mg2; Mode = 'install'; Ipa = $last.FullName })
            return
        }
        $ms = Get-MultiShell; $mg = Get-MergeScript
        $id = if ($ms.Name -match 'shell-\d+-([0-9a-f]+)') { $Matches[1] } else { 'multi' }
        $outs = @()
        foreach ($dir in $dirs) {
            $g = $cards[$dir].Tag
            if (-not $g.Base) { [void][Windows.MessageBox]::Show("$($g.Name) 的資料夾裡沒有遊戲本體（NSP/XCI）。", '缺本體'); return }
            # 每款先用多遊戲殼各自打包成 <資料夾>-multi-<殼版本>.ipa，不碰正式的 IPA
            $o = Join-Path $g.Dir ("$($g.Name)-multi-$id.ipa")
            $outs += $o
            $jobs += @{ Game = $g; Mode = 'mergepart'; Ipa = ''; Out = $o; Shell = $ms.FullName }
        }
        $mdir = (Pack-Dir)
        New-Item -ItemType Directory -Force -Path $mdir | Out-Null
        $names = ($dirs | ForEach-Object { $cards[$_].Tag.Name }) -join '、'
        $pname = Ask-Text '合成一包' 'iPad 主畫面上顯示的名稱（之後也可以在「合包」裡改）' '遊戲合包'
        if (-not $pname) { return }
        $mout = Pack-Path $pname
        # 每包自己的 bundle ID，兩包才能同時裝在 iPad 上（改名時不給，沿用原本的，存檔才留得住）
        $md5 = [Security.Cryptography.MD5]::Create()
        $bid = 'org.nxnative.games.p' + (-join ($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFileNameWithoutExtension($mout))) | Select-Object -First 4 | ForEach-Object { $_.ToString('x2') }))
        $call = "Write-Host '==> 合成一包：$($names -replace "'", "''")'; & $(Quote (Get-Python)) $(Quote $mg) -o $(Quote $mout) --name $(Quote $pname) --bundle-id $bid $(($outs | ForEach-Object { Quote $_ }) -join ' '); " +
                "if (`$LASTEXITCODE) { Write-Host '出錯了：合包失敗'; `$global:LASTEXITCODE = 1; return }; Write-Host `"合包完成：$($mout -replace "'", "''")`""
        if ($mode -eq 'both') { $call += "; & $(Quote $script) -Ipa $(Quote $mout) -NoPause" }
        $mg2 = [pscustomobject]@{ Dir = $mdir; Name = "合成一包（$($dirs.Count) 款）"; Ipas = @(); Base = $true }
        $jobs += @{ Game = $mg2; Mode = $(if ($mode -eq 'both') { 'merge+install' } else { 'merge' }); Ipa = ''; Call = $call }
    } else {
        foreach ($dir in $dirs) {
            $g = $cards[$dir].Tag
            if ($mode -eq 'install') {
                if (-not $g.Ipas.Count) { [void][Windows.MessageBox]::Show("$($g.Name) 還沒有打包好的 IPA，先用「打包並安裝」。", '沒有 IPA'); return }
                # 裝資料夾裡最新打包的那個（重簽才是照安裝紀錄裝上次那個）
                $jobs += @{ Game = $g; Mode = 'install'; Ipa = $g.Ipas[0].FullName }
            } else {
                if (-not $g.Base) { [void][Windows.MessageBox]::Show("$($g.Name) 的資料夾裡沒有遊戲本體（NSP/XCI）。", '缺本體'); return }
                $jobs += @{ Game = $g; Mode = $mode; Ipa = '' }
            }
        }
    }
    Start-Run $jobs
}

$ui.TabGames.Add_Checked({ Set-Tab })
$ui.TabPacks.Add_Checked({ Set-Tab })
# 切到遊戲庫：勾選換成遊戲庫現在有的遊戲（加入合包時不換，勾的是要加的）；切回各自安裝就清掉
$ui.Start.Add_Click({
    if (@(Setup-Missing).Count) { [void][Windows.MessageBox]::Show('還沒安裝打包和簽章工具，請先按上面的「安裝」。', 'PadSwitch'); return }
    if ($picked.Count) {
        $pd = @(Picked-Dirs | Where-Object { $cards[$_].Tag.Base })
        $again = @($pd | Where-Object { $cards[$_].Tag.Ready })
        if ($again.Count) {
            $ok = [Windows.MessageBox]::Show($win, "選的遊戲裡有 $($again.Count) 款已經轉好了（$((@($again | ForEach-Object { $cards[$_].Tag.Name }) | Select-Object -First 4) -join '、')）。`n`n是：全部重新轉檔　否：只轉還沒轉的", '轉檔', 'YesNoCancel', 'Question')
            if ($ok -eq 'Cancel') { return }
            if ($ok -eq 'No') { $pd = @($pd | Where-Object { -not $cards[$_].Tag.Ready }) }
        }
        $picked.Clear()
        if ($state.Running) { $b = @(Busy-Dirs); $pd = @($pd | Where-Object { $b -notcontains $_ }) }
        Run-Convert $pd; Build-Library; return
    }
    $conv = @($selected | Where-Object { $cards.ContainsKey($_) -and -not $cards[$_].Tag.Ready -and $cards[$_].Tag.Base })
    Run-Convert $conv })
# 只放轉換好的（和本來就在 iPad 上的）；還沒轉換的等下次「轉檔」
# 轉換中按：正在轉和排隊中的也算進去，排在它們後面，轉完就接著合成、裝
function Sync-Library { Run-Sync }
$ui.Sync.Add_Click({
    if (@(Setup-Missing).Count) { [void][Windows.MessageBox]::Show('還沒安裝打包和簽章工具，請先按上面的「安裝」。', 'PadSwitch'); return }
    Sync-Library })

# 重簽本來只把現在的遊戲庫重裝一次；換了殼還沒合成過就順便用新殼合成，不然 iPad 上一直是舊殼
$ui.RenewBtn.Add_Click({
    if ($state.Running) { return }
    $ms = Get-MultiShell
    if ($ms -and ((Shell-Changed $ms.FullName) -or (Look-Changed)) -and -not @(Setup-Missing).Count) { Sync-Library } else { Run-Library @() 'install' } })

$ui.Stop.Add_Click({
    $state.Queue.Clear()
    if ($state.Proc -and -not $state.Proc.HasExited) { & taskkill.exe /PID $state.Proc.Id /T /F | Out-Null }
})
# 跑完後倒數回遊戲庫
$backTimer = New-Object Windows.Threading.DispatcherTimer
$backTimer.Interval = [TimeSpan]::FromSeconds(1)
$backTimer.Add_Tick({
    $state.BackIn--
    if ($state.BackIn -le 0) { $backTimer.Stop(); $ui.Back.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
    else { $ui.ProgTitle.Text = "$($state.DoneTitle)，$($state.BackIn) 秒後回到遊戲庫" }
})
$ui.Back.Add_Click({
    $backTimer.Stop()
    $ui.ProgressView.Visibility = 'Collapsed'; $ui.LibraryView.Visibility = 'Visible'; Fade-In $ui.LibraryView
    $ui.Back.Visibility = 'Collapsed'; $ui.Start.Visibility = 'Visible'; $ui.Sync.Visibility = 'Visible'; $ui.Options.Visibility = 'Visible'
    # 還在跑：回遊戲庫看、加遊戲排隊，「查看進度」回來
    if ($state.Running) { $ui.Stop.Visibility = 'Collapsed'; $ui.ShowProg.Visibility = 'Visible' }
    Set-Tab
    Build-Library })
$ui.ShowProg.Add_Click({ Show-Progress })
$ui.Refresh.Add_Click({
    # 之前讀不到圖示的再試一次（例如後來才放了 prod.keys）
    Get-ChildItem -Path $coverDir -Filter '*.none' -ErrorAction SilentlyContinue | Remove-Item -ErrorAction SilentlyContinue
    Build-Library; Update-Account; Check-Updates; Start-SpaceProbe -Force })

# ---------------------------------------------------------------- 清理空間：只清做得回來的東西（照 NX Play / NX2Apple 的 Free Up Space），一律丟資源回收筒
# 遊戲本體、正式的 IPA、存檔備份都不碰
function Size-Of($item) {
    if ($item.PSIsContainer) { [long](Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum }
    else { [long]$item.Length }
}
# 合成遊戲庫成功後自動清：已經有現在格式遊戲包的那幾款，舊殼做的遊戲包和以前單款安裝的 IPA 都用不到了。
# 直接刪（不進資源回收筒，不然空間不會回來）；要的話都能從原檔再轉。留著可以退回的那一版殼做的
function Clean-AfterMerge {
    $keepIds = @(Keep-Shells | ForEach-Object { Multi-Id $_ })
    $freed = 0L
    foreach ($gd in Get-ChildItem -LiteralPath $gamesDir -Directory -ErrorAction SilentlyContinue) {
        $ipas = @(Get-ChildItem -LiteralPath $gd.FullName -File -Filter '*.ipa' -ErrorAction SilentlyContinue)
        $isKept = { param($f) @($keepIds | Where-Object { $f.Name -like "*-multi-$_.ipa" }).Count -gt 0 }
        if (-not @($ipas | Where-Object { & $isKept $_ }).Count) { continue }   # 這款還沒有現在格式的遊戲包：舊的先留著
        foreach ($f in $ipas) {
            if (& $isKept $f) { continue }
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $freed += $f.Length } catch { }
        }
    }
    $freed
}
function Free-Space($owner) {
    $found = @()   # @{ Item; What; Size }
    foreach ($f in Get-ChildItem -LiteralPath (Join-Path $work 'lite') -File -Filter '*.ipa' -ErrorAction SilentlyContinue) {
        $found += @{ Item = $f; What = '安裝用的小 App（下次安裝會重做）' }
    }
    foreach ($gd in Get-ChildItem -LiteralPath $gamesDir -Directory -ErrorAction SilentlyContinue) {
        # 打包器留下的工作資料夾（--keep-work 或中途停掉的），記錄 logs\ 留著
        foreach ($pk in Get-ChildItem -LiteralPath $gd.FullName -Directory -Filter '*_pack' -ErrorAction SilentlyContinue) {
            foreach ($x in Get-ChildItem -LiteralPath $pk.FullName -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'logs' }) {
                $found += @{ Item = $x; What = "$($gd.Name) 的打包暫存" }
            }
        }
        # 遊戲包（<名稱>-multi-<格式>.ipa）：留著的殼（正在用的和可以退回的）做的要留，其他的用不到
        $keepIds = @(Keep-Shells | ForEach-Object { Multi-Id $_ })
        foreach ($x in Get-ChildItem -LiteralPath $gd.FullName -File -Filter '*-multi-*.ipa' -ErrorAction SilentlyContinue) {
            if (@($keepIds | Where-Object { $x.Name -like "*-multi-$_.ipa" }).Count) { continue }
            $found += @{ Item = $x; What = "$($gd.Name) 舊殼做的遊戲包" }
        }
        # 一款一個 App 時打包的 IPA：現在只用遊戲庫，用不到了
        foreach ($x in Get-ChildItem -LiteralPath $gd.FullName -File -Filter '*.ipa' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*-multi-*.ipa' }) {
            $found += @{ Item = $x; What = '以前單款安裝的 IPA（遊戲庫用不到）' }
        }
    }
    # 留正在用的多遊戲殼和可以退回的那一個：其他測試殼、舊殼和它們的打包器原始碼（src-<版本>），以及換打包器時留的備份
    $keepShells = @(Keep-Shells)
    foreach ($sub in 'multigame', 'phonepads', 'dl') {
        foreach ($x in Get-ChildItem -Path (Join-Path $work $sub) -Recurse -Filter 'shell-*.zip' -File -ErrorAction SilentlyContinue) {
            if (@($keepShells | Where-Object { $x.FullName -eq $_.FullName }).Count) { continue }
            $found += @{ Item = $x; What = '用不到的舊殼' }
        }
        foreach ($x in Get-ChildItem -Path (Join-Path $work $sub) -Recurse -Directory -Filter 'src-*' -ErrorAction SilentlyContinue) {
            if (@($keepShells | Where-Object { $x.Parent.FullName -eq $_.DirectoryName -and $_.Name -like "shell-*-$($x.Name.Substring(4))*" }).Count) { continue }
            $found += @{ Item = $x; What = '用不到的舊殼' }
        }
    }
    foreach ($x in Get-ChildItem -LiteralPath $work -Directory -Filter 'src-*-backup*' -ErrorAction SilentlyContinue) {
        $found += @{ Item = $x; What = '換打包器時留的備份' }
    }
    $old = (Get-Date).AddDays(-30)
    foreach ($x in Get-ChildItem -LiteralPath $logDir -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $old }) {
        $found += @{ Item = $x; What = '30 天前的記錄' }
    }
    foreach ($f in $found) { $f.Size = Size-Of $f.Item }
    $found = @($found | Where-Object { $_.Size -gt 0 })
    if (-not $found.Count) { [void][Windows.MessageBox]::Show($owner, '沒有可以清的暫存檔。', '清理空間'); return }
    $total = ($found | ForEach-Object { $_.Size } | Measure-Object -Sum).Sum
    $lines = $found | Group-Object { $_.What } | ForEach-Object { '  {0}：{1:N1} GB' -f $_.Name, (($_.Group | ForEach-Object { $_.Size } | Measure-Object -Sum).Sum / 1GB) }
    $ok = [Windows.MessageBox]::Show($owner, ("可以清出 {0:N1} GB：`n`n{1}`n`n遊戲本體、遊戲庫和它用的遊戲包、存檔備份都不會動。移到資源回收筒？" -f ($total / 1GB), ($lines -join "`n")), '清理空間', 'YesNo', 'Question')
    if ($ok -ne 'Yes') { return }
    $freed = 0
    foreach ($f in $found) { if (Recycle $f.Item.FullName $f.Item.PSIsContainer) { $freed += $f.Size } }
    [void][Windows.MessageBox]::Show($owner, ('清掉 {0:N1} GB（在資源回收筒，清空回收筒才會真的空出來）。' -f ($freed / 1GB)), '清理空間')
}

# ---------------------------------------------------------------- 診斷資訊：回報問題時貼上（照 NX2Apple 的 Copy diagnostics）。不含金鑰內容、Apple ID 或遊戲檔
function Copy-Diagnostics($owner) {
    [Windows.Clipboard]::SetText((Diagnostics-Text))
    [void][Windows.MessageBox]::Show($owner, '診斷資訊複製好了，貼到 GitHub issue 或訊息裡就可以。裡面沒有金鑰內容、Apple ID 或遊戲檔。', '複製診斷資訊')
}
function Diagnostics-Text {
    $read = { param($f) if (Test-Path $f) { (Get-Content $f -Raw -ErrorAction SilentlyContinue).Trim() } else { '（沒有）' } }
    $py = Get-Python
    $pyv = '（找不到）'
    if ($py) { try { $pyv = (& $py --version 2>&1 | Out-String).Trim() } catch { } }
    $tpf = Join-Path $work 'python-transfer.txt'
    $k = Find-Keys
    $gens = if ($k) { @(Select-String -LiteralPath $k -Pattern '^\s*titlekek_([0-9a-fA-F]{2})\s*=' -ErrorAction SilentlyContinue | ForEach-Object { [Convert]::ToInt32($_.Matches[0].Groups[1].Value, 16) }) } else { @() }
    $sh = Current-Shell
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $apple = @(Get-Service -Name 'Apple Mobile Device Service', 'AppleMobileDeviceService' -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name)=$($_.Status)" })
    if (-not $apple.Count -and (Get-AppxPackage -Name 'AppleInc.AppleDevices' -ErrorAction SilentlyContinue)) { $apple = @('Apple Devices（Microsoft Store）') }
    $last = Get-ChildItem -LiteralPath $logDir -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $tail = if ($last) { (Get-Content -LiteralPath $last.FullName -Tail 40 -Encoding UTF8 -ErrorAction SilentlyContinue) -join "`n" } else { '' }
    # 記錄裡可能有 email：遮掉
    $tail = $tail -replace '[\w.+-]+@[\w-]+(\.[\w-]+)+', '<email>'
    $text = @(
        '=== PadSwitch 診斷資訊 ==='
        "PadSwitch：$(& $read (Join-Path $work 'app-version.txt'))"
        "殼和打包器：$(& $read (Join-Path $work 'release.txt'))"
        "使用中的殼：$(if ($sh) { $sh.Label } else { '（沒有）' })"
        "Windows：$(if ($os) { "$($os.Caption) $($os.Version)" } else { [Environment]::OSVersion.VersionString })"
        "PowerShell：$($PSVersionTable.PSVersion)"
        "Python（打包）：$pyv"
        "Python（傳檔）：$(& $read $tpf)"
        "plumesign：$(if (Test-Path $plume) { '有' } else { '沒有' })"
        "Apple 裝置服務：$(if ($apple.Count) { $apple -join ', ' } else { '找不到' })"
        "prod.keys：$(if ($k) { "有，最新到第 $(if ($gens) { [int]($gens | Measure-Object -Maximum).Maximum + 1 } else { '?' }) 代" } else { '找不到' })"
        "遊戲數：$(@(Get-ChildItem -LiteralPath $gamesDir -Directory -ErrorAction SilentlyContinue).Count)"
        "缺的工具：$(if (@(Setup-Missing).Count) { @(Setup-Missing) -join '、' } else { '無' })"
        ''
        "=== 最近的記錄（$(if ($last) { $last.Name } else { '沒有' })，最後 40 行）==="
        $tail
    ) -join "`r`n"
    return $text
}

# ---------------------------------------------------------------- 問題回報：一款遊戲閃退或打不開時，一鍵把要給人看的東西包成一個 zip
# iPad 那邊（saves_data.py logs --report）：這款最近兩次的記錄、殼另外留的最近兩次閃退記錄、紅字和閃退摘要
# 電腦這邊（這裡先放進暫存資料夾）：診斷資訊、這款最近的打包記錄、它用的設定檔 game.tsv（暫定設定檔的話看得出是推導的）
function Start-Report($g) {
    if ($state.Running -or -not $g.Tid) { return }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $extra = Join-Path $work "report\$stamp"
    New-Item -ItemType Directory -Force -Path $extra | Out-Null
    try { [IO.File]::WriteAllText((Join-Path $extra '診斷資訊.txt'), (Diagnostics-Text), (New-Object Text.UTF8Encoding $true)) } catch { }
    $l = Latest-Log $g
    if ($l) { Copy-Item -LiteralPath $l.FullName -Destination (Join-Path $extra ('打包記錄-' + $l.Name)) -ErrorAction SilentlyContinue }
    $prof = @(Get-ChildItem -Path (Join-Path $work "multigame\*\src-*\dm\games\$($g.Tid)\game.tsv") -ErrorAction SilentlyContinue) +
            @(Get-ChildItem -Path (Join-Path $work "src\dm\games\$($g.Tid)\game.tsv") -ErrorAction SilentlyContinue) | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($prof) { Copy-Item -LiteralPath $prof.FullName -Destination (Join-Path $extra 'game.tsv') -ErrorAction SilentlyContinue }
    $safe = ($g.Name -replace '[\\/:*?"<>|]', '_')
    $zip = Join-Path $base "記錄\問題回報\$safe-$stamp.zip"
    Start-Run @(@{ Game = $g; Mode = 'report'; Ipa = (Library-Ipa); Out = $zip; Shell = $extra })
}

# ---------------------------------------------------------------- 設定視窗
$ui.Settings.Add_Click({
    $sx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="設定" Width="560" SizeToContent="Height" Background="#141416" Foreground="#F5F5F7" ResizeMode="NoResize"
        FontFamily="Segoe UI, Microsoft JhengHei UI" FontSize="14" WindowStartupLocation="CenterOwner">
  <Window.Resources>__RES__</Window.Resources>
  <StackPanel Margin="22">
    <TextBlock Text="遊戲庫" Foreground="#8E8E93" Margin="4,0,0,6"/>
    <Border Background="#1C1C1E" CornerRadius="12" Padding="14">
      <StackPanel>
        <TextBlock x:Name="LibText" TextWrapping="Wrap"/>
        <WrapPanel Margin="0,10,0,0">
          <Button x:Name="SaveBackup" Content="備份 iPad 存檔" Margin="0,0,8,8"/>
          <Button x:Name="SaveRestore" Content="還原存檔…" Margin="0,0,8,8"/>
          <Button x:Name="SaveFolder" Content="存檔備份資料夾" Margin="0,0,8,8"/>
          <Button x:Name="Migrate" Content="搬舊 App 存檔…" Margin="0,0,8,8"/>
          <Button x:Name="PullLogs" Content="讀 iPad 記錄" Margin="0,0,8,8" ToolTip="遊戲在 iPad 上打不開或卡住時按：把記錄拿回電腦，列出殼還沒做的功能"/>
        </WrapPanel>
        <DockPanel Margin="0,6,0,0">
          <WrapPanel DockPanel.Dock="Right">
            <Button x:Name="ShellBack" Content="退回上一版" Margin="8,0,0,0" ToolTip="新殼裝到 iPad 後有遊戲變差：改用上一版殼，再按「同步」"/>
            <Button x:Name="ShellLock" Content="鎖定這一版" Margin="8,0,0,0" ToolTip="之後有新殼也先不換，等你解除鎖定"/>
            <Button x:Name="ShellLatest" Content="改用最新殼" Margin="8,0,0,0"/>
          </WrapPanel>
          <TextBlock x:Name="ShellText" VerticalAlignment="Center" TextWrapping="Wrap"/>
        </DockPanel>
        <TextBlock Foreground="#8E8E93" FontSize="12" Margin="0,2,0,0" TextWrapping="Wrap"
                   Text="每次更新遊戲庫前都會自動備份存檔。「搬舊 App 存檔」是換到遊戲庫時用的：先按一次把舊 App 的存檔存到電腦，刪掉舊 App、裝好遊戲庫後再按一次放進去。多遊戲殼的 .zip 放進 work\multigame，預設用最新的；新殼裝到 iPad 後有遊戲變差，按「退回上一版」再「同步」，遊戲格式一樣就不用重新轉換。"/>
      </StackPanel>
    </Border>
    <TextBlock Text="iPad" Foreground="#8E8E93" Margin="4,16,0,6"/>
    <Border Background="#1C1C1E" CornerRadius="12" Padding="14">
      <StackPanel>
        <DockPanel>
          <TextBlock Text="UDID（選填）" VerticalAlignment="Center" Margin="0,0,10,0"/>
          <TextBox x:Name="Udid" Background="#2C2C2E" Foreground="White" BorderThickness="0" Padding="6,4"/>
        </DockPanel>
        <TextBlock Foreground="#8E8E93" FontSize="12" Margin="0,8,0,0" TextWrapping="Wrap" Text="留空會自動找 USB 上的 iPad。"/>
      </StackPanel>
    </Border>
    <TextBlock Text="金鑰" Foreground="#8E8E93" Margin="4,16,0,6"/>
    <Border Background="#1C1C1E" CornerRadius="12" Padding="14">
      <StackPanel>
        <DockPanel>
          <Button x:Name="ChangeKeys" DockPanel.Dock="Right" Content="更換"/>
          <TextBlock x:Name="KeysText" VerticalAlignment="Center" TextWrapping="Wrap" Margin="0,0,12,0"/>
        </DockPanel>
        <TextBlock Foreground="#8E8E93" FontSize="12" Margin="0,8,0,0" TextWrapping="Wrap"
                   Text="打包要用你自己 Switch 匯出的 prod.keys。新遊戲解包失敗、說 prod.keys 太舊時，把 Switch 更新到最新系統，用 Lockpick_RCM 重新匯出，再按「更換」選新的檔案（也可以直接拖進主視窗）。"/>
      </StackPanel>
    </Border>
    <TextBlock Text="PadSwitch" Foreground="#8E8E93" Margin="4,16,0,6"/>
    <Border Background="#1C1C1E" CornerRadius="12" Padding="14">
      <DockPanel>
        <Button x:Name="UpdateApp" DockPanel.Dock="Right" Content="更新" Style="{StaticResource Primary}"/>
        <TextBlock x:Name="UpdateText" VerticalAlignment="Center" TextWrapping="Wrap" Margin="0,0,12,0"/>
      </DockPanel>
    </Border>
    <TextBlock Text="資料夾" Foreground="#8E8E93" Margin="4,16,0,6"/>
    <Border Background="#1C1C1E" CornerRadius="12" Padding="14">
      <WrapPanel>
        <Button x:Name="OpenGames" Content="打開遊戲資料夾" Margin="0,0,8,8"/>
        <Button x:Name="OpenLogs" Content="打開記錄資料夾" Margin="0,0,8,8"/>
        <Button x:Name="FreeSpace" Content="清理空間…" Margin="0,0,8,8"/>
        <Button x:Name="Diag" Content="複製診斷資訊" Margin="0,0,8,8"/>
        <Button x:Name="OldGui" Content="舊版簡易視窗" Margin="0,0,8,8"/>
      </WrapPanel>
    </Border>
    <Button x:Name="Done" Content="完成" Background="#0A84FF" FontWeight="SemiBold" HorizontalAlignment="Right" Margin="0,18,0,0" Padding="28,8"/>
  </StackPanel>
</Window>
'@
    $sw = Load-Window $sx
    $sw.Owner = $win
    $lib = Library-Ipa; $ms = Get-MultiShell
    $have = Test-Path -LiteralPath $lib
    $sw.FindName('LibText').Text = $(if ($have) { "$lib（$(@(Library-Tids).Count) 款）" } else { '還沒有遊戲庫：加入遊戲，按「轉檔」再按「同步」' })
    $idle = -not $state.Running
    # 殼：正在用哪一版、是不是最新、能不能退回
    $showShell = {
        $cur = Get-MultiShell; $all = @(Get-MultiShells); $newest = $all | Select-Object -First 1
        $pinned = [bool]($cfg.ShellPin -and $cur -and $cur.FullName -eq $cfg.ShellPin)
        $older = if ($cur) { $all | Where-Object { $_.LastWriteTime -lt $cur.LastWriteTime } | Select-Object -First 1 }
        $sw.FindName('ShellText').Text = if (-not $cur) { '還沒有多遊戲殼（放進 work\multigame）' } else {
            "多遊戲殼 $(Shell-Sha $cur)（$($cur.LastWriteTime.ToString('MM/dd'))）" +
            $(if ($pinned -and $newest.FullName -ne $cur.FullName) { "`n鎖定中，最新的是 $(Shell-Sha $newest)" + $(if ((Multi-Id $newest) -ne (Multi-Id $cur)) { '（換過去要重新轉換）' } else { '（換過去不用重新轉換）' }) }
              elseif ($pinned) { "`n鎖定中" } else { "`n最新的" }) }
        $sw.FindName('ShellBack').IsEnabled = $idle -and [bool]$older
        $sw.FindName('ShellBack').ToolTip = if ($older) { "改用 $(Shell-Sha $older)（$($older.LastWriteTime.ToString('MM/dd'))），再按「同步」" + $(if ((Multi-Id $older) -ne (Multi-Id $cur)) { '。遊戲格式不同，沒留著舊遊戲包的遊戲要重新轉換' } else { '。遊戲格式一樣，不用重新轉換' }) } else { '沒有上一版殼可以退回' }
        $sw.FindName('ShellLock').Visibility = if ($pinned -or -not $cur) { 'Collapsed' } else { 'Visible' }
        $sw.FindName('ShellLatest').Visibility = if ($pinned) { 'Visible' } else { 'Collapsed' }
        $sw.FindName('ShellLatest').IsEnabled = $idle
    }
    & $showShell
    $sw.FindName('ShellBack').Add_Click({ $cur = Get-MultiShell; $older = Get-MultiShells | Where-Object { $_.LastWriteTime -lt $cur.LastWriteTime } | Select-Object -First 1
        if ($older) { $cfg.ShellPin = $older.FullName; Save-Settings; & $showShell; Update-MergeOption; Build-Library } })
    $sw.FindName('ShellLock').Add_Click({ if ($cur = Get-MultiShell) { $cfg.ShellPin = $cur.FullName; Save-Settings; & $showShell } })
    $sw.FindName('ShellLatest').Add_Click({ $cfg.ShellPin = ''; Save-Settings; & $showShell; Update-MergeOption; Build-Library })
    $sw.FindName('SaveBackup').IsEnabled = $have -and $idle
    $sw.FindName('SaveRestore').IsEnabled = $have -and $idle -and [bool]@(Save-Backups (Save-Root $lib)).Count
    $sw.FindName('Migrate').IsEnabled = $idle
    $sw.FindName('PullLogs').IsEnabled = $have -and $idle
    $sw.FindName('PullLogs').Add_Click({ $sw.DialogResult = $false; Start-Run @(@{ Game = (Library-Game); Mode = 'pulllogs'; Ipa = (Library-Ipa) }) })
    $sw.FindName('SaveBackup').Add_Click({ $sw.DialogResult = $false; Run-Saves (Library-Game) (Library-Ipa) $false })
    $sw.FindName('SaveRestore').Add_Click({ $sw.DialogResult = $false; Run-Saves (Library-Game) (Library-Ipa) $true })
    $sw.FindName('SaveFolder').Add_Click({ Open-Folder (Save-Root (Library-Ipa)) })
    $sw.FindName('Migrate').Add_Click({ Run-Migrate $sw })
    $sw.FindName('Udid').Text = $cfg.Udid
    # 金鑰：現在用哪個 prod.keys（Find-Keys 的順序），最新到第幾代 titlekek（只讀名稱，不讀值）
    $showKeys = {
        $k = Find-Keys
        $sw.FindName('KeysText').Text = if (-not $k) { '找不到 prod.keys' } else {
            $gens = @(Select-String -LiteralPath $k -Pattern '^\s*titlekek_([0-9a-fA-F]{2})\s*=' -ErrorAction SilentlyContinue | ForEach-Object { [Convert]::ToInt32($_.Matches[0].Groups[1].Value, 16) })
            $newest = if ($gens) { [int]($gens | Measure-Object -Maximum).Maximum } else { $null }
            "$k`n" + $(if ($null -ne $newest) { "金鑰最新到第 $($newest + 1) 代（titlekek_$('{0:x2}' -f $newest)）" } else { '這個檔案裡沒有 titlekek，可能不完整' })
        }
    }
    & $showKeys
    $sw.FindName('ChangeKeys').Add_Click({
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Title = '選擇 prod.keys'; $dlg.Filter = 'prod.keys|*.keys|所有檔案|*.*'
        if ($dlg.ShowDialog($sw)) { Set-Keys $dlg.FileName; & $showKeys }
    })
    $sw.FindName('OpenGames').Add_Click({ Start-Process explorer.exe "`"$gamesDir`"" })
    $sw.FindName('OpenLogs').Add_Click({ Start-Process explorer.exe "`"$logDir`"" })
    $sw.FindName('FreeSpace').IsEnabled = -not $state.Running
    $sw.FindName('FreeSpace').Add_Click({ Free-Space $sw })
    $sw.FindName('Diag').Add_Click({ Copy-Diagnostics $sw })
    if ($here -ne $base -or -not (Test-Path (Join-Path $here 'nxn-gui.ps1'))) { $sw.FindName('OldGui').Visibility = 'Collapsed' }   # 舊版視窗只認得最上層的 遊戲\
    $sw.FindName('OldGui').Add_Click({ Start-HiddenPs (Join-Path $here 'nxn-gui.ps1') })
    $upd = Update-Available
    $sw.FindName('UpdateText').Text = if ($upd) { "有新版本：$upd" } elseif ($latest) { "已是最新（$($latest.tag_name)）" } else { '還沒問到 GitHub 上的版本' }
    $ub = $sw.FindName('UpdateApp')
    if (-not $upd) { $ub.Content = '重新安裝'; $ub.Style = $sw.FindResource([Windows.Controls.Button]) }
    $ub.IsEnabled = -not $state.Running
    $ub.Add_Click({ $sw.DialogResult = $false; Run-Setup })
    $sw.FindName('Done').Add_Click({ $sw.DialogResult = $true })
    if ($sw.ShowDialog()) {
        $cfg.Udid = $sw.FindName('Udid').Text.Trim()
        Save-Settings
        Update-ShellLabel
    }
})

$win.Add_Closing({ param($s, $e)
    if ($state.Proc -and -not $state.Proc.HasExited) {
        $r = [Windows.MessageBox]::Show('還有工作在跑，關掉會停止它。確定要關？', '還在執行', 'YesNo')
        if ($r -ne 'Yes') { $e.Cancel = $true; return }
        & taskkill.exe /PID $state.Proc.Id /T /F | Out-Null
    }
    if ($iconJob -and -not $iconJob.Proc.HasExited) { try { $iconJob.Proc.Kill() } catch { } } })

# 卡片排滿整個寬度：依視窗寬度決定一排幾張，每張一樣寬
$ui.LibraryView.Add_SizeChanged({ param($s, $e)
    $cols = [math]::Max(1, [math]::Floor(($e.NewSize.Width - 12) / 218))   # 一格：小框框那欄 58 + 8 + 圖示和名字 140 + 邊距 12
    if ($ui.Library.Columns -ne $cols) { $ui.Library.Columns = $cols; $ui.Others.Columns = $cols; $ui.Packs.Columns = $cols } })

Update-ShellLabel
# 視窗先出來再畫卡片（遊戲多時要幾秒），開啟時只畫一次
$ui.GamesHead.Text = '載入遊戲中…'
$win.Add_ContentRendered({ try { Update-Bg } catch { }; $bgTimer.Start(); try { Start-SpaceProbe } catch { } })
$ui.AllTrack.Add_SizeChanged({ param($s, $e) try { Update-Overall } catch { } })
[void]$win.ShowDialog()
