# =============================================================
# k60pro-ios-sched 发布脚本
# 一条命令完成: 版本号写入 -> 打包 -> update.json -> 推送 -> GitHub Release
# 用法: .\publish.ps1 -Version v1.2.0 -VersionCode 11200 -Changelog "更新说明"
# =============================================================
param(
    [Parameter(Mandatory = $true)][string]$Version,     # 版本号, 如 "v1.2.0"
    [int]$VersionCode = 0,                               # 留 0 = 从 module.prop 读取
    [string]$Changelog = "问题修复与优化"
)
$ErrorActionPreference = 'Stop'

$ghUser   = 'Jeff1108123'
$repoName = 'k60pro-ios-sched'
$modDir   = Join-Path $PSScriptRoot 'ios_sched_k60pro'
$zipName  = "ios_sched_k60pro-$Version.zip"
$zipPath  = Join-Path $PSScriptRoot $zipName

if ($VersionCode -eq 0) {
    $VersionCode = [int]((Select-String -Path "$modDir\module.prop" -Pattern '^versionCode=(\d+)').Matches[0].Groups[1].Value)
}

# 1) 版本号写入 module.prop (用 .NET 读取避免 PS5.1 GBK 编码问题)
$prop = [IO.File]::ReadAllText("$modDir\module.prop")
$prop = $prop -replace '(?m)^version=.*$', "version=$Version"
$prop = $prop -replace '(?m)^versionCode=.*$', "versionCode=$VersionCode"
[IO.File]::WriteAllText("$modDir\module.prop", $prop, (New-Object System.Text.UTF8Encoding($false)))

# 2) LF 行尾 + UTF-8 无 BOM 规范化 (Android shell 要求)
foreach ($f in Get-ChildItem $modDir -File) {
    $t = [IO.File]::ReadAllText($f.FullName)
    $t = $t -replace "`r`n", "`n"
    [IO.File]::WriteAllText($f.FullName, $t, (New-Object System.Text.UTF8Encoding($false)))
}

# 3) 打 zip (模块文件必须位于 zip 根目录)
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($f in Get-ChildItem $modDir -File) {
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip, $f.FullName, $f.Name, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
        Write-Host ("  + " + $f.Name)
    }
} finally { $zip.Dispose() }

# 4) 生成 update.json (KernelSU 在线更新索引, 无 BOM)
$zipUrl = "https://github.com/$ghUser/$repoName/releases/download/$Version/$zipName"
$json = @{
    version     = $Version
    versionCode = $VersionCode
    zipUrl      = $zipUrl
    changelog   = $Changelog
} | ConvertTo-Json
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'update.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "update.json -> $zipUrl"

# 5) 提交推送
git -C $PSScriptRoot add -A
$status = git -C $PSScriptRoot status --porcelain
if ($status) {
    git -C $PSScriptRoot commit -m "release $Version"
    git -C $PSScriptRoot push
} else {
    Write-Host "无变更, 跳过提交"
}

# 6) 创建 GitHub Release 并上传 zip
gh release create $Version $zipPath --repo "$ghUser/$repoName" --title "$Version" --notes $Changelog

Write-Host "`nOK -> $Version 已发布, KernelSU 管理器将提示在线更新"
