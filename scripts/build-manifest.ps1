<#
.SYNOPSIS
  Write deterministic deployment identity metadata without modifying Lua source files.
.DESCRIPTION
  contentSha256 covers sorted paths and SHA-256 hashes of shipped lua/ files and modScript.lua.
  This is a deployment claim, not evidence that a running VM has loaded those files. Live junction
  edits require regenerating this manifest; diagnostics explicitly report that disk is not verified.
#>
param(
  [Parameter(Mandatory = $true)][string] $OutputPath,
  [string] $RepoRoot = (Split-Path $PSScriptRoot -Parent)
)
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$repoPath = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\', '/')
$luaPath = Join-Path $repoPath 'lua'
$loaderPath = Join-Path $repoPath 'scripts/beammcp/modScript.lua'
if (-not (Test-Path -LiteralPath $luaPath) -or -not (Test-Path -LiteralPath $loaderPath)) {
  throw 'Build identity requires lua/ and scripts/beammcp/modScript.lua'
}
# Never generate identity inside lua/: dist/beammcp/lua can be a junction to the tracked sources.
$outputFull = [IO.Path]::GetFullPath($OutputPath)
if ([IO.Path]::GetFileName($outputFull) -ne 'build.json' -or
    [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($outputFull)) -ne 'beammcp' -or
    [IO.Path]::GetFileName([IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($outputFull))) -ne 'scripts') {
  throw 'OutputPath must end in scripts/beammcp/build.json'
}
$files = @(Get-ChildItem -LiteralPath $luaPath -File -Recurse) + @(Get-Item -LiteralPath $loaderPath)
$byPath = @{}
foreach ($file in $files) {
  $relative = $file.FullName.Substring($repoPath.Length + 1).Replace('\', '/')
  $byPath[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
}
$paths = [string[]]@($byPath.Keys)
[Array]::Sort($paths, [StringComparer]::Ordinal)
$records = foreach ($path in $paths) { "$path`t$($byPath[$path])`n" }
$bytes = [Text.Encoding]::UTF8.GetBytes(($records -join ''))
$sha = [Security.Cryptography.SHA256]::Create()
try { $contentHash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
finally { $sha.Dispose() }
$commit = (& git -C $repoPath rev-parse HEAD 2>$null)
if ($LASTEXITCODE -ne 0) { throw 'Cannot determine Git commit for build identity' }
$status = @(& git -C $repoPath status --porcelain --untracked-files=normal)
if ($LASTEXITCODE -ne 0) { throw 'Cannot determine Git dirty state for build identity' }
$manifest = [ordered]@{
  schemaVersion = 1
  commit = [string]$commit
  dirty = $status.Count -gt 0
  contentSha256 = $contentHash
  fileCount = $paths.Length
}
$parentPath = Split-Path $outputFull -Parent
[IO.Directory]::CreateDirectory($parentPath) | Out-Null
[IO.File]::WriteAllText($outputFull, (($manifest | ConvertTo-Json) + "`n"), [Text.UTF8Encoding]::new($false))
Write-Output "Build manifest: $outputFull ($contentHash)"
