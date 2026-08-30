[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Target,

    [Parameter(Mandatory = $true)]
    [string]$RemotePluginPath,

    [string]$PackagePath,

    [string]$SourceDirectory,

    [switch]$Rollback,

    [string]$BackupPath,

    [int]$Port = 22
)

$ErrorActionPreference = "Stop"

function Assert-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "找不到命令：$Name"
    }
}

function Quote-Posix([string]$Value) {
    $singleQuote = [string][char]39
    $escapedQuote = $singleQuote + "\" + $singleQuote + $singleQuote
    return $singleQuote + $Value.Replace($singleQuote, $escapedQuote) + $singleQuote
}

function Invoke-Remote([string]$Command) {
    $output = & ssh -p $Port $Target $Command 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "远端命令失败：$Command`n$($output | Out-String)"
    }
    return $output
}

Assert-Command "ssh"
Assert-Command "scp"

$RemotePluginPath = $RemotePluginPath.TrimEnd('/')
if (-not $RemotePluginPath.StartsWith('/')) {
    throw "RemotePluginPath 必须是绝对路径"
}

Invoke-Remote "true" | Out-Null
$parentIndex = $RemotePluginPath.LastIndexOf('/')
$remoteParent = if ($parentIndex -le 0) { '/' } else { $RemotePluginPath.Substring(0, $parentIndex) }
Invoke-Remote "set -eu; test -d $(Quote-Posix $remoteParent)" | Out-Null

if ($Rollback) {
    if ($PackagePath -or $SourceDirectory) {
        throw "Rollback 不能同时指定 PackagePath 或 SourceDirectory"
    }
    if (-not $BackupPath) {
        throw "Rollback 必须指定 BackupPath"
    }
    $BackupPath = $BackupPath.TrimEnd('/')
    if (-not $BackupPath.StartsWith('/')) {
        throw "BackupPath 必须是绝对路径"
    }

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $rollbackPath = "$RemotePluginPath.__before-rollback-$stamp"
    $current = Quote-Posix $RemotePluginPath
    $backup = Quote-Posix $BackupPath
    $rollback = Quote-Posix $rollbackPath
    Invoke-Remote "set -eu; test -d $backup; test ! -e $rollback; if [ -e $current ]; then mv $current $rollback; fi; mv $backup $current"
    Write-Host "已回滚：$BackupPath -> $RemotePluginPath"
    Write-Host "回滚前版本保留在：$rollbackPath"
    exit 0
}

if ($PackagePath -and $SourceDirectory) {
    throw "PackagePath 和 SourceDirectory 只能指定一个"
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$temporaryRoot = $null
try {
    if ($PackagePath) {
        $package = (Resolve-Path -LiteralPath $PackagePath).Path
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("pickthought-deploy-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
        Expand-Archive -LiteralPath $package -DestinationPath $temporaryRoot
        $source = Join-Path $temporaryRoot "pickthought.koplugin"
    } elseif ($SourceDirectory) {
        $source = (Resolve-Path -LiteralPath $SourceDirectory).Path
    } else {
        $source = Join-Path $repoRoot "pickthought.koplugin"
    }

    if (-not (Test-Path -LiteralPath (Join-Path $source "main.lua") -PathType Leaf)) {
        throw "部署源不是有效的 pickthought.koplugin 目录：$source"
    }

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $remoteStage = "$RemotePluginPath.__staging-$stamp"
    $remoteBackup = "$RemotePluginPath.__backup-$stamp"
    $stage = Quote-Posix $remoteStage
    $backup = Quote-Posix $remoteBackup
    $current = Quote-Posix $RemotePluginPath
    $stagedPlugin = Quote-Posix "$remoteStage/pickthought.koplugin"

    Invoke-Remote "set -eu; test ! -e $stage; mkdir -p $stage"
    $destination = "{0}:{1}/" -f $Target, $remoteStage
    & scp -P $Port -r $source $destination 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "上传插件失败，远端暂存目录已保留：$remoteStage"
    }

    Invoke-Remote "set -eu; test -f $stagedPlugin/main.lua; test ! -e $backup; if [ -e $current ]; then mv $current $backup; fi; mv $stagedPlugin $current; rmdir $stage"
    Write-Host "部署完成：$RemotePluginPath"
    Write-Host "旧版本备份：$remoteBackup"
    Write-Host "请完全重启 KOReader 后再验证。"
} finally {
    if ($temporaryRoot -and (Test-Path -LiteralPath $temporaryRoot)) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
