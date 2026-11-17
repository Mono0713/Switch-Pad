# nxn-queue.ps1 - 背景佇列：一款一款跑 nxn.ps1（不用開 Switch Pad），進度寫進 work\status\queue-<名稱>.json，
# Switch Pad 主視窗的「背景工作」卡片每幾秒讀一次：正在做哪一款、第幾款、完成/失敗/排隊、失敗原因、預估還要多久。
# 一款失敗不影響後面的。每款的完整記錄在 work\gui-logs\<時間>-<遊戲>.log。
#
# 用法：
#   .\nxn-queue.ps1 -Name art57 -Games '..\遊戲\Kirby','..\遊戲\MK8D' -Pass '-PackOnly','-Overwrite'
#   .\nxn-queue.ps1 -Name art57 -List 清單.txt          一行一款：<遊戲資料夾>，要另外加參數就寫 <資料夾> | -Out x.ipa -PackOnly
#   .\nxn-queue.ps1 -Name art57 -Note '全部打包好了，準備傳到 iPad'   只改卡片最下面那行說明（佇列在跑或跑完都可以）
#
# 別的程式也可以自己寫一份同樣格式的 queue-*.json 到 work\status\，卡片一樣看得懂：
#   { "kind":"queue", "name":"art57", "pid":1234, "state":"running|done|stopped", "started":"<ISO 時間>", "note":"…",
#     "items":[ { "name":"遊戲名", "dir":"資料夾", "state":"queued|running|done|failed|skipped",
#                 "started":"…", "ended":"…", "message":"失敗原因或備註", "log":"記錄檔路徑" } ] }
param(
    [string]$Name = 'queue',
    [string[]]$Games = @(),
    [string]$List = '',
    [string[]]$Pass = @(),
    [string]$Note = $null
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$stDir = Join-Path $here 'work\status'
$logDir = Join-Path $here 'work\gui-logs'
New-Item -ItemType Directory -Force -Path $stDir, $logDir | Out-Null
$file = Join-Path $stDir ("queue-" + ($Name -replace '[^\w.-]', '_') + ".json")
$utf8 = New-Object Text.UTF8Encoding $false

function Save($q, [switch]$KeepNote) {
    # 佇列在跑的時候別人可能用 -Note 改過說明：沿用檔案裡最新的
    if (-not $KeepNote -and (Test-Path -LiteralPath $file)) { try { $q.note = [string](Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json).note } catch { } }
    $q.updated = (Get-Date).ToString('o')
    for ($i = 0; $i -lt 5; $i++) {
        try {
            [IO.File]::WriteAllText("$file.tmp", ($q | ConvertTo-Json -Depth 5 -Compress), $utf8)
            if (Test-Path -LiteralPath $file) { [IO.File]::Replace("$file.tmp", $file, [NullString]::Value) } else { [IO.File]::Move("$file.tmp", $file) }
            return
        } catch { Start-Sleep -Milliseconds 300 }   # Switch Pad 剛好在讀
    }
}

# 只改說明
if ($null -ne $Note -and -not $Games.Count -and -not $List) {
    if (-not (Test-Path -LiteralPath $file)) { throw "沒有 $file" }
    $q = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    $q | Add-Member -NotePropertyName note -NotePropertyValue $Note -Force
    $q | Add-Member -NotePropertyName updated -NotePropertyValue '' -Force
    Save $q -KeepNote
    return
}

$entries = @()
foreach ($g in $Games) { $entries += [pscustomobject]@{ Dir = $g; Extra = @() } }
if ($List) {
    foreach ($line in Get-Content -LiteralPath $List -Encoding UTF8) {
        $l = $line.Trim()
        if (-not $l -or $l.StartsWith('#')) { continue }
        $parts = $l -split '\s*\|\s*', 2
        $extra = if ($parts.Count -gt 1) { @([Management.Automation.PSParser]::Tokenize($parts[1], [ref]$null) | ForEach-Object { $_.Content }) } else { @() }
        $entries += [pscustomobject]@{ Dir = $parts[0].Trim('"'); Extra = $extra }
    }
}
if (-not $entries.Count) { throw '沒有要跑的遊戲（-Games 或 -List）' }

$q = [ordered]@{ kind = 'queue'; name = $Name; pid = $PID; state = 'running'; started = (Get-Date).ToString('o'); updated = ''; ended = ''
                 note = $(if ($Note) { $Note } else { '' }); items = @() }
if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }   # 同名的舊佇列：換成這一次的
$q.items = @($entries | ForEach-Object {
    $d = $_.Dir
    if (-not [IO.Path]::IsPathRooted($d)) { $d = Join-Path (Get-Location) $d }
    [ordered]@{ name = (Split-Path $d -Leaf); dir = $d; state = 'queued'; started = ''; ended = ''; message = ''; log = ''; extra = @($_.Extra) }
})
Save $q

$nxn = Join-Path $here 'nxn.ps1'
function Q($s) { "'" + ($s -replace "'", "''") + "'" }
$stopped = $false
try {
    foreach ($it in $q.items) {
        if (-not (Test-Path -LiteralPath $it.dir)) { $it.state = 'skipped'; $it.message = '找不到這個資料夾'; Save $q; continue }
        $it.state = 'running'; $it.started = (Get-Date).ToString('o')
        $it.log = Join-Path $logDir ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ($it.name -replace '[^\w.-]', '_') + '.log')
        Save $q
        $argv = @('-GameDir', (Q $it.dir)) + @($Pass | ForEach-Object { if ($_ -match '^-') { $_ } else { Q $_ } }) + @($it.extra | ForEach-Object { if ($_ -match '^-') { $_ } else { Q $_ } }) + '-NoPause'
        $cmd = "[Console]::OutputEncoding=[Text.Encoding]::UTF8; `$env:PYTHONUTF8='1'; `$global:LASTEXITCODE=0; & { & $(Q $nxn) $($argv -join ' ') } *>&1 | Out-File -Encoding utf8 -Width 400 $(Q $it.log); exit `$LASTEXITCODE"
        # 跟 Switch Pad 開子程序的方式一樣（Start-Process 在 PowerShell 5.1 不會幫有空白的參數加引號）
        $psi = New-Object Diagnostics.ProcessStartInfo 'powershell.exe'
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"$($cmd -replace '"', '\"')`""
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $p = [Diagnostics.Process]::Start($psi)
        $it.pid = $p.Id; Save $q
        $p.WaitForExit()
        $it.ended = (Get-Date).ToString('o')
        # nxn.ps1 寫的 run-<PID>.json 有整理過的結果（失敗原因）；子程序是 powershell -Command 裡再開的同一個程序，PID 相同
        $run = Join-Path $stDir "run-$($p.Id).json"
        $r = $null; try { $r = Get-Content -LiteralPath $run -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        if ($p.ExitCode -eq 0) { $it.state = 'done'; if ($r -and $r.message -match '^沿用') { $it.message = '沒有變，沿用打包好的' } }
        else {
            $it.state = 'failed'
            $it.message = if ($r -and $r.message) { $r.message } else { "結束碼 $($p.ExitCode)，看記錄 $(Split-Path $it.log -Leaf)" }
        }
        Save $q
    }
} catch {
    $stopped = $true; throw
} finally {
    $q.state = if ($stopped) { 'stopped' } else { 'done' }
    $q.ended = (Get-Date).ToString('o')
    foreach ($it in $q.items) { if ($it.state -in 'queued', 'running') { $it.state = 'skipped'; if (-not $it.message) { $it.message = '佇列停了' } } }
    Save $q
}
