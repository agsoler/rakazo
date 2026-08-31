Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-RakazoFullPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    return [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
}

function Test-RakazoPathWithin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root,
        [switch]$AllowRoot
    )

    $candidate = (Get-RakazoFullPath $Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $boundary = (Get-RakazoFullPath $Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ($candidate.Equals($boundary, [StringComparison]::OrdinalIgnoreCase)) {
        return [bool]$AllowRoot
    }
    return $candidate.StartsWith($boundary + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-RakazoSafeChildPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$AllowedRoot,
        [string]$Description = "target"
    )

    if (-not (Test-RakazoPathWithin -Path $Path -Root $AllowedRoot)) {
        throw "The $Description must be a child of the configured root. Refusing path: $Path"
    }
}

function Resolve-RakazoContainedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseDirectory,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$AllowedRoot,
        [string]$Description = "referenced file"
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath)) {
        throw "The $Description path must be relative."
    }
    $candidate = Get-RakazoFullPath (Join-Path $BaseDirectory $RelativePath)
    Assert-RakazoSafeChildPath -Path $candidate -AllowedRoot $AllowedRoot -Description $Description
    return $candidate
}

function New-RakazoHexSecret {
    [CmdletBinding()]
    param([ValidateRange(16, 128)][int]$Bytes = 32)

    $buffer = [byte[]]::new($Bytes)
    [Security.Cryptography.RandomNumberGenerator]::Fill($buffer)
    return [Convert]::ToHexString($buffer).ToLowerInvariant()
}

function Protect-RakazoPrivatePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not $IsWindows) { return }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Private path not found: $Path"
    }
    $item = Get-Item -LiteralPath $Path
    $inheritance = if ($item.PSIsContainer) {
        [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    }
    else {
        [Security.AccessControl.InheritanceFlags]::None
    }
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRuleAll($rule)
    }
    $identities = @(
        [Security.Principal.WindowsIdentity]::GetCurrent().User,
        [Security.Principal.SecurityIdentifier]::new("S-1-5-18"),
        [Security.Principal.SecurityIdentifier]::new("S-1-5-32-544")
    )
    foreach ($identity in $identities) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $identity,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Read-RakazoEnvFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Environment file not found: $Path"
    }
    $values = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^(?<name>[A-Za-z_][A-Za-z0-9_]*)=(?<value>.*)$') {
            $values[$Matches.name] = $Matches.value
        }
    }
    return $values
}

function Write-RakazoEnvFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values,
        [Parameter(Mandatory)][string]$Path,
        [string]$Header = "Generated Rakazo deployment configuration. Contains secrets; never commit."
    )

    $parent = Split-Path -Parent (Get-RakazoFullPath $Path)
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $lines = @("# $Header", "")
    foreach ($entry in $Values.GetEnumerator()) {
        if ([string]$entry.Key -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw "Invalid environment variable name: $($entry.Key)"
        }
        $value = [string]$entry.Value
        if ($value -match "[`r`n]") {
            throw "Environment value for $($entry.Key) contains a newline."
        }
        $lines += "$($entry.Key)=$value"
    }
    $lines | Set-Content -LiteralPath $Path -Encoding utf8
}

function Write-RakazoJsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(2, 100)][int]$Depth = 20
    )

    $parent = Split-Path -Parent (Get-RakazoFullPath $Path)
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $Value | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $Path -Encoding utf8
}

function Get-RakazoStringSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    return [Convert]::ToHexString($hash).ToLowerInvariant()
}

function Get-RakazoFileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-RakazoChecksums {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string[]]$RelativePaths,
        [string]$FileName = "checksums.sha256"
    )

    $root = (Resolve-Path -LiteralPath $Directory).Path
    $lines = foreach ($relativePath in ($RelativePaths | Sort-Object -Unique)) {
        if ([IO.Path]::IsPathRooted($relativePath) -or $relativePath -match '(^|[\\/])\.\.([\\/]|$)') {
            throw "Checksum path must be a safe relative path: $relativePath"
        }
        $target = Join-Path $root $relativePath
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            throw "Checksum target not found: $target"
        }
        "$(Get-RakazoFileSha256 $target) *$($relativePath.Replace('\', '/'))"
    }
    $lines | Set-Content -LiteralPath (Join-Path $root $FileName) -Encoding ascii
}

function Test-RakazoChecksums {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [string]$FileName = "checksums.sha256"
    )

    $root = (Resolve-Path -LiteralPath $Directory).Path
    $checksumPath = Join-Path $root $FileName
    if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) {
        throw "Checksum file not found: $checksumPath"
    }
    $verified = [Collections.Generic.List[string]]::new()
    foreach ($line in Get-Content -LiteralPath $checksumPath) {
        if ($line -notmatch '^(?<hash>[0-9a-fA-F]{64}) \*(?<name>.+)$') {
            throw "Malformed checksum line in ${checksumPath}: $line"
        }
        $name = $Matches.name
        if ([IO.Path]::IsPathRooted($name) -or $name -match '(^|[\\/])\.\.([\\/]|$)') {
            throw "Unsafe checksum path: $name"
        }
        $target = Join-Path $root $name
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            throw "Checksum target not found: $name"
        }
        if ((Get-RakazoFileSha256 $target) -ne $Matches.hash.ToLowerInvariant()) {
            throw "Checksum mismatch: $name"
        }
        $verified.Add($name)
    }
    return @($verified)
}

function Assert-RakazoRequiredChecksums {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string[]]$RequiredPaths,
        [string]$FileName = "checksums.sha256"
    )

    $verified = @(Test-RakazoChecksums -Directory $Directory -FileName $FileName)
    foreach ($requiredPath in $RequiredPaths) {
        $normalized = $requiredPath.Replace('\', '/')
        if ($normalized -notin $verified) {
            throw "Required file is not covered by ${FileName}: $requiredPath"
        }
    }
    return $verified
}

function Invoke-RakazoNativeCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [switch]$Quiet,
        [switch]$AllowFailure
    )

    $rawOutput = @(& $FilePath @ArgumentList 2>&1)
    $output = @($rawOutput | ForEach-Object {
        if ($_ -is [Management.Automation.ErrorRecord]) { [string]$_.Exception.Message }
        else { [string]$_ }
    })
    $exitCode = $LASTEXITCODE
    if (-not $Quiet) {
        $output | ForEach-Object { Write-Host $_ }
    }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        $safeCommand = "$FilePath $($ArgumentList -join ' ')"
        throw "Command failed with exit code ${exitCode}: $safeCommand"
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($output)
    }
}

function Invoke-RakazoNativeToFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][string]$OutputPath
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    foreach ($argument in $ArgumentList) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw "Could not start command: $FilePath"
    }
    $target = [IO.File]::Open($OutputPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $process.StandardOutput.BaseStream.CopyTo($target)
    }
    finally {
        $target.Dispose()
    }
    $errorText = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
        throw "Command failed with exit code $($process.ExitCode): $FilePath. $errorText"
    }
}

function Get-RakazoDockerOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DockerContext,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $result = Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList (@("--context", $DockerContext) + $Arguments) -Quiet
    return ($result.Output -join [Environment]::NewLine).Trim()
}

function Invoke-RakazoDocker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DockerContext,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$Quiet
    )

    return Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList (@("--context", $DockerContext) + $Arguments) -Quiet:$Quiet
}

function Get-RakazoVolumeMountpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DockerContext,
        [Parameter(Mandatory)][string]$VolumeName
    )

    $value = Get-RakazoDockerOutput -DockerContext $DockerContext -Arguments @("volume", "inspect", "--format", "{{.Mountpoint}}", $VolumeName)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Docker volume has no mountpoint: $VolumeName"
    }
    return $value
}

function Test-RakazoBotOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Container,
        [Parameter(Mandatory)][string]$ExpectedAppDataRoot,
        [Parameter(Mandatory)][string]$ExpectedProject
    )

    $labels = $Container.Config.Labels
    if (-not $labels -or [string]$labels.'rakazo.managed' -ne "true") {
        return $false
    }
    $containerProject = [string]$labels.'com.docker.compose.project'
    if ($containerProject -and -not $containerProject.Equals($ExpectedProject, [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    $root = $ExpectedAppDataRoot.Replace('\', '/').TrimEnd('/')
    foreach ($mount in @($Container.Mounts)) {
        if ([string]$mount.Destination -ne "/home/rakazo") { continue }
        $source = ([string]$mount.Source).Replace('\', '/').TrimEnd('/')
        if ($source.StartsWith($root + "/", [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-RakazoOwnedBotContainerIds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DockerContext,
        [Parameter(Mandatory)][string]$ExpectedAppDataRoot,
        [Parameter(Mandatory)][string]$ExpectedProject,
        [switch]$RunningOnly
    )

    $psArguments = @("ps")
    if (-not $RunningOnly) { $psArguments += "-a" }
    $psArguments += @("--filter", "label=rakazo.managed=true", "--format", "{{.ID}}")
    $idText = Get-RakazoDockerOutput -DockerContext $DockerContext -Arguments $psArguments
    if ([string]::IsNullOrWhiteSpace($idText)) { return @() }
    $owned = [Collections.Generic.List[string]]::new()
    foreach ($id in ($idText -split "\r?\n" | Where-Object { $_ })) {
        $container = (Get-RakazoDockerOutput -DockerContext $DockerContext -Arguments @("inspect", $id) | ConvertFrom-Json)[0]
        if (Test-RakazoBotOwnership -Container $container -ExpectedAppDataRoot $ExpectedAppDataRoot -ExpectedProject $ExpectedProject) {
            $owned.Add($id)
        }
    }
    return @($owned)
}

function Get-RakazoImageRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DockerContext,
        [Parameter(Mandatory)][string]$Reference
    )

    $image = (Get-RakazoDockerOutput -DockerContext $DockerContext -Arguments @("image", "inspect", $Reference) | ConvertFrom-Json)[0]
    return [ordered]@{
        reference = $Reference
        id = [string]$image.Id
        repoDigests = @($image.RepoDigests | Sort-Object)
        architecture = [string]$image.Architecture
        os = [string]$image.Os
        size = [long]$image.Size
    }
}

function New-RakazoImageSetManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Images,
        [Parameter(Mandatory)][string]$SourceCommit,
        [string]$SourceBranch = ""
    )

    $identityRecords = @($Images | ForEach-Object {
        [ordered]@{
            reference = [string]$_.reference
            id = [string]$_.id
            repoDigests = @($_.repoDigests | Sort-Object)
            architecture = [string]$_.architecture
            os = [string]$_.os
        }
    } | Sort-Object { $_.reference })
    $canonical = $identityRecords | ConvertTo-Json -Depth 10 -Compress
    $setHash = Get-RakazoStringSha256 $canonical
    return [ordered]@{
        schemaVersion = 1
        kind = "rakazo-image-set"
        imageSetId = "sha256-$setHash"
        createdAt = [DateTime]::UtcNow.ToString("o")
        source = [ordered]@{ commit = $SourceCommit; branch = $SourceBranch }
        images = $identityRecords
    }
}

function Assert-RakazoImageSetManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Manifest,
        [string]$ExpectedImageSetId = ""
    )

    if ($Manifest.schemaVersion -ne 1 -or $Manifest.kind -ne "rakazo-image-set") {
        throw "Unsupported image-set manifest."
    }
    $images = @($Manifest.images)
    if ($images.Count -eq 0) { throw "Image-set manifest contains no images." }
    $references = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $records = foreach ($image in $images) {
        $reference = [string]$image.reference
        $id = [string]$image.id
        if ([string]::IsNullOrWhiteSpace($reference) -or $id -notmatch '^sha256:[0-9a-f]{64}$') {
            throw "Image-set manifest contains an invalid reference or image ID."
        }
        if (-not $references.Add($reference)) { throw "Image-set manifest contains a duplicate reference: $reference" }
        [ordered]@{
            reference = $reference
            id = $id
            repoDigests = @($image.repoDigests)
            architecture = [string]$image.architecture
            os = [string]$image.os
        }
    }
    $recomputed = New-RakazoImageSetManifest -Images @($records) -SourceCommit "verification"
    if ([string]$Manifest.imageSetId -ne [string]$recomputed.imageSetId) {
        throw "Image-set identity does not match its recorded images."
    }
    if ($ExpectedImageSetId -and [string]$Manifest.imageSetId -ne $ExpectedImageSetId) {
        throw "Image-set identity does not match the recovery point."
    }
    if ($Manifest.PSObject.Properties.Name -contains "roles") {
        foreach ($property in $Manifest.roles.PSObject.Properties) {
            if ([string]$property.Value -notin $references) {
                throw "Image-set role '$($property.Name)' references an image outside the set."
            }
        }
    }
    return $Manifest
}

function Test-RakazoImageArchiveDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$ExpectedImageSetId
    )

    $root = (Resolve-Path -LiteralPath $Directory).Path
    $required = @("image-set.json", "archive.json", "rakazo-images.tar")
    foreach ($name in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $name) -PathType Leaf)) {
            throw "Incomplete image archive. Missing: $name"
        }
    }
    [void](Assert-RakazoRequiredChecksums -Directory $root -RequiredPaths $required)
    $imageSet = Get-Content -Raw -LiteralPath (Join-Path $root "image-set.json") | ConvertFrom-Json
    [void](Assert-RakazoImageSetManifest -Manifest $imageSet -ExpectedImageSetId $ExpectedImageSetId)
    $metadata = Get-Content -Raw -LiteralPath (Join-Path $root "archive.json") | ConvertFrom-Json
    if ($metadata.schemaVersion -ne 1 -or $metadata.kind -ne "rakazo-image-archive" -or
        [string]$metadata.imageSetId -ne $ExpectedImageSetId -or [string]$metadata.file -ne "rakazo-images.tar") {
        throw "Unsupported or mismatched image archive metadata."
    }
    $archive = Resolve-RakazoContainedPath -BaseDirectory $root -RelativePath ([string]$metadata.file) -AllowedRoot $root -Description "image archive"
    if ((Get-RakazoFileSha256 $archive) -ne [string]$metadata.sha256 -or
        (Get-Item -LiteralPath $archive).Length -ne [long]$metadata.size) {
        throw "Image archive hash or size does not match its metadata."
    }
    return [pscustomobject]@{ Directory = $root; ImageSet = $imageSet; Metadata = $metadata; Archive = $archive }
}

function Import-RakazoImageSetArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DockerContext,
        [Parameter(Mandatory)]$ImageSet,
        [Parameter(Mandatory)][string]$ArchivePath
    )

    [void](Assert-RakazoImageSetManifest -Manifest $ImageSet)
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @("load", "--input", $ArchivePath) -Quiet | Out-Null
    foreach ($image in @($ImageSet.images)) {
        $actual = Get-RakazoImageRecord -DockerContext $DockerContext -Reference ([string]$image.reference)
        if ($actual.id -ne [string]$image.id) {
            throw "Loaded image does not match the image-set manifest: $($image.reference)"
        }
    }
}

function Test-RakazoVolumeOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Volume,
        [Parameter(Mandatory)][string]$ExpectedProject,
        [Parameter(Mandatory)][string]$ExpectedVolume
    )

    $labels = $Volume.Labels
    return [bool]($labels -and
        [string]$labels.'com.docker.compose.project' -eq $ExpectedProject -and
        [string]$labels.'com.docker.compose.volume' -eq $ExpectedVolume)
}

function Assert-RakazoDockerVolumeOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DockerContext,
        [Parameter(Mandatory)][string]$VolumeName,
        [Parameter(Mandatory)][string]$ExpectedProject,
        [Parameter(Mandatory)][string]$ExpectedVolume
    )

    $volume = (Get-RakazoDockerOutput -DockerContext $DockerContext -Arguments @("volume", "inspect", $VolumeName) | ConvertFrom-Json)[0]
    if (-not (Test-RakazoVolumeOwnership -Volume $volume -ExpectedProject $ExpectedProject -ExpectedVolume $ExpectedVolume)) {
        throw "Docker volume is not owned by the expected Compose project: $VolumeName"
    }
    return $volume
}

function Wait-RakazoHttp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 120,
        [ValidateRange(1, 30)][int]$IntervalSeconds = 2
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $Uri -TimeoutSec ([Math]::Min(5, $IntervalSeconds + 2))
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) { return $true }
        }
        catch {
            # The service is still starting.
        }
        Start-Sleep -Seconds $IntervalSeconds
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function New-RakazoAtomicDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name
    )

    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]+$') {
        throw "Unsafe directory name: $Name"
    }
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    $incomplete = Join-Path $Root ".$Name.incomplete"
    $final = Join-Path $Root $Name
    Assert-RakazoSafeChildPath -Path $incomplete -AllowedRoot $Root -Description "incomplete recovery point"
    Assert-RakazoSafeChildPath -Path $final -AllowedRoot $Root -Description "recovery point"
    if ((Test-Path -LiteralPath $incomplete) -or (Test-Path -LiteralPath $final)) {
        throw "Recovery-point directory already exists: $Name"
    }
    New-Item -ItemType Directory -Path $incomplete | Out-Null
    return [pscustomobject]@{ Incomplete = $incomplete; Final = $final }
}

function Complete-RakazoAtomicDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IncompletePath,
        [Parameter(Mandatory)][string]$FinalPath,
        [Parameter(Mandatory)][string]$AllowedRoot
    )

    Assert-RakazoSafeChildPath -Path $IncompletePath -AllowedRoot $AllowedRoot -Description "incomplete recovery point"
    Assert-RakazoSafeChildPath -Path $FinalPath -AllowedRoot $AllowedRoot -Description "recovery point"
    if (-not (Test-Path -LiteralPath $IncompletePath -PathType Container)) {
        throw "Incomplete directory not found: $IncompletePath"
    }
    if (Test-Path -LiteralPath $FinalPath) {
        throw "Final directory already exists: $FinalPath"
    }
    Move-Item -LiteralPath $IncompletePath -Destination $FinalPath
}

Export-ModuleMember -Function @(
    "Assert-RakazoDockerVolumeOwnership",
    "Assert-RakazoImageSetManifest",
    "Assert-RakazoRequiredChecksums",
    "Assert-RakazoSafeChildPath",
    "Complete-RakazoAtomicDirectory",
    "Get-RakazoDockerOutput",
    "Get-RakazoFileSha256",
    "Get-RakazoFullPath",
    "Get-RakazoImageRecord",
    "Get-RakazoOwnedBotContainerIds",
    "Get-RakazoStringSha256",
    "Get-RakazoVolumeMountpoint",
    "Import-RakazoImageSetArchive",
    "Invoke-RakazoDocker",
    "Invoke-RakazoNativeCommand",
    "Invoke-RakazoNativeToFile",
    "New-RakazoAtomicDirectory",
    "New-RakazoHexSecret",
    "New-RakazoImageSetManifest",
    "Protect-RakazoPrivatePath",
    "Read-RakazoEnvFile",
    "Resolve-RakazoContainedPath",
    "Test-RakazoImageArchiveDirectory",
    "Test-RakazoBotOwnership",
    "Test-RakazoChecksums",
    "Test-RakazoPathWithin",
    "Test-RakazoVolumeOwnership",
    "Wait-RakazoHttp",
    "Write-RakazoChecksums",
    "Write-RakazoEnvFile",
    "Write-RakazoJsonFile"
)
