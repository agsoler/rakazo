# Rakazo personal stable on Windows

These scripts build and operate a private stable deployment from the latest pushed
`integration/rakazo-dev` commit. They target only Docker Compose project `rakazo-personal` and the
personal deployment's own volumes. The included local convention uses web port 5400 and API port
3300; those numbers are preferences, not requirements imposed by Rakazo.

## First setup

Initialization creates ignored local configuration and secrets but starts no containers:

```powershell
.\scripts\windows-personal\Test-RakazoPersonalPrerequisites.ps1
.\scripts\windows-personal\Initialize-RakazoPersonal.ps1
```

Create the first deployment and its first complete local recovery point before initializing a new
off-machine repository:

```powershell
.\scripts\windows-personal\Update-RakazoPersonal.ps1
.\scripts\windows-personal\Backup-RakazoPersonal.ps1 -SkipReplication
```

The default local recovery area is `.local/recovery/personal`. Configure an encrypted restic
repository and a separately protected password file when off-machine storage is ready. Never put
the password or a private storage path in a tracked file.

For a NAS that backs up several applications, prefer an application-owned location such as
`\\YOUR-NAS\Backups\Applications\Rakazo\personal-restic`. This scales more clearly than placing
Rakazo beneath a generic Docker folder: the repository contains Rakazo recovery material regardless
of which container runtime restores it.

Install Restic using its current official Windows instructions, then verify it is on `PATH`:

```powershell
winget install --exact --id restic.restic --scope Machine
restic version

.\scripts\windows-personal\Initialize-RakazoPersonalReplication.ps1 `
  -Repository "<absolute-private-backup-path>" `
  -GeneratePasswordFile `
  -InitializeRepository
```

The first backup precedes `-InitializeRepository` because repository initialization immediately
syncs a complete recovery point. See the
[official Restic installation guide](https://restic.readthedocs.io/en/latest/020_installation.html)
if the WinGet command changes.

Copy the generated password into a password manager or separate physical recovery record. A restic
repository cannot be recovered without it.

## Ordinary actions

```powershell
# Build the latest pushed integration commit, test it, back up current state, and deploy it.
.\scripts\windows-personal\Update-RakazoPersonal.ps1

# Always save state; save the exact runtime images only when their image-set ID is new.
.\scripts\windows-personal\Backup-RakazoPersonal.ps1

# Retry encrypted off-machine replication when the NAS is awake. Each recovery point gets its own
# snapshot identity, so a later failed sync does not erase the record of earlier successful copies.
.\scripts\windows-personal\Sync-RakazoPersonalBackups.ps1

# Inspect without exposing secrets.
.\scripts\windows-personal\Get-RakazoPersonalStatus.ps1
```

The update command also records deployment identity `rakazo-personal` in the private local `.env`.
This upgrades personal configuration created before deployment-scoped bot computers were added.
Start, Backup, and Restore refuse to proceed if that identity is missing or points at another
deployment; run Update once to repair an older personal configuration.

Bot-computer containers created by personal stable have names beginning `rakazo-personal-bot-` and
networks beginning `rakazo-personal-computer-`. Docker Desktop lists these dynamic containers beside
the Compose stack because Rakazo creates them through the Docker API rather than Compose. The prefix
and the `rakazo.deployment` label show which installation owns them and prevent a cloned database
from causing personal stable to reuse a development or release bot computer.

A one-time import restores the complete bot appdata home, including `shared/`, every `bots/<id>/`
directory, browser profiles, and other home files. It deliberately clears source container IDs,
screen URLs, running state, and control/execution leases from PostgreSQL. Those values describe live
processes rather than durable data. The first computer use in personal stable therefore creates a
new `rakazo-personal-bot-...` container and mounts the restored home instead of trying to reuse a
container owned by the source deployment.

Install optional desktop shortcuts only after reviewing their destination:

```powershell
.\scripts\windows-personal\Install-RakazoPersonalShortcuts.ps1 -ConfirmShortcutInstallation
```

Downloaded Restic snapshots are verified and imported into the same local recovery catalogue, so
they appear in the Restore shortcut without manual copying. The Restore shortcut lists valid local
recovery points, verifies the chosen point and image archive, creates a safety backup of existing
personal state, and requires the exact phrase
`RESTORE rakazo-personal`. It never targets the official reference or source-development stacks.

## What is and is not recovered

A complete recovery point links the PostgreSQL dump, bot appdata, secret-bearing `.env`, Compose
configuration, source commit, and exact app, computer, PostgreSQL, and BusyBox images. When the
optional `rakazo_bot_reader` maintenance login exists, the backup also stores its SCRAM password
hash and read-only grants in a private, checksummed recovery artifact; Restore recreates that login
after restoring the tables. GitHub alone can rebuild software; it cannot recover accounts,
conversations, bots, groups, files, logins, or secrets.

The appdata archive contains the complete Team Computer home: shared files, every bot-specific
directory, profiles, and other durable workspace content. The custom Team Computer image includes
`nano` and the PostgreSQL command-line client (`psql`), so these tools remain available when a
computer is recreated or a recovery point is restored.

Personal stable also gives its Team Computer an additional connection to only the
`rakazo-personal_data` network. This makes a restored read-only `postgres:5432` credential file
usable without exposing PostgreSQL on the Windows host or connecting the computer to another
Rakazo deployment. The supervisor refuses an extra network that does not match its deployment.
