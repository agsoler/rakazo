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

The initializer refuses to overwrite an existing `.env`. The start script checks Docker Desktop and
Ollama, verifies the effective Node requirement, starts the isolated PostgreSQL and supervisor
containers, installs the pinned dependencies, runs migrations, builds the bot-computer image, and
launches the web/API/worker processes in the background. It resolves Corepack beside the active Node
executable so Windows installations with more than one Node version do not silently mix toolchains.

The compatibility patch is applied only inside a temporary detached worktree used to build the
Windows supervisor image. It does not alter the checked-out feature code.
