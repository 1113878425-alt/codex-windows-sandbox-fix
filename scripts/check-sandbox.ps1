# check-sandbox.ps1
# Codex for Windows 沙箱故障一键诊断
#
# 用法: powershell -ExecutionPolicy Bypass -File .\check-sandbox.ps1
# 排查前 / 修复后各跑一次，对比「ACL 报错时间」与「当前 Codex 启动时间」即可。
#
# 注意: 本文件必须保存为 UTF-8 with BOM，否则 Windows PowerShell 5.1 会把中文按 ANSI
#       读取而导致脚本报「字符串缺少终止符」。

$ErrorActionPreference = 'SilentlyContinue'

$codexHome  = Join-Path $env:USERPROFILE '.codex'
$sandboxDir = Join-Path $codexHome '.sandbox'
$configPath = Join-Path $codexHome 'config.toml'

function Section($t) {
    Write-Host ""
    Write-Host ("=" * 62) -ForegroundColor DarkGray
    Write-Host "  $t" -ForegroundColor Cyan
    Write-Host ("=" * 62) -ForegroundColor DarkGray
}

# 从日志行首解析时间戳，统一转成本地时间
function Parse-LogTime([string]$line) {
    # 形式 A: [2026-10-08 17:09:56.385 codex.exe]   本地时间
    if ($line -match '^\[(?<t>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})(?:\.\d+)?\s') {
        try { return [datetime]::Parse($matches['t'], [Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
    }
    # 形式 B: [2026-10-08T09:09:57.270800400+00:00]  UTC / 带偏移
    if ($line -match '^\[(?<d>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.\d+)?(?<off>Z|[+-]\d{2}:\d{2})\]') {
        try { return [datetimeoffset]::Parse($matches['d'] + $matches['off'], [Globalization.CultureInfo]::InvariantCulture).LocalDateTime } catch { return $null }
    }
    return $null
}

Section "Codex for Windows - 沙箱诊断"
Write-Host ("时间: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

# ---------- 1. 进程 ----------
Section "1) 相关进程"
$procs = @(Get-Process | Where-Object { $_.ProcessName -match 'codex|node_repl' })
$codexStart = $null
if ($procs.Count -gt 0) {
    $procs | Sort-Object ProcessName, Id |
        Select-Object Id, ProcessName, StartTime, @{n='MemMB';e={[math]::Round($_.WorkingSet64/1MB,1)}} |
        Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    $codexProc = $procs | Where-Object { $_.ProcessName -eq 'codex' }
    if ($codexProc) { $codexStart = ($codexProc | Sort-Object StartTime | Select-Object -First 1).StartTime }
    if ($codexStart) { Write-Host ("  当前 Codex 实例启动于: " + $codexStart) }
} else {
    Write-Host "  (无 codex / node_repl 进程在运行)" -ForegroundColor Yellow
}

# ---------- 2. 沙箱日志统计 ----------
Section "2) 沙箱日志"
$log = Get-ChildItem -Path $sandboxDir -Filter 'sandbox.*.log' -ErrorAction SilentlyContinue |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $log) {
    Write-Host "  未找到沙箱日志 ($sandboxDir)" -ForegroundColor Yellow
} else {
    Write-Host ("  日志    : " + $log.FullName)
    Write-Host ("  最后修改: " + $log.LastWriteTime)
    $lines = @(Get-Content $log.FullName -Encoding UTF8)
    Write-Host ("  总行数  : " + $lines.Count)

    $ok    = @($lines | Select-String -SimpleMatch 'errors=[]').Count
    $fail  = @($lines | Select-String -SimpleMatch 'setup refresh completed with errors').Count
    $spawn = @($lines | Select-String -SimpleMatch 'setup refresh: spawning').Count
    $acl   = @($lines | Select-String -SimpleMatch 'runtime read/execute validation failed').Count
    $ro    = @($lines | Select-String -SimpleMatch 'read-acl-only').Count

    # 关键时间点（取最后一次出现）
    $lastSpawn  = $null
    $lastAclErr = $null
    foreach ($ln in $lines) {
        if ($ln -like '*setup refresh: spawning*') {
            $t = Parse-LogTime $ln; if ($t) { $lastSpawn = $t }
        }
        if ($ln -like '*runtime read/execute validation failed*') {
            $t = Parse-LogTime $ln; if ($t) { $lastAclErr = $t }
        }
    }

    Write-Host ""
    Write-Host ("  setup 成功 (errors=[])             : $ok")
    Write-Host ("  setup 失败 (completed with errors) : $fail")
    Write-Host ("  setup 启动次数 (spawning)          : $spawn")
    Write-Host ("  ACL 校验报错 (validation failed)   : $acl")
    Write-Host ("  只读降级 (read-acl-only)           : $ro")
    Write-Host ""
    Write-Host ("  最近一次 setup 启动 : " + $(if ($lastSpawn)  { $lastSpawn }  else { '(无)' }))
    Write-Host ("  最近一次 ACL 报错   : " + $(if ($lastAclErr) { $lastAclErr } else { '(无)' }))
    Write-Host ""

    # ---- 判据 ----
    if ($spawn -eq 0) {
        Write-Host "  >> 判据: setup refresh 从未运行 -> 未走 ACL 路径（正常）" -ForegroundColor Green
    } elseif (-not $lastAclErr) {
        Write-Host "  >> 判据: 日志中无 ACL 报错（正常）" -ForegroundColor Green
    } elseif ($codexStart -and $lastAclErr -lt $codexStart) {
        Write-Host "  >> 判据: 最近一次 ACL 报错早于当前 Codex 启动 -> 当前实例未被触发（已规避成功）" -ForegroundColor Green
    } else {
        Write-Host "  >> 判据: ACL 报错发生在当前实例运行期间 -> 疑似命中 os error 32 竞态（未修复）" -ForegroundColor Red
        Write-Host '     修复方法: config.toml 中 [windows] sandbox = "unelevated"，然后完整重启 Codex' -ForegroundColor Red
    }

    Write-Host ""
    Write-Host "  ---- 最近 2 条 ACL 报错 ----" -ForegroundColor DarkGray
    @($lines | Select-String -SimpleMatch 'runtime read/execute validation failed') |
        Select-Object -Last 2 | ForEach-Object { Write-Host ("    " + $_.Line) }

    Write-Host ""
    Write-Host "  ---- 日志最后 4 行 ----" -ForegroundColor DarkGray
    $lines | Select-Object -Last 4 | ForEach-Object { Write-Host ("    " + $_) }
}

# ---------- 3. setup_error.json ----------
Section "3) setup_error.json"
$se = Join-Path $sandboxDir 'setup_error.json'
if (Test-Path $se) {
    Write-Host ("  " + (Get-Content $se -Raw -Encoding UTF8).Trim())
    Write-Host "  (存在该文件 -> setup 曾报错; 注意它不会随修复自动删除)" -ForegroundColor Yellow
} else {
    Write-Host "  (不存在 -> 无 setup 错误记录)" -ForegroundColor Green
}

# ---------- 4. 当前配置 ----------
Section "4) config.toml 关键取值"
if (Test-Path $configPath) {
    Write-Host ("  路径    : " + $configPath)
    Write-Host ("  修改时间: " + (Get-Item $configPath).LastWriteTime)
    Write-Host ""
    Get-Content $configPath -Encoding UTF8 |
        Select-String -Pattern '^\s*(sandbox_mode|model_catalog_json|sandbox)\s*=' |
        ForEach-Object { Write-Host ("    " + $_.Line.Trim()) }
    Write-Host ""
    Write-Host "  提示: [windows] sandbox 合法值 = elevated / unelevated" -ForegroundColor DarkGray
    Write-Host '        本故障的修复 = sandbox = "unelevated"' -ForegroundColor DarkGray
    Write-Host "        model_catalog_json 必须为绝对路径" -ForegroundColor DarkGray
    Write-Host "        (sandbox_mode 的 danger-full-access 并不能绕过本故障)" -ForegroundColor DarkGray
} else {
    Write-Host "  未找到 $configPath" -ForegroundColor Yellow
}

# ---------- 5. 磁盘 ----------
Section "5) 磁盘余量"
Get-PSDrive -PSProvider FileSystem |
    Where-Object { $null -ne $_.Used } |
    Select-Object Name, @{n='UsedGB';e={[math]::Round($_.Used/1GB,1)}}, @{n='FreeGB';e={[math]::Round($_.Free/1GB,1)}} |
    Format-Table -AutoSize | Out-String -Width 200 | Write-Host

Write-Host ""
Write-Host "诊断完成。" -ForegroundColor Cyan
