[CmdletBinding()]
param(
    [ValidateSet('Install','Uninstall','Status')][string]$Action = 'Install',
    [string]$GameRoot,
    [string]$OriginalBackup,
    [switch]$AllowTestPackage
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$maximumAssetBytes = 160 * 1024 * 1024
$Game = @{Title='Chained Beasts'; Process='ChainedBeasts'; AppId='3569420'; Build='26152147'; AnyLocation=$false}
# Shared installer steps. The game part sets $Game (Title, Process, AppId, Build, AnyLocation), $GameRoot and $maximumAssetBytes.
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
    # ConvertFrom-Json silently keeps the last of duplicate property names, so they are refused first.
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
function Assert-Previous($Previous, [string]$PinnedJson) {
    # Assign before @(): PowerShell 5.1 emits a parsed JSON array as one object, so @(ConvertFrom-Json '[]') has one element.
    $pinned = ConvertFrom-Json $PinnedJson
    $pinned = @($pinned)
    $Previous = @($Previous)
    if ($Previous.Count -ne $pinned.Count) { throw 'Unsupported previous output identity.' }
    for ($i = 0; $i -lt $pinned.Count; $i++) {
        if ($Previous[$i].sha256 -cne $pinned[$i].sha256 -or $Previous[$i].size -ne $pinned[$i].size) { throw 'Unsupported previous output identity.' }
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
function Assert-Contained([string]$Root, [string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (!$full.StartsWith($Root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Path escape refused.' }
    Assert-SafePath $full
    return $full
}
function Get-Sha([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-','').ToLowerInvariant() }
    finally { $hasher.Dispose(); $stream.Dispose() }
}
function Get-BytesSha([byte[]]$Bytes) {
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hasher.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant() }
    finally { $hasher.Dispose() }
}
function Assert-File([string]$Path, $Identity) {
    Assert-SafePath $Path
    if (!(Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-Item -LiteralPath $Path).Length -ne $Identity.size -or (Get-Sha $Path) -cne $Identity.sha256) {
        throw "File missing or corrupt: $Path"
    }
}
function Assert-GameStopped {
    foreach ($gameProcess in @(Get-Process -Name $Game.Process -ErrorAction SilentlyContinue)) {
        # Elevated processes hide their path, so an unknown path counts as this game.
        if ($Game.AnyLocation -or !$gameProcess.Path -or [IO.Path]::GetDirectoryName($gameProcess.Path) -eq $GameRoot) {
            throw "Close $($Game.Title) before changing files."
        }
    }
}
function Find-SteamGame {
    $roots = @()
    foreach ($key in @('HKCU:\Software\Valve\Steam','HKLM:\SOFTWARE\WOW6432Node\Valve\Steam')) {
        $entry = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($entry) { foreach ($property in @('SteamPath','InstallPath')) { if ($entry.PSObject.Properties.Name -contains $property) { $roots += $entry.$property } } }
    }
    $libraries = @($roots)
    foreach ($root in $roots) {
        $file = Join-Path $root 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $file) { foreach ($match in [regex]::Matches([IO.File]::ReadAllText($file), '"path"\s+"([^"]+)"')) { $libraries += $match.Groups[1].Value.Replace('\\','\') } }
    }
    $games = @()
    foreach ($library in @($libraries | Select-Object -Unique)) {
        $file = Join-Path $library ('steamapps\appmanifest_' + $Game.AppId + '.acf')
        if (Test-Path -LiteralPath $file) {
            $match = [regex]::Match([IO.File]::ReadAllText($file), '"installdir"\s+"([^"]+)"')
            if ($match.Success) { $games += Join-Path (Join-Path $library 'steamapps\common') $match.Groups[1].Value }
        }
    }
    if ($games.Count -eq 1) { return $games[0] }
    # Install.cmd and Uninstall.cmd set THAI_MOD_PICK, so a player picks the folder instead of typing a PowerShell command;
    # a direct or scripted run keeps the error and never waits on a dialog.
    if ($env:THAI_MOD_PICK -eq '1') {
        $picked = Resolve-PickedPath (Select-GameFolder @(Get-GameGuesses $libraries $games))
        if ($picked) { return $picked }
    }
    throw "Cannot identify one Steam installation. Pass -GameRoot with the $($Game.Title) folder (Steam > Manage > Browse local files)."
}
function Get-GameGuesses([string[]]$Libraries, [string[]]$Found) {
    # Steam's own answers first, then any steamapps\common folder holding the game's exe (a missing or stale appmanifest).
    $guesses = @($Found)
    foreach ($library in @($Libraries)) {
        $common = Join-Path $library 'steamapps\common'
        foreach ($folder in @(Get-ChildItem -LiteralPath $common -Directory -ErrorAction SilentlyContinue)) {
            if (Test-Path -LiteralPath (Join-Path $folder.FullName ($Game.Process + '.exe'))) { $guesses += $folder.FullName }
        }
    }
    return @($guesses | Where-Object { $_ } | Select-Object -Unique)
}
function Resolve-PickedPath([string]$Text) {
    # A pasted path may carry quotes or name the exe itself.
    if (!$Text) { return $null }
    $path = $Text.Trim().Trim('"').Trim()
    if (!$path) { return $null }
    if (Test-Path -LiteralPath $path -PathType Leaf) { $path = [IO.Path]::GetDirectoryName($path) }
    if ($path.Length -gt 3) { $path = $path.TrimEnd('\') }
    return $path
}
function Select-GameFolder([string[]]$Guesses) {
    # User 2026-10-28: the folder tree alone was hard to use; a box to paste a path, prefilled with the best guess.
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "$($Game.Title) Thai mod: game folder"
    $form.ClientSize = New-Object System.Drawing.Size(600, 170)
    $form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false; $form.MinimizeBox = $false
    $form.StartPosition = 'CenterScreen'; $form.TopMost = $true
    $help = New-Object System.Windows.Forms.Label
    $help.Text = "Paste or type the $($Game.Title) folder, or click Browse.`nIn Steam: right-click the game > Manage > Browse local files, then copy the address bar."
    $help.SetBounds(12, 10, 576, 36)
    $box = New-Object System.Windows.Forms.ComboBox
    $box.DropDownStyle = 'DropDown'; $box.SetBounds(12, 52, 480, 24)
    foreach ($guess in @($Guesses)) { [void]$box.Items.Add($guess) }
    if (@($Guesses).Count -gt 0) { $box.Text = @($Guesses)[0] }
    $browse = New-Object System.Windows.Forms.Button
    $browse.Text = 'Browse...'; $browse.SetBounds(500, 51, 88, 26)
    $status = New-Object System.Windows.Forms.Label
    $status.SetBounds(12, 84, 576, 20)
    $update = {
        $path = Resolve-PickedPath $box.Text
        if ($path -and (Test-Path -LiteralPath (Join-Path $path ($Game.Process + '.exe')))) { $status.ForeColor = 'DarkGreen'; $status.Text = "Found $($Game.Process).exe in this folder." }
        else { $status.ForeColor = 'DarkRed'; $status.Text = "$($Game.Process).exe is not in this folder." }
    }
    $box.add_TextChanged($update); $box.add_SelectedIndexChanged($update)
    $browse.add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = "Select the $($Game.Title) game folder."
        $dialog.ShowNewFolderButton = $false
        $start = Resolve-PickedPath $box.Text
        if ($start -and (Test-Path -LiteralPath $start -PathType Container)) { $dialog.SelectedPath = $start }
        try { if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { $box.Text = $dialog.SelectedPath } } finally { $dialog.Dispose() }
    })
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'; $ok.SetBounds(412, 128, 84, 28); $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'; $cancel.SetBounds(504, 128, 84, 28); $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.AcceptButton = $ok; $form.CancelButton = $cancel
    $form.Controls.AddRange(@($help, $box, $browse, $status, $ok, $cancel))
    & $update
    try { if ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $box.Text } } finally { $form.Dispose() }
    return $null
}
function Read-SteamBuild {
    # User decision 2026-10-26: the Steam build label only warns. File hashes decide what may be patched.
    $library = [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($GameRoot))
    $label = $null
    if ($library) {
        $acf = Join-Path $library ('appmanifest_' + $Game.AppId + '.acf')
        Assert-SafePath $acf
        if (Test-Path -LiteralPath $acf -PathType Leaf) {
            if ((Get-Item -LiteralPath $acf).Length -gt 1048576) { throw 'Steam app manifest bound exceeded.' }
            $text = [IO.File]::ReadAllText($acf)
            $apps = [regex]::Matches($text, '"appid"\s+"([^"\r\n]+)"')
            if ($apps.Count -ne 1 -or $apps[0].Groups[1].Value -cne $Game.AppId) { throw 'Steam app mismatch.' }
            $builds = [regex]::Matches($text, '"buildid"\s+"([^"\r\n]+)"')
            if ($builds.Count -eq 1) { $label = $builds[0].Groups[1].Value }
        }
    }
    if ($label -cne $Game.Build) {
        $seen = if ($label) { "Steam reports build $label" } else { 'Steam build is unknown' }
        Write-Warning "$seen, not the tested build $($Game.Build). Continuing with file hash checks."
    }
    return [pscustomobject]@{Label = $label; Changed = ($null -ne $label -and $label -cne $Game.Build)}
}
# One Unity data file patched by a CBDLT001 delta from its verified original backup. Needs installer_core.ps1 and $Action.
$copyBuffer = New-Object byte[] 1048576
function Copy-Count($Source, $Destination, [long]$Count) {
    while ($Count -gt 0) {
        $take = [int][Math]::Min($copyBuffer.Length, $Count)
        $got = $Source.Read($copyBuffer, 0, $take)
        if ($got -eq 0) { throw 'Truncated delta/source.' }
        $Destination.Write($copyBuffer, 0, $got)
        $Count -= $got
    }
}
function Expand-Delta([string]$SourcePath, [string]$StagePath, $member, [string]$patchPath) {
    $sourceStream = $null; $patchStream = $null; $writer = $null; $reader = $null
    try {
        $sourceStream = [IO.File]::Open($SourcePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $patchStream = [IO.File]::Open($patchPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
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
function Open-Shared([string]$Path) {
    return [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
}
# $Plan: Target, Backup, Stage, BackupStage, Lock (full paths), Member (original/output/patch), Previous (earlier own outputs),
# PatchPath, Support (@{path; identity} the mod reads but never writes), OriginalBackup (optional), Suffix (Status/result tag).
function Invoke-DeltaInstall($Plan) {
    $target = $Plan.Target; $backup = $Plan.Backup; $stage = $Plan.Stage; $backupStage = $Plan.BackupStage; $member = $Plan.Member
    foreach ($path in @($target,$backup,$stage,$backupStage,$Plan.Lock)) { Assert-SafePath $path }
    if (!(Test-Path -LiteralPath $target -PathType Leaf)) { throw 'Game target file missing.' }
    $name = [IO.Path]::GetFileName($target)
    $lock = $null; $held = @(); $ownStage = $false; $ownBackupStage = $false
    try {
        $held += Open-Shared $Plan.PatchPath
        $steam = Read-SteamBuild
        Assert-GameStopped
        $support = @()
        foreach ($file in @($Plan.Support)) {
            $path = Assert-Contained $GameRoot (Join-Path $GameRoot $file.path)
            $seen = $null
            if (Test-Path -LiteralPath $path -PathType Leaf) { $held += Open-Shared $path; $seen = Get-Sha $path }
            $support += [pscustomobject]@{path=$file.path; full=$path; seen=$seen; tested=($seen -ceq $file.identity.sha256 -and (Get-Item -LiteralPath $path).Length -eq $file.identity.size)}
        }
        $changed = @($support | Where-Object { !$_.tested } | ForEach-Object { $_.path })
        if ($changed.Count -and $Action -eq 'Install') { Write-Warning (($changed -join ', ') + ' differs from the tested build. Thai text may misbehave; run Uninstall if it does.') }
        $targetSha = Get-Sha $target
        if ($targetSha -ceq $member.original.sha256) { Assert-File $target $member.original; $state = 'original' }
        elseif ($targetSha -ceq $member.output.sha256) { Assert-File $target $member.output; $state = 'patched' }
        elseif (@($Plan.Previous | Where-Object { $_.sha256 -ceq $targetSha }).Count) {
            # An earlier output of this program is replaced only from the verified original backup.
            Assert-File $target @($Plan.Previous | Where-Object { $_.sha256 -ceq $targetSha })[0]; $state = 'previous'
        }
        else { $state = 'updated' }
        $backupExists = Test-Path -LiteralPath $backup
        if ($backupExists) { Assert-File $backup $member.original }
        if ($Action -eq 'Status') { return "State=$state; backup=$backupExists; tested_support=$($changed.Count -eq 0); build=$($Game.Build)$($Plan.Suffix)" }
        if ($state -eq 'updated' -and !$steam.Changed) { throw "$name is unknown or modified, and Steam does not report a newer build. The Thai backup is kept. Run Steam > Verify integrity of game files, then try again." }
        if ($state -eq 'updated' -and $Action -eq 'Install') { throw "$name changed in a Steam update; this release cannot patch it. Wait for an updated Thai release." }
        $lock = [IO.File]::Open($Plan.Lock, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        if ($lock.Length -ne 0) { throw 'Unknown lock content; refusing ownership.' }
        if ((Get-Sha $target) -cne $targetSha) { throw 'Target changed before operation lock.' }
        if ($state -eq 'updated') {
            # Steam replaced the patched file in a new build; only the verified backup is ours to remove.
            if (!$backupExists) { return 'Steam already replaced the patched file. Nothing to remove.' }
            Assert-File $backup $member.original; [IO.File]::Delete($backup)
            return 'Steam already replaced the patched file. Removed the Thai backup; game files are untouched.'
        }
        # An interrupted stage is ours only when its complete bytes match a pinned identity.
        foreach ($temporary in @($stage,$backupStage)) {
            if (Test-Path -LiteralPath $temporary) {
                $temporarySha = Get-Sha $temporary
                if ($temporarySha -cne $member.original.sha256 -and ($temporary -cne $stage -or $temporarySha -cne $member.output.sha256)) { throw 'Unknown/partial recovery stage; preserve for manual inspection.' }
                [IO.File]::Delete($temporary)
            }
        }
        if ($state -ne 'original' -and !$backupExists) {
            # User 2026-10-28 met this after a test install made outside the installer; say how to recover.
            if (!$Plan.OriginalBackup) { throw 'The game file is already modified and this mod has no backup of the original. In Steam: right-click the game > Properties > Installed Files > Verify integrity of game files, then run Install.cmd again.' }
            Assert-File $Plan.OriginalBackup $member.original
        }
        if ($Action -eq 'Uninstall' -and $state -eq 'original') { return 'Already original.' }
        if (!$backupExists) {
            $source = if ($state -eq 'original') { $target } else { $Plan.OriginalBackup }
            $ownBackupStage = $true
            [IO.File]::Copy($source, $backupStage, $false)
            Assert-File $backupStage $member.original
            [IO.File]::Move($backupStage, $backup)
            $ownBackupStage = $false
        }
        $held += Open-Shared $backup
        Assert-File $backup $member.original
        if ($Action -eq 'Install' -and $state -eq 'patched') { return 'Already installed.' }
        $ownStage = $true
        if ($Action -eq 'Install') { Expand-Delta $backup $stage $member $Plan.PatchPath; $expected = $member.output }
        else { [IO.File]::Copy($backup, $stage, $false); $expected = $member.original }
        Assert-File $stage $expected
        Assert-GameStopped
        if ((Get-Sha $target) -cne $targetSha) { throw 'Target changed during operation.' }
        foreach ($file in $support) {
            if ($file.seen -and (Get-Sha $file.full) -cne $file.seen) { throw "Game file changed during operation: $($file.path)" }
        }
        Assert-File $backup $member.original
        [IO.File]::Replace($stage, $target, [NullString]::Value)
        $ownStage = $false
        Assert-File $target $expected
        return "$Action complete. SHA256=$($expected.sha256)$($Plan.Suffix)"
    } finally {
        if ($ownStage -and [IO.File]::Exists($stage)) { [IO.File]::Delete($stage) }
        if ($ownBackupStage -and [IO.File]::Exists($backupStage)) { [IO.File]::Delete($backupStage) }
        foreach ($handle in $held) { $handle.Dispose() }
        if ($lock) { $lock.Dispose() }
    }
}

try {
    $manifestPath = Join-Path $PSScriptRoot 'manifest.json'
    # Every identity the package may claim is pinned below; the manifest hash binds the rest, so a package cannot widen them.
    if (!(Test-Path -LiteralPath $manifestPath -PathType Leaf) -or (Get-Sha $manifestPath) -cne '361e1b5cbc2d42dd3b11702a8cb58909c7b9e00fcdf6161b605c795720e20de4') { throw 'Package manifest differs from the installer pin.' }
    $manifest = Read-Json $manifestPath
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
    if ($member.output.sha256 -cne 'c882bc713fa5376abd2a3587f7bab07807996f2a3079b7ab205544962872846c' -or $member.output.size -ne 121035252 -or
        $member.patch.sha256 -cne '6c140d83c20e174ebd4455b7a64b6ac1ce7a7bcd97685709e59c72f033031367' -or $member.patch.size -ne 3229071 -or
        $member.patch.operations -ne 11) { throw 'Package output or patch identity differs from the installer pins.' }
    if ($member.patch.size -lt 29 -or $member.patch.operations -gt [Math]::Floor(($member.patch.size - 12) / 17)) {
        throw 'Invalid operation count/patch size.'
    }
    if ($manifest.test_only) {
        if (!$AllowTestPackage -or $manifest.profile -cne 'synthetic-fixture' -or
            $member.original.sha256 -cne '2e2489566f66ca46e96548a3f159d9752ebb31a8cfa613b9753894fd7da560e5' -or $member.original.size -ne 528 -or
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
    if (!$GameRoot) { $GameRoot = Find-SteamGame }
    $GameRoot = [IO.Path]::GetFullPath($GameRoot).TrimEnd([char[]]@('\','/'))
    Assert-SafePath $GameRoot
    Assert-GameStopped
    if ($manifest.test_only -and ((Test-Path -LiteralPath (Join-Path $GameRoot 'ChainedBeasts.exe')) -or
        ![IO.File]::Exists((Join-Path $GameRoot '.cb-synthetic-fixture')) -or
        [IO.File]::ReadAllText((Join-Path $GameRoot '.cb-synthetic-fixture')) -cne 'cb-replace-en-synthetic-v1')) { throw 'Synthetic fixture root required without game executable.' }
    $data = Join-Path $GameRoot 'ChainedBeasts_Data'
    Write-Output (Invoke-DeltaInstall @{
        Target = Join-Path $data 'resources.assets'; Backup = Join-Path $data '.cb-thai-en-original-26152147.bak'
        Stage = Join-Path $data '.cb-thai-en-stage.tmp'; BackupStage = Join-Path $data '.cb-thai-en-backup.tmp'; Lock = Join-Path $data '.cb-thai.lock'
        Member = $member; Previous = @(); PatchPath = $patchPath; OriginalBackup = $OriginalBackup; Suffix = ''
        Support = @(@{path = 'GameAssembly.dll'; identity = $manifest.original_dll})
    })
} catch {
    Write-Error -ErrorAction Continue $_
    exit 1
}
