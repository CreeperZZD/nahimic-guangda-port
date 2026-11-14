#Requires -Version 5.1
<#
.SYNOPSIS
    从使用者自己提供的官方驱动包，生成适配本机的驱动包（只改写匹配表，不修改任何二进制）。

.DESCRIPTION
    做的事：
      1. 读取本机 Realtek 声卡的硬件 ID（VEN / DEV / SUBSYS）
      2. 在 EXT 驱动安装信息的匹配表里补一行本机 ID（幂等，不会重复写）
      3. 可选：把调音档案 CAB 里 152D1535_*.nsx 复制一份改名为 <本机SUBSYS>_*.nsx 后重新打包
      4. 全部输出到 -OutDir，-KitDir 原目录只读不改

    不做的事（重要）：
      - 不修改任何 .dll / .exe / .sys
      - 不修改 .cat 签名目录，不伪造签名
      - 不生成、不提供任何第三方文件
      - 不联网下载任何东西

.PARAMETER KitDir
    你解包好的官方驱动目录，需包含 1-Driver-APO 与 2-Driver-EXT 两个子目录。

.PARAMETER OutDir
    输出目录。默认在 KitDir 旁边生成 kit-ready。

.PARAMETER SkipCab
    跳过调音档案 CAB 的重建（跳过后音效仍可用，仅扬声器调音曲线用默认值）。

.EXAMPLE
    .\prepare-kit.ps1 -KitDir "D:\kit" -OutDir "D:\kit-ready"

.NOTES
    本脚本为原创代码，MIT 许可。不包含任何第三方版权文件。
    侵权投诉请联系 1876536805@qq.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$KitDir,

    [string]$OutDir,

    [switch]$SkipCab
)

$ErrorActionPreference = 'Stop'

# ============================ 输出helper ============================
function Info($m) { Write-Host ('  ' + $m) -ForegroundColor Gray }
function Ok($m) { Write-Host ('  [OK] ' + $m) -ForegroundColor Green }
function Warn($m) { Write-Host ('  [!] ' + $m) -ForegroundColor Yellow }
function Fail($m) { Write-Host ('  [X] ' + $m) -ForegroundColor Red }
function Step($m) { Write-Host ''; Write-Host ('== ' + $m + ' ==') -ForegroundColor Cyan }

# ============================ 文本读写（保持原编码）============================
function Read-TextKeepEncoding([string]$path) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return @{ Text = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2); Enc = 'Unicode' }
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return @{ Text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3); Enc = 'UTF8BOM' }
    }
    # 无 BOM：INF 一般为 ANSI（中文系统为 GBK）
    $ansi = [System.Text.Encoding]::Default
    return @{ Text = $ansi.GetString($bytes); Enc = 'ANSI' }
}

function Write-TextKeepEncoding([string]$path, [string]$text, [string]$enc) {
    switch ($enc) {
        'Unicode' { [System.IO.File]::WriteAllText($path, $text, [System.Text.Encoding]::Unicode) }
        'UTF8BOM' { [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($true))) }
        default { [System.IO.File]::WriteAllText($path, $text, [System.Text.Encoding]::Default) }
    }
}

# ============================ 开始 ============================
Write-Host ''
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host '  prepare-kit : 生成适配本机的驱动包' -ForegroundColor Cyan
Write-Host '=====================================================' -ForegroundColor Cyan

# ---------- 0. 前置检查 ----------
Step '0. 检查输入目录'

if (-not (Test-Path $KitDir)) { Fail ('找不到 KitDir: ' + $KitDir); exit 1 }
$KitDir = (Resolve-Path $KitDir).Path

$apoDir = Join-Path $KitDir '1-Driver-APO'
$extDir = Join-Path $KitDir '2-Driver-EXT'
$found = $false
foreach ($cand in @($extDir, $KitDir)) {
    if (Test-Path $cand) {
        $inf = Get-ChildItem $cand -Filter 'AVoluteNH3Ext.inf' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($inf) { $extDir = $cand; $found = $true; break }
    }
}
if (-not $found) {
    Fail '在 KitDir 里找不到 AVoluteNH3Ext.inf（EXT 扩展驱动的安装信息）。'
    Warn '请确认你已从官方渠道解包出 EXT 驱动，并放在 2-Driver-EXT 子目录。'
    exit 1
}
Info ('EXT 目录 : ' + $extDir)
if (Test-Path $apoDir) { Info ('APO 目录 : ' + $apoDir) } else { Warn '没有 1-Driver-APO 目录（安装时 SWC 驱动会缺失，请补上）' }

$extInfPath = (Get-ChildItem $extDir -Filter 'AVoluteNH3Ext.inf' | Select-Object -First 1).FullName
Info ('EXT INF  : ' + (Split-Path $extInfPath -Leaf))

# ---------- 1. 读本机硬件 ID ----------
Step '1. 读取本机声卡硬件 ID'

$dev = $null
$patterns = @(
    'INTELAUDIO\FUNC_01&VEN_10EC*',
    'HDAUDIO\FUNC_01&VEN_10EC*'
)
foreach ($p in $patterns) {
    $dev = Get-PnpDevice -Class Media -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like $p } |
        Select-Object -First 1
    if ($dev) { break }
}

if (-not $dev) {
    # 退一步：直接从注册表枚举 Media 类设备
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Enum'
    foreach ($p in $patterns) {
        $hit = Get-ChildItem (Join-Path $base ($p -replace '\*', '')) -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { break }
    }
    Fail '没有找到 Realtek（VEN_10EC）音频编解码器设备。'
    Warn '本方案只适用于 Realtek ALC 系列。请确认声卡驱动正常，或本机不是 Realtek 声卡。'
    exit 1
}

$instanceId = $dev.InstanceId
Info ('设备实例 : ' + $instanceId)

# 解析 VEN / DEV / SUBSYS
$ven = $null; $devId = $null; $subsys = $null; $bus = $null
if ($instanceId -match 'VEN_([0-9A-Fa-f]{4})') { $ven = $Matches[1].ToUpper() }
if ($instanceId -match 'DEV_([0-9A-Fa-f]{4})') { $devId = $Matches[1].ToUpper() }
if ($instanceId -match 'SUBSYS_([0-9A-Fa-f]{8})') { $subsys = $Matches[1].ToUpper() }
if ($instanceId -match '^(INTELAUDIO|HDAUDIO)') { $bus = $Matches[1].ToUpper() }

if (-not $ven -or -not $devId -or -not $subsys) {
    Fail ('无法从设备实例解析出完整的硬件 ID: ' + $instanceId)
    exit 1
}

Info ('总线     : ' + $bus)
Info ('供应商   : VEN_' + $ven)
Info ('设备     : DEV_' + $devId)
Info ('子系统   : SUBSYS_' + $subsys)

if ($ven -ne '10EC') {
    Fail ('供应商不是 Realtek（VEN_10EC），当前是 VEN_' + $ven + '。本方案不适用。')
    exit 1
}

$subVendor = $subsys.Substring(0, 4)
if ($subVendor -ne '152D') {
    Warn ('子系统厂商是 ' + $subVendor + '，不是广达（152D）。')
    Warn '仍可尝试，但同模具假设不成立，调音曲线与端点拓扑可能不匹配。'
    $ans = Read-Host '  仍要继续吗？(y/N)'
    if ($ans -ne 'y' -and $ans -ne 'Y') { Info '已取消。'; exit 0 }
}

# ---------- 2. 准备输出目录 ----------
Step '2. 准备输出目录'

if (-not $OutDir) { $OutDir = Join-Path (Split-Path $KitDir -Parent) 'kit-ready' }
if (Test-Path $OutDir) {
    Warn ('输出目录已存在，将覆盖其中的同名文件: ' + $OutDir)
} else {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}
$OutDir = (Resolve-Path $OutDir).Path
Info ('输出到   : ' + $OutDir)

# 复制整个结构（保持原样）
foreach ($sub in @('1-Driver-APO', '2-Driver-EXT', 'appx')) {
    $src = Join-Path $KitDir $sub
    if (Test-Path $src) {
        $dst = Join-Path $OutDir $sub
        if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
        Copy-Item (Join-Path $src '*') $dst -Recurse -Force
        Info ('已复制 ' + $sub)
    }
}
# EXT 直接在 KitDir 根的情况
if (-not (Test-Path (Join-Path $OutDir '2-Driver-EXT\AVoluteNH3Ext.inf'))) {
    $dstExt = Join-Path $OutDir '2-Driver-EXT'
    if (-not (Test-Path $dstExt)) { New-Item -ItemType Directory -Path $dstExt -Force | Out-Null }
    Copy-Item (Join-Path $extDir '*') $dstExt -Recurse -Force
    Info '已复制 EXT 驱动（从根目录）'
}

$outExtDir = Join-Path $OutDir '2-Driver-EXT'
$outInf = Join-Path $outExtDir 'AVoluteNH3Ext.inf'
if (-not (Test-Path $outInf)) { Fail '复制后找不到 EXT INF，中止。'; exit 1 }

# ---------- 3. 改写匹配表 ----------
Step '3. 在 EXT INF 匹配表里补本机 ID'

$src = Read-TextKeepEncoding $outInf
$text = $src.Text
$lines = $text -split "`r`n|`n"
Info ('INF 编码 : ' + $src.Enc + '   行数 ' + $lines.Count)

$targetLine = 'INTELAUDIO\FUNC_01&VEN_' + $ven + '&DEV_' + $devId + '&SUBSYS_' + $subsys
$already = $false
foreach ($ln in $lines) {
    if ($ln -match [regex]::Escape('&SUBSYS_' + $subsys) -and $ln -match [regex]::Escape('DEV_' + $devId)) {
        $already = $true; break
    }
}

if ($already) {
    Ok ('匹配表里已经有 DEV_' + $devId + '&SUBSYS_' + $subsys + '，无需改动（幂等）')
} else {
    # 找模板：优先同 DEV 的行，其次任意 INTELAUDIO 行
    $template = $null
    $templateIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'RtkHDARenderCapture0_Install,.*DEV_' + $devId) {
            $template = $lines[$i]; $templateIdx = $i; break
        }
    }
    if (-not $template) {
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match 'RtkHDARenderCapture0_Install,INTELAUDIO') {
                $template = $lines[$i]; $templateIdx = $i; break
            }
        }
    }

    if (-not $template) {
        Fail '在 INF 里找不到可参考的匹配行（RtkHDARenderCapture0_Install,INTELAUDIO...）。'
        Warn '可能这不是预期的 EXT 驱动 INF，或格式已被改动。请检查文件。'
        exit 1
    }

    Info ('参考行   : 第 ' + ($templateIdx + 1) + ' 行')
    Info ('           ' + $template.Trim())

    # 用模板构造新行：替换 DEV 与 SUBSYS，注释换成说明
    $newLine = $template -replace 'DEV_[0-9A-Fa-f]{4}', ('DEV_' + $devId)
    $newLine = $newLine -replace 'SUBSYS_[0-9A-Fa-f]{8}', ('SUBSYS_' + $subsys)
    # 去掉原注释，追加自己的
    $newLine = ($newLine -replace ';;.*$', '').TrimEnd()
    $newLine = $newLine + ' ;; patched for SUBSYS_' + $subsys + ' (' + $bus + ' VEN_' + $ven + ' DEV_' + $devId + ')'

    # 插到模板行之后
    $newLines = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $lines.Count; $i++) {
        [void]$newLines.Add($lines[$i])
        if ($i -eq $templateIdx) { [void]$newLines.Add($newLine) }
    }

    $newText = ($newLines -join "`r`n")
    Write-TextKeepEncoding $outInf $newText $src.Enc
    Ok '已插入本机匹配行：'
    Info ('           ' + $newLine)
}

# 校验：重新读一遍确认写入成功
$chk = Read-TextKeepEncoding $outInf
if ($chk.Text -match [regex]::Escape('SUBSYS_' + $subsys)) {
    Ok '写入校验通过'
} else {
    Fail '写入后校验失败，请检查文件编码与权限。'
    exit 1
}

# ---------- 4. 调音档案 CAB ----------
Step '4. 调音档案（可跳过）'

$outCab = Join-Path $outExtDir 'NH3ProductSettings.cab'
if ($SkipCab) {
    Info '已指定 -SkipCab，跳过。'
} elseif (-not (Test-Path $outCab)) {
    Warn '没有找到 NH3ProductSettings.cab（如果原包里没有，安装时会提示，不影响音效功能）。'
} else {
    $tmp = Join-Path $env:TEMP ('nh3cab_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        Info '展开 CAB...'
        & expand.exe $outCab ('-F:*') $tmp | Out-Null
        if ($LASTEXITCODE -ne 0) { throw ('expand 失败 code=' + $LASTEXITCODE) }

        $nsxFiles = @(Get-ChildItem $tmp -Filter '*.nsx' -ErrorAction SilentlyContinue)
        Info ('CAB 内 .nsx 文件数: ' + $nsxFiles.Count)

        # 找可作模板的扬声器档案：优先 152D1535_InternalSpeakers，其次任意 InternalSpeakers
        $tpl = $nsxFiles | Where-Object { $_.Name -like '152D1535*InternalSpeakers*' } | Select-Object -First 1
        if (-not $tpl) { $tpl = $nsxFiles | Where-Object { $_.Name -like '*InternalSpeakers*' } | Select-Object -First 1 }

        $copied = 0
        foreach ($f in $nsxFiles) {
            if ($f.Name -match '^([0-9A-Fa-f]{8})_(.+)$') {
                $oldSub = $Matches[1].ToUpper()
                $suffix = $Matches[2]
                if ($oldSub -eq $subsys) { continue }
                # 只有当原 SUBSYS 的档案不存在时，才补一份本机 SUBSYS 的
                $newName = $subsys + '_' + $suffix
                $newPath = Join-Path $tmp $newName
                if (-not (Test-Path $newPath)) {
                    Copy-Item $f.FullName $newPath -Force
                    $copied++
                }
            }
        }
        if ($copied -gt 0) {
            Ok ('已补 ' + $copied + ' 份 <' + $subsys + '> 调音档案（复制自同模具档案）')
        } else {
            Info 'CAB 里已经有本机 SUBSYS 的档案，无需补充。'
        }

        # 重新打包
        Info '重新打包 CAB...'
        Remove-Item $outCab -Force -ErrorAction SilentlyContinue
        $files = @(Get-ChildItem $tmp -File)
        if ($files.Count -eq 0) { throw 'CAB 展开后没有文件' }

        # 用 makecab + DDF
        $ddf = Join-Path $tmp '_pack.ddf'
        $ddfLines = New-Object System.Collections.ArrayList
        [void]$ddfLines.Add('.Set CabinetNameTemplate=NH3ProductSettings.cab')
        [void]$ddfLines.Add('.Set Cabinet=on')
        [void]$ddfLines.Add('.Set Compress=on')
        [void]$ddfLines.Add('.Set MaxDiskSize=CDROM')
        [void]$ddfLines.Add('.Set DiskDirectoryTemplate=' + $tmp)
        [void]$ddfLines.Add('.Set CompressionType=LZX')
        [void]$ddfLines.Add('.Set CompressionMemory=21')
        foreach ($f in $files) {
            if ($f.Name -eq '_pack.ddf') { continue }
            [void]$ddfLines.Add('"' + $f.FullName + '"')
        }
        [System.IO.File]::WriteAllText($ddf, ($ddfLines -join "`r`n"), [System.Text.Encoding]::Default)

        $mkcab = & where.exe makecab.exe 2>$null | Select-Object -First 1
        if (-not $mkcab) { throw '系统里找不到 makecab.exe' }
        & $mkcab /F $ddf 2>&1 | Out-Null
        $built = Join-Path $tmp 'NH3ProductSettings.cab'
        if (-not (Test-Path $built)) { throw 'makecab 未生成 CAB' }

        Copy-Item $built $outCab -Force
        Ok ('已重建 CAB: ' + [math]::Round((Get-Item $outCab).Length / 1KB, 1) + ' KB')
    } catch {
        Warn ('CAB 重建失败: ' + $_.Exception.Message)
        Warn '这不影响音效功能，只是扬声器调音使用默认曲线。可加 -SkipCab 跳过。'
    } finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# ---------- 5. 完成 ----------
Step '5. 完成'

$outApo = Join-Path $OutDir '1-Driver-APO'
$outAppx = Join-Path $OutDir 'appx'

Info ('输出目录 : ' + $OutDir)
if (Test-Path $outApo) {
    $swc = Get-ChildItem $outApo -Filter '*.inf' -ErrorAction SilentlyContinue
    if ($swc) { Info ('  SWC 驱动  : ' + $swc.Count + ' 个 INF') } else { Warn '  SWC 驱动  : 缺失' }
}
Info ('  EXT 驱动  : AVoluteNH3Ext.inf（已补 SUBSYS_' + $subsys + '）')
if (Test-Path $outCab) { Info '  调音档案  : 已就绪' } else { Info '  调音档案  : 未提供（不影响音效）' }
if (Test-Path $outAppx) {
    $appx = @(Get-ChildItem $outAppx -Filter '*.appx*' -ErrorAction SilentlyContinue)
    Info ('  应用包    : ' + $appx.Count + ' 个')
} else {
    Warn '  应用包    : 缺失（请把官方 appxbundle 与依赖放进 appx 目录，或安装时用 -AppxDir 指定）'
}

Write-Host ''
Write-Host '  下一步：' -ForegroundColor Yellow
Write-Host ('    .\scripts\install.ps1 -KitDir "' + $OutDir + '"') -ForegroundColor White
Write-Host ''
Write-Host '  提示：原目录未被修改，可随时删除输出目录重来。' -ForegroundColor DarkGray
Write-Host ''
