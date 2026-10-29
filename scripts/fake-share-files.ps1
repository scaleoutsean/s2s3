#!/usr/bin/env pwsh

# (c) scaleoutSean, 2026 
# Script for file share contents simulation on Windows OS only.
# ./fake-share-files.ps1 -path <directory> -count <number> -tree <depth> [-size <file size>]
# The script creates a fake file share structure with the specified number of files and directory tree depth.
# Example:
# ./fake-share-files.ps1 -path C:\FakeShare -count 10 -tree 3 -size 1MB
# This will create a directory structure under C:\FakeShare with 10 files distributed across 3 levels of subdirectories, each file being 1MB in size.
# To avoid large files, omit the -size parameter which will create empty files instead.
# Parameters:
# -path: The root directory where the fake share will be created.
# -count: The total number of files to create.
# -tree: The depth of the directory tree.
# -size: (Optional) The size of each file. If omitted, files will be empty.
# Defaults:
# -count: 10
# -tree: 3
# -size: 0MB
# Maximum accepted values:
# -count: 100000
# -tree: 100
# -size: 1TB

[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)]
	[ValidateNotNullOrEmpty()]
	[string]$Path,

	[ValidateRange(1, 100000)]
	[int]$Count = 10,

	[ValidateRange(0, 100)]
	[int]$Tree = 3,

	[ValidatePattern('^\d+(?:\.\d+)?\s*(?:B|KB|MB|GB|TB)?$')]
	[string]$Size = '0'
)

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
	throw 'This script supports Windows only.'
}

$ErrorActionPreference = 'Stop'
$root = Get-Item -LiteralPath $Path -Force
if ($root.PSProvider.Name -ne 'FileSystem' -or -not $root.PSIsContainer) {
	throw "Path must be an existing file system directory: $Path"
}

$sizeMatch = [regex]::Match($Size, '^(\d+(?:\.\d+)?)\s*(B|KB|MB|GB|TB)?$', 'IgnoreCase')
$multipliers = @{ B = 1L; KB = 1KB; MB = 1MB; GB = 1GB; TB = 1TB }
$unit = $sizeMatch.Groups[2].Value.ToUpperInvariant()
if (-not $unit) {
	$unit = 'B'
}
$byteCount = [decimal]::Parse($sizeMatch.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture) * $multipliers[$unit]
if ($byteCount -gt 1TB -or $byteCount -ne [decimal]::Truncate($byteCount)) {
	throw 'Size must be a whole number of bytes between 0 and 1TB.'
}
$fileSize = [long]$byteCount
$requiredBytes = $fileSize * [long]$Count

$driveName = 'FakeShare' + [guid]::NewGuid().ToString('N')
$drive = New-PSDrive -Name $driveName -PSProvider FileSystem -Root $root.FullName
try {
	$freeBytes = $drive.Free
	if ($null -eq $freeBytes) {
		throw "Cannot determine available space for: $Path"
	}
	if ($requiredBytes -gt $freeBytes) {
		throw "Insufficient free space: need $requiredBytes bytes, but only $freeBytes bytes are available."
	}
} finally {
	Remove-PSDrive -Name $driveName
}

$runId = [guid]::NewGuid().ToString('N')
$directories = @($root.FullName)
$currentDirectory = $root.FullName
for ($level = 1; $level -le $Tree; $level++) {
	$directoryName = 'level-{0:D3}' -f $level
	if ($level -eq 1) {
		$directoryName += "-$runId"
	}
	$currentDirectory = Join-Path $currentDirectory $directoryName
	$directory = New-Item -ItemType Directory -Path $currentDirectory
	$directories += $directory.FullName
}

for ($index = 0; $index -lt $Count; $index++) {
	$directory = $directories[$index % $directories.Count]
	$filePath = Join-Path $directory ('file-{0}-{1:D6}.bin' -f $runId, ($index + 1))
	$stream = [IO.File]::Open($filePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
	try {
		$stream.SetLength($fileSize)
	} catch {
		$stream.Dispose()
		[IO.File]::Delete($filePath)
		throw
	} finally {
		$stream.Dispose()
	}
}

Write-Output "Created $Count files of $fileSize bytes under $($root.FullName)."

