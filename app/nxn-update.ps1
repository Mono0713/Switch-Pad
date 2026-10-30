# nxn-update.ps1 - Switch Pad 的安裝和更新：Python、Python 套件、打包器（殼、Windows 工具、原始碼）、plumesign、Switch Pad 自己。
# 全部從 GitHub 下載：殼和打包器取 Mono0713/ns2ios-shell 最新的 release，Switch Pad 取 Mono0713/Switch-Pad 最新的 release，
# plumesign 取 Impactor 最新的 release。
# 已經是最新的部分會跳過，所以重複執行沒關係。Switch Pad 的「安裝」「更新」按鈕就是跑這個。
#
# 用法：
#   .\nxn-update.ps1            安裝缺的、更新舊的
#   .\nxn-update.ps1 -Force     全部重新下載
param(
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo = 'Mono0713/ns2ios-shell'
$AppRepo = 'Mono0713/Switch-Pad'
$PlumeRepo = 'khcrysalis/Impactor'
$here = $PSScriptRoot
# 程式檔、work、工具 在 nxn\程式\，遊戲在上一層（舊版全部在同一層，Switch Pad 開起來會自己搬）
$base = if ((Split-Path $here -Leaf) -eq '程式') { Split-Path $here -Parent } else { $here }
$work = Join-Path $here 'work'
$toolDir = Join-Path $here '工具'
New-Item -ItemType Directory -Force -Path $work, $toolDir, (Join-Path $base '遊戲') | Out-Null
$headers = @{ 'User-Agent' = 'SwitchPad' }

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Ok($msg) { Write-Host $msg -ForegroundColor Green }
function Warn($msg) { Write-Host $msg -ForegroundColor Yellow }
function Download($url, $dest, $what) {
    Write-Host "下載 $what…"
    $tmp = "$dest.part"
    Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -Headers $headers
    Move-Item -LiteralPath $tmp -Destination $dest -Force
}
# 原生程式寫到 stderr 時 PowerShell 5.1 會當成錯誤，所以只看結束碼
function RunExe($exe, $arglist) {
    $ErrorActionPreference = 'Continue'
    & $exe @arglist 2>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" } } |
        Where-Object { $_ -ne 'System.Management.Automation.RemoteException' } | ForEach-Object { Write-Host $_ }
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    return $code
}

try {
    # ---- Python ----
    Step '檢查 Python'
    function Find-Python {
        # 每個候選是 程式 + 前面要加的參數（py 啟動器要 -3）
        function Cand($exe, $pre = @()) { [pscustomobject]@{ Exe = $exe; Pre = @($pre) } }
        $cands = @()
        $saved = Join-Path $work 'python.txt'
        if (Test-Path $saved) { $cands += Cand (Get-Content $saved -Raw).Trim() }
        $cands += Cand 'python'
        $cands += Cand 'py' @('-3')
        # 剛用 winget 裝好的還不在這個程式的 PATH 裡：直接看安裝位置
        foreach ($f in Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe", "$env:ProgramFiles\Python3*\python.exe" -ErrorAction SilentlyContinue |
                 Sort-Object FullName -Descending) { $cands += Cand $f.FullName }
        # PowerShell 5.1 傳給外部程式的參數裡如果有雙引號會被吃掉，所以這段 Python 不能用雙引號
        $probe = 'import sys; print(sys.version_info[0], sys.version_info[1], sys.executable, sep=chr(124))'
        foreach ($c in $cands) {
            if (-not $c.Exe) { continue }
            $exe = $c.Exe; $pre = $c.Pre
            try {
                $ErrorActionPreference = 'Continue'
                $v = (& $exe @pre -c $probe 2>$null | Out-String).Trim()
                $ErrorActionPreference = 'Stop'
                # Windows 的「python」沒裝時會是 Microsoft Store 的捷徑，它什麼都不印
                if ($v -match '^3\|(\d+)\|(.+)$' -and [int]$Matches[1] -ge 9) { return $Matches[2].Trim() }
            } catch { $ErrorActionPreference = 'Stop' }
        }
        return $null
    }
    $py = Find-Python
    if (-not $py) {
        if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
            Write-Host '沒有 Python 3.9 以上，用 winget 安裝 Python 3.12（會跳出安裝視窗或系統詢問）'
            $code = RunExe 'winget.exe' @('install', '-e', '--id', 'Python.Python.3.12', '--scope', 'user', '--accept-package-agreements', '--accept-source-agreements', '--silent')
            if ($code) { Warn "winget 結束碼 $code" }
            $py = Find-Python
        }
        if (-not $py) { throw '找不到 Python 3.9 以上。請到 https://www.python.org/downloads/ 安裝（安裝時勾「Add python.exe to PATH」），再按一次安裝。' }
    }
    Set-Content -LiteralPath (Join-Path $work 'python.txt') -Value $py -Encoding UTF8
    Ok "Python：$py"

    Step '安裝 Python 套件'
    # Python 3.14 起內建 compression.zstd，backports.zstd 只支援 3.13 以下
    $code = RunExe $py @('-m', 'pip', 'install', '--disable-pip-version-check', '--quiet', 'lz4', 'capstone', 'fonttools', 'pillow', "backports.zstd; python_version < '3.14'")
    if ($code) { throw "pip 安裝失敗（結束碼 $code）" }
    # 把遊戲資料直接傳進 iPad 用的（romfs_data.py）；裝不起來也沒關係，安裝時會改成整包裝
    $code = RunExe $py @('-m', 'pip', 'install', '--disable-pip-version-check', '--quiet', '--only-binary', ':all:', 'pymobiledevice3==11.45.0')
    if ($code) { Write-Host "傳檔工具 pymobiledevice3 沒裝起來（結束碼 $code），安裝遊戲時會整包傳" }
    Ok '套件好了'

    # ---- 打包器：殼、Windows 工具、原始碼 ----
    Step '檢查打包器'
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $headers
    $tag = $rel.tag_name
    $stamp = Join-Path $work 'release.txt'
    $have = if (Test-Path $stamp) { (Get-Content $stamp -Raw).Trim() } else { '' }
    $shellZip = Join-Path $work 'shell.zip'
    $toolsDir = Join-Path $work 'tools'
    $srcDir = Join-Path $work 'src'
    $complete = (Test-Path $shellZip) -and (Test-Path (Join-Path $toolsDir 'nx_extract.exe')) -and (Test-Path (Join-Path $srcDir 'scripts\nxn_pack.py'))
    Write-Host "最新：$tag　本機：$(if ($have) { $have } else { '（沒有）' })"
    if ($Force -or -not $complete -or $have -ne $tag) {
        $asset = { param($n) $rel.assets | Where-Object { $_.name -eq $n } | Select-Object -First 1 }
        $shellA = & $asset "$tag.zip"; $toolsA = & $asset 'nxnative-windows-tools.zip'; $supA = & $asset "$tag-supported.tsv"
        if (-not $shellA -or -not $toolsA) { throw "release $tag 缺少殼或 Windows 工具" }

        Download $shellA.browser_download_url "$shellZip.new" "殼（$([int]($shellA.size / 1MB)) MB）"

        $tz = Join-Path $work 'tools.zip'
        Download $toolsA.browser_download_url $tz "Windows 工具（$([int]($toolsA.size / 1MB)) MB）"
        $tnew = Join-Path $work 'tools-new'
        if (Test-Path $tnew) { Remove-Item -Recurse -Force $tnew }
        Expand-Archive $tz $tnew
        Remove-Item $tz
        # 工具壓縮檔裡可能多一層資料夾：.exe 一律攤平到 tools\
        $flat = Join-Path $work 'tools-flat'
        if (Test-Path $flat) { Remove-Item -Recurse -Force $flat }
        New-Item -ItemType Directory -Path $flat | Out-Null
        Get-ChildItem $tnew -Recurse -File | Move-Item -Destination $flat -Force
        Remove-Item -Recurse -Force $tnew

        $sz = Join-Path $work 'src.zip'
        Download "https://github.com/$Repo/archive/refs/tags/$tag.zip" $sz '打包器原始碼'
        $snew = Join-Path $work 'src-new'
        if (Test-Path $snew) { Remove-Item -Recurse -Force $snew }
        Expand-Archive $sz $snew
        Remove-Item $sz
        $inner = Get-ChildItem $snew -Directory | Select-Object -First 1

        # 自己做的設定檔（新版裡沒有的 dm\games\<title ID>）留著
        $kept = 0
        if (Test-Path (Join-Path $srcDir 'dm\games')) {
            foreach ($d in Get-ChildItem (Join-Path $srcDir 'dm\games') -Directory) {
                $dst = Join-Path $inner.FullName "dm\games\$($d.Name)"
                if ($d.Name -match '^[0-9A-Fa-f]{16}$' -and -not (Test-Path $dst)) { Copy-Item -Recurse $d.FullName $dst; $kept++ }
            }
        }

        # 下載都成功了才換掉舊的
        if (Test-Path $srcDir) { Remove-Item -Recurse -Force $srcDir }
        Move-Item $inner.FullName $srcDir
        Remove-Item -Recurse -Force $snew
        if (Test-Path $toolsDir) { Remove-Item -Recurse -Force $toolsDir }
        Move-Item $flat $toolsDir
        Move-Item "$shellZip.new" $shellZip -Force
        Get-ChildItem $work -Filter '*-supported.tsv' -File -ErrorAction SilentlyContinue | Remove-Item -ErrorAction SilentlyContinue
        if ($supA) { Download $supA.browser_download_url (Join-Path $work $supA.name) '支援清單' }
        Set-Content $stamp $tag
        Ok "打包器更新到 $tag$(if ($kept) { "（保留了 $kept 個自己的設定檔）" })"
    } else { Ok '打包器已經是最新的' }

    # ---- plumesign（Impactor 的命令列版）和 Apple 裝置服務 ----
    Step '檢查簽章工具'
    $plume = Join-Path $toolDir 'plumesign.exe'
    if ($Force -or -not (Test-Path $plume)) {
        $pr = Invoke-RestMethod -Uri "https://api.github.com/repos/$PlumeRepo/releases/latest" -Headers $headers
        $pa = $pr.assets | Where-Object { $_.name -eq 'plumesign-windows-x86_64.exe' } | Select-Object -First 1
        if (-not $pa) { throw "Impactor $($pr.tag_name) 沒有 plumesign-windows-x86_64.exe" }
        Download $pa.browser_download_url $plume "plumesign $($pr.tag_name)"
    }
    Ok 'plumesign 好了'
    # iPad 要透過 Apple 的裝置服務才連得到（「Apple 裝置」App 或 iTunes 會裝）
    if (-not (Get-Service -Name 'Apple Mobile Device Service' -ErrorAction SilentlyContinue)) {
        Warn '這台電腦沒有 Apple 行動裝置服務，iPad 會連不到。請從 Microsoft Store 安裝「Apple 裝置」（Apple Devices）或 iTunes。'
    }

    # ---- Switch Pad 自己 ----
    Step '檢查 Switch Pad'
    # Switch Pad 有自己的 repo；問不到（或還沒有 release）就用殼 release 附的那份
    $appA = $null
    try {
        $ar = Invoke-RestMethod -Uri "https://api.github.com/repos/$AppRepo/releases/latest" -Headers $headers
        $appA = $ar.assets | Where-Object { $_.name -eq 'SwitchPad.zip' } | Select-Object -First 1
    } catch { }
    if (-not $appA) { $appA = $rel.assets | Where-Object { $_.name -eq 'SwitchPad.zip' } | Select-Object -First 1 }
    $verFile = Join-Path $work 'app-version.txt'
    $appHave = if (Test-Path $verFile) { (Get-Content $verFile -Raw).Trim() } else { '' }
    if (-not $appA) { Write-Host '這個 release 沒有附 Switch Pad，跳過' }
    elseif (-not $Force -and $appHave -eq $appA.updated_at) { Ok 'Switch Pad 已經是最新的' }
    else {
        $az = Join-Path $work 'SwitchPad.zip'
        Download $appA.browser_download_url $az 'Switch Pad'
        $anew = Join-Path $work 'app-new'
        if (Test-Path $anew) { Remove-Item -Recurse -Force $anew }
        Expand-Archive $az $anew
        Remove-Item $az
        $from = $anew
        $one = @(Get-ChildItem $anew)
        if ($one.Count -eq 1 -and $one[0].PSIsContainer) { $from = $one[0].FullName }
        # 程式檔放在這個資料夾（程式\），圖示放到 工具\；遊戲、work、工具 裡的其他東西不碰
        foreach ($f in Get-ChildItem $from -File) {
            $dst = if ($f.Extension -eq '.ico') { Join-Path $toolDir $f.Name } else { Join-Path $here $f.Name }
            # 沒變的檔案不用蓋（舊版 Switch Pad 開著時會鎖住自己的圖示）；圖示蓋不過去也不算失敗，下次再換
            if ((Test-Path -LiteralPath $dst) -and (Get-FileHash -LiteralPath $dst).Hash -eq (Get-FileHash -LiteralPath $f.FullName).Hash) { continue }
            try { Copy-Item -LiteralPath $f.FullName -Destination $dst -Force -ErrorAction Stop }
            catch {
                if ($f.Extension -ne '.ico') { throw }
                Write-Host "圖示 $($f.Name) 正在使用中，先不換（不影響使用）"
            }
        }
        Remove-Item -Recurse -Force $anew
        Set-Content $verFile $appA.updated_at
        # Switch Pad 看到這個檔就會自己重開，換成新版
        if ($appHave) { Set-Content (Join-Path $work 'app-restart.flag') (Get-Date).ToString('s') }
        Ok 'Switch Pad 更新好了'
    }

    Write-Host ''
    Ok '全部準備好了'
    exit 0
} catch {
    Write-Host ''
    Write-Host "失敗：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
