# Rakazo personal stable on Windows

These scripts build and operate a private stable deployment from the latest pushed
`integration/rakazo-dev` commit. They target only Docker Compose project `rakazo-personal`, web port
5400, API port 3300, and the personal deployment's own volumes.

## First setup

Initialization creates ignored local configuration and secrets but starts no containers:

```powershell
.\scripts\windows-personal\Test-RakazoPersonalPrerequisites.ps1
.\scripts\windows-personal\Initialize-RakazoPersonal.ps1
```

The default local recovery area is `.local/recovery/personal`. Configure an encrypted restic
repository and a separately protected password file when off-machine storage is ready. Never put
the password or a private storage path in a tracked file.

For a NAS that backs up several applications, prefer an application-owned location such as
`\\YOUR-NAS\Backups\Applications\Rakazo\personal-restic`. This scales more clearly than placing
Rakazo beneath a generic Docker folder: the repository contains Rakazo recovery material regardless
of which container runtime restores it.

```powershell
.\scripts\windows-personal\Initialize-RakazoPersonalReplication.ps1 `
  -Repository "<absolute-private-backup-path>" `
  -GeneratePasswordFile `
  -InitializeRepository
```

Copy the generated password into a password manager or separate physical recovery record. A restic
repository cannot be recovered without it.

## Ordinary actions

```powershell
# Build the latest pushed integration commit, test it, back up current state, and deploy it.
.\scripts\windows-personal\Update-RakazoPersonal.ps1

# Always save state; save the exact runtime images only when their image-set ID is new.
.\scripts\windows-personal\Backup-RakazoPersonal.ps1

# Retry encrypted off-machine replication when the NAS is awake.
.\scripts\windows-personal\Sync-RakazoPersonalBackups.ps1

# Inspect without exposing secrets.
.\scripts\windows-personal\Get-RakazoPersonalStatus.ps1
```

Install optional desktop shortcuts only after reviewing their destination:

```powershell
.\scripts\windows-personal\Install-RakazoPersonalShortcuts.ps1 -ConfirmShortcutInstallation
```

The Restore shortcut lists valid local recovery points, verifies the chosen point and image
archive, creates a safety backup of existing personal state, and requires the exact phrase
`RESTORE rakazo-personal`. It never targets the official reference or source-development stacks.

## What is and is not recovered

A complete recovery point links the PostgreSQL dump, bot appdata, secret-bearing `.env`, Compose
configuration, source commit, and exact app, computer, PostgreSQL, and BusyBox images. GitHub alone
can rebuild software; it cannot recover accounts, conversations, bots, groups, files, or secrets.
