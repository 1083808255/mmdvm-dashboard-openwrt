# 7628 (hilink,hlk-7628n) 三合一镜像生成脚本
# 同源固件: squashfs-sysupgrade.bin
# 产物 1: 编程器直刷镜像 = uboot(0x00000) + env(0x30000) + factory(0x40000) + firmware(0x50000 起) 补齐到 32MB (0xFF)
# 产物 2: breed 直刷镜像 = firmware 部分 (0x50000 起刷, 即 sysupgrade.bin 原样)
# 产物 3: OTA 固件       = sysupgrade.bin 原样 (dash OTA / sysupgrade 用)
param(
    [string]$Sysupgrade = "$PSScriptRoot\artifacts\hlk7628-20261122-1417\openwrt-ramips-mt76x8-hilink_hlk-7628n-squashfs-sysupgrade.bin",
    [string]$Uboot      = "$PSScriptRoot\flash-backup\uboot.bin",
    [string]$EnvB       = "$PSScriptRoot\flash-backup\uboot-env.bin",
    [string]$Factory    = "$PSScriptRoot\flash-backup\factory.bin",
    [string]$OutDir     = "$PSScriptRoot\artifacts\hlk7628-flash-images"
)
$ErrorActionPreference = 'Stop'
# flash 布局 (与 DTS mt7628an_hilink_hlk-7628n.dts 一致, flash = mx25l25635e 32MB)
$UBOOT_OFF = 0x000000; $UBOOT_SZ = 0x030000
$ENV_OFF   = 0x030000; $ENV_SZ   = 0x010000
$FACT_OFF  = 0x040000; $FACT_SZ  = 0x010000
$FW_OFF    = 0x050000; $FW_SZ    = 0x1FB0000
$FLASH_SZ  = 0x2000000

foreach ($f in @($Sysupgrade,$Uboot,$EnvB,$Factory)) {
    if (-not (Test-Path $f)) { throw "缺少输入文件: $f" }
}
$fwLen = (Get-Item $Sysupgrade).Length
if ($fwLen -gt $FW_SZ) { throw "sysupgrade.bin ($fwLen B) 超过 firmware 分区 $FW_SZ B" }
if ((Get-Item $Uboot).Length -gt $UBOOT_SZ) { throw "uboot.bin 超过 0x30000" }
if ((Get-Item $EnvB).Length -gt $ENV_SZ) { throw "uboot-env.bin 超过 0x10000" }
if ((Get-Item $Factory).Length -gt $FACT_SZ) { throw "factory.bin 超过 0x10000" }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stem = 'openwrt-ramips-mt76x8-hilink_hlk-7628n'
$progPath = Join-Path $OutDir "$stem-programmer-32MB.bin"
$breedPath = Join-Path $OutDir "$stem-breed-firmware.bin"

# breed/OTA 镜像 = sysupgrade.bin 原样
Copy-Item $Sysupgrade $breedPath -Force

# 编程器镜像: 流式写入
$fs = [IO.File]::Create($progPath)
try {
    $padBlock = [byte[]]::new(65536); for ($i=0; $i -lt 65536; $i++) { $padBlock[$i] = 0xFF }
    function Copy-In([string]$src, [int]$offset) {
        $bytes = [IO.File]::ReadAllBytes($src)
        $null = $fs.Write($bytes, 0, $bytes.Length)
        Write-Output ("{0} -> 0x{1:X6} ({2} B)" -f (Split-Path $src -Leaf), $offset, $bytes.Length)
    }
    function Pad-To([int]$target) {
        $cur = $fs.Position
        if ($cur -gt $target) { throw "分区重叠: 当前 0x$('{0:X}' -f $cur) 超过目标 0x$('{0:X}' -f $target)" }
        while ($cur -lt $target) {
            $n = [Math]::Min(65536, $target - $cur)
            $fs.Write($padBlock, 0, $n)
            $cur += $n
        }
    }
    Copy-In $Uboot $UBOOT_OFF;   Pad-To $ENV_OFF
    Copy-In $EnvB $ENV_OFF;      Pad-To $FACT_OFF
    Copy-In $Factory $FACT_OFF;  Pad-To $FW_OFF
    Copy-In $Sysupgrade $FW_OFF; Pad-To $FLASH_SZ
} finally { $fs.Close() }

# SHA256SUMS
$lines = @()
foreach ($p in @($progPath,$breedPath,$Sysupgrade)) {
    $h = (Get-FileHash $p -Algorithm SHA256).Hash.ToLower()
    $lines += "$h  $(Split-Path $p -Leaf)"
}
$lines | Set-Content -Encoding ASCII (Join-Path $OutDir 'SHA256SUMS')

Write-Output "输出目录: $OutDir"
Get-ChildItem $OutDir | ForEach-Object { '{0}  {1}' -f $_.Name, $_.Length }
