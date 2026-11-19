$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$sources = @('offline-deps-ubuntu24.04-amd64', 'offline-deps-repair-ubuntu24.04-amd64')
$name = 'offline-deps-complete-ubuntu24.04-amd64'
$destination = Join-Path $root $name
if (Test-Path -LiteralPath $destination) { throw "Output already exists: $destination" }
$utf8 = [System.Text.UTF8Encoding]::new($false)
function Write-Utf8Lf($path, $content) {
    [System.IO.File]::WriteAllText($path, ($content -replace "`r`n", "`n"), $utf8)
}
New-Item -ItemType Directory -Path (Join-Path $destination 'debs') | Out-Null
$rows = @()
$indexes = @()
foreach ($source in $sources) {
    $sourcePath = Join-Path $root $source
    $rows += Import-Csv -LiteralPath (Join-Path $sourcePath 'package-versions.tsv') -Delimiter "`t"
    $indexes += (Get-Content -LiteralPath (Join-Path $sourcePath 'Packages') -Raw).TrimEnd()
    foreach ($deb in Get-ChildItem -LiteralPath (Join-Path $sourcePath 'debs') -Filter '*.deb') {
        $target = Join-Path $destination "debs/$($deb.Name)"
        if (Test-Path -LiteralPath $target) { throw "Duplicate package: $target" }
        Copy-Item -LiteralPath $deb.FullName -Destination $target
    }
}
$rows = @($rows | Sort-Object Package)
if (@($rows | Group-Object Package | Where-Object Count -gt 1).Count) { throw 'Duplicate package names' }
Write-Utf8Lf (Join-Path $destination 'Packages') (($indexes -join "`n`n") + "`n`n")
$tsv = "Package`tVersion`tArchitecture`n" + (($rows | ForEach-Object { "$($_.Package)`t$($_.Version)`t$($_.Architecture)" }) -join "`n") + "`n"
Write-Utf8Lf (Join-Path $destination 'package-versions.tsv') $tsv
Write-Utf8Lf (Join-Path $root 'DEPENDENCIES.tsv') $tsv
$intro = @'
# 离线部署依赖与版本

适用系统：Ubuntu 24.04（noble），amd64。此清单记录完整离线包中可安装的软件包版本，不代表目标服务器已全部安装。

完整包合并基础包和修复补充包；安装器只安装部署所需依赖，并同步服务器上已经存在的 systemd/udev 等组件。已有 Docker 引擎会被保留，其实际版本可能不同。系统中更高版本也不强制降级。

在部署目录执行 `sudo bash deploy-offline.sh`。成功安装依赖后，实际安装版本保存为 `offline-deps-complete-ubuntu24.04-amd64/installed-dependencies.tsv`。该文件只列出完整包清单中在服务器上实际处于 installed 状态的软件包，不包含操作系统的全部软件。

'@
$table = "共 $($rows.Count) 个软件包。`n`n| 软件包 | 包内版本 | 架构 |`n|---|---|---|`n" + (($rows | ForEach-Object { "| $($_.Package) | $($_.Version) | $($_.Architecture) |" }) -join "`n") + "`n"
Write-Utf8Lf (Join-Path $root 'DEPENDENCIES.md') ($intro + "`n" + $table)
Write-Utf8Lf (Join-Path $destination 'README.md') ($intro + "`n" + $table)
Write-Utf8Lf (Join-Path $destination 'COMPLETE-BUNDLE') "Ubuntu 24.04 amd64: base plus systemd/curl repair dependencies.`n"
Write-Utf8Lf (Join-Path $destination 'install-offline.sh') (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'install.sh') -Raw)
Write-Output "Merged $($rows.Count) packages into $destination"
