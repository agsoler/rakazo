# Windows development helpers

These tracked helpers reconstruct and run the isolated source-development environment described in
[`docs/fork-development-handbook.md`](../../docs/fork-development-handbook.md).

They operate only on Docker Compose project `rakazo-dev`. Mutable data, logs, generated secrets, and
process IDs remain under ignored `.local/` and `.env` paths.

On a fresh clone:

```powershell
.\scripts\windows-dev\Initialize-RakazoDev.ps1
.\scripts\windows-dev\Start-RakazoDev.ps1
```

For normal use:

```powershell
.\scripts\windows-dev\Start-RakazoDev.ps1
.\scripts\windows-dev\Stop-RakazoDev.ps1
```

Audit a fresh or rebuilt machine before initialization:

```powershell
.\scripts\windows-dev\Test-RakazoDevPrerequisites.ps1
```

Create a complete development-state recovery point on an encrypted external or remote drive:

```powershell
.\scripts\windows-dev\Backup-RakazoDevState.ps1 -DestinationDirectory "E:\Rakazo-Backups"
```

`E:\Rakazo-Backups` is an example. Create the destination first and substitute the real off-machine
location. Use `-ValidateOnly` to check the source and destination without stopping anything or
writing a backup.

Verify a recovery point before depending on or restoring it:

```powershell
.\scripts\windows-dev\Test-RakazoDevRecoveryPoint.ps1 -RecoveryPointDirectory "E:\Rakazo-Backups\rakazo-dev-state-..."
```

The initializer refuses to overwrite an existing `.env`. The start script checks Docker Desktop and
Ollama, verifies the effective Node requirement, starts the isolated PostgreSQL and supervisor
containers, installs the pinned dependencies, runs migrations, builds the bot-computer image, and
launches the web/API/worker processes in the background. It resolves Corepack beside the active Node
executable so Windows installations with more than one Node version do not silently mix toolchains.

The development supervisor identifies itself as deployment `rakazo-dev`. Bot computers it creates
therefore have names beginning `rakazo-dev-bot-` and private networks beginning
`rakazo-dev-computer-`. Docker Desktop still shows these dynamic containers separately rather than
inside the Compose stack, but their names make their owner unambiguous. The deployment label also
prevents development from attaching to a personal-stable bot computer after data has been copied
between environments.

The compatibility patch is applied only inside a temporary detached worktree used to build the
Windows supervisor image. It does not alter the checked-out feature code.
