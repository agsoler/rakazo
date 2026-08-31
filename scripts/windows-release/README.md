# Windows release backup and restore

These tracked scripts replace machine-local copies of the official-image backup tools. They require
explicit deployment and backup roots and default to Compose project `rakazo`. Dynamic bot
containers are selected only when `rakazo.managed=true` and their `/home/rakazo` mount is beneath
the release appdata volume; a name prefix alone is never trusted.

```powershell
.\scripts\windows-release\Backup-RakazoRelease.ps1 `
  -DeploymentRoot "X:\path\to\release" `
  -BackupRoot "X:\path\to\private-backups"
```

Restore supports both recovery points created by the tracked script and the inspected historical
image-set layout. It verifies checksums, creates a fresh safety backup when release state exists,
loads exact images, and requires the phrase `RESTORE rakazo`. Never put real paths, backups, or
secret-bearing `.env` files in Git.
