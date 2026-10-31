# nxn.ps1 - 一鍵：把一個遊戲資料夾打包成 IPA，再簽章並安裝到接著的 iPad。
# 需要先準備好 work\（打包器、工具、Python 套件）：在 Switch Pad 按「安裝」，或執行 nxn-update.ps1。
#
# 用法：
#   .\nxn.ps1 -Login                       第一次：登入 Apple ID（之後不用再登）
#   .\nxn.ps1 "遊戲\Boomerang Fu"          打包並安裝
#   .\nxn.ps1 "遊戲\Boomerang Fu" -Out 測試.ipa     換個輸出檔名，不蓋掉舊的 IPA
#   .\nxn.ps1 "遊戲\Boomerang Fu" -PackOnly         只打包，不安裝
#   .\nxn.ps1 "遊戲\Boomerang Fu" -Shell work\phonepads\art7\shell-....zip   用別的殼（輸出成 <資料夾>-<殼版本>.ipa）
#   .\nxn.ps1 -Ipa "遊戲\Boomerang Fu\x.ipa"        只安裝現成的 IPA
param(
    [Parameter(Position = 0)][string]$GameDir = '',
    [string]$Ipa = '',
    [string]$Out = '',
    [string]$Keys = '',              # 沒給就自己找（見 Find-Keys）
    [string]$Udid = '',
    [string]$Shell = '',
    [string]$Python = '',            # 沒給就用 nxn-update.ps1 記下的那個
    [switch]$Login,
    [switch]$PackOnly,
    [switch]$Overwrite,
    [switch]$Full,                   # 整包裝（遊戲資料也放在 App 裡），不分開傳
    [switch]$NoPause
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$started = Get-Date

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Ok($msg) { Write-Host $msg -ForegroundColor Green }
function Warn($msg) { Write-Host $msg -ForegroundColor Yellow }

# 原生程式寫到 stderr 時 PowerShell 5.1 會當成錯誤，所以這些呼叫都只看結束碼。
function RunExe($exe, $arglist) {
    $ErrorActionPreference = 'Continue'
    & $exe @arglist 2>&1 | ForEach-Object {
        # stderr 的空行在 PowerShell 5.1 會變成 "System.Management.Automation.RemoteException"
        $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
        if ($line -eq 'System.Management.Automation.RemoteException') { $line = '' }
        # 打包器找不到設定檔時說的 title ID（檔名裡不一定有）
        if ($line -match 'no game profile for title ID (0[0-9A-Fa-f]{15})') { $script:noProfile = $Matches[1].ToUpper() }
        # 打包器停下來時的原因（die() 印的 "[x] ..."），失敗時拿來說明
        if ($line -match '^\[x\] (.+)') { $script:packErr = $Matches[1] }
        Write-Host $line
    }
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    return $code
}

# 打包失敗的說明：常見原因直接講要怎麼做；只有真的有 *_pack\logs 才叫人去看
function Pack-FailMessage($code, $dir) {
    $e = $script:packErr
    $hint = if (-not $e) { '' }
        elseif ($e -match '^no base game for (\w+)') { "資料夾裡只有更新檔或 DLC，沒有遊戲本體。請把本體（title ID $($Matches[1])）的 NSP/XCI 放進這個資料夾，跟更新檔放在一起，再打包一次。" }
        elseif ($e -match '^no update for (\w+)') { "這款需要特定版本的更新檔，資料夾裡沒有。請把 $($Matches[1]) 的更新檔放進這個資料夾。" }
        elseif ($e -match '^the folder holds \d+ different games') { '這個資料夾裡有好幾款不同的遊戲，一款遊戲要放一個資料夾。' }
        elseif ($e -match '^no game could be identified') { '認不出資料夾裡是哪一款遊戲：檔案可能不完整，或 prod.keys 太舊打不開。' }
        elseif ($e -match '^no \.nsp or \.xci') { '資料夾裡沒有 NSP 或 XCI 檔。' }
        elseif ($e -match 'NSZ file') { '資料夾裡是 NSZ 壓縮檔，打包器只讀 NSP/XCI，請先解壓成 NSP。' }
        elseif ($e -match '^not enough space') { '硬碟空間不夠，請清出空間再打包。' }
        else { '' }
    $msg = "打包失敗（結束碼 $code）"
    if ($hint) { $msg += "：$hint" }
    if ($e) { $msg += "`n打包器說：$e" }
    $logs = @(Get-ChildItem -LiteralPath $dir -Directory -Filter '*_pack' -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'logs') })
    if ($logs.Count) { $msg += "`n詳細記錄在 $(Join-Path $logs[0].FullName 'logs')。" }
    elseif (-not $e) { $msg += "，請看上面打包器印出的訊息。" }
    return $msg
}

$here = $PSScriptRoot
# 程式檔在 nxn\程式\，遊戲和合包在上一層（舊版全部在同一層）
$base = if ((Split-Path $here -Leaf) -eq '程式') { Split-Path $here -Parent } else { $here }
$root = Join-Path $here 'work'
# prod.keys：Switch Pad 自己的 → Ryujinx → yuzu 系的模擬器，第一個找到的
function Find-Keys {
    $c = @((Join-Path $root 'prod.keys'), (Join-Path $base 'prod.keys'), "$env:APPDATA\Ryujinx\system\prod.keys")
    foreach ($emu in 'yuzu', 'suyu', 'sudachi', 'citron', 'eden', 'torzu') { $c += "$env:APPDATA\$emu\keys\prod.keys" }
    foreach ($p in $c) { if (Test-Path -LiteralPath $p) { return $p } }
    return ''
}
if (-not $Keys) { $Keys = Find-Keys }
if (-not $Python) {
    $saved = Join-Path $root 'python.txt'
    $Python = if (Test-Path $saved) { (Get-Content $saved -Raw).Trim() } else { '' }
    if (-not $Python) {
        # 沒記下來就找一個裝好打包套件的：PATH 上的 python 會變（例如後來裝了別的版本排到前面），不能直接用
        # PowerShell 5.1 傳給外部程式的參數裡如果有雙引號會被吃掉，所以這段 Python 不能用雙引號
        $probe = 'import sys, lz4.block, capstone, fontTools; print(sys.executable)'
        $cands = @('python') + @(Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe", "$env:ProgramFiles\Python3*\python.exe" -ErrorAction SilentlyContinue |
                                 Sort-Object FullName -Descending | ForEach-Object { $_.FullName })
        # py 啟動器知道所有裝好的版本（包括不在 PATH、不在預設位置的）
        $ErrorActionPreference = 'Continue'
        try { $cands += @(& py -0p 2>$null | ForEach-Object { if ("$_" -match '([A-Za-z]:\\.+\.exe)\s*$') { $Matches[1] } }) } catch { }
        $ErrorActionPreference = 'Stop'
        foreach ($c in $cands) {
            $ErrorActionPreference = 'Continue'
            try { $v = (& $c -c $probe 2>$null | Out-String).Trim() } catch { $v = '' }
            $ErrorActionPreference = 'Stop'
            if ($v -and (Test-Path -LiteralPath $v)) { $Python = $v; Set-Content -LiteralPath $saved -Value $v -Encoding UTF8; break }
        }
        if (-not $Python) {
            # 都沒有：裝到 PATH 上那個（跟 nxn-update.ps1 裝的套件一樣）
            $Python = 'python'
            Write-Host '找不到裝好打包套件的 Python，先安裝套件（lz4、capstone、fonttools、pillow）…'
            $ErrorActionPreference = 'Continue'
            & $Python -m pip install --disable-pip-version-check --quiet lz4 capstone fonttools pillow "backports.zstd; python_version < '3.14'" 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -and $_ -ne 'System.Management.Automation.RemoteException' } | ForEach-Object { Write-Host $_ }
            $ErrorActionPreference = 'Stop'
            try { $v = (& $Python -c $probe 2>$null | Out-String).Trim() } catch { $v = '' }
            if ($v -and (Test-Path -LiteralPath $v)) { $Python = $v; Set-Content -LiteralPath $saved -Value $v -Encoding UTF8 }
        }
    }
}
$plume = Join-Path $here '工具\plumesign.exe'

function Finish($msg, $color) {
    Write-Host ''
    Write-Host $msg -ForegroundColor $color
    Write-Host ("總共花了 {0:mm\:ss}" -f (New-TimeSpan $started (Get-Date)))
    if (-not $NoPause -and $Host.Name -eq 'ConsoleHost') { Write-Host ''; Read-Host '按 Enter 關閉' | Out-Null }
}

try {
    if (-not (Test-Path $plume)) { throw "找不到 $plume（Impactor 的命令列版，從 Impactor 的 release 下載 plumesign-windows-x86_64.exe 改名成 plumesign.exe）。" }

    # ---- 第一次：登入 Apple ID ----
    if ($Login) {
        Step '登入 Apple ID'
        $user = (Read-Host 'Apple ID（email）').Trim()
        if (-not $user) { throw '沒有輸入 Apple ID。' }
        # plumesign 自己問密碼時會把字顯示出來，所以由這裡用隱藏輸入問，再交給它
        $sec = Read-Host '密碼（打字不會顯示）' -AsSecureString
        $pw = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
        if (-not $pw) { throw '沒有輸入密碼。' }
        Write-Host '登入中，如果要雙重驗證碼會在下面問。'
        # 直接跑、不接管輸出，雙重驗證碼才能在這個視窗輸入
        & $plume account login --username $user --password $pw
        $code = $LASTEXITCODE
        $pw = $null
        if ($code) { throw "登入失敗（結束碼 $code）。" }
        Finish '登入完成。' Green
        return
    }

    if (-not $GameDir -and -not $Ipa) { throw '請用 -GameDir 或 -Ipa 指定要打包或安裝的東西。' }

    # ---- 先確認登入狀態，不然白打包一小時 ----
    if (-not $PackOnly) {
        Step '檢查 Apple ID'
        # plumesign 的記錄寫在 stderr，Stop 模式下會被當成錯誤，所以這裡改用 Continue 收輸出
        $ErrorActionPreference = 'Continue'
        $acct = (& $plume account list 2>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" } }) -join "`n"
        $acctCode = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        $mail = [regex]::Match($acct, '[\w.+-]+@[\w-]+(\.[\w-]+)+').Value
        if ($acctCode -or -not $mail) { Write-Host $acct.Trim(); throw "還沒登入 Apple ID，請先執行：`n  .\nxn.ps1 -Login" }
        Write-Host "已登入：$mail"
    }

    # ---- 打包 ----
    if (-not $Ipa) {
        if (-not (Test-Path $GameDir)) { throw "找不到遊戲資料夾：$GameDir" }
        $GameDir = (Resolve-Path $GameDir).Path
        if (-not $Keys -or -not (Test-Path $Keys)) { throw "找不到 prod.keys。把它拖進 Switch Pad 的視窗，或用 -Keys 指定。" }
        $Keys = (Resolve-Path $Keys).Path

        $srcDir = Join-Path $root 'src'
        $shellZip = Join-Path $root 'shell.zip'
        $customShell = $false
        if ($Shell) {
            if (-not (Test-Path $Shell)) { throw "找不到殼：$Shell" }
            $Shell = (Resolve-Path $Shell).Path
            $customShell = $Shell -ne (Resolve-Path $shellZip -ErrorAction SilentlyContinue).Path
            $shellZip = $Shell
        }
        Write-Host "殼：$shellZip"
        $packer = Join-Path $srcDir 'scripts\nxn_pack.py'
        foreach ($p in @($srcDir, $shellZip, $packer)) {
            if (-not (Test-Path $p)) { throw "還沒準備好打包器（缺 $p），請先在 Switch Pad 按「安裝」。" }
        }
        $nx = Get-ChildItem (Join-Path $root 'tools') -Recurse -Filter 'nx_extract.exe' | Select-Object -First 1
        if (-not $nx) { throw "在 $root\tools 找不到 nx_extract.exe，請先在 Switch Pad 按「安裝」。" }

        $outArg = @()
        $existing = @(Get-ChildItem $GameDir -Filter '*.ipa' -ErrorAction SilentlyContinue)
        if ($Out) {
            # 只有檔名就放在遊戲資料夾裡；有資料夾的相對路徑以 nxn\ 為準（不然會變成 遊戲\X\遊戲\X\…）
            $outPath = if ([System.IO.Path]::IsPathRooted($Out)) { $Out }
                       elseif ($Out -match '[\\/]') { Join-Path $base $Out }
                       else { Join-Path $GameDir $Out }
            $outArg = @('-o', $outPath)
        } elseif ($customShell) {
            # 不是正式殼（例如測試殼）：輸出成 <資料夾>-<殼版本>.ipa，不碰正式的 IPA
            $tag = if ((Split-Path $shellZip -Leaf) -match 'shell-\d+-([0-9a-f]+)') { $Matches[1] } else { [IO.Path]::GetFileNameWithoutExtension($shellZip) }
            $outPath = Join-Path $GameDir ((Split-Path $GameDir -Leaf) + "-$tag.ipa")
            $outArg = @('-o', $outPath)
            Warn "用的不是正式殼，這次會輸出成 $(Split-Path $outPath -Leaf)"
        } elseif ($existing.Count -and -not $Overwrite) {
            # 資料夾裡已經有驗證過的 IPA，預設不蓋掉它：這次輸出成 <資料夾>-new.ipa
            $outPath = Join-Path $GameDir ((Split-Path $GameDir -Leaf) + '-new.ipa')
            $outArg = @('-o', $outPath)
            Warn "資料夾裡已經有 $($existing[0].Name)，這次會輸出成 $(Split-Path $outPath -Leaf)（要蓋掉舊的請加 -Overwrite）"
        }

        Step "打包 $(Split-Path $GameDir -Leaf)（這一步最久，大作可能一小時以上）"
        $pyExe = (& $Python -c 'import sys; print(sys.executable)').Trim()
        $before = @(Get-ChildItem $GameDir -Filter '*.ipa' | ForEach-Object { $_.FullName })
        Push-Location $srcDir
        try {
            $env:PYTHONUTF8 = '1'
            $code = RunExe $pyExe (@($packer, $shellZip, $GameDir, '-k', $Keys, '--tools', $nx.DirectoryName) + $outArg)
            # 上游沒有這款的設定檔（迴旋鏢當初也是）：用 make_provisional.py 從遊戲檔猜一份暫定的，再打包一次
            if ($code) {
                $nsps = @(Get-ChildItem -LiteralPath $GameDir -File | Where-Object { $_.Extension -match '^\.(nsp|xci)$' })
                $baseFile = $nsps | Where-Object { $_.Name -match '\[(01[0-9A-Fa-f]{11}000)\]' } | Sort-Object Length -Descending | Select-Object -First 1
                $tid = if ($baseFile -and $baseFile.Name -match '\[(01[0-9A-Fa-f]{11}000)\]') { $Matches[1].ToUpper() } else { '' }
                if ($script:noProfile) {
                    # 檔名裡沒有 title ID（例如「Tricky Towers.nsp」）：用打包器說的，本體取最大的那個檔
                    $tid = $script:noProfile
                    if (-not $baseFile) { $baseFile = $nsps | Where-Object { $_.Name -notmatch '\[0[0-9A-Fa-f]{12}(800|[0-9A-Fa-f]{2}[1-9A-Fa-f])\]' } | Sort-Object Length -Descending | Select-Object -First 1 }
                }
                $prov = Join-Path $here 'make_provisional.py'
                if ($tid -and $baseFile -and (Test-Path $prov) -and -not (Test-Path (Join-Path $srcDir "dm\games\$tid\game.tsv"))) {
                    $updRe = '\[' + $tid.Substring(0, 13) + '800\]'
                    $upd = $nsps | Where-Object { $_.Name -match $updRe } |
                        Sort-Object { if ($_.Name -match '\[v(\d+)\]') { [long]$Matches[1] } else { 0 } } -Descending | Select-Object -First 1
                    $ver = if ($upd -and $upd.Name -match '\[v(\d+)\]') { "v$($Matches[1])" } else { 'v0' }
                    Step "上游沒有 $tid 的設定檔，自己做一份暫定的（實驗性，遊戲不一定能跑）"
                    $code = RunExe $pyExe @($prov, $srcDir, $nx.DirectoryName, $Keys, $baseFile.FullName, $(if ($upd) { $upd.FullName } else { '-' }), $ver, $tid)
                    if ($code) { throw "做不出暫定設定檔（結束碼 $code）" }
                    Step "用暫定設定檔重新打包 $(Split-Path $GameDir -Leaf)"
                    $code = RunExe $pyExe (@($packer, $shellZip, $GameDir, '-k', $Keys, '--tools', $nx.DirectoryName) + $outArg)
                }
            }
        } finally { Pop-Location }
        if ($code) { throw (Pack-FailMessage $code $GameDir) }

        if ($outArg) {
            $ipaFile = Get-Item $outPath
        } else {
            # 取這次新出現的 IPA；都沒有新的就取最新改過的
            $after = Get-ChildItem $GameDir -Filter '*.ipa' | Sort-Object LastWriteTime -Descending
            $ipaFile = ($after | Where-Object { $before -notcontains $_.FullName } | Select-Object -First 1)
            if (-not $ipaFile) { $ipaFile = $after | Select-Object -First 1 }
        }
        if (-not $ipaFile) { throw "打包器沒有產生 IPA。" }

        # 沒有 RomFS 的遊戲（例如 ANIMAL WELL）會讓 shell 顯示 "Game files not found"，補一個佔位檔
        Step '檢查 RomFS'
        $fix = Join-Path $here 'fix_empty_romfs.py'
        if (Test-Path $fix) { RunExe $pyExe @('-I', $fix, $ipaFile.FullName) | Out-Null }

        $Ipa = $ipaFile.FullName
        Ok "IPA：$Ipa（$([int]($ipaFile.Length / 1MB)) MB）"
    } else {
        if (-not (Test-Path $Ipa)) { throw "找不到 IPA：$Ipa" }
        $Ipa = (Resolve-Path $Ipa).Path
    }

    if ($PackOnly) { Finish "打包完成：$Ipa" Green; return }

    # ---- 簽章並安裝 ----
    Step '簽章並安裝到 iPad（iPad 要用 USB 接著並解鎖；第一次會問要不要信任這台電腦）'
    # plumesign 的 --udid 其實要的是 Apple 行動裝置服務（usbmuxd）給這次連線的編號（1、2、3…），
    # 不是真的 UDID，所以直接問服務（127.0.0.1:27015）現在接著哪些裝置，免得 plumesign 每次都問「Select a device」
    function Get-MuxDevices {
        $tcp = New-Object Net.Sockets.TcpClient
        try {
            $tcp.Connect('127.0.0.1', 27015)
            $ns = $tcp.GetStream(); $ns.ReadTimeout = 5000
            $body = [Text.Encoding]::UTF8.GetBytes('<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>MessageType</key><string>ListDevices</string><key>ClientVersionString</key><string>nxn</string><key>ProgName</key><string>nxn</string></dict></plist>')
            $hdr = [byte[]]([BitConverter]::GetBytes([uint32](16 + $body.Length)) + [BitConverter]::GetBytes([uint32]1) +
                   [BitConverter]::GetBytes([uint32]8) + [BitConverter]::GetBytes([uint32]1))
            $ns.Write($hdr, 0, 16); $ns.Write($body, 0, $body.Length)
            function ReadN($n) { $b = New-Object byte[] $n; $o = 0
                while ($o -lt $n) { $r = $ns.Read($b, $o, $n - $o); if ($r -le 0) { throw 'usbmuxd 斷線' }; $o += $r }; $b }
            $len = [BitConverter]::ToUInt32((ReadN 16), 0)
            $doc = New-Object Xml.XmlDocument; $doc.XmlResolver = $null
            $doc.LoadXml([Text.Encoding]::UTF8.GetString((ReadN ($len - 16))))
            # DeviceList 裡每台：<dict> DeviceID / Properties{ SerialNumber(=UDID), ConnectionType } </dict>
            foreach ($d in $doc.SelectNodes('/plist/dict/array/dict')) {
                $id = $d.SelectSingleNode('key[.="DeviceID"]/following-sibling::*[1]').InnerText
                $pr = $d.SelectSingleNode('key[.="Properties"]/following-sibling::dict[1]')
                [pscustomobject]@{
                    Id     = $id
                    Serial = $pr.SelectSingleNode('key[.="SerialNumber"]/following-sibling::*[1]').InnerText
                    Usb    = $pr.SelectSingleNode('key[.="ConnectionType"]/following-sibling::*[1]').InnerText -eq 'USB'
                }
            }
        } finally { $tcp.Close() }
    }
    function Find-Device {
        try { $devs = @(Get-MuxDevices) }
        catch { throw "問不到 Apple 行動裝置服務（$($_.Exception.Message)）。請安裝 Apple Devices 或 iTunes。" }
        $norm = { param($x) ($x -replace '-', '').ToUpper() }
        if ($Udid) { $pick = @($devs | Where-Object { (& $norm $_.Serial) -eq (& $norm $Udid) }) }
        else {
            # 同一台 iPad 用 USB 又開 Wi-Fi 同步時會出現兩筆，優先 USB
            $pick = @($devs | Where-Object Usb)
            if (-not $pick) { $pick = $devs }
            $pick = @($pick | Group-Object Serial | ForEach-Object { $_.Group[0] })
        }
        if (-not $pick) { throw '找不到 iPad：請用 USB 接上並解鎖，第一次要在 iPad 上按「信任」。' }
        if ($pick.Count -gt 1) { Warn "接著 $($pick.Count) 台 Apple 裝置，裝到第一台（$($pick[0].Serial)）；要指定請在設定填 UDID" }
        $pick[0]
    }
    # plumesign 只有在沒給 --udid（選裝置）或帳號有好幾個團隊時才會問問題，其他時候可以直接在背景跑，記錄寫進這裡
    function Run-Sign($argv) {
        $ErrorActionPreference = 'Continue'
        $env:RUST_LOG = 'info'   # plumesign 預設印除錯訊息（整段資料結構），只留一般進度
        $lines = New-Object Collections.Generic.List[string]
        & $plume @argv 2>&1 | ForEach-Object {
            $l = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
            if ($l.Trim()) { Write-Host $l; $lines.Add($l) }
        }
        $c = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        $script:signOut = $lines -join "`n"
        return $c
    }
    $dev = Find-Device
    Write-Host "裝置：$($dev.Serial)（連線編號 $($dev.Id)）"

    # 遊戲資料（romfs）分開放：裝一個不含 romfs 的小 App，資料放進 App 的 Documents/romfs（殼會先讀那裡，重裝也不會被清掉）。
    # 之後每週重簽只傳小 App；資料只有第一次或遊戲換版本時才傳。合包和沒什麼 RomFS 的遊戲照舊整包裝。
    $dataTool = Join-Path $here 'romfs_data.py'
    # 安靜地跑一個程式、只拿 stdout 和結束碼（PowerShell 5.1 在 Stop 模式下會把 stderr 當成錯誤）
    function Quiet($exe, $argv) {
        $ErrorActionPreference = 'Continue'
        $o = (& $exe @argv 2>$null | Out-String).Trim()
        [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o }
    }
    $py = (Quiet $Python @('-c', 'import sys; print(sys.executable)')).Out
    # 傳檔工具 pymobiledevice3 的相依套件在 Python 3.14 還沒有現成的 Windows 版（要裝 C++ 編譯器），
    # 所以找一個裝得起來的 Python（先找已經裝好的，再試 3.13 → 3.10），記在 work\python-transfer.txt
    function Transfer-Python {
        $saved = Join-Path $root 'python-transfer.txt'
        $cands = @()
        if (Test-Path $saved) { $cands += (Get-Content $saved -Raw).Trim() }
        $cands += $py
        foreach ($v in '3.13', '3.12', '3.11', '3.10') {
            $r = Quiet 'py' @("-$v", '-c', 'import sys; print(sys.executable)')
            if (-not $r.Code -and $r.Out) { $cands += $r.Out }
        }
        $cands = @($cands | Where-Object { $_ } | Select-Object -Unique)
        foreach ($c in $cands) { if (-not (Quiet $c @('-c', 'import pymobiledevice3')).Code) { Set-Content $saved $c -Encoding UTF8; return $c } }
        foreach ($c in $cands) {
            Write-Host "安裝傳檔工具（pymobiledevice3，只要一次）：$c"
            $code = RunExe $c @('-m', 'pip', 'install', '--disable-pip-version-check', '--quiet', '--only-binary', ':all:', 'pymobiledevice3==11.45.0')
            if (-not $code -and -not (Quiet $c @('-c', 'import pymobiledevice3')).Code) { Set-Content $saved $c -Encoding UTF8; return $c }
        }
        return ''
    }
    $signIpa = $Ipa; $split = $null
    if (-not $Full -and (Test-Path $dataTool) -and $py) {
        $r = Quiet $py @('-I', $dataTool, 'info', $Ipa)
        if (-not $r.Code) { try { $split = $r.Out | ConvertFrom-Json } catch { $split = $null } }
        if ($split -and -not $split.lite) { $split = $null }
        if ($split) {
            $tpy = Transfer-Python
            if ($tpy) { $py = $tpy } else { Warn '傳檔工具裝不起來，這次整包裝'; $split = $null }
        }
        if ($split) {
            $liteDir = Join-Path $root 'lite'
            New-Item -ItemType Directory -Force -Path $liteDir | Out-Null
            $stem = [IO.Path]::GetFileNameWithoutExtension($Ipa) -replace '[^\w.-]', '_'
            $f = Get-Item -LiteralPath $Ipa
            $lite = Join-Path $liteDir ("$stem-" + $f.Length + '-' + $f.LastWriteTimeUtc.Ticks + '.ipa')
            if (-not (Test-Path -LiteralPath $lite)) {
                # 同一個 IPA 的舊小包（IPA 改過了）先清掉
                Get-ChildItem -LiteralPath $liteDir -Filter "$stem-*.ipa" -ErrorAction SilentlyContinue | Remove-Item -ErrorAction SilentlyContinue
                Write-Host "做不含遊戲資料的小 App（遊戲資料 $([int]($split.bytes / 1MB)) MB 另外傳）"
                $c = RunExe $py @('-I', $dataTool, 'lite', $Ipa, "$lite.part")
                if ($c) { Warn '做小 App 失敗，這次整包裝'; $split = $null; Remove-Item -LiteralPath "$lite.part" -ErrorAction SilentlyContinue }
                else { Move-Item -LiteralPath "$lite.part" -Destination $lite -Force }
            }
            if ($split) { $signIpa = $lite; Write-Host "小 App：$([int]((Get-Item -LiteralPath $lite).Length / 1MB)) MB" }
        }
    }
    $signArgs = @('sign', '--package', $signIpa, '--apple-id', '--register-and-install')
    $code = Run-Sign ($signArgs + @('--udid', $dev.Id))
    if ($code -and $script:signOut -match '(?i)device.{0,20}not found') {
        # 編號在拔插後會變，重新問一次再試
        $dev = Find-Device
        Warn "裝置編號變了，改用 $($dev.Id) 再試一次"
        $code = Run-Sign ($signArgs + @('--udid', $dev.Id))
    }
    if ($code -and $script:signOut -match '(?i)no account selected|please login|unauthori[sz]ed|re-?authenticat') {
        throw "Apple ID 要重新登入：按右上角的「登入 Apple ID」，登入後再按一次安裝。IPA 本身是好的：$Ipa"
    }
    if (-not $code -and $split) {
        Step '傳遊戲資料到 iPad'
        $c = RunExe $py @('-I', $dataTool, 'push', $Ipa, '--udid', $dev.Serial)
        if ($c) {
            throw @"
App 裝好了，但遊戲資料沒傳完（結束碼 $c），現在打開會找不到遊戲檔。
iPad 保持接著、解鎖，再按一次安裝就會重新傳一次。
"@
        }
    }
    if ($code) {
        throw @"
安裝失敗（結束碼 $code）。IPA 本身是好的：$Ipa
常見原因：
  - iPad 沒解鎖，或還沒按「信任這台電腦」
  - 免費 Apple ID 的憑證 7 天就過期、同時最多 3 個 App，先在 iPad 上刪掉一個舊的
  - 上面的記錄有 plumesign 的原始訊息
  - 還是不行就用 工具\Impactor-windows-x86_64-portable.exe 手動拖這個 IPA 進去
"@
    }

    # 記下這個遊戲最後裝的是哪個 IPA，給「全部重簽」用（同一個資料夾只記最新一次）
    try {
        $db = Join-Path $root 'installed.json'
        $map = [ordered]@{}
        if (Test-Path $db) {
            (Get-Content $db -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $map[$_.Name] = $_.Value }
        }
        # 合包資料夾裡每包是不同的 App，用 IPA 本身當鍵；遊戲資料夾只記最新一次
        $key = if ((Split-Path (Split-Path $Ipa -Parent) -Leaf) -eq '合包') { $Ipa } else { Split-Path $Ipa -Parent }
        $map[$key] = [ordered]@{ ipa = $Ipa; time = (Get-Date).ToString('s') }
        $map | ConvertTo-Json -Depth 3 | Set-Content $db -Encoding UTF8
    } catch { Warn "記錄安裝紀錄失敗：$($_.Exception.Message)" }

    Finish "裝好了：$Ipa 已經在 iPad 上，可以直接開。（免費帳號 7 天後要重簽）" Green
} catch {
    Finish "出錯了：$($_.Exception.Message)" Red
    exit 1
}
