# nxn-app.ps1 - Switch Pad：Switch 遊戲打包到 iPad 的正式版視窗：遊戲用卡片選單挑，選好按「開始」就自動打包、簽章、裝到 iPad。
# 真正做事的是 nxn.ps1（每款一個 powershell 子程序），這裡只負責畫面、排隊和讀進度。
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.IO.Compression.FileSystem
# 從 .cmd 開時命令列視窗是隱藏的，出錯要用對話框才看得到
trap { [void][Windows.MessageBox]::Show($_.ToString(), 'Switch Pad 出錯'); break }

$here = $PSScriptRoot
# 程式檔都在 nxn\程式\，遊戲、合包和 Switch Pad.exe 在上一層 nxn\（舊版全部攤在 nxn\ 最上層，開起來會自己搬）
$appDirName = '程式'
$base = if ((Split-Path $here -Leaf) -eq $appDirName) { Split-Path $here -Parent } else { $here }
# 用 Start-Process 開 powershell 會走 ShellExecute：Windows 11 的預設主控台是 Windows Terminal，-WindowStyle Hidden 藏不住，
# 會留下一個標題「powershell」的視窗。跟 Switch Pad.exe 一樣用 CreateNoWindow 開就沒有視窗
function Start-HiddenPs($ps1, [string[]]$more = @()) {
    $psi = New-Object Diagnostics.ProcessStartInfo (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    $psi.Arguments = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$ps1`"") + $more) -join ' '
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WorkingDirectory = Split-Path $ps1
    [void][Diagnostics.Process]::Start($psi)
}

# ---------------------------------------------------------------- 搬家：最上層只留 Switch Pad.exe、遊戲、合包，其他收進 程式\
# 搬到一半失敗也沒關係：每次開都會把還留在最上層的搬過去。正在打包或安裝（另一個 Switch Pad 在跑）就等下次再搬。
function Build-Launcher($exe, $ico) {
    # Switch Pad.exe：只是用隱藏視窗的 PowerShell 開 程式\nxn-app.ps1，讓最上層有一個帶圖示的程式可以點
    $src = @'
using System; using System.Diagnostics; using System.IO; using System.Runtime.InteropServices;
static class SwitchPadLauncher {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int MessageBoxW(IntPtr h, string text, string caption, uint type);
    static int Main() {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string ps1 = Path.Combine(Path.Combine(dir, "程式"), "nxn-app.ps1");
        if (!File.Exists(ps1)) ps1 = Path.Combine(dir, "nxn-app.ps1");
        if (!File.Exists(ps1)) { MessageBoxW(IntPtr.Zero, "找不到 " + ps1, "Switch Pad", 0x10); return 1; }
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
        if ($r.Errors.HasErrors) { throw "做不出 Switch Pad.exe：$(@($r.Errors | ForEach-Object { $_.ErrorText }) -join '; ')" }
        Move-Item -LiteralPath $cp.OutputAssembly -Destination $exe -Force
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
function Move-ToAppDir {
    $appDir = Join-Path $base $appDirName
    $others = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'nxn[\w-]*\.ps1' })
    $plain = @('nxn*.ps1', 'nxn_*.py', 'fix_empty_romfs.py', 'make_provisional.py', 'romfs_data.py', 'keys_check.py', 'saves_data.py', 'NOTICE.txt', 'LibraryIcon.png', 'SwitchPad.ico', 'Switch Pad.cmd', '打包安裝視窗.cmd', '一鍵打包安裝.cmd', '首次登入AppleID.cmd') |
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
    # 舊版放在最上層的捷徑指向舊位置，Switch Pad.exe 取代它
    $lnk = Join-Path $base 'Switch Pad.lnk'
    if (Test-Path -LiteralPath $lnk) {
        try { if ((New-Object -ComObject WScript.Shell).CreateShortcut($lnk).Arguments -like '*nxn-app.ps1*') { Remove-Item -LiteralPath $lnk } } catch { }
    }
}
try {
    Move-ToAppDir
    $appDir = Join-Path $base $appDirName
    $exe = Join-Path $base 'Switch Pad.exe'
    if ((Test-Path (Join-Path $appDir 'nxn-app.ps1')) -and -not (Test-Path -LiteralPath $exe)) {
        $ico = Join-Path $appDir '工具\SwitchPad.ico'
        if (-not (Test-Path $ico)) { $ico = Join-Path $appDir 'SwitchPad.ico' }
        Build-Launcher $exe $ico
    }
    # 這次是從最上層開的，搬好了就從 程式\ 重開
    if ($here -eq $base -and (Test-Path (Join-Path $appDir 'nxn-app.ps1')) -and -not (Test-Path (Join-Path $base 'nxn-app.ps1'))) {
        if (Test-Path -LiteralPath $exe) { Start-Process -FilePath $exe }
        else { Start-HiddenPs (Join-Path $appDir 'nxn-app.ps1') }
        exit
    }
} catch {
    [void][Windows.MessageBox]::Show("整理資料夾沒完成，下次打開會再試一次：`n$($_.Exception.Message)", 'Switch Pad')
    if ($here -eq $base -and -not (Test-Path (Join-Path $base 'work'))) { exit }   # work\ 已經搬走，從這裡跑不起來
}

# 只開一個：已經開著就把那個視窗叫到前面。Switch Pad 自己重開（更新後）時舊的還沒關，等它幾秒
$appMutex = New-Object Threading.Mutex($false, 'Local\SwitchPadApp')
$owned = $false
try { $owned = $appMutex.WaitOne($(if ($args -contains '-Restart') { 15000 } else { 0 })) } catch [Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) {
    Add-Type -Namespace SwitchPad -Name Win -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr h, int cmd);'
    $other = Get-Process -Name powershell -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID -and $_.MainWindowTitle -eq 'Switch Pad' } | Select-Object -First 1
    if ($other) { [void][SwitchPad.Win]::ShowWindowAsync($other.MainWindowHandle, 9); [void][SwitchPad.Win]::SetForegroundWindow($other.MainWindowHandle) }
    else { [void][Windows.MessageBox]::Show('Switch Pad 已經在開啟中，等幾秒視窗就會出來。', 'Switch Pad') }
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
$appRepo = 'Mono0713/Switch-Pad'     # Switch Pad 自己的新版從這個 repo 的 release 拿
New-Item -ItemType Directory -Force -Path $logDir, $coverDir, $gamesDir | Out-Null

# ---------------------------------------------------------------- 設定（殼、UDID、要不要蓋舊 IPA），存在 work\app-settings.json
$cfg = @{ Shell = ''; Udid = ''; Overwrite = $false; Mode = 'both'; Library = $true }
try { (Get-Content $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $cfg[$_.Name] = $_.Value } } catch { }
function Save-Settings { try { [pscustomobject]$cfg | ConvertTo-Json | Set-Content $settingsFile -Encoding UTF8 } catch { } }

# ---------------------------------------------------------------- 樣式：照殼的設定頁（深色、iOS 分組卡片、藍色主按鈕）
$styles = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <SolidColorBrush x:Key="Bg" Color="#000000"/>
  <SolidColorBrush x:Key="Card" Color="#1C1C1E"/>
  <SolidColorBrush x:Key="Card2" Color="#2C2C2E"/>
  <SolidColorBrush x:Key="Sub" Color="#8E8E93"/>
  <SolidColorBrush x:Key="Accent" Color="#0A84FF"/>
  <Style TargetType="Button">
    <Setter Property="Foreground" Value="White"/>
    <Setter Property="Background" Value="#2C2C2E"/>
    <Setter Property="Padding" Value="16,8"/>
    <Setter Property="FontSize" Value="14"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="10" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.85"/></Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.7"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.35"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
    <Setter Property="Background" Value="#0A84FF"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="FontSize" Value="17"/>
    <Setter Property="Padding" Value="34,11"/>
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
    <Setter Property="Background" Value="#2C2C2E"/><Setter Property="Foreground" Value="White"/><Setter Property="BorderThickness" Value="0"/>
  </Style>
</ResourceDictionary>
'@

$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Switch Pad" Width="1220" Height="820" MinWidth="820" MinHeight="560"
        Background="#000000" Foreground="White" AllowDrop="True"
        FontFamily="Microsoft JhengHei UI" FontSize="14" WindowStartupLocation="CenterScreen">
  <Window.Resources>__RES__</Window.Resources>
  <Grid Margin="28,20,28,0">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- 標題列 -->
    <DockPanel Grid.Row="0" Margin="0,0,0,14">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
        <Ellipse x:Name="AcctDot" Width="9" Height="9" Fill="#8E8E93" Margin="0,0,8,0" VerticalAlignment="Center"/>
        <TextBlock x:Name="Account" Text="…" Foreground="#8E8E93" VerticalAlignment="Center" Margin="0,0,14,0"/>
        <Button x:Name="Login" Content="登入 Apple ID" Margin="0,0,8,0"/>
        <Button x:Name="Refresh" Content="⟳" ToolTip="重新整理" Margin="0,0,8,0" Padding="13,8"/>
        <Button x:Name="Settings" Content="⚙" ToolTip="設定" Padding="13,8"/>
      </StackPanel>
      <StackPanel>
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="Switch Pad" FontSize="30" FontWeight="Bold" ToolTip="按「＋ 加入」放進遊戲庫，按「放進遊戲庫」轉換，iPad 接上後按「裝到 iPad」；把 NSP / XCI / NSZ 拖到遊戲上加進那款，拖到空白處新增一款"/>
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
    </StackPanel>

    <!-- 遊戲庫 -->
    <ScrollViewer x:Name="LibraryView" Grid.Row="2" VerticalScrollBarVisibility="Auto">
      <StackPanel Margin="0,0,0,24">
        <TextBlock x:Name="GamesHead" Text="遊戲庫" FontSize="22" FontWeight="SemiBold" Margin="0,4,0,2"/>
        <TextBlock x:Name="InHint" Foreground="#8E8E93" FontSize="13" Margin="0,0,0,10" TextWrapping="Wrap" Text="iPad 上「遊戲庫」App 裡的遊戲。按「移除」拿掉。"/>
        <UniformGrid x:Name="Library" Columns="5" VerticalAlignment="Top" Margin="-6,0,8,16"/>
        <TextBlock x:Name="OutHead" Text="還沒加入" FontSize="22" FontWeight="SemiBold" Margin="0,8,0,2"/>
        <TextBlock x:Name="OutHint" Foreground="#8E8E93" FontSize="13" Margin="0,0,0,10" TextWrapping="Wrap" Text="電腦上有、還不在遊戲庫的遊戲。按「＋ 加入」放進去；把 NSP / XCI / NSZ 拖進視窗可以新增遊戲。"/>
        <UniformGrid x:Name="Others" Columns="5" VerticalAlignment="Top" Margin="-6,0,8,16"/>
        <TextBlock x:Name="PacksHead" Text="合包" FontSize="20" FontWeight="SemiBold" Margin="0,8,0,4" Visibility="Collapsed"
                   ToolTip="好幾款遊戲合成的一個 App。點一下看裡面有哪些遊戲"/>
        <UniformGrid x:Name="Packs" Visibility="Collapsed" Columns="5" VerticalAlignment="Top" Margin="-8,0,4,12"/>
      </StackPanel>
    </ScrollViewer>

    <!-- 進度 -->
    <DockPanel x:Name="ProgressView" Grid.Row="2" Visibility="Collapsed">
      <DockPanel DockPanel.Dock="Top" Margin="0,0,0,12">
        <TextBlock x:Name="ProgTotal" DockPanel.Dock="Right" Foreground="#8E8E93" VerticalAlignment="Center"/>
        <TextBlock x:Name="ProgTitle" Text="執行中" FontSize="20" FontWeight="SemiBold"/>
      </DockPanel>
      <ProgressBar x:Name="Busy" DockPanel.Dock="Top" Height="4" IsIndeterminate="True" Margin="0,0,0,12"
                   Background="#1C1C1E" Foreground="#0A84FF" BorderThickness="0"/>
      <ScrollViewer VerticalScrollBarVisibility="Auto">
        <StackPanel x:Name="Jobs" Margin="0,0,0,12"/>
      </ScrollViewer>
    </DockPanel>

    <!-- 底部列 -->
    <Border Grid.Row="3" Background="#1C1C1E" CornerRadius="18,18,0,0" Padding="22,14" Margin="-28,0,-28,0">
      <DockPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
          <Button x:Name="Stop" Content="停止" Margin="0,0,10,0" Visibility="Collapsed"/>
          <Button x:Name="Back" Content="返回" Margin="0,0,10,0" Visibility="Collapsed"/>
          <Button x:Name="RenewBtn" Margin="0,0,10,0" Visibility="Collapsed"/>
          <Button x:Name="Start" Content="放進遊戲庫" ToolTipService.ShowOnDisabled="True"
                  ToolTip="第一步，只在電腦上做：把加入的遊戲轉換好。不用接 iPad，一款失敗不影響其他款"/>
          <Button x:Name="Sync" Content="裝到 iPad" Style="{StaticResource Primary}" Margin="10,0,0,0" ToolTipService.ShowOnDisabled="True"
                  ToolTip="第二步，iPad 接著電腦時按：用轉換好的遊戲合成遊戲庫，裝到 iPad（存檔都留著）"/>
        </StackPanel>
        <StackPanel x:Name="Options" VerticalAlignment="Center" Margin="0,0,16,0">
          <TextBlock x:Name="SelCount" Text="" FontSize="15" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
          <TextBlock x:Name="SelSub" Text="" FontSize="13" Foreground="#8E8E93" Margin="0,3,0,0" TextTrimming="CharacterEllipsis" Visibility="Collapsed"/>
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
function Load-Window([string]$text) { [Windows.Markup.XamlReader]::Parse($text.Replace('__RES__', $styles)) }
# 自己的工作列身分，工作列才會用 Switch Pad 的圖示，不是 PowerShell 的
try {
    Add-Type -Namespace SwitchPad -Name Shell -MemberDefinition '[DllImport("shell32.dll")] public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string id);'
    [void][SwitchPad.Shell]::SetCurrentProcessExplicitAppUserModelID('SwitchPad.App')
} catch { }
$win = Load-Window $xamlText
if (Test-Path $appIcon) {
    # 讀進記憶體再用：BitmapFrame::Create(Uri) 會一直鎖住檔案，更新時就蓋不過去（"另一個處理程序正在使用檔案 ...\SwitchPad.ico"）
    try {
        $fs = [IO.File]::OpenRead($appIcon)
        try { $win.Icon = [Windows.Media.Imaging.BitmapFrame]::Create($fs, 'None', 'OnLoad') } finally { $fs.Dispose() }
    } catch { }
    # 不自己建桌面捷徑（使用者不要）；只把舊版建的「PowerShell 開 nxn-app.ps1」捷徑改指向 Switch Pad.exe
    try {
        $exe = Join-Path $base 'Switch Pad.exe'
        $lnkPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Switch Pad.lnk'
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
foreach ($n in 'AcctDot','Account','Login','Refresh','Settings','Subtitle','RenewBtn','LibraryView','Library','Notice','NoticeText','NoticeBtn','GamesHead','PacksHead','Packs','TabGames','TabPacks','InHint','OutHead','OutHint','Others',
               'ProgressView','ProgTitle','ProgTotal','Busy','Jobs','Stop','Back','Start','Sync','Options','SelCount',
               'ModeBoth','ModePack','ModeInstall','Separate','Merge','ShellLabel','SelSub') { $ui[$n] = $win.FindName($n) }

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
    $g = [pscustomobject]@{ Dir = $dir.FullName; Name = $dir.Name; Base = $false; BaseFile = ''; Update = ''; UpdateN = -1; Dlc = 0; Ipas = @(); Stray = 0; Tid = '' }
    foreach ($f in Get-ChildItem -LiteralPath $dir.FullName -File -ErrorAction SilentlyContinue) {
        if ($f.Extension -eq '.ipa') { if ($f.Name -notlike '*-multi-*') { $g.Ipas += $f }; continue }   # -multi- 是合包的半成品，不能單獨裝
        if ($f.Extension -notin '.nsp', '.xci', '.nsz', '.xcz') { continue }   # NSZ / XCZ 打包時會先解壓（nxn.ps1）
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
function Precheck-Of($g) {
    $f = Join-Path $g.Dir 'precheck.json'
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    try { @((Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json).items) } catch { @() }
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
    if (@(Get-ChildItem -Path (Join-Path $work "multigame\*\src-*\dm\games\$($g.Tid)\game.tsv") -ErrorAction SilentlyContinue).Count) { return @{ Text = '● 暫定設定'; Color = '#64D2FF'; Tip = '不在上游的支援清單，用打包器自動推導的設定檔：轉換過了，能不能玩要在 iPad 上試' } }
    return @{ Text = '● 不支援'; Color = '#FF453A'; Tip = '不在上游的支援清單，打包器會試著自動推導，但大多需要在 Mac 上調整才打得開' }
}

# ---------------------------------------------------------------- 遊戲圖示：一律用遊戲檔案裡的圖示（自己換的 cover.* 優先）
# 快取在 work\covers\<名稱>.png：先從資料夾裡的 IPA 拿（就是遊戲圖示），沒有 IPA 就在背景用 nx_extract 從本體讀出來
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
    if ($g.BaseFile -and -not (Test-Path -LiteralPath (Join-Path $coverDir "$key.none"))) { Queue-Icon $g $jpg }
    return $null
}

# 從本體讀圖示：nx_extract 會先寫 control.nacp 和 icon.jpg 再解程式，看到 icon.jpg 就把它停掉（--manifest 不解 RomFS）
$iconQueue = New-Object System.Collections.Queue
$iconJob = $null
$nxExtract = Join-Path $work 'tools\nx_extract.exe'
# prod.keys：Switch Pad 自己的（拖進視窗的會放在 work\）→ Ryujinx → yuzu 系的模擬器（跟 nxn.ps1 的 Find-Keys 一樣）
function Find-Keys {
    $c = @((Join-Path $work 'prod.keys'), (Join-Path $base 'prod.keys'), "$env:APPDATA\Ryujinx\system\prod.keys")
    foreach ($emu in 'yuzu', 'suyu', 'sudachi', 'citron', 'eden', 'torzu') { $c += "$env:APPDATA\$emu\keys\prod.keys" }
    foreach ($p in $c) { if (Test-Path -LiteralPath $p) { return $p } }
    return ''
}
function Queue-Icon($g, $dest) {
    $prodKeys = Find-Keys
    if (-not (Test-Path $nxExtract) -or -not $prodKeys) { return }
    if ($iconJob -and $iconJob.Dest -eq $dest) { return }
    foreach ($q in $iconQueue) { if ($q.Dest -eq $dest) { return } }
    $iconQueue.Enqueue(@{ Dir = $g.Dir; File = $g.BaseFile; Dest = $dest; Keys = $prodKeys })
    $iconTimer.Start()
}
$iconTimer = New-Object Windows.Threading.DispatcherTimer
$iconTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$iconTimer.Add_Tick({
    if ($script:iconJob) {
        $j = $script:iconJob
        $got = Join-Path $j.Tmp 'icon.jpg'
        $done = $j.Proc.HasExited
        if ((Test-Path $got) -or $done -or ((Get-Date) - $j.Start).TotalSeconds -gt 120) {
            Start-Sleep -Milliseconds 300   # 等它寫完
            if (-not $j.Proc.HasExited) { try { $j.Proc.Kill() } catch { } }
            if (Test-Path $got) {
                Copy-Item -LiteralPath $got -Destination $j.Dest -Force
                $card = $cards[$j.Dir]
                if ($card) { Paint-Icon $card.FindName('Icon') $card.FindName('Letter') $card.Tag (Load-Bitmap $j.Dest) }
            } else {
                # 讀不到（缺金鑰、檔案壞了）就記下來，不要每次開都重試
                Set-Content -LiteralPath ([IO.Path]::ChangeExtension($j.Dest, '.none')) -Value (Get-Date).ToString('s')
            }
            Start-Sleep -Milliseconds 200
            Remove-Item -LiteralPath $j.Tmp -Recurse -Force -ErrorAction SilentlyContinue
            $script:iconJob = $null
        }
        return
    }
    if ($iconQueue.Count -eq 0) { $iconTimer.Stop(); return }
    $q = $iconQueue.Dequeue()
    $tmp = Join-Path $env:TEMP ('switchpad-icon-' + [guid]::NewGuid().ToString('N'))
    $psi = New-Object Diagnostics.ProcessStartInfo $nxExtract
    $psi.Arguments = "`"$($q.Keys)`" `"$($q.File)`" - `"$tmp`" --manifest"
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    try {
        $p = [Diagnostics.Process]::Start($psi)
        $p.BeginOutputReadLine(); $p.BeginErrorReadLine()   # 不讀會塞住
        $script:iconJob = @{ Proc = $p; Tmp = $tmp; Dest = $q.Dest; Dir = $q.Dir; Start = Get-Date }
    } catch { }
})
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
        Margin="6" CornerRadius="18" Background="#1C1C1E" BorderThickness="3" BorderBrush="Transparent"
        AllowDrop="True">
  <Grid>
    <DockPanel Margin="14,16,14,14">
      <Button x:Name="Act" DockPanel.Dock="Bottom" HorizontalAlignment="Stretch" Margin="0,12,0,0" Padding="12,7" FontWeight="SemiBold"/>
      <StackPanel>
        <Border x:Name="Icon" Width="112" Height="112" CornerRadius="26" HorizontalAlignment="Center" Background="#2C2C2E">
          <TextBlock x:Name="Letter" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="52" FontWeight="Bold" Foreground="White"/>
        </Border>
        <TextBlock x:Name="Title" Margin="0,12,0,0" FontSize="15" FontWeight="SemiBold" Foreground="White" TextWrapping="Wrap"
                   TextAlignment="Center" MaxHeight="40" TextTrimming="CharacterEllipsis" Height="40"/>
        <TextBlock x:Name="Detail" Margin="0,2,0,0" FontSize="12" MinHeight="16" Foreground="#8E8E93" TextAlignment="Center" TextTrimming="CharacterEllipsis"/>
        <TextBlock x:Name="State" Margin="0,6,0,0" FontSize="13" FontWeight="SemiBold" TextAlignment="Center" TextTrimming="CharacterEllipsis"/>
        <TextBlock x:Name="Support" Margin="0,4,0,0" FontSize="12" TextAlignment="Center" TextTrimming="CharacterEllipsis"/>
      </StackPanel>
    </DockPanel>
    <Border x:Name="Pending" CornerRadius="9" Padding="10,3" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="10,10,0,0" Visibility="Collapsed">
      <TextBlock x:Name="PendingText" Foreground="White" FontSize="12" FontWeight="SemiBold"/>
    </Border>
    <Border x:Name="Check" Width="30" Height="30" CornerRadius="15" Background="#0A84FF" HorizontalAlignment="Right"
            VerticalAlignment="Top" Margin="0,10,10,0" Visibility="Collapsed">
      <TextBlock Text="✓" Foreground="White" FontSize="17" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <Border x:Name="DropHint" CornerRadius="17" Background="#D90A84FF" Visibility="Collapsed">
      <TextBlock Text="放開就加進這款" Foreground="White" FontSize="16" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
  </Grid>
</Border>
'@
$cards = @{}          # 資料夾路徑 → 卡片
$selected = New-Object System.Collections.Generic.List[string]

# 卡片：在遊戲庫的按「移除」、不在的按「＋ 加入」，左上角標還要做的那一步（待轉換、待裝到 iPad、裝到 iPad 時拿掉）
function Card-Paint($card) {
    $g = $card.Tag; $in = $selected.Contains($g.Dir)
    $act = $card.FindName('Act'); $pend = $card.FindName('Pending'); $pt = $card.FindName('PendingText')
    $act.Style = $win.FindResource([Windows.Controls.Button])
    $pend.Visibility = 'Collapsed'; $card.BorderBrush = [Windows.Media.Brushes]::Transparent   # 狀態只看卡片上那一行「●」
    if ($in) { $act.Content = '移除' } else { $act.Content = '＋ 加入'; $act.Style = $win.FindResource('Primary') }
    $act.IsEnabled = -not $state.Running -and ($in -or $g.Base -or $g.Ready)
    $act.ToolTip = if (-not $in -and -not $g.Base -and -not $g.Ready) { '資料夾裡沒有遊戲本體（NSP / XCI / NSZ）' } else { $null }
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
    $add = @($mine | Where-Object { $_.Ready -and -not $_.OnPad } | ForEach-Object { $_.Name })
    $del = @($cards.Values | Where-Object { $_.Tag.OnPad -and -not $selected.Contains($_.Tag.Dir) } | ForEach-Object { $_.Tag.Name })
    $upd = @($mine | Where-Object { $_.Newer } | ForEach-Object { $_.Name })
    $gl = @($mine | Where-Object { $_.OnPad -and (Game-Tid $_) -and (Test-Path -LiteralPath (Join-Path $base "合包\GL著色器\$(Game-Tid $_)")) })
    $left = @($mine | Where-Object { $_.Ready -or $_.OnPad }).Count
    $names = { param($l) (@($l | Select-Object -First 3) -join '、') + $(if ($l.Count -gt 3) { " 等 $($l.Count) 款" } else { '' }) }
    $t = @("遊戲庫 $($mine.Count) 款")
    if ($conv.Count) { $t += "$($conv.Count) 款要轉換" }
    $pad = @(); if ($add.Count) { $pad += "加入 $(& $names $add)" }; if ($del.Count) { $pad += "拿掉 $(& $names $del)" }; if ($upd.Count) { $pad += "更新 $(& $names $upd)" }
    $sub = if ($pad.Count) { "裝到 iPad 會" + ($pad -join '，') } elseif ($gl.Count) { '裝到 iPad 時會拿回 OpenGL 著色器' } elseif ($left) { 'iPad 已是最新' } else { '' }
    $ui.SelCount.Text = $t -join ' · '; $ui.SelCount.ToolTip = $null
    $ui.SelSub.Text = $sub; $ui.SelSub.ToolTip = $(if ($sub) { $sub } else { $null }); $ui.SelSub.Visibility = $(if ($sub) { 'Visible' } else { 'Collapsed' })
    $ui.Start.Content = if ($conv.Count) { "放進遊戲庫（轉換 $($conv.Count) 款）" } else { '放進遊戲庫' }
    $ui.Start.IsEnabled = [bool]$conv.Count
    $ui.Sync.IsEnabled = ($left -gt 0) -and ([bool]$pad.Count -or [bool]$gl.Count)
    $n = $add.Count + $del.Count + $upd.Count
    $ui.Sync.Content = if ($n) { "裝到 iPad（$n 款）" } else { '裝到 iPad' }
    if (-not $left -and $del.Count) { $ui.SelCount.Text = '遊戲庫至少要留一款轉換好的遊戲，才能裝到 iPad' }
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
    Menu-Item $cm '🔁  下次更新時重新打包' $g.Dir 'repack' ($ms -and (Test-Path -LiteralPath (Part-For $g (Multi-Id $ms)).Path) -and -not $state.Running)
    [void]$cm.Items.Add((New-Sep))
    Menu-Item $cm '🖼  換圖示…' $g.Dir 'cover'
    Menu-Item $cm '🔄  用遊戲原本的圖示' $g.Dir 'uncover' ([bool](Get-ChildItem -LiteralPath $g.Dir -Filter 'cover.*' -File -ErrorAction SilentlyContinue))
    [void]$cm.Items.Add((New-Sep))
    Menu-Item $cm '🗑  刪除…' $g.Dir 'delete' (-not $state.Running)
}
# ---------------------------------------------------------------- iPad 存檔：備份、還原都由 nxn.ps1 做（saves_data.py 經 App 的 Documents 讀寫）
# 備份在 <遊戲資料夾>\存檔備份\<時間>\，合包的在 合包\存檔備份\<合包名稱>\；每次安裝前也會自動備份一次
function Save-Root($ipa) {
    $d = Split-Path $ipa -Parent
    if ((Split-Path $d -Leaf) -eq '合包') { Join-Path $d ('存檔備份\' + [IO.Path]::GetFileNameWithoutExtension($ipa)) } else { Join-Path $d '存檔備份' }
}
function Save-Backups($root) {
    @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{8}-\d{6}' -and $_.Name -notmatch '\.part$' } | Sort-Object Name -Descending)
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
        Width="460" SizeToContent="Height" Background="#000000" Foreground="White" ResizeMode="NoResize"
        FontFamily="Microsoft JhengHei UI" FontSize="14" WindowStartupLocation="CenterOwner">
  <Window.Resources>__RES__</Window.Resources>
  <StackPanel Margin="22">
    <TextBlock Foreground="#8E8E93" TextWrapping="Wrap" Margin="0,0,0,10"
               Text="選一份備份還原回 iPad。iPad 上現在的存檔會先另外備份一份（名稱有 before-restore），選錯也救得回來。還原前先在 iPad 上把遊戲關掉。"/>
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
        $when = [datetime]::ParseExact($b.Name.Substring(0, 15), 'yyyyMMdd-HHmmss', $null)
        $it.Content = $when.ToString('yyyy/MM/dd HH:mm:ss') + $(if ($b.Name -match 'before-restore') { '（還原前自動備份）' } else { '' })
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
        'savebackup'  { Run-Saves $g (Save-Ipa $g) $false }
        'saverestore' { Run-Saves $g (Save-Ipa $g) $true }
        'log'    { $l = Latest-Log $g; if ($l) { Start-Process notepad.exe "`"$($l.FullName)`"" } }
        # 遊戲包是快取：刪掉，下次按「放進遊戲庫」就從遊戲檔重新轉換這款
        'repack' { $ms = Get-MultiShell; if ($ms) { Remove-Item -LiteralPath (Part-For $g (Multi-Id $ms)).Path -ErrorAction SilentlyContinue }; Build-Library }
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
function Build-Library {
    $script:libStamp = Library-Stamp
    $ui.Library.Children.Clear(); $ui.Others.Children.Clear(); $cards.Clear()
    $inst = @(Get-Installed)
    $libTids = @(Library-Tids)
    $ms = Get-MultiShell; $partId = if ($ms) { Multi-Id $ms } else { '' }
    $libTime = (Get-Item -LiteralPath (Library-Ipa) -ErrorAction SilentlyContinue).LastWriteTime
    $newShell = if ($ms) { Shell-Changed $ms.FullName } else { $false }
    $dirs = @(Get-ChildItem -LiteralPath $gamesDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($d in $dirs) {
        $g = Scan-Game $d
        if (-not $g.Base -and -not $g.Ipas.Count) { continue }   # 不是遊戲資料夾
        $g | Add-Member -NotePropertyName InLib -NotePropertyValue $selected.Contains($g.Dir) -Force
        $g | Add-Member -NotePropertyName OnPad -NotePropertyValue ([bool](Game-Tid $g) -and $libTids -contains (Game-Tid $g)) -Force
        $pf = if ($partId) { Part-For $g $partId }
        $g | Add-Member -NotePropertyName Ready -NotePropertyValue ([bool]$pf -and $pf.Fresh) -Force
        # iPad 上的是舊的：遊戲包比上次合成的遊戲庫新（換了殼或重新轉換過），裝到 iPad 時會換掉
        $g | Add-Member -NotePropertyName Newer -NotePropertyValue ([bool]($g.Ready -and $g.OnPad -and $libTime -and ($newShell -or (Get-Item -LiteralPath $pf.Path).LastWriteTime -gt $libTime))) -Force
        $card = [Windows.Markup.XamlReader]::Parse($cardXaml)
        $card.Tag = $g
        $card.FindName('Title').Text = $g.Name
        $parts = @()
        if (-not $g.Base) { $parts += '缺本體' }
        if ($g.Update -and $g.Update -notlike '#*') { $parts += "v$($g.Update)" } elseif ($g.Update) { $parts += '已更新' }   # 沒有更新檔就不寫版本，本體的版本號看不出來
        if ($g.Dlc) { $parts += "$($g.Dlc) DLC" }
        $card.FindName('Detail').Text = $parts -join ' · '
        $st = $card.FindName('State')
        $glRec = Join-Path $base "合包\GL著色器\$(Game-Tid $g)"
        $glN = if ((Game-Tid $g) -and (Test-Path -LiteralPath $glRec)) { @(Get-ChildItem -LiteralPath $glRec -File -ErrorAction SilentlyContinue).Count } else { -1 }
        $green = Brush '#30D158'; $blue = Brush '#0A84FF'; $gray = Brush '#8E8E93'; $st.ToolTip = $null
        $red = Brush '#FF453A'; $orange = Brush '#FF9F0A'
        $why = if ($addFail.ContainsKey($g.Dir)) { $addFail[$g.Dir] } else { '' }
        # 體檢（打包器解包完先看一下，寫在遊戲資料夾的 precheck.json）：不能玩的原因，和要注意的事
        $pre = Precheck-Of $g
        $preBad = @($pre | Where-Object { $_.level -eq 'bad' } | ForEach-Object { $_.text })
        $preWarn = @($pre | Where-Object { $_.level -eq 'warn' } | ForEach-Object { $_.text })
        if (-not $why -and $preBad.Count -and -not $g.Ready) { $why = $preBad -join '；' }
        $g | Add-Member -NotePropertyName Order -NotePropertyValue 9 -Force
        if ($g.InLib -and -not $g.Ready -and $why) { $st.Text = '● 轉換失敗'; $st.Foreground = $red; $st.ToolTip = "$why。右上角選單「最近的記錄」看完整記錄；其他遊戲不受影響"; $g.Order = 0 }
        elseif ($g.InLib -and $g.OnPad -and $glN -eq 0) { $st.Text = '● 到 iPad 上玩一下'; $st.Foreground = $orange; $st.ToolTip = 'OpenGL 遊戲：第一次沒有畫面，玩一下讓 iPad 記下它用的著色器，再接著電腦按「裝到 iPad」，就會有畫面'; $g.Order = 1 }
        elseif ($g.InLib -and $g.OnPad -and -not $g.Ready) { $st.Text = '● 要重新轉換'; $st.Foreground = $orange; $st.ToolTip = '換了新的殼或遊戲檔有更新：按「放進遊戲庫」重新轉換，iPad 上的這款先照舊能玩'; $g.Order = 1 }
        elseif ($g.InLib -and $g.Newer) { $st.Text = '● 等更新到 iPad'; $st.Foreground = $blue; $st.ToolTip = 'iPad 上的是舊的版本（換了殼或重新轉換過），按「裝到 iPad」換成新的，存檔都留著'; $g.Order = 2 }
        elseif ($g.InLib -and $g.OnPad) { $st.Text = '● 在 iPad 上'; $st.Foreground = $green; if ($glN -gt 0) { $st.ToolTip = "iPad 記下的 OpenGL 著色器 $glN 個" }; $g.Order = 4 }
        elseif ($g.InLib -and $g.Ready) { $st.Text = '● 等裝到 iPad'; $st.Foreground = $blue; $st.ToolTip = '轉換好了，iPad 接上後按「裝到 iPad」'; $g.Order = 2 }
        elseif ($g.InLib) { $st.Text = '● 等轉換'; $st.Foreground = $gray; $st.ToolTip = '按「放進遊戲庫」在電腦上轉換'; $g.Order = 3 }
        elseif ($g.OnPad) { $st.Text = '● 裝到 iPad 時拿掉'; $st.Foreground = $red; $g.Order = 0 }
        elseif ($why) { $st.Text = '● 上次轉換失敗'; $st.Foreground = $red; $st.ToolTip = $why; $g.Order = 1 }
        elseif ($g.Ready) { $st.Text = '● 轉換過了，加入就能裝'; $st.Foreground = $gray; $g.Order = 2 }
        else { $st.Text = '' }
        if ($g.Stray) { $st.Text += $(if ($st.Text) { ' · ' } else { '' }) + '⚠'; $st.ToolTip = "子資料夾裡有 $($g.Stray) 個檔案不會用到（打包器只讀第一層），要用的話把檔案移到外面" }
        if ($preWarn.Count -and -not $why) {
            if ($st.Text -and $st.Text -notlike '*⚠') { $st.Text += ' · ⚠' } elseif (-not $st.Text) { $st.Text = '⚠ 要注意'; $st.Foreground = $orange }
            $st.ToolTip = (@($(if ($st.ToolTip) { "$($st.ToolTip)" })) + @($preWarn | ForEach-Object { "⚠ $_" })) -join "`n"
        }
        # 支援程度只在「還沒加入」顯示，幫你挑；已經在遊戲庫的看上面那行就好
        $sb = $card.FindName('Support')
        if (-not $g.InLib) {
            $sup = Support-Of $g
            if ($sup.Text -eq '● 已驗證') { $sb.Text = '✓ 已驗證'; $sb.Foreground = $green }
            elseif ($sup.Text) { $sb.Text = '未驗證，可能打不開'; $sb.Foreground = $gray }
            if ($sup.Tip) { $sb.ToolTip = $sup.Tip }
        } else { $sb.Visibility = 'Collapsed' }
        Paint-Icon $card.FindName('Icon') $card.FindName('Letter') $g (Cover-For $g)

        $card.Add_MouseEnter({ param($s, $e) $s.Background = Brush '#2C2C2E' })
        $card.Add_MouseLeave({ param($s, $e) $s.Background = Brush '#1C1C1E' })
        $act = $card.FindName('Act'); $act.Tag = $card
        $act.Add_Click({ param($s, $e)
            $c = $s.Tag; $dir = $c.Tag.Dir
            if ($selected.Contains($dir)) { [void]$selected.Remove($dir) } else { $selected.Add($dir) }
            Save-Want; Build-Library })
        $card.Add_DragEnter({ param($s, $e) if ($e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { $s.FindName('DropHint').Visibility = 'Visible' } })
        $card.Add_DragLeave({ param($s, $e) $s.FindName('DropHint').Visibility = 'Collapsed' })
        $card.Add_Drop({ param($s, $e)
            $s.FindName('DropHint').Visibility = 'Collapsed'
            Add-Files $s.Tag.Dir @($e.Data.GetData([Windows.DataFormats]::FileDrop))
            $e.Handled = $true })
        $card.ContextMenu = New-CardMenu $g
        $card.Add_ContextMenuOpening({ param($s, $e) $m = $s.ContextMenu; $m.Items.Clear(); Fill-CardMenu $m $s.Tag })
        $panel = if ($g.InLib) { $ui.Library } else { $ui.Others }
        $at = 0; foreach ($c in $panel.Children) { if ($c.Tag.Order -le $g.Order) { $at++ } }   # 要你處理的排前面，在 iPad 上的排後面
        [void]$panel.Children.Insert($at, $card)
        $cards[$g.Dir] = $card
        Card-Paint $card
    }
    $nIn = $ui.Library.Children.Count; $nOut = $ui.Others.Children.Count
    $onPad = @($ui.Library.Children | Where-Object { $_.Tag.OnPad }).Count
    $ui.GamesHead.Text = "遊戲庫 · $nIn 款"; $ui.OutHead.Text = "還沒加入 · $nOut 款"
    if (-not $nIn) { $ui.InHint.Text = '遊戲庫還是空的：在下面的遊戲按「＋ 加入」，再按右下角「放進遊戲庫」。' }
    else { $ui.InHint.Text = "iPad 上 $onPad 款" + $(if ($nIn - $onPad) { "，還有 $($nIn - $onPad) 款沒裝上去" } else { '' }) + '。滑鼠移到卡片的狀態上可以看說明。' }
    if (-not $nOut) {
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = if ($cards.Count) { '電腦上的遊戲都在遊戲庫裡了。把 NSP / XCI / NSZ 拖進視窗新增遊戲。' } else { '把 NSP / XCI / NSZ 拖進來新增遊戲' }
        $t.ToolTip = "遊戲會放在 $gamesDir"
        $t.Foreground = Brush '#8E8E93'; $t.Margin = '8,16,8,0'; $t.FontSize = 15; $t.TextWrapping = 'Wrap'
        [void]$ui.Others.Children.Add($t)
    }
    Build-Packs $inst
    Update-SelCount
    Update-Banner $inst
    Update-MergeOption
    Update-Notice
}

# ---------------------------------------------------------------- 合包：nxn\合包 裡每個 IPA 一張卡，點進去看裡面的遊戲
# 合包裡每款在 Payload/<App>.app/games/<title ID>/：game.json（id、name、version…）和 icon.png
$packCache = @{}      # IPA 路徑|修改時間 → 讀到的遊戲清單（讀 zip 目錄要一點時間，不要每次重畫都讀）
function Read-Pack($ipa) {
    $key = "$($ipa.FullName)|$($ipa.LastWriteTimeUtc.Ticks)"
    if ($packCache.ContainsKey($key)) { return $packCache[$key] }
    $games = @()
    try {
        $z = [IO.Compression.ZipFile]::OpenRead($ipa.FullName)
        try {
            foreach ($e in $z.Entries) {
                if ($e.FullName -notmatch '^Payload/[^/]+\.app/games/([0-9A-Fa-f]{16})/game\.json$') { continue }
                $tid = $Matches[1].ToUpper()
                $sr = New-Object IO.StreamReader($e.Open(), [Text.Encoding]::UTF8)
                try { $j = $sr.ReadToEnd() | ConvertFrom-Json } finally { $sr.Dispose() }
                $icon = Join-Path $coverDir "pack-$tid.png"
                $ie = $z.GetEntry(($e.FullName -replace 'game\.json$', 'icon.png'))
                if ($ie -and -not (Test-Path -LiteralPath $icon)) { [IO.Compression.ZipFileExtensions]::ExtractToFile($ie, $icon, $true) }
                $games += [pscustomobject]@{ Tid = $tid; Name = $(if ($j.name) { $j.name } else { $tid }); Version = [string]$j.version
                                            Icon = $(if (Test-Path -LiteralPath $icon) { $icon } else { '' }) }
            }
        } finally { $z.Dispose() }
    } catch { }
    $games = @($games | Sort-Object Name)
    $packCache[$key] = $games
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
    $mdir = Join-Path $base '合包'
    $ipas = @(Get-ChildItem -LiteralPath $mdir -Filter '*.ipa' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        if (-not $ipas.Count) {
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = '還沒有遊戲庫：在「還沒加入」按「＋ 加入」，按「放進遊戲庫」，再按「裝到 iPad」'
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
        $card.Add_MouseEnter({ param($s, $e) $s.Background = Brush '#2C2C2E' })
        $card.Add_MouseLeave({ param($s, $e) $s.Background = Brush '#1C1C1E' })
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
            if ($p.Name -eq $libName) { [void][Windows.MessageBox]::Show("「$libName」的名稱是固定的，Switch Pad 靠它找到遊戲庫。", '合包改名'); return }
            $n = Ask-Text '合包改名' 'iPad 主畫面上顯示的名稱（也是檔名）。iPad 上要重新安裝才會變。' $p.Name
            if ($n -and $n -ne $p.Name) { Rename-Pack $p $n }
        }
    }
}
# 合包的名稱就是它的檔名，也是 iPad 主畫面上的名稱（nxn_merge.py --name）
function Pack-Path($name) {
    $safe = ($name -replace '[\\/:*?"<>|]', '_').Trim()
    if (-not $safe) { $safe = '遊戲合包' }
    $p = Join-Path (Join-Path $base '合包') "$safe.ipa"
    if (Test-Path -LiteralPath $p) { $p = Join-Path (Join-Path $base '合包') ("$safe-" + (Get-Date -Format 'MMdd-HHmm') + '.ipa') }
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
        Width="440" SizeToContent="Height" Background="#000000" Foreground="White" ResizeMode="NoResize"
        FontFamily="Microsoft JhengHei UI" FontSize="14" WindowStartupLocation="CenterOwner">
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
        Width="520" SizeToContent="Height" MaxHeight="760" Background="#000000" Foreground="White" ResizeMode="NoResize"
        FontFamily="Microsoft JhengHei UI" FontSize="14" WindowStartupLocation="CenterOwner">
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
$latestApp = $null    # Switch Pad 最新的 release
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
    if ($app -and $appHave -ne $app.updated_at) { $what += 'Switch Pad' }
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
    $ui.Settings.Foreground = Brush $(if ($upd) { '#0A84FF' } else { '#FFFFFF' })
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
        # 一個 WebClient 同時只能下載一個，Switch Pad 自己的 release 另開一個問
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
    $g = [pscustomobject]@{ Dir = $here; Name = 'Switch Pad'; Ipas = @(); Base = $false; BaseFile = ''; Icon = $appIcon }
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
    $lib = Library-Ipa
    if (-not (Test-Path -LiteralPath $lib)) { $ui.RenewBtn.Visibility = 'Collapsed'; return }
    $mine = $inst | Where-Object { $_.Ipa -eq $lib } | Select-Object -First 1
    $ui.RenewBtn.Content = if (-not $mine) { '重簽' } elseif ($mine.Left -le 0) { '重簽（已過期）' } else { "重簽（剩 $($mine.Left) 天）" }
    $ui.RenewBtn.Foreground = Brush $(if ($mine -and $mine.Left -le 3) { '#FF9F0A' } else { '#EBEBF5' })
    $ui.RenewBtn.ToolTip = "免費 Apple ID 簽的 App 7 天後就打不開。按這裡把 iPad 上的遊戲庫重簽一次，遊戲和存檔都不動。"
    $ms = Get-MultiShell
    if ($ms -and (Shell-Changed $ms.FullName)) { $ui.RenewBtn.ToolTip += "`n換了新殼，這次會先用新殼重新合成遊戲庫再裝。" }
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
# 兩秒內只看一次（在 Switch Pad 和別的視窗之間切來切去時不要每次都掃）
$lastActive = [datetime]::MinValue
$win.Add_Activated({
    if (((Get-Date) - $script:lastActive).TotalSeconds -lt 2) { return }
    $script:lastActive = Get-Date
    if (-not $state.Running -and $script:libStamp -and (Library-Stamp) -ne $script:libStamp) { Build-Library } })

# ---------------------------------------------------------------- Apple ID
function Update-Account {
    if (-not (Test-Path $plume)) { $ui.Account.Text = '找不到 plumesign.exe'; return }
    try {
        $out = (& $plume account list 2>&1 | ForEach-Object { "$_" }) -join "`n"
        $mail = [regex]::Match($out, '[\w.+-]+@[\w-]+(\.[\w-]+)+').Value
        if ($mail) { $ui.Account.Text = $mail; $ui.Account.Foreground = Brush '#EBEBF5'; $ui.AcctDot.Fill = Brush '#30D158'; $ui.Login.Content = '換帳號' }
        else { $ui.Account.Text = '還沒登入 Apple ID'; $ui.AcctDot.Fill = Brush '#FF453A'; $ui.Login.Content = '登入 Apple ID' }
    } catch { $ui.Account.Text = '無法確認 Apple ID' }
}
# 在 app 裡登入：plumesign 在背景跑，密碼和雙重驗證碼從它的標準輸入餵進去（不放在命令列上），輸出寫進檔案再輪詢
function Show-Login {
    $lx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="420" SizeToContent="Height" Background="#000000" Foreground="White" ResizeMode="NoResize"
        FontFamily="Microsoft JhengHei UI" FontSize="14" WindowStartupLocation="CenterOwner" Title="Apple ID">
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
$win.Add_ContentRendered({ Select-Library; Update-Account; Check-Updates })

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
        <TextBlock x:Name="Time" DockPanel.Dock="Right" Foreground="#8E8E93" FontFamily="Consolas"/>
        <TextBlock x:Name="Title" FontSize="17" FontWeight="SemiBold" Foreground="White"/>
      </DockPanel>
      <WrapPanel x:Name="Steps" Margin="0,10,0,0"/>
      <TextBlock x:Name="Msg" Foreground="#8E8E93" FontSize="12" Margin="0,8,0,0" TextTrimming="CharacterEllipsis"/>
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
    @{ Name = '同步';     Re = '==> 同步 OpenGL 著色器' },
    @{ Name = '合成';     Re = '==> 合成一包' },
    @{ Name = 'Python';   Re = '==> 檢查 Python' },
    @{ Name = '套件';     Re = '==> 安裝 Python 套件' },
    @{ Name = '打包器';   Re = '==> 檢查打包器' },
    @{ Name = '簽章工具'; Re = '==> 檢查簽章工具' },
    @{ Name = 'Switch Pad'; Re = '==> 檢查 Switch Pad' }
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
$state = @{ Queue = New-Object System.Collections.Queue; Job = $null; Proc = $null; Running = $false; Ok = 0; Fail = @(); Started = $null }

function Quote($s) { "'" + ($s -replace "'", "''") + "'" }

function New-Job($g, $mode, $ipa, $out = '', $shellPath = '') {
    $row = [Windows.Markup.XamlReader]::Parse($jobXaml)
    $row.FindName('Title').Text = $g.Name
    Paint-Icon $row.FindName('Icon') $row.FindName('Letter') $g (Cover-For $g)
    # @(...)：只有一個步驟時 switch 會把陣列攤成一個字串，$names[0] 就只剩第一個字（「同步」變「同」）
    $names = @(switch ($mode) {
        'setup'   { @('Python', '套件', '打包器', '簽章工具', 'Switch Pad') }
        'pack'    { @('解包', '轉換程式', '著色器', '打包') }
        { $_ -in 'mergepart', 'mergepart-reuse' } { @('解包', '轉換程式', '著色器', '準備合包') }
        'glsync'  { @('同步') }
        'merge'   { @('合成') }
        'merge+install' { @('合成', '檢查帳號', '簽章安裝', '傳資料') }
        'install' { @('檢查帳號', '簽章安裝', '傳資料') }
        { $_ -in 'savebackup', 'saverestore', 'savemigrate' } { @('存檔') }
        'pulllogs' { @('記錄') }
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
        'glsync'      { $a += @('-Ipa', (Quote $ipa), '-GlSync') }
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
    $job = [pscustomobject]@{ Game = $g; Row = $row; Steps = $pills; StepNames = $names; Args = $a; Call = ''; NeedAllOk = $false; Log = ''; Pos = 0; Dec = $null
                             Started = $null; Cur = -1; Text = $row.FindName('Log'); Msg = $row.FindName('Msg'); Time = $row.FindName('Time') }
    Set-Step $job -1 'todo'
    $job.Msg.Text = '排隊中'
    [void]$ui.Jobs.Children.Add($row)
    return $job
}

function Start-Run($jobs) {
    if (-not $jobs.Count) { return }
    $ui.Jobs.Children.Clear()
    $state.Queue.Clear(); $state.Ok = 0; $state.Fail = @(); $state.Running = $true; $state.Started = Get-Date
    foreach ($j in $jobs) {
        $nj = New-Job $j.Game $j.Mode $j.Ipa $j.Out $j.Shell
        if ($j.Lib) { $nj | Add-Member -NotePropertyName Lib -NotePropertyValue $j.Lib -Force }
        elseif ($j.Call) { $nj.Call = $j.Call; $nj.NeedAllOk = $true }
        $state.Queue.Enqueue($nj)
    }
    $ui.LibraryView.Visibility = 'Collapsed'; $ui.ProgressView.Visibility = 'Visible'; $ui.RenewBtn.Visibility = 'Collapsed'
    $ui.Options.Visibility = 'Hidden'; $ui.Start.Visibility = 'Collapsed'; $ui.Sync.Visibility = 'Collapsed'; $ui.Back.Visibility = 'Collapsed'; $ui.Stop.Visibility = 'Visible'
    $ui.Login.IsEnabled = $false; $ui.Settings.IsEnabled = $false; $ui.Refresh.IsEnabled = $false
    $ui.Busy.Visibility = 'Visible'; $ui.ProgTitle.Text = '執行中'
    Start-Next
}

function Start-Next {
    if ($state.Queue.Count -eq 0) {
        $state.Running = $false; $state.Job = $null
        $ui.Busy.Visibility = 'Collapsed'
        $ui.ProgTitle.Text = if ($state.Fail.Count) { "完成 $($state.Ok) 款，失敗：$($state.Fail -join '、')" } else { "全部完成（$($state.Ok) 款）" }
        $ui.Stop.Visibility = 'Collapsed'; $ui.Back.Visibility = 'Visible'
        $ui.Login.IsEnabled = $true; $ui.Settings.IsEnabled = $true; $ui.Refresh.IsEnabled = $true
        # 安裝或更新完：Switch Pad 自己換了新版就重開，不然重新讀殼、支援清單和帳號
        $flag = Join-Path $work 'app-restart.flag'
        if (Test-Path $flag) {
            Remove-Item $flag -ErrorAction SilentlyContinue
            Start-HiddenPs (Join-Path $here 'nxn-app.ps1') @('-Restart')
            $win.Close(); return
        }
        Load-Supported; Update-ShellLabel; Update-Account
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
            Set-Step $job 0 'fail'; $job.Msg.Text = "沒有新的遊戲可以放進遊戲庫，這次沒有重新合成（失敗：$($lc.Skip -join '、')）"; $job.Msg.Foreground = Brush '#FF453A'
            Start-Next; return
        }
        $job.Call = $lc.Call
        if ($lc.Skip.Count) { $job.Msg.Text = "跳過 $($lc.Skip -join '、')，其他照樣放進去" }
    }
    $state.Job = $job
    $job.Log = Join-Path $logDir ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ($job.Game.Name -replace '[^\w.-]', '_') + '.log')
    $job.Pos = 0; $job.Dec = [Text.Encoding]::UTF8.GetDecoder(); $job.Started = Get-Date
    Set-Step $job 0 'active'
    $job.Msg.Text = '開始…'
    # Write-Host 走資訊串流（6），*>&1 才收得到；結束碼交給外層的 exit
    $call = if ($job.Call) { $job.Call } else { "& $(Quote $script) $($job.Args -join ' ') -NoPause" }
    $cmd = "[Console]::OutputEncoding=[Text.Encoding]::UTF8; `$env:PYTHONUTF8='1'; `$global:LASTEXITCODE=0; & { $call } *>&1 | Out-File -Encoding utf8 -Width 400 $(Quote $job.Log); exit `$LASTEXITCODE"
    $psi = New-Object Diagnostics.ProcessStartInfo 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"$($cmd -replace '"', '\"')`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $state.Proc = [Diagnostics.Process]::Start($psi)
    $timer.Start()
}

function Read-Log($job) {
    if (-not $job.Log -or -not (Test-Path -LiteralPath $job.Log)) { return }
    try {
        $fs = New-Object IO.FileStream($job.Log, 'Open', 'Read', 'ReadWrite')
        try {
            if ($fs.Length -le $job.Pos) { return }
            [void]$fs.Seek($job.Pos, 'Begin')
            $buf = New-Object byte[] ($fs.Length - $job.Pos)
            $n = $fs.Read($buf, 0, $buf.Length)
            $job.Pos += $n
            $chars = New-Object char[] ($job.Dec.GetCharCount($buf, 0, $n))
            [void]$job.Dec.GetChars($buf, 0, $n, $chars, 0)
            $text = (-join $chars).Replace([string][char]0xFEFF, '')
            if (-not $text) { return }
            $job.Text.AppendText($text); $job.Text.ScrollToEnd()
            # 看到哪一步的開頭就把那一步點亮
            foreach ($line in ($text -split "`r?`n")) {
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
    $job.Time.Text = '{0:hh\:mm\:ss}' -f ((Get-Date) - $job.Started)
    $ui.ProgTotal.Text = '總共 {0:hh\:mm\:ss}' -f ((Get-Date) - $state.Started)
    if ($state.Proc -and $state.Proc.HasExited) {
        $timer.Stop()
        Read-Log $job
        $code = $state.Proc.ExitCode
        $state.Proc = $null
        if ($code -eq 0) {
            $state.Ok++
            if ($job.Game.Dir) { $addFail.Remove($job.Game.Dir) }
            Set-Step $job $job.StepNames.Count 'done'
            $job.Msg.Text = if ($job.StepNames -contains '簽章安裝') { '裝好了，可以在 iPad 上打開' } elseif ($job.StepNames -contains '打包器') { '準備好了' } elseif ($job.StepNames -contains '存檔') { '存檔好了' } elseif ($job.StepNames -contains '同步') { '著色器同步好了' } elseif ($job.StepNames -contains '記錄') { '記錄拿回來了，展開「記錄」看紅字清單' } else { '打包完成' }
            $job.Msg.Foreground = Brush '#30D158'
        } else {
            $state.Fail += $job.Game.Name
            if ($job.Game.Dir) { $addFail[$job.Game.Dir] = Fail-Reason $job.Log; $job.Msg.Text = $addFail[$job.Game.Dir] }
            Set-Step $job ([math]::Max($job.Cur, 0)) 'fail'
            $job.Msg.Foreground = Brush '#FF453A'
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
$libName = '遊戲庫'
$libBid = 'org.nxnative.games.library'
function Library-Ipa { Join-Path (Join-Path $base '合包') "$libName.ipa" }
# 遊戲庫上次是用哪個殼合成的（合成好時記在 遊戲庫.ipa.shell）；換了殼，遊戲包沒變也要重新合成，iPad 才用得到新殼
function Shell-Changed($shell) {
    $lib = Library-Ipa; $li = Get-Item -LiteralPath $lib -ErrorAction SilentlyContinue
    if (-not $shell -or -not $li) { return $false }
    $sh = Get-Item -LiteralPath $shell -ErrorAction SilentlyContinue
    $rec = "$lib.shell"
    if (Test-Path -LiteralPath $rec) { return ((Get-Content -LiteralPath $rec -Raw -Encoding UTF8).Trim() -ne $sh.Name) }
    return [bool]($sh -and $sh.LastWriteTime -gt $li.LastWriteTime)   # 還沒有記錄的舊遊戲庫：殼比遊戲庫新就算換過
}
function Library-Tids {
    $f = Get-Item -LiteralPath (Library-Ipa) -ErrorAction SilentlyContinue
    if (-not $f) { return @() }
    @(Read-Pack $f | ForEach-Object { $_.Tid })
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
function Part-For($g, $id) {
    $o = Join-Path $g.Dir ("$($g.Name)-multi-$id.ipa")
    $f = Get-Item -LiteralPath $o -ErrorAction SilentlyContinue
    $newest = Get-ChildItem -LiteralPath $g.Dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.nsp', '.xci', '.nsz', '.xcz' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    [pscustomobject]@{ Path = $o; Fresh = [bool]($f -and (-not $newest -or $f.LastWriteTime -ge $newest.LastWriteTime)) }
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
        "換到遊戲庫的順序：`n1. 按這裡，把舊 App 的存檔存到電腦`n2. 在 iPad 上刪掉舊 App（免費 Apple ID 最多 3 個 App）`n3. 加入遊戲，按「放進遊戲庫」再按「裝到 iPad」`n4. 再按一次這裡，存檔就放進遊戲庫`n`n" +
        "同一款在好幾個舊 App 裡，用最近玩過的那份；遊戲庫裡已經有存檔的遊戲不會被蓋掉，放進去之前也會先備份遊戲庫。`n`niPad 用 USB 接著並解鎖，遊戲先關掉。要開始嗎？", '搬舊 App 存檔', 'YesNo', 'Question')
    if ($ok -ne 'Yes') { return }
    $owner.DialogResult = $false
    Start-Run @(@{ Game = (Library-Game); Mode = 'savemigrate'; Ipa = (Library-Ipa) })
}
function Run-Library($dirs, $mode) {
    $lib = Library-Ipa
    $libGame = Library-Game
    if ($mode -eq 'install') {
        if (-not (Test-Path -LiteralPath $lib)) { [void][Windows.MessageBox]::Show('還沒有遊戲庫：勾遊戲按「打包並安裝」。', $libName); return }
        Start-Run @(@{ Game = $libGame; Mode = 'install'; Ipa = $lib }); return
    }
    $ms = Get-MultiShell; $mg = Get-MergeScript
    if (-not $ms -or -not $mg) { [void][Windows.MessageBox]::Show($ui.Merge.ToolTip, $libName); return }
    $id = Multi-Id $ms
    $jobs = @(); $outs = @()
    # OpenGL 遊戲（Roof Rage）在 iPad 上記下的著色器：先拿回來，那幾款的遊戲包有新的著色器才重包（nxn.ps1 -ReuseIfFresh）
    $glGames = @($dirs | Where-Object { $t = Game-Tid $cards[$_].Tag; $t -and (Test-Path -LiteralPath (Join-Path (Split-Path $lib -Parent) "GL著色器\$t")) })
    if ($glGames.Count -and (Test-Path -LiteralPath $lib)) { $jobs += @{ Game = $libGame; Mode = 'glsync'; Ipa = $lib } }
    foreach ($dir in $dirs) {
        $g = $cards[$dir].Tag
        $part = Part-For $g $id
        if ($mode -ne 'pack' -and $part.Fresh -and $glGames -contains $dir) {
            $jobs += @{ Game = $g; Mode = 'mergepart-reuse'; Ipa = ''; Out = $part.Path; Shell = $ms.FullName }
        } elseif ($mode -eq 'pack' -or -not $part.Fresh) {
            if (-not $g.Base) { [void][Windows.MessageBox]::Show("$($g.Name) 的資料夾裡沒有遊戲本體（NSP/XCI/NSZ）。", '缺本體'); return }
            $jobs += @{ Game = $g; Mode = 'mergepart'; Ipa = ''; Out = $part.Path; Shell = $ms.FullName }
        }
        $outs += [pscustomobject]@{ Path = $part.Path; Name = $g.Name; Dir = $dir; WasIn = [bool]$g.OnPad }
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $lib -Parent) | Out-Null
    $before = @(Library-Tids)
    $now = @($dirs | ForEach-Object { Game-Tid $cards[$_].Tag })
    $gone = @($cards.Values | Where-Object { $t = Game-Tid $_.Tag; $t -and $before -contains $t -and $now -notcontains $t } | ForEach-Object { $_.Tag.Name })
    # 合成那一步等前面跑完才決定放哪些：打包失敗的那款先跳過，其他照樣放進去（Library-Call）
    $jobs += @{ Game = $libGame; Mode = $(if ($mode -eq 'both') { 'merge+install' } else { 'merge' }); Ipa = ''; Call = '-';
                Lib = [pscustomobject]@{ Parts = $outs; Gone = $gone; Mode = $mode; Shell = $ms.FullName; Merge = $mg } }
    Start-Run $jobs
}

# 第一步「放進遊戲庫」：只把還沒轉換的遊戲各自打包成遊戲包，不合成、不用接 iPad；一款失敗其他照做
function Run-Convert($dirs) {
    $ms = Get-MultiShell
    if (-not $ms) { [void][Windows.MessageBox]::Show($ui.Merge.ToolTip, $libName); return }
    $id = Multi-Id $ms
    $jobs = @(foreach ($dir in $dirs) { $g = $cards[$dir].Tag; @{ Game = $g; Mode = 'mergepart'; Ipa = ''; Out = (Part-For $g $id).Path; Shell = $ms.FullName } })
    Start-Run $jobs
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
    if (-not $use.Count -or (-not $added.Count -and -not $lib.Gone.Count -and -not $newer.Count -and -not $newShell)) { return @{ Call = ''; Skip = $skip } }   # 遊戲庫沒有要變的，不重包也不重裝
    $what = "$($use.Count) 款" + $(if ($added.Count) { "，加入 $(($added | ForEach-Object { $_.Name }) -join '、')" } else { '' }) +
            $(if ($lib.Gone.Count) { "，拿掉 $($lib.Gone -join '、')" } else { '' }) + $(if ($skip.Count) { "，跳過 $($skip -join '、')" } else { '' }) +
            $(if ($newShell) { '，換新殼' } elseif ($newer.Count) { "，更新 $(($newer | ForEach-Object { $_.Name }) -join '、')" } else { '' })
    $tmp = "$libIpa.new"
    $icon = Join-Path $here 'LibraryIcon.png'
    $call = "Write-Host '==> 合成一包：$libName（$($what -replace "'", "''")）'; " +
            "& $(Quote (Get-Python)) $(Quote $lib.Merge) -o $(Quote $tmp) --name $(Quote $libName) --bundle-id $libBid --shell $(Quote $lib.Shell)" +
            $(if (Test-Path $icon) { " --icon $(Quote $icon)" } else { '' }) + " $(($use | ForEach-Object { Quote $_.Path }) -join ' '); " +
            "if (`$LASTEXITCODE) { Write-Host '出錯了：遊戲庫合成失敗'; Remove-Item -LiteralPath $(Quote $tmp) -ErrorAction SilentlyContinue; `$global:LASTEXITCODE = 1; return }; " +
            "Move-Item -LiteralPath $(Quote $tmp) -Destination $(Quote $libIpa) -Force; " +
            "Set-Content -LiteralPath $(Quote "$libIpa.shell") -Value $(Quote (Split-Path $lib.Shell -Leaf)) -Encoding UTF8; Write-Host '遊戲庫合成好了'"
    if ($lib.Mode -eq 'both') { $call += "; & $(Quote $script) -Ipa $(Quote $libIpa) -NoPause" }
    return @{ Call = $call; Skip = $skip }
}

# 打包失敗的原因：從記錄裡挑一行看得懂的
function Fail-Reason($log) {
    $lines = @(Get-Content -LiteralPath $log -Encoding UTF8 -ErrorAction SilentlyContinue)
    if ($lines -match 'without type trees') { return 'Unity 舊版的著色器格式還不支援' }
    if ($lines -match '32-bit|32 位元') { return '32 位元的遊戲，還不支援' }
    $l = @($lines | Where-Object { $_ -match '\[x\] precheck: ' }) | Select-Object -Last 1
    if ($l) { return ($l -replace '^.*precheck:\s*', '').Trim() }
    $l = @($lines | Where-Object { $_ -match '\[RED\]|\[x\]|Error|出錯了' -and $_ -notmatch '出錯了：打包失敗' }) | Select-Object -Last 1
    if ($l) { return ($l -replace '^\[[\d:]+\]\s*', '').Trim() }
    return '打包失敗'
}

# 跑選的遊戲：mode = both / pack / install；merge = 合成一包
function Run-Games($dirs, $mode, $merge) {
    $jobs = @()
    if ($merge -and $script:addTo) { Add-ToPack $script:addTo $dirs $mode; return }
    if ($merge) { Run-Library $dirs $mode; return }
    if ($merge) {
        if ($mode -ne 'install' -and $dirs.Count -lt 2) { [void][Windows.MessageBox]::Show('合成一包至少要選 2 款。', '合成一包'); return }
        if ($mode -eq 'install') {
            # 只安裝：裝 nxn\合包 裡最新的那包，不管勾了哪些遊戲
            $mdir = Join-Path $base '合包'
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
        $mdir = Join-Path $base '合包'
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
    if (@(Setup-Missing).Count) { [void][Windows.MessageBox]::Show('還沒安裝打包和簽章工具，請先按上面的「安裝」。', 'Switch Pad'); return }
    $conv = @($selected | Where-Object { $cards.ContainsKey($_) -and -not $cards[$_].Tag.Ready -and $cards[$_].Tag.Base })
    Run-Convert $conv })
# 只放轉換好的（和本來就在 iPad 上的）；還沒轉換的等下次「放進遊戲庫」
function Sync-Library { Run-Library @($selected | Where-Object { $cards.ContainsKey($_) -and ($cards[$_].Tag.Ready -or $cards[$_].Tag.OnPad) }) 'both' }
$ui.Sync.Add_Click({
    if (@(Setup-Missing).Count) { [void][Windows.MessageBox]::Show('還沒安裝打包和簽章工具，請先按上面的「安裝」。', 'Switch Pad'); return }
    Sync-Library })

# 重簽本來只把現在的遊戲庫重裝一次；換了殼還沒合成過就順便用新殼合成，不然 iPad 上一直是舊殼
$ui.RenewBtn.Add_Click({
    if ($state.Running) { return }
    $ms = Get-MultiShell
    if ($ms -and (Shell-Changed $ms.FullName) -and -not @(Setup-Missing).Count) { Sync-Library } else { Run-Library @() 'install' } })

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
    $ui.ProgressView.Visibility = 'Collapsed'; $ui.LibraryView.Visibility = 'Visible'
    $ui.Back.Visibility = 'Collapsed'; $ui.Start.Visibility = 'Visible'; $ui.Sync.Visibility = 'Visible'; $ui.Options.Visibility = 'Visible'
    Set-Tab
    Build-Library })
$ui.Refresh.Add_Click({
    # 之前讀不到圖示的再試一次（例如後來才放了 prod.keys）
    Get-ChildItem -Path $coverDir -Filter '*.none' -ErrorAction SilentlyContinue | Remove-Item -ErrorAction SilentlyContinue
    Build-Library; Update-Account; Check-Updates })

# ---------------------------------------------------------------- 清理空間：只清做得回來的東西（照 NX Play / NX2Apple 的 Free Up Space），一律丟資源回收筒
# 遊戲本體、正式的 IPA、存檔備份都不碰
function Size-Of($item) {
    if ($item.PSIsContainer) { [long](Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum }
    else { [long]$item.Length }
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
        '=== Switch Pad 診斷資訊 ==='
        "Switch Pad：$(& $read (Join-Path $work 'app-version.txt'))"
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
    [Windows.Clipboard]::SetText($text)
    [void][Windows.MessageBox]::Show($owner, '診斷資訊複製好了，貼到 GitHub issue 或訊息裡就可以。裡面沒有金鑰內容、Apple ID 或遊戲檔。', '複製診斷資訊')
}

# ---------------------------------------------------------------- 設定視窗
$ui.Settings.Add_Click({
    $sx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="設定" Width="560" SizeToContent="Height" Background="#000000" Foreground="White" ResizeMode="NoResize"
        FontFamily="Microsoft JhengHei UI" FontSize="14" WindowStartupLocation="CenterOwner">
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
            <Button x:Name="ShellBack" Content="退回上一版" Margin="8,0,0,0" ToolTip="新殼裝到 iPad 後有遊戲變差：改用上一版殼，再按「裝到 iPad」"/>
            <Button x:Name="ShellLock" Content="鎖定這一版" Margin="8,0,0,0" ToolTip="之後有新殼也先不換，等你解除鎖定"/>
            <Button x:Name="ShellLatest" Content="改用最新殼" Margin="8,0,0,0"/>
          </WrapPanel>
          <TextBlock x:Name="ShellText" VerticalAlignment="Center" TextWrapping="Wrap"/>
        </DockPanel>
        <TextBlock Foreground="#8E8E93" FontSize="12" Margin="0,2,0,0" TextWrapping="Wrap"
                   Text="每次更新遊戲庫前都會自動備份存檔。「搬舊 App 存檔」是換到遊戲庫時用的：先按一次把舊 App 的存檔存到電腦，刪掉舊 App、裝好遊戲庫後再按一次放進去。多遊戲殼的 .zip 放進 work\multigame，預設用最新的；新殼裝到 iPad 後有遊戲變差，按「退回上一版」再「裝到 iPad」，遊戲格式一樣就不用重新轉換。"/>
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
    <TextBlock Text="Switch Pad" Foreground="#8E8E93" Margin="4,16,0,6"/>
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
    $sw.FindName('LibText').Text = $(if ($have) { "$lib（$(@(Library-Tids).Count) 款）" } else { '還沒有遊戲庫：加入遊戲，按「放進遊戲庫」再按「裝到 iPad」' })
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
        $sw.FindName('ShellBack').ToolTip = if ($older) { "改用 $(Shell-Sha $older)（$($older.LastWriteTime.ToString('MM/dd'))），再按「裝到 iPad」" + $(if ((Multi-Id $older) -ne (Multi-Id $cur)) { '。遊戲格式不同，沒留著舊遊戲包的遊戲要重新轉換' } else { '。遊戲格式一樣，不用重新轉換' }) } else { '沒有上一版殼可以退回' }
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
    $cols = [math]::Max(1, [math]::Floor(($e.NewSize.Width - 12) / 236))
    if ($ui.Library.Columns -ne $cols) { $ui.Library.Columns = $cols; $ui.Others.Columns = $cols; $ui.Packs.Columns = $cols } })

Update-ShellLabel
# 視窗先出來再畫卡片（遊戲多時要幾秒），開啟時只畫一次
$ui.GamesHead.Text = '載入遊戲中…'
[void]$win.ShowDialog()
