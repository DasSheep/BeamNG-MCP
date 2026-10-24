$ErrorActionPreference = 'Stop'
$script = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/build-manifest.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('beammcp-identity-' + [Guid]::NewGuid())
[IO.Directory]::CreateDirectory((Join-Path $testRoot 'lua/common')) | Out-Null
[IO.Directory]::CreateDirectory((Join-Path $testRoot 'scripts/beammcp')) | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)
try {
  [IO.File]::WriteAllText((Join-Path $testRoot 'lua/common/example.lua'), 'return 1', $utf8)
  [IO.File]::WriteAllText((Join-Path $testRoot 'scripts/beammcp/modScript.lua'), 'return {}', $utf8)
  [IO.File]::WriteAllText((Join-Path $testRoot '.gitignore'), 'dist/', $utf8)
  & git -C $testRoot init --quiet
  & git -C $testRoot add lua/common/example.lua scripts/beammcp/modScript.lua .gitignore
  & git -C $testRoot -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m fixture
  if ($LASTEXITCODE -ne 0) { throw 'Fixture Git initialization failed' }
  $output = Join-Path $testRoot 'dist/scripts/beammcp/build.json'
  & $script -RepoRoot $testRoot -OutputPath $output | Out-Null
  $first = [IO.File]::ReadAllText($output)
  & $script -RepoRoot $testRoot -OutputPath $output | Out-Null
  if ($first -ne [IO.File]::ReadAllText($output)) { throw 'Manifest is not deterministic' }
  $before = $first | ConvertFrom-Json
  if ($before.dirty -or $before.fileCount -ne 2) { throw 'Incorrect clean manifest' }
  [IO.File]::WriteAllText((Join-Path $testRoot 'lua/common/example.lua'), 'return 2', $utf8)
  & $script -RepoRoot $testRoot -OutputPath $output | Out-Null
  $after = [IO.File]::ReadAllText($output) | ConvertFrom-Json
  if (-not $after.dirty -or $after.contentSha256 -eq $before.contentSha256) { throw 'Source edit did not change identity' }
  [IO.File]::WriteAllText((Join-Path $testRoot 'lua/common/new.lua'), 'return 3', $utf8)
  & $script -RepoRoot $testRoot -OutputPath $output | Out-Null
  $added = [IO.File]::ReadAllText($output) | ConvertFrom-Json
  if ($added.fileCount -ne 3 -or $added.contentSha256 -eq $after.contentSha256) { throw 'Untracked shipped file not included' }
  if (Test-Path (Join-Path $testRoot 'lua/common/build.json')) { throw 'Generated source pollution' }
  Write-Output 'Build manifest tests passed: deterministic, clean/dirty, source edits, untracked shipped files.'
} finally {
  $resolved = [IO.Path]::GetFullPath($testRoot)
  $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
  if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or
      -not ([IO.Path]::GetFileName($resolved)).StartsWith('beammcp-identity-')) { throw 'Unsafe fixture cleanup path' }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
