[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ImageSetManifestPath,
    [string]$DockerContext = "desktop-linux",
    [switch]$KeepOnFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
Import-Module (Join-Path $repoRoot "scripts\windows-ops\Rakazo.Operations.psm1") -Force
. (Join-Path $repoRoot "scripts\windows-personal\RakazoPersonal.Common.ps1")

$manifest = Get-Content -Raw -LiteralPath (Resolve-Path $ImageSetManifestPath) | ConvertFrom-Json
$app = @($manifest.images | Where-Object reference -like "rakazo-personal/app:*")
$computer = @($manifest.images | Where-Object reference -like "rakazo-personal/computer:*")
if ($app.Count -ne 1 -or $computer.Count -ne 1) { throw "Integration test requires one personal app and computer image." }
$suffix = [Guid]::NewGuid().ToString("N").Substring(0, 10)
$project = "rakazo-personal-recovery-test-$suffix"
if ($project -notmatch '^rakazo-personal-recovery-test-[0-9a-f]{10}$') { throw "Unsafe integration project." }
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) $project
$recovery = Join-Path $tempRoot "recovery"
$composeFile = Join-Path $tempRoot "docker-compose.images.yml"
$envFile = Join-Path $tempRoot ".env"
$webPort = Get-RakazoAvailableTcpPort
$apiPort = Get-RakazoAvailableTcpPort
$pre5200 = (Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:5200/" -TimeoutSec 5).StatusCode
$pre5300 = (Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:5300/" -TimeoutSec 5).StatusCode
New-Item -ItemType Directory -Path $tempRoot, $recovery | Out-Null
Copy-Item (Join-Path $repoRoot "infra\compose\docker-compose.images.yml") $composeFile

$values = [ordered]@{
    POSTGRES_USER = "rakazo"; POSTGRES_PASSWORD = New-RakazoHexSecret 16; POSTGRES_DB = "rakazo"
    BETTER_AUTH_SECRET = New-RakazoHexSecret 32; ENCRYPTION_KEY = New-RakazoHexSecret 32; SCREEN_PROXY_SECRET = New-RakazoHexSecret 32; SANDBOX_SUPERVISOR_TOKEN = New-RakazoHexSecret 32
    BETTER_AUTH_URL = "http://127.0.0.1:$webPort"; WEB_ORIGIN = "http://127.0.0.1:$webPort"; API_URL = "http://127.0.0.1:$webPort"; RAKAZO_HOST = "localhost"
    RAKAZO_WEB_PORT = [string]$webPort; RAKAZO_API_PORT = [string]$apiPort; SIGNUPS_ENABLED = "false"; SANDBOX_PROVIDER = "docker"
    RAKAZO_IMAGE = "rakazo-personal/app"; RAKAZO_IMAGE_TAG = ([string]$app[0].reference).Substring("rakazo-personal/app:".Length)
    RAKAZO_COMPUTER_IMAGE = "rakazo-personal/computer"; RAKAZO_COMPUTER_IMAGE_TAG = ([string]$computer[0].reference).Substring("rakazo-personal/computer:".Length)
}
Write-RakazoEnvFile -Values $values -Path $envFile
$composeArgs = @("compose", "-p", $project, "--env-file", $envFile, "-f", $composeFile)
$appDataVolume = "${project}_appdata"
$passed = $false

try {
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("up", "-d")) -Quiet | Out-Null
    if (-not (Wait-RakazoHttp -Uri "http://127.0.0.1:$apiPort/health" -TimeoutSeconds 180)) { throw "Fixture API did not become healthy." }
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("exec", "-T", "postgres", "psql", "-U", "rakazo", "-d", "rakazo", "-v", "ON_ERROR_STOP=1", "-c", "CREATE TABLE recovery_fixture(value text NOT NULL); INSERT INTO recovery_fixture VALUES ('original');")) -Quiet | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @("run", "--rm", "--mount", "source=$appDataVolume,target=/data", "busybox:1", "sh", "-c", "printf original >/data/recovery-marker.txt") -Quiet | Out-Null

    Invoke-RakazoNativeToFile -FilePath "docker" -ArgumentList (@("--context", $DockerContext) + $composeArgs + @("exec", "-T", "postgres", "pg_dump", "-U", "rakazo", "-d", "rakazo", "--format=custom", "--no-owner", "--no-privileges")) -OutputPath (Join-Path $recovery "rakazo.pgdump")
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @("run", "--rm", "--mount", "source=$appDataVolume,target=/data,readonly", "--mount", "type=bind,source=$recovery,target=/backup", "busybox:1", "tar", "-czf", "/backup/rakazo-appdata.tar.gz", "-C", "/data", ".") -Quiet | Out-Null
    Write-RakazoChecksums -Directory $recovery -RelativePaths @("rakazo.pgdump", "rakazo-appdata.tar.gz")
    [void](Test-RakazoChecksums -Directory $recovery)

    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("exec", "-T", "postgres", "psql", "-U", "rakazo", "-d", "rakazo", "-c", "DROP TABLE recovery_fixture;")) -Quiet | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @("run", "--rm", "--mount", "source=$appDataVolume,target=/data", "busybox:1", "sh", "-c", "printf changed >/data/recovery-marker.txt") -Quiet | Out-Null

    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("down", "--volumes", "--remove-orphans")) -Quiet | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("run", "--rm", "data-init")) -Quiet | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @("run", "--rm", "--mount", "source=$appDataVolume,target=/data", "--mount", "type=bind,source=$recovery,target=/backup,readonly", "busybox:1", "sh", "-c", "tar -xzf /backup/rakazo-appdata.tar.gz -C /data && chown -R 1000:1000 /data") -Quiet | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("up", "-d", "postgres")) -Quiet | Out-Null
    Start-Sleep -Seconds 4
    $postgresId = Get-RakazoDockerOutput -DockerContext $DockerContext -Arguments ($composeArgs + @("ps", "-q", "postgres"))
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments @("cp", (Join-Path $recovery "rakazo.pgdump"), "${postgresId}:/tmp/recovery.pgdump") -Quiet | Out-Null
    Invoke-RakazoDocker -DockerContext $DockerContext -Arguments ($composeArgs + @("exec", "-T", "postgres", "pg_restore", "-U", "rakazo", "-d", "rakazo", "--clean", "--if-exists", "--no-owner", "--no-privileges", "/tmp/recovery.pgdump")) -Quiet | Out-Null
    $dbValue = Get-RakazoDockerOutput -DockerContext $DockerContext -Arguments ($composeArgs + @("exec", "-T", "postgres", "psql", "-U", "rakazo", "-d", "rakazo", "-Atqc", "SELECT value FROM recovery_fixture"))
    $fileValue = Get-RakazoDockerOutput -DockerContext $DockerContext -Arguments @("run", "--rm", "--mount", "source=$appDataVolume,target=/data,readonly", "busybox:1", "cat", "/data/recovery-marker.txt")
    if ($dbValue.Trim() -ne "original" -or $fileValue.Trim() -ne "original") { throw "Recovered fixture state did not match the backup." }
    $passed = $true
    Write-Host "Disposable database and appdata backup/restore integration passed."
}
finally {
    if ($passed -or -not $KeepOnFailure) {
        Invoke-RakazoNativeCommand -FilePath "docker" -ArgumentList (@("--context", $DockerContext) + $composeArgs + @("down", "--volumes", "--remove-orphans")) -Quiet -AllowFailure | Out-Null
        if (Test-Path $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
    else { Write-Warning "Integration resources retained: project $project, files $tempRoot" }
    $post5200 = (Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:5200/" -TimeoutSec 5).StatusCode
    $post5300 = (Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:5300/" -TimeoutSec 5).StatusCode
    if ($pre5200 -ne $post5200 -or $pre5300 -ne $post5300) { throw "Reference or development health changed during integration testing." }
}
