param(
  [Parameter(Mandatory=$true)][string]$Archive,
  [Parameter(Mandatory=$true)][string]$InstallDir,
  [Parameter(Mandatory=$true)][int]$AppProcessId,
  [Parameter(Mandatory=$true)][string]$ExpectedHash,
  [Parameter(Mandatory=$true)][string]$Version,
  [ValidateSet('x64', 'arm64')][string]$Architecture = 'x64',
  [string]$StatusPrefix = '',
  [switch]$ValidateOnly
)
$ErrorActionPreference = 'Stop'
$stage = $null
$changed = @()
$root = $null
$backup = $null
if (-not $StatusPrefix) { $StatusPrefix = $Archive }
$readyFile = "$StatusPrefix.ready"
$errorFile = "$StatusPrefix.error"
$updateMutex = $null
$ownsMutex = $false
function UpdateStatus([string]$Status) {
  try { [IO.File]::WriteAllText("$StatusPrefix.progress", $Status) } catch { }
}
function AssertNoOtherInstance {
  $executable = Join-Path $root 'oplayer.exe'
  $other = Get-Process -Name oplayer -ErrorAction SilentlyContinue | Where-Object {
    $_.Id -ne $AppProcessId -and $_.Path -eq $executable
  }
  if ($other) { throw 'Another OPlayer instance is using this folder. Close other OPlayer windows before updating.' }
}
function ChildPath([string]$Base, [string]$Relative) {
  $basePath = [IO.Path]::GetFullPath($Base).TrimEnd('\') + '\'
  $resolved = [IO.Path]::GetFullPath([IO.Path]::Combine($basePath, $Relative))
  if (-not $resolved.StartsWith($basePath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Unsafe update entry path'
  }
  return $resolved
}
try {
  if ($Version -notmatch '^\d+\.\d+\.\d+(?:-(?:beta|nightly)\.[0-9A-Za-z.-]+)?$' -or $ExpectedHash -notmatch '^[0-9a-fA-F]{64}$') {
    throw 'Invalid update metadata'
  }
  $archivePath = (Get-Item -LiteralPath $Archive).FullName
  $root = (Get-Item -LiteralPath $InstallDir).FullName
  $mutexHash = [Security.Cryptography.SHA256]::Create()
  try { $mutexName = [BitConverter]::ToString($mutexHash.ComputeHash([Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant()))).Replace('-', '') }
  finally { $mutexHash.Dispose() }
  $updateMutex = New-Object Threading.Mutex($false, "Local\OPlayer.Update.$mutexName")
  try { $ownsMutex = $updateMutex.WaitOne(0) }
  catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
  if (-not $ownsMutex) { throw 'An update is already running for this OPlayer folder.' }
  if (-not (Test-Path -LiteralPath (Join-Path $root 'oplayer.exe') -PathType Leaf)) { throw 'OPlayer executable was not found' }
  if ((Get-Item -LiteralPath $root).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Install directory is a reparse point' }
  UpdateStatus 'hash'
  $hashAlgorithm = [Security.Cryptography.SHA256]::Create()
  $archiveStream = [IO.File]::OpenRead($archivePath)
  try { $actualHash = [BitConverter]::ToString($hashAlgorithm.ComputeHash($archiveStream)).Replace('-', '') }
  finally { $archiveStream.Dispose(); $hashAlgorithm.Dispose() }
  if ($actualHash -ne $ExpectedHash) { throw 'Update checksum mismatch' }
  $stage = Join-Path ([IO.Path]::GetDirectoryName($archivePath)) ('stage-' + [Guid]::NewGuid().ToString('N'))
  $null = New-Item -ItemType Directory -Path $stage
  $backup = Join-Path $stage 'backup'
  $null = New-Item -ItemType Directory -Path $backup
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [IO.Compression.ZipFile]::OpenRead($archivePath)
  $prefix = "OPlayer-$Version-windows-$Architecture/"
  try {
    foreach ($entry in $zip.Entries) {
      $name = $entry.FullName.Replace('\', '/')
      if (-not $name.StartsWith($prefix, [StringComparison]::Ordinal) -or $name.Contains(':') -or $name -match '(^|/)\.\.(/|$)') { throw 'Unsafe archive entry' }
      $null = ChildPath $stage $name
      # Release Windows archives contain files/directories, never symlinks.
      if ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'Archive links are not supported' }
    }
  } finally { $zip.Dispose() }
  UpdateStatus 'extract'
  [IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $stage)
  $incoming = ChildPath $stage $prefix.TrimEnd('/')
  if (-not (Test-Path -LiteralPath (Join-Path $incoming 'oplayer.exe')) -or
      -not (Test-Path -LiteralPath (Join-Path $incoming 'flutter_windows.dll')) -or
      -not (Test-Path -LiteralPath (Join-Path $incoming 'data'))) { throw 'Incomplete update bundle' }
  $files = @(Get-ChildItem -LiteralPath $incoming -File -Recurse)
  UpdateStatus 'inspect'
  foreach ($file in $files) {
    $relative = $file.FullName.Substring($incoming.Length).TrimStart('\')
    $destination = ChildPath $root $relative
    $parent = [IO.Path]::GetDirectoryName($destination)
    while ($parent.Length -ge $root.Length) {
      if ((Test-Path -LiteralPath $parent) -and ((Get-Item -LiteralPath $parent).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Update destination traverses a reparse point'
      }
      $parent = [IO.Path]::GetDirectoryName($parent)
      if (-not $parent) { break }
    }
    if ((Test-Path -LiteralPath $destination) -and ((Get-Item -LiteralPath $destination).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw 'Update destination is a reparse point'
    }
  }
  if ($ValidateOnly) { Write-Output 'Update archive validated'; exit 0 }
  AssertNoOtherInstance
  # Fail before asking the running app to close if this folder is read-only.
  $probe = ChildPath $root ('.oplayer-update-' + [Guid]::NewGuid().ToString('N'))
  [IO.File]::WriteAllText($probe, '')
  Remove-Item -LiteralPath $probe
  [IO.File]::WriteAllText($readyFile, 'ready')
  UpdateStatus 'waiting'
  # The app can exit between checking its PID and Wait-Process attaching to it.
  $exitDeadline = [DateTime]::UtcNow.AddSeconds(120)
  while (Get-Process -Id $AppProcessId -ErrorAction SilentlyContinue) {
    if ([DateTime]::UtcNow -ge $exitDeadline) { throw 'OPlayer did not exit before the update timeout' }
    Start-Sleep -Milliseconds 200
  }
  AssertNoOtherInstance
  foreach ($file in $files) {
    $relative = $file.FullName.Substring($incoming.Length).TrimStart('\')
    $destination = ChildPath $root $relative
    $saved = ChildPath $backup $relative
    $existed = Test-Path -LiteralPath $destination
    if ($existed) {
      $null = New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($saved))
      Copy-Item -LiteralPath $destination -Destination $saved
    }
    $changed += [pscustomobject]@{Destination=$destination; Backup=$saved; Existed=$existed}
    $null = New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($destination))
    Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
  }
  Start-Process -FilePath (Join-Path $root 'oplayer.exe') -WorkingDirectory $root
} catch {
  $message = $_.Exception.Message
  for ($i = $changed.Count - 1; $i -ge 0; $i--) {
    $change = $changed[$i]
    try {
      if ($change.Existed) { Copy-Item -LiteralPath $change.Backup -Destination $change.Destination -Force }
      elseif (Test-Path -LiteralPath $change.Destination) { Remove-Item -LiteralPath $change.Destination }
    } catch { }
  }
  [IO.File]::WriteAllText($errorFile, $message)
  if (-not $ValidateOnly -and $changed.Count -gt 0 -and $root) {
    Start-Process -FilePath (Join-Path $root 'oplayer.exe') -WorkingDirectory $root
  }
  Write-Error $message
  exit 1
} finally {
  if ($ownsMutex) { $updateMutex.ReleaseMutex() }
  if ($updateMutex) { $updateMutex.Dispose() }
  if ($stage -and (Test-Path -LiteralPath $stage)) {
    $resolvedStage = [IO.Path]::GetFullPath($stage)
    $intendedParent = [IO.Path]::GetFullPath(([IO.Path]::GetDirectoryName($archivePath))).TrimEnd('\') + '\'
    if ($resolvedStage.StartsWith($intendedParent, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolvedStage -Leaf).StartsWith('stage-')) {
      Remove-Item -LiteralPath $resolvedStage -Recurse -Force
    }
  }
}
