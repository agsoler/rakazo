# Rakazo fork development handbook

This handbook explains how this fork is organised, how the isolated Windows development environment
works, and how to recover it. It is written for someone who is new to Git, Docker, and source-based
application development.

For a visual, interactive version, open
[`fork-development-guide/index.html`](./fork-development-guide/index.html) directly in a browser.

## The short version

There are two separate Rakazo installations on this computer:

| Purpose | Address | Docker project | Data | Safe use |
|---|---|---|---|---|
| Published release | `http://127.0.0.1:5200` | `rakazo` | Release volumes | Everyday use and comparison |
| Source development | `http://127.0.0.1:5300` | `rakazo-dev` | `rakazo-dev_pgdata` and `.local/data` | Building and testing this fork |

The tracked scripts in [`scripts/windows-dev`](../scripts/windows-dev) operate only on
`rakazo-dev`. They do not update, stop, delete, or share storage with the release installation.

From the repository root, normal development is:

```powershell
# Start or repair the isolated development environment.
.\scripts\windows-dev\Start-RakazoDev.ps1

# Open the source build.
Start-Process http://127.0.0.1:5300

# Stop it without deleting its data.
.\scripts\windows-dev\Stop-RakazoDev.ps1
```

> **Recovery truth:** GitHub contains the source code and Git history. It does not contain your
> users, bots, conversations, bot files, passwords, encryption keys, Docker volumes, or Ollama
> model downloads. A GitHub-only recovery produces a working but empty Rakazo.

## 1. The mental model

The development installation is a hybrid: some services run directly from source on Windows, while
stateful and isolated services run in Docker.

```text
Browser
  |
  | http://127.0.0.1:5300
  v
Web source process (Windows)
  |
  | http://127.0.0.1:3200
  v
API source process (Windows) <---- Worker source process (Windows)
  |               |                         |
  |               |                         |
  v               v                         v
PostgreSQL       Sandbox supervisor       Ollama
Docker :5433     Docker :7091              Windows :11434
  |               |
  v               v
rakazo-dev_       Bot-computer containers
pgdata            + .local/data
```

This matters because `pnpm build` does not start the site, and Docker Desktop alone does not host the
development web application. The start script coordinates both halves.

### What each component does

| Component | Job | Runs where | Persistent? |
|---|---|---|---|
| Web | The browser interface | Windows source process, port 5300 | No |
| API | Authentication and application operations | Windows source process, port 3200 | No |
| Worker | Background jobs and bot runs | Windows source process | No |
| PostgreSQL | Users, bots, groups, messages, settings | Docker, host port 5433 | Yes: Docker volume |
| Supervisor | Creates and controls bot-computer containers | Docker, port 7091 | Its files live in `.local/data` |
| Ollama | Runs or brokers the configured language models | Windows, port 11434 | Models live in Ollama's storage |

## 2. Why the fork and branches are organised this way

The repository has two remotes:

- `origin` is the writable fork, `agsoler/rakazo`.
- `upstream` is the official project, `elie222/rakazo`.

Check them with:

```powershell
git remote -v
```

The branches have separate responsibilities:

| Branch kind | Purpose | Pull-request target? |
|---|---|---|
| `main` | A clean local mirror of official `upstream/main` | No feature commits here |
| `feat/...` or `fix/...` | One reviewable contribution | Yes, individually |
| `integration/rakazo-dev` | All locally approved changes combined for everyday testing | No |

This gives us both things we want:

1. Each proposed contribution remains small enough for upstream to review.
2. Port 5300 can run the combined experience before upstream accepts every contribution.

Do not turn `main` into the combined local product. Doing so makes official updates and clean pull
requests harder. The integration branch is the correct place for the combined experience.

### Refreshing the clean `main` branch

First commit or stash your current work. Then:

```powershell
git fetch --all --prune
git switch main
git merge --ff-only upstream/main
git push origin main
```

`--ff-only` is a safety check: it refuses to manufacture a merge when local `main` has diverged.
If it refuses, stop and inspect the branch rather than forcing it.

### Starting a contribution

```powershell
git switch main
git switch -c feat/short-description
```

Commit only that feature. Push it with:

```powershell
git push -u origin feat/short-description
```

Before opening a pull request, update the feature from official Rakazo and run its tests. Rebasing
rewrites commit IDs, so ask for help the first few times rather than improvising on a branch that
other people use.

### Updating the integration branch

The integration branch combines selected feature and fix branches. Update it deliberately: merge
the refreshed `main`, then merge only branches that have passed their own review. Do not open an
upstream pull request from the integration branch because it contains several independent changes.

## 3. Dependencies

Install these before the first run:

| Dependency | Required version or setting | Why |
|---|---|---|
| Windows | A supported Windows desktop | Host environment |
| PowerShell | PowerShell 7 | Runs the helper scripts |
| Git | Current supported release | Clone, branches, updates |
| Node.js | `22.22.2+`, `24.15.0+`, or `26+` (not 23 or 25) | Runs Rakazo source |
| Corepack | Included with compatible Node installations | Selects the pinned package manager |
| pnpm | Repository pins `9.15.0` | Installs and runs the monorepo |
| Docker Desktop | Linux containers and Compose enabled | PostgreSQL and bot computers |
| Ollama | Running on `127.0.0.1:11434` | Local/model-cloud access |

Verify the command-line tools:

```powershell
pwsh --version
git --version
node --version
corepack pnpm --version
docker version
docker compose version
ollama --version
```

The repository's [`package.json`](../package.json) and `pnpm-lock.yaml` are the sources of truth for
Node and pnpm versions. The lockfile can impose a stricter minimum through a dependency; it currently
raises the Node 24 minimum to 24.15.0. The tracked start script checks that effective requirement.

The default initializer configures these Ollama models:

```text
deepseek-v4-flash:cloud
qwen3.6:27b
```

Confirm that Ollama knows them:

```powershell
ollama list
```

## 4. First setup from a fresh clone

Choose a normal source-code directory. The exact parent directory does not matter.

```powershell
git clone https://github.com/agsoler/rakazo.git Rakazo
Set-Location .\Rakazo
git remote add upstream https://github.com/elie222/rakazo.git
git fetch --all --prune
git switch integration/rakazo-dev
```

Create the local secret-bearing configuration:

```powershell
.\scripts\windows-dev\Initialize-RakazoDev.ps1
```

The initializer:

- copies safe defaults from `.env.example`;
- generates independent random secrets;
- configures web 5300, API 3200, PostgreSQL 5433, and supervisor 7091;
- configures the Ollama endpoint and the two models above;
- refuses to overwrite an existing `.env`.

`.env` is ignored by Git. Never add it to a commit, paste it into an issue, or store it unencrypted
in cloud storage.

Start the environment:

```powershell
.\scripts\windows-dev\Start-RakazoDev.ps1
```

The first run is slower because it installs packages and builds Docker images. The script performs
these steps:

1. Verifies `.env`, Docker Desktop, and Ollama.
2. Starts PostgreSQL in Compose project `rakazo-dev`.
3. Prepares `.local/data` for the sandbox containers.
4. Builds a Windows-compatible supervisor image in a temporary Git worktree.
5. Starts the supervisor.
6. Installs the exact dependencies from `pnpm-lock.yaml`.
7. Generates Prisma code and applies database migrations.
8. Builds the bot-computer image.
9. Starts the web, API, and worker from source in the background.
10. Waits until web 5300 and API 3200 answer health checks.

Open `http://127.0.0.1:5300`. The release remains at `http://127.0.0.1:5200`.

## 5. Everyday workflow

At the start of a development session:

```powershell
Set-Location <your-rakazo-checkout>
git status --short
git branch --show-current
.\scripts\windows-dev\Start-RakazoDev.ps1
```

While editing, the source processes normally reload changes automatically. Check the logs if the UI
cannot reconnect:

```powershell
Get-Content .\.local\run\source.out.log -Tail 100
Get-Content .\.local\run\source.err.log -Tail 100
```

At the end:

```powershell
.\scripts\windows-dev\Stop-RakazoDev.ps1
```

Stopping preserves PostgreSQL and bot files. Starting again resumes the same development state.

### Quick health checks

```powershell
Invoke-WebRequest http://127.0.0.1:5300 -UseBasicParsing
Invoke-RestMethod http://127.0.0.1:3200/health
Invoke-RestMethod http://127.0.0.1:11434/api/tags
docker compose -p rakazo-dev ps
```

The last command may not show the correct files if run by itself. For authoritative Compose
operations, use the tracked start/stop scripts because they always supply both Compose files and the
correct `.env`.

## 6. Build, check, test, and run are different actions

| Action | Command | Meaning |
|---|---|---|
| Install | `corepack pnpm install --frozen-lockfile` | Recreate `node_modules` exactly from the lockfile |
| Build | `corepack pnpm build` | Compile/package projects; does not host port 5300 |
| Run | `Start-RakazoDev.ps1` | Start the complete development environment |
| Lint | `corepack pnpm lint` | Check formatting and static code rules |
| Type-check | `corepack pnpm check` | Check TypeScript and package contracts |
| Unit test | `corepack pnpm test` | Run fast isolated tests |
| Integration test | `corepack pnpm test:integration` | Exercise PostgreSQL and service journeys |
| Browser test | `corepack pnpm test:e2e` | Exercise the product through Playwright |

A sensible sequence before pushing a feature is:

```powershell
corepack pnpm lint
corepack pnpm check
corepack pnpm build
corepack pnpm test
```

Run integration and end-to-end suites when the change affects persistence, jobs, API behaviour, or
the UI. The repository's [`CONTRIBUTING.md`](../CONTRIBUTING.md) remains the authority for upstream
contributions.

## 7. Where everything is stored

| Item | Location | In GitHub? | Required for full recovery? |
|---|---|---:|---:|
| Source and tracked scripts | Git repository | Yes | Yes |
| Branch and commit history | GitHub fork | Yes | Yes |
| Local secrets and URLs | `.env` | No | Yes for the same encrypted data |
| Users, bots, groups, messages, settings | Docker volume `rakazo-dev_pgdata` | No | Yes |
| Bot homes, files, revisions, artifacts | `.local/data` | No | Yes |
| Runtime logs and PID | `.local/run` | No | No |
| Installed JavaScript packages | `node_modules` | No | No; reinstall them |
| Built Docker images | Docker Desktop | No | Usually no; rebuild or pull them |
| Ollama models | Ollama's local storage | No | Usually no; download them again |

Containers and images are not the primary backup. Containers are disposable runtime processes;
images are reproducible software packages. The irreplaceable parts are the database, bot files, and
the secrets needed to decrypt stored credentials.

## 8. Backup strategy

Use the 3-2-1 rule for state you care about: keep three copies, on two types of storage, with one
copy off the computer. At minimum, copy a verified recovery set to an encrypted external drive or
encrypted remote storage.

### Published release

The published release already has its own `BACKUP-RESTORE.md`, `backup.ps1`, and `restore.ps1` in
the release installation directory. Its recovery points include:

- a PostgreSQL dump;
- application/bot data;
- `.env` and Compose configuration;
- exact Docker image manifests and saved images when required;
- checksums.

Creating that backup on the same disk is only the first step. Copy the completed recovery-point
directory off the machine. Otherwise one disk failure destroys both the installation and backup.

### Development environment

For a full development-state backup, preserve these together:

1. A PostgreSQL logical dump from project `rakazo-dev`.
2. The complete `.local/data` directory.
3. The `.env` file in encrypted storage.
4. The Git commit/branch name that produced the snapshot.

Do not commit any of them. Stop active bot work before taking a coordinated snapshot. Automated,
destructive development restore tooling is intentionally outside this documentation change; it
should be implemented and tested as a separate safety-focused change before relying on it.

Record the current code point with:

```powershell
git rev-parse HEAD
git branch --show-current
```

After copying a backup, verify that it exists on another device and that its checksum can be read.
An untested backup is only a hope.

## 9. Disaster recovery

### Scenario A: the disk fails and only the GitHub fork survives

You can recover the application software, all pushed branches, this handbook, and the start scripts.
You cannot recover old accounts, chats, bots, groups, files, secrets, or model downloads.

Recovery procedure:

1. Reinstall Windows prerequisites: Git, PowerShell 7, compatible Node, Docker Desktop, and Ollama.
2. Clone the fork and add `upstream` as shown in section 4.
3. Check out `integration/rakazo-dev`.
4. Restore or download the required Ollama models.
5. Run `Initialize-RakazoDev.ps1` to create new secrets and an empty configuration.
6. Run `Start-RakazoDev.ps1`.
7. Create a new Rakazo account and rebuild the desired bot configuration manually.

Result: a working, empty development installation.

### Scenario B: the disk fails and an off-machine state backup survives

1. Reinstall prerequisites and clone the exact Git commit recorded with the backup.
2. Keep Rakazo stopped.
3. Restore the backed-up `.env` securely.
4. Recreate the `rakazo-dev` PostgreSQL service and restore the logical database dump.
5. Restore `.local/data` to the repository root.
6. Start Rakazo and run migrations only as required by the checked-out version.
7. Verify sign-in, bots, group history, bot files, model access, and one disposable bot run.
8. Only then update to newer upstream code.

Result: the application and its saved state can be recovered.

Why restore the old code first? A backup is easiest to validate against the schema and encryption
behaviour that created it. Upgrade after proving the restored baseline.

### Scenario C: Docker images disappear from their registry

The source development images can be rebuilt from the fork. The published release backup stores the
exact image set so it can be restored even if a registry image later disappears. This is useful, but
saved images do not replace database and application-data backups.

## 10. A recovery drill worth doing

Every few months:

1. Confirm all feature and integration commits are pushed to `origin`.
2. Create a fresh recovery point for the release.
3. Copy it to encrypted off-machine storage.
4. Record checksums and the corresponding Git commit.
5. On disposable storage or another machine, clone the fork.
6. Confirm the tracked initializer and start scripts parse and begin correctly.
7. Test a state restore only in an isolated environment with different project names and ports.
8. Write down any missing step while it is fresh.

Never test a destructive restore against the only working release or its only backup.

## 11. Troubleshooting

### Port 5300 says “Cannot reach the server”

Run:

```powershell
.\scripts\windows-dev\Start-RakazoDev.ps1
Get-Content .\.local\run\source.err.log -Tail 100
```

Also verify Docker Desktop and Ollama are running. The script reports which prerequisite or health
check failed.

### A port is already in use

```powershell
Get-NetTCPConnection -State Listen |
    Where-Object LocalPort -In 5300, 3200, 5433, 7091, 11434 |
    Format-Table LocalAddress, LocalPort, OwningProcess
```

Do not “solve” this by stopping an unknown process. Identify it first. Port 5200 belongs to the
separate release and should remain untouched.

### Docker Desktop restarted

Run the start script again. It is designed to restore the isolated development services and keep
existing development data.

### The Windows supervisor patch no longer applies

Upstream changed the same supervisor code. Do not edit the patch blindly. Review the new upstream
path handling and either retire the compatibility patch or update it as a small, tested maintenance
change.

### I want to erase development data and start over

Stopping Rakazo does not erase anything. Deleting the Docker volume or `.local/data` is destructive
and cannot be inferred from “stop” or “restart.” Make a backup, resolve the exact targets, and use a
separate explicit reset procedure.

## 12. Glossary

**Clone** — a local copy of a Git repository and its history.

**Remote** — a named Git server location. `origin` is our fork; `upstream` is the official project.

**Branch** — a movable line of commits. Feature branches isolate contributions.

**Commit** — a saved, named change set in Git history.

**Pull request** — a request for one repository/branch to review and merge another branch.

**Rebase** — replaying branch commits on a newer base. Useful, but history-rewriting.

**Container** — a running isolated process created from an image. It is disposable.

**Image** — the packaged filesystem and instructions used to create containers.

**Volume** — Docker-managed persistent data that survives container replacement.

**Bind mount** — a normal host directory made visible inside a container; `.local/data` is one.

**Compose project** — a named group of containers, networks, and volumes. The project name is a
major part of the safety boundary between release and development.

**Migration** — a versioned database-schema change.

**Secret** — a value that grants access or decrypts data. Secrets belong in encrypted private
storage, not Git.

## Sources of truth

- [`package.json`](../package.json): Node, pnpm, and repository commands.
- [`.env.example`](../.env.example): supported environment settings.
- [`infra/compose/docker-compose.yml`](../infra/compose/docker-compose.yml): development services.
- [`scripts/windows-dev`](../scripts/windows-dev): canonical Windows port-5300 operation.
- [`CONTRIBUTING.md`](../CONTRIBUTING.md): upstream contribution requirements.
- [`AGENTS.md`](../AGENTS.md): repository safety and quality rules.
