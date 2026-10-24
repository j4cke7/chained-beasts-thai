[CmdletBinding()]
param(
    [ValidateSet('Install','Uninstall','Status')][string]$Action = 'Install',
    [string]$GameRoot,
    [string]$OriginalBackup,
    [switch]$AllowTestPackage
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$copyBuffer = New-Object byte[] 1048576
$maximumAssetBytes = 160 * 1024 * 1024

function Assert-Hash($Value) {
    if ($Value -isnot [string] -or $Value -cnotmatch '^[0-9a-f]{64}$') { throw 'Invalid SHA-256 format.' }
}
function Assert-PositiveInteger($Value, [long]$Maximum) {
    if (($Value -isnot [int] -and $Value -isnot [long]) -or $Value -le 0 -or $Value -gt $Maximum) {
        throw 'Manifest resource bound/type violation.'
    }
}
function Assert-TrueBoolean($Value) {
    if ($Value -isnot [bool] -or $Value -cne $true) { throw 'Runtime attestation requires exact true booleans.' }
}
function Assert-Keys($Object, [string[]]$Keys) {
    if ($null -eq $Object -or $Object -isnot [pscustomobject]) { throw 'Invalid object type.' }
    $actual = @($Object.PSObject.Properties.Name)
    if ($actual.Count -ne $Keys.Count) { throw 'Unsupported object properties.' }
    foreach ($key in $Keys) { if ($actual -cnotcontains $key) { throw "Missing exact property: $key" } }
}
function Read-Json([string]$Path) {
    if ((Get-Item -LiteralPath $Path).Length -gt 1048576) { throw 'JSON resource bound exceeded.' }
    $raw = [IO.File]::ReadAllText($Path)
    $sets = New-Object 'Collections.Generic.Stack[object]'
    foreach ($token in [regex]::Matches($raw, '"(?:[^"\\]|\\.)*"|[{}]')) {
        if ($token.Value -eq '{') { $sets.Push((New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase))) }
        elseif ($token.Value -eq '}') { if ($sets.Count -eq 0) { throw 'Invalid JSON nesting.' }; $null = $sets.Pop() }
        elseif ($raw.Substring($token.Index + $token.Length).TrimStart().StartsWith(':')) {
            $name = $token.Value | ConvertFrom-Json
            if ($sets.Count -eq 0 -or !$sets.Peek().Add([string]$name)) { throw 'Duplicate JSON property.' }
        }
    }
    return ($raw | ConvertFrom-Json)
}
function Assert-Identity($Identity) {
    Assert-Keys $Identity @('sha256','size')
    Assert-Hash $Identity.sha256
    Assert-PositiveInteger $Identity.size $maximumAssetBytes
}
function Assert-File([string]$Path, $Identity) {
    Assert-SafePath $Path
    if (!(Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-Item -LiteralPath $Path).Length -ne $Identity.size -or (Get-Sha $Path) -cne $Identity.sha256) {
        throw "File missing or corrupt: $Path"
    }
}

function Assert-SafePath([string]$Path) {
    $itemPath = [IO.Path]::GetFullPath($Path)
    while ($itemPath) {
        $pathItem = Get-Item -Force -LiteralPath $itemPath -ErrorAction SilentlyContinue
        if ($pathItem -and ($pathItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Reparse point refused: $itemPath"
        }
        $parent = [IO.Path]::GetDirectoryName($itemPath)
        if ($parent -eq $itemPath) { break }
        $itemPath = $parent
    }
}
function Get-Sha([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-','').ToLowerInvariant() }
    finally { $hasher.Dispose(); $stream.Dispose() }
}
function Assert-Original([string]$Path) {
    Assert-File $Path $member.original
}
function Assert-GameStopped {
    foreach ($gameProcess in @(Get-Process -Name 'ChainedBeasts' -ErrorAction SilentlyContinue)) {
        $exePath = $gameProcess.Path
        if (!$exePath -or [IO.Path]::GetDirectoryName($exePath) -eq $GameRoot) {
            throw 'Close Chained Beasts before changing files.'
        }
    }
}
function Copy-Count($Source, $Destination, [long]$Count) {
    while ($Count -gt 0) {
        $take = [int][Math]::Min($copyBuffer.Length, $Count)
        $got = $Source.Read($copyBuffer, 0, $take)
        if ($got -eq 0) { throw 'Truncated delta/source.' }
        $Destination.Write($copyBuffer, 0, $got)
        $Count -= $got
    }
}
function Expand-Delta([string]$SourcePath, [string]$StagePath) {
    $sourceStream = $null; $patchStream = $null; $writer = $null; $reader = $null
    try {
        $sourceStream = [IO.File]::Open($SourcePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $patchStream = [IO.File]::OpenRead($patchPath)
        $reader = New-Object IO.BinaryReader($patchStream)
        if ([Text.Encoding]::ASCII.GetString($reader.ReadBytes(8)) -ne 'CBDLT001') { throw 'Unsupported delta magic.' }
        $count = $reader.ReadUInt32()
        if ($count -ne $member.patch.operations -or $count -gt 1000000 -or
            $count -gt [Math]::Floor(($patchStream.Length - 12) / 17)) { throw 'Invalid operation count.' }
        $writer = [IO.File]::Open($StagePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        for ($i = 0; $i -lt $count; $i++) {
            $kind = $reader.ReadByte(); $offset = $reader.ReadUInt64(); $length = $reader.ReadUInt64()
            if ($length -gt $member.output.size -or $writer.Position -gt $member.output.size - $length) { throw 'Delta output bounds exceeded.' }
            if ($kind -eq 0) {
                if ($offset -gt $sourceStream.Length -or $length -gt $sourceStream.Length - $offset) { throw 'Delta COPY bounds exceeded.' }
                $sourceStream.Position = [long]$offset
                Copy-Count $sourceStream $writer ([long]$length)
            } elseif ($kind -eq 1 -and $offset -eq 0) {
                Copy-Count $patchStream $writer ([long]$length)
            } else { throw 'Unsupported delta instruction.' }
        }
        if ($patchStream.Position -ne $patchStream.Length -or $writer.Length -ne $member.output.size) { throw 'Delta length mismatch.' }
        $writer.Flush($true)
    } finally {
        if ($writer) { $writer.Dispose() }
        if ($reader) { $reader.Dispose() }
        if ($patchStream) { $patchStream.Dispose() }
        if ($sourceStream) { $sourceStream.Dispose() }
    }
}

$lock = $null; $stage = $null; $backupStage = $null; $dllGuard = $null
try {
    $manifest = Read-Json (Join-Path $PSScriptRoot 'manifest.json')
    Assert-Keys $manifest @('schema','buildid','appid','profile','mode','target','dll_path','asset','original_dll','test_only','runtime_proof','runtime_proof_source','static_verification','release_check','fonts')
    $member = $manifest.asset
    Assert-Keys $member @('original','output','patch')
    Assert-Keys $member.patch @('file','sha256','size','operations')
    if ($manifest.schema -cne 'cb-thai-release-en-v1' -or $manifest.buildid -cne '26152147' -or $manifest.appid -cne '3569420' -or
        $manifest.mode -cne 'replace:en' -or $manifest.dll_path -cne 'GameAssembly.dll' -or
        $manifest.target -cne 'ChainedBeasts_Data/resources.assets' -or $member.patch.file -cne 'resources.cbd') { throw 'Unsupported package manifest/path.' }
    if ($manifest.test_only -isnot [bool]) { throw 'Manifest test_only must be a boolean.' }
    Assert-Identity $member.original
    Assert-Identity $member.output
    Assert-Identity $manifest.original_dll
    foreach ($record in @($member.patch)) {
        Assert-Hash $record.sha256
        Assert-PositiveInteger $record.size $maximumAssetBytes
    }
    Assert-PositiveInteger $member.patch.operations 1000000
    if ($member.patch.size -lt 29 -or $member.patch.operations -gt [Math]::Floor(($member.patch.size - 12) / 17)) {
        throw 'Invalid operation count/patch size.'
    }
    if ($manifest.test_only) {
        if (!$AllowTestPackage -or $manifest.profile -cne 'synthetic-fixture' -or
            $member.original.sha256 -cne '2e2489566f66ca46e96548a3f159d9752ebb31a8cfa613b9753894fd7da560e5' -or $member.original.size -ne 528 -or
            $member.output.sha256 -cne '016017d0325cee76be11b1d2518a34787e132a8a22a42f13c7b139a19e0a7724' -or $member.output.size -ne 493 -or
            $manifest.original_dll.sha256 -cne '6b4e935cf89342d785fb5873a99feca4bac88aacafef43f4704671fff4a04492' -or $manifest.original_dll.size -ne 200 -or
            $null -ne $manifest.runtime_proof -or $null -ne $manifest.runtime_proof_source -or
            $null -ne $manifest.static_verification -or $null -ne $manifest.release_check) { throw 'Unsupported synthetic fixture profile.' }
    }
    if (!$manifest.test_only) {
        if ($manifest.profile -cne 'production' -or $member.original.size -ne 120316364 -or
            $member.original.sha256 -cne '7cbe524a07847be4918358e13bdd9b01076e3a71182ac1a7b856350844991284' -or
            $manifest.original_dll.size -ne 87522304 -or $manifest.original_dll.sha256 -cne 'ba3ef02fa87da4c41bb27d7610539c9578132204f0fb5713833e2ef93415ce29') { throw 'Unsupported production original identities.' }
        $proof = $manifest.runtime_proof
        Assert-Keys $proof @('schema','buildid','release','provenance','evidence','english_selection_displays_thai','restart_persistence','another_original_language','rendering_smoke')
        Assert-Keys $proof.release @('asset','original_dll')
        Assert-Keys $proof.release.asset @('original','output')
        Assert-Identity $proof.release.asset.original
        Assert-Identity $proof.release.asset.output
        Assert-Identity $proof.release.original_dll
        if ($proof.schema -cne 'cb-thai-runtime-attestation-en-v1' -or $proof.buildid -cne $manifest.buildid -or
            $proof.release.asset.original.sha256 -cne $member.original.sha256 -or $proof.release.asset.original.size -ne $member.original.size -or
            $proof.release.asset.output.sha256 -cne $member.output.sha256 -or $proof.release.asset.output.size -ne $member.output.size -or
            $proof.release.original_dll.sha256 -cne $manifest.original_dll.sha256 -or $proof.release.original_dll.size -ne $manifest.original_dll.size) { throw 'Runtime attestation missing or mismatched.' }
        foreach ($outcome in @($proof.english_selection_displays_thai,$proof.restart_persistence,$proof.another_original_language,$proof.rendering_smoke)) { Assert-TrueBoolean $outcome }
        Assert-Keys $proof.provenance @('observer','observed_at','method')
        foreach ($value in @($proof.provenance.observer,$proof.provenance.observed_at,$proof.provenance.method)) {
            if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) { throw 'Runtime attestation provenance missing.' }
        }
        if (@($proof.evidence).Count -lt 1) { throw 'Runtime attestation evidence missing.' }
        foreach ($evidence in @($proof.evidence)) {
            Assert-Keys $evidence @('reference','sha256')
            Assert-Hash $evidence.sha256
            if ($evidence.reference -isnot [string] -or [string]::IsNullOrWhiteSpace($evidence.reference)) { throw 'Runtime evidence reference missing.' }
        }
        Assert-Hash $manifest.runtime_proof_source.sha256
        Assert-Keys $manifest.runtime_proof_source @('reference','sha256')
        if ([string]::IsNullOrWhiteSpace($manifest.runtime_proof_source.reference)) { throw 'Runtime proof reference missing.' }
        $verification = $manifest.static_verification
        Assert-TrueBoolean $verification.result.ok
        Assert-Hash $verification.verifier_sha256
        if ($verification.verifier -cne 'adapters.chained_beasts.verify' -or $verification.input_sha256 -cne $member.original.sha256 -or
            $verification.output_sha256 -cne $member.output.sha256) { throw 'Static verification binding missing or mismatched.' }
        Assert-TrueBoolean $manifest.release_check.result.ok
        Assert-Hash $manifest.release_check.verifier_sha256
        if ($manifest.release_check.verifier -cne 'adapters.chained_beasts_batch.release_check') { throw 'Release-check provenance missing.' }
    }
    $patchPath = Join-Path $PSScriptRoot 'resources.cbd'
    Assert-File $patchPath $member.patch
    if (!$GameRoot) {
        $steam = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
        $candidates = @()
        if ($steam) {
            $libraries = @($steam)
            $libraryFile = Join-Path $steam 'steamapps/libraryfolders.vdf'
            if (Test-Path -LiteralPath $libraryFile) {
                foreach ($match in [regex]::Matches([IO.File]::ReadAllText($libraryFile), '"path"\s+"([^"]+)"')) {
                    $libraries += $match.Groups[1].Value.Replace('\\','\')
                }
            }
            foreach ($library in ($libraries | Select-Object -Unique)) {
                $candidate = Join-Path $library 'steamapps/common/Chained Beasts'
                if (Test-Path -LiteralPath (Join-Path $candidate 'ChainedBeasts_Data/resources.assets')) { $candidates += $candidate }
            }
        }
        if ($candidates.Count -ne 1) { throw 'Specify -GameRoot with the Chained Beasts folder (Steam > Manage > Browse local files).' }
        $GameRoot = $candidates[0]
    }
    $GameRoot = [IO.Path]::GetFullPath($GameRoot).TrimEnd([char[]]@('\','/'))
    $target = Join-Path $GameRoot 'ChainedBeasts_Data/resources.assets'
    $dllPath = Join-Path $GameRoot 'GameAssembly.dll'
    $backup = Join-Path $GameRoot 'ChainedBeasts_Data/.cb-thai-en-original-26152147.bak'
    $lockPath = Join-Path $GameRoot 'ChainedBeasts_Data/.cb-thai.lock'
    foreach ($path in @($target,$backup,$lockPath,$dllPath)) { Assert-SafePath $path }
    if (!(Test-Path -LiteralPath $target -PathType Leaf)) { throw 'Game target file missing.' }
    $acf = Join-Path ([IO.Directory]::GetParent($GameRoot).Parent.FullName) 'appmanifest_3569420.acf'
    if (!(Test-Path -LiteralPath $acf -PathType Leaf)) { throw 'Steam build manifest missing.' }
    $buildMatch = [regex]::Match([IO.File]::ReadAllText($acf), '"buildid"\s+"(\d+)"')
    if (!$buildMatch.Success -or $buildMatch.Groups[1].Value -ne $manifest.buildid) { throw 'Unsupported Steam build.' }
    Assert-GameStopped
    if ($manifest.test_only -and ((Test-Path -LiteralPath (Join-Path $GameRoot 'ChainedBeasts.exe')) -or
        ![IO.File]::Exists((Join-Path $GameRoot '.cb-synthetic-fixture')) -or
        [IO.File]::ReadAllText((Join-Path $GameRoot '.cb-synthetic-fixture')) -cne 'cb-replace-en-synthetic-v1')) { throw 'Synthetic fixture root required without game executable.' }
    $dllGuard = [IO.File]::Open($dllPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    Assert-File $dllPath $manifest.original_dll
    $targetSha = Get-Sha $target
    if ($targetSha -eq $member.original.sha256) { $state = 'original' }
    elseif ($targetSha -eq $member.output.sha256) { $state = 'patched' }
    else { throw 'Foreign or corrupt game target. Restore the supported original through Steam first.' }
    $backupExists = Test-Path -LiteralPath $backup
    if ($backupExists) { Assert-Original $backup }
    if ($Action -eq 'Status') { Write-Output "State=$state; backup=$backupExists; build=$($manifest.buildid)"; exit 0 }
    $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    if ((Get-Sha $target) -cne $targetSha) { throw 'Target changed before operation lock.' }
    if ($state -ne 'original' -and !$backupExists) {
        if (!$OriginalBackup) { throw 'Patched state requires a verified original backup (-OriginalBackup).' }
        Assert-SafePath $OriginalBackup
        Assert-Original $OriginalBackup
    }
    if ($Action -eq 'Uninstall' -and $state -eq 'original') { Write-Output 'Already original.'; exit 0 }
    if (!$backupExists) {
        $backupSource = if ($state -eq 'original') { $target } else { $OriginalBackup }
        $backupStage = $backup + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        [IO.File]::Copy($backupSource, $backupStage, $false)
        Assert-Original $backupStage
        [IO.File]::Move($backupStage, $backup)
        $backupStage = $null
    }
    if ($Action -eq 'Install' -and $state -eq 'patched') { Write-Output 'Already installed.'; exit 0 }
    $stage = $target + '.cb-thai-' + [guid]::NewGuid().ToString('N') + '.tmp'
    if ($Action -eq 'Install') {
        Expand-Delta $backup $stage
        $expected = $member.output.sha256
    } else {
        [IO.File]::Copy($backup, $stage, $false)
        $expected = $member.original.sha256
    }
    if ((Get-Sha $stage) -ne $expected) { throw 'Reconstructed output SHA-256 mismatch.' }
    Assert-GameStopped
    if ((Get-Sha $target) -ne $targetSha) { throw 'Target changed during operation.' }
    Assert-Original $backup
    Assert-File $dllPath $manifest.original_dll
    [IO.File]::Replace($stage, $target, [NullString]::Value)
    $stage = $null
    if ((Get-Sha $target) -ne $expected) { throw 'Installed file SHA-256 mismatch.' }
    Write-Output "$Action complete. SHA256=$expected"
} catch {
    Write-Error -ErrorAction Continue $_
    exit 1
} finally {
    foreach ($temporary in @($stage,$backupStage)) {
        if ($temporary -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
    if ($lock) { $lock.Dispose() }
    if ($dllGuard) { $dllGuard.Dispose() }
}
