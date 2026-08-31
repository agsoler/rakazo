# Rakazo fork development handbook

This handbook explains how this fork is organised, how the isolated Windows development environment
works, and how to recover it. It is written for someone who is new to Git, Docker, and source-based
application development.

For a visual, interactive version, open
[`fork-development-guide/index.html`](./fork-development-guide/index.html) directly in a browser.

## The short version

The recommended example layout uses three separate Rakazo environments:

| Purpose | Suggested address | Docker project | Data | Safe use |
|---|---|---|---|---|
| Published release | `http://127.0.0.1:5200` | `rakazo` | Release volumes | Reference comparison |
| Source development | `http://127.0.0.1:5300` | `rakazo-dev` | `rakazo-dev_pgdata` and `.local/data` | Building and testing this fork |
| Personal stable | `http://127.0.0.1:5400` | `rakazo-personal` | Independent personal volumes | Daily use of locally approved integration builds |

These port numbers are a convenient local convention, not a Rakazo requirement. The tracked helper
scripts use them as defaults to keep the three environments apart. Another installation may use
different non-conflicting ports if its local configuration and scripts are changed consistently.
Personal stable does not exist merely because it appears in this table: initialization and the
first successful update create it.

The tracked scripts in [`scripts/windows-dev`](../scripts/windows-dev) operate only on
`rakazo-dev`. They do not update, stop, delete, or share storage with the release installation.
The scripts in [`scripts/windows-personal`](../scripts/windows-personal) likewise operate only on
`rakazo-personal`. Personal stable is built from a pushed integration commit, not from uncommitted
files in the current checkout.

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
| `ops/...` | Recovery, deployment, or maintenance work kept separate while it is reviewed | Usually no |

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

### Rebuilding a Windows machine

There are two stages. First install only PowerShell 7 and Git so you can clone the fork. Then let
the fork's prerequisite audit tell you exactly what is missing or incompatible. Do not guess from an
old copy of this guide.

If WinGet is available, open **Windows PowerShell** as your normal Windows user and run:

```powershell
winget install --id Microsoft.PowerShell -e --source winget
winget install --id Git.Git -e --source winget
```

If `winget` is not recognised, use the official installers:

- [PowerShell for Windows](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-windows)
- [Git for Windows](https://git-scm.com/install/windows)

Open a new **PowerShell 7** window after installation, clone the fork as described in section 4,
then run this read-only audit from the repository root:

```powershell
.\scripts\windows-dev\Test-RakazoDevPrerequisites.ps1
```

The audit prints `PASS`, `FAIL`, or `INFO` for every dependency. A `FAIL` includes the corrective
action. Install only the failed components, restart them if required, and rerun the audit until it
exits without a failure. The audit does not install software or modify Rakazo.

Use these official sources when a component is missing:

| Dependency | What to install | WinGet command | Official installer or instructions |
|---|---|---|---|
| PowerShell | Version 7 or newer | `winget install --id Microsoft.PowerShell -e --source winget` | [Install PowerShell on Windows](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-windows) |
| Git | Current supported Git for Windows | `winget install --id Git.Git -e --source winget` | [Git for Windows](https://git-scm.com/install/windows) |
| Node.js | Prefer current Node 24 LTS, at least 24.15.0; the accepted ranges are listed below | `winget install --id OpenJS.NodeJS.LTS -e --source winget` | [Download Node.js](https://nodejs.org/en/download) |
| Docker Desktop | Current supported release, using Linux containers and Compose v2 | `winget install --id Docker.DockerDesktop -e --source winget` | [Install Docker Desktop on Windows](https://docs.docker.com/desktop/setup/install/windows-install/) |
| Ollama | Current Windows release, running its local API | `winget install --id Ollama.Ollama -e --source winget` | [Ollama for Windows](https://docs.ollama.com/windows) |

After installing Docker Desktop, start it and confirm it is using Linux containers. After installing
Ollama, start it and confirm `http://127.0.0.1:11434/api/tags` responds. The start script manages the
repository-pinned `pnpm` version; do not install a random global pnpm to solve an audit failure.

### Version rules

The prerequisite audit applies these rules:

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
| Restic | Current supported release; optional until NAS replication is configured | Encrypted off-machine recovery |

You can also inspect the individual command-line tools manually:

```powershell
pwsh --version
git --version
node --version
corepack pnpm --version
docker version
docker compose version
ollama --version
restic version
```

The repository's [`package.json`](../package.json) and `pnpm-lock.yaml` are the sources of truth for
Node and pnpm versions. The lockfile can impose a stricter minimum through a dependency; it currently
raises the Node 24 minimum to 24.15.0. The tracked start script checks that effective requirement.
Git, Docker Desktop, Ollama, and Restic do not have a repository-pinned patch version; install their
current supported Windows releases and let the audit verify the capabilities Rakazo actually uses.
Restic is optional for local development and local backups. On Windows, its official documentation
supports WinGet or Scoop; for example:

```powershell
winget install --exact --id restic.restic --scope Machine
restic version
```

See the [official Restic installation guide](https://restic.readthedocs.io/en/latest/020_installation.html)
if the package-manager command changes. `Test-RakazoPersonalPrerequisites.ps1 -RequireRestic`
checks availability without installing anything.

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

### Optional: initialize personal stable and encrypted recovery

Personal stable is independent of development. The following sequence uses the suggested 5400/3300
ports and creates no release or development data:

```powershell
# Read-only host audit.
.\scripts\windows-personal\Test-RakazoPersonalPrerequisites.ps1

# Generate ignored local configuration and secrets. No containers start yet.
.\scripts\windows-personal\Initialize-RakazoPersonal.ps1

# Build the latest pushed integration commit, smoke-test it, and deploy personal stable.
.\scripts\windows-personal\Update-RakazoPersonal.ps1

# Create the first complete local state-and-image recovery point.
.\scripts\windows-personal\Backup-RakazoPersonal.ps1 -SkipReplication
```

Install Restic only if encrypted off-machine replication is wanted. Then configure an
application-owned repository using a generic private path:

```powershell
winget install --exact --id restic.restic --scope Machine
restic version

.\scripts\windows-personal\Initialize-RakazoPersonalReplication.ps1 `
  -Repository "\\YOUR-NAS\Backups\Applications\Rakazo\personal-restic" `
  -GeneratePasswordFile `
  -InitializeRepository
```

The first local backup deliberately comes before `-InitializeRepository`: initialization performs
the first encrypted sync, so it needs a complete recovery point to send. Replace `YOUR-NAS` with a
private value only at execution time; never commit it. Copy the generated Restic password to a
password manager or separate physical recovery record before relying on the NAS copy.

Optional readable desktop launchers can then be installed:

```powershell
.\scripts\windows-personal\Install-RakazoPersonalShortcuts.ps1 -ConfirmShortcutInstallation
```

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

### Personal stable: promote tested integration code for daily use

In the suggested layout, port 5300 is the workshop and port 5400 is personal stable. Updating
personal stable does not copy a running development container. The update command performs a
controlled promotion:

1. Fetch the pushed `origin/integration/rakazo-dev` commit.
2. Check out that exact commit in a temporary detached worktree, away from private `.local` data.
3. Build immutable app and computer images tagged with the full commit ID.
4. Record the exact PostgreSQL and BusyBox images needed by the same deployment.
5. Start a uniquely named disposable stack on temporary ports and wait for its health checks.
6. Back up current personal state if port 5400 has already been initialized.
7. Deploy the tested image set to only `rakazo-personal` and verify ports 5400 and 3300.

After the one-time initialization, normal promotion is one command:

```powershell
.\scripts\windows-personal\Update-RakazoPersonal.ps1
```

The command refuses an unpushed integration commit. This is intentional: after a disk failure the
fork must contain the source for every personal image we depended on. A failed update retains the
pre-update recovery point and does not silently reverse a database migration.

Optional Windows shortcuts provide Backup, Update, Restore, Sync, Start, Stop, and Status actions.
Restore remains guided because it replaces data: it verifies the selected recovery point, creates a
safety backup, and requires the exact phrase `RESTORE rakazo-personal`.

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
| Personal-stable database | Docker volume `rakazo-personal_pgdata` | No | Yes |
| Personal-stable bot files | Docker volume `rakazo-personal_appdata` | No | Yes |
| Personal configuration | ignored `.local/personal` | No | Yes |
| Personal recovery points | ignored local recovery root, then encrypted off-machine repository | No | Yes |

Containers and images are not the primary backup. Containers are disposable runtime processes;
images are reproducible software packages. The irreplaceable parts are the database, bot files, and
the secrets needed to decrypt stored credentials.

## 8. Backup strategy

Use the 3-2-1 rule for state you care about: keep three copies, on two types of storage, with one
copy off the computer. At minimum, copy a verified recovery set to an encrypted external drive or
encrypted remote storage.

### Personal stable

Run `Backup-RakazoPersonal.ps1` or use the Backup shortcut. Every run creates a matching database,
appdata, configuration, source-commit, and checksum snapshot. The first backup for an exact image
set also saves the app, computer, PostgreSQL, and BusyBox images. Later state backups reuse that
archive until any image identity changes.

The local recovery point completes first. If encrypted off-machine storage is configured and
available, the script then asks restic to replicate it. If that storage is asleep or disconnected,
the local backup remains valid and Sync can retry later:

```powershell
.\scripts\windows-personal\Backup-RakazoPersonal.ps1
.\scripts\windows-personal\Sync-RakazoPersonalBackups.ps1
```

Restic encryption is an additional storage layer, not the Rakazo recovery format. Each local
recovery-point directory remains self-describing and checksum-verifiable. Keep the restic password
outside the workstation as well as in its restricted local password file. Losing both the machine
and the only password makes the encrypted NAS copy unrecoverable.

Each recovery point is replicated as its own Restic snapshot, linked to its exact image-set ID.
Successful points stay recorded as successful if a later point cannot sync. Retrieval verifies the
download and imports it into the local recovery catalogue used by the Restore shortcut; no manual
file rearrangement is required.

On a NAS shared by several systems, use an application-owned path such as
`\\YOUR-NAS\Backups\Applications\Rakazo\personal-restic`. The contents are an encrypted Restic
repository, not a live Docker volume and not an ordinary folder of readable Rakazo files.

### Published release

The canonical tracked release tools live in [`scripts/windows-release`](../scripts/windows-release).
They replace machine-local copies while accepting explicit deployment and backup roots. Their
recovery points include:

- a PostgreSQL dump;
- application/bot data;
- `.env` and Compose configuration;
- exact Docker image manifests and saved images when required;
- checksums.

Creating that backup on the same disk is only the first step. Copy the completed recovery-point
directory off the machine. Otherwise one disk failure destroys both the installation and backup.

### Development environment

A **development state recovery point** is one timestamped directory containing everything
irreplaceable from one consistent moment. It contains:

1. `database.sql`: users, bots, groups, messages, settings, and other PostgreSQL records.
2. `appdata.tar.gz`: bot homes, files, revisions, and artifacts from `.local/data`.
3. `.env`: the matching secrets and configuration needed to decrypt and run that state.
4. `manifest.json`: the exact Git commit, branch, ports, and tool versions.
5. `checksums.sha256`: hashes used to detect missing or damaged files.
6. `RECOVERY.txt`: a plain-English inventory and warning.

The recovery point does not include source code, Docker images, installed packages, or Ollama model
downloads. Those are reconstructible from the recorded Git commit and official installers. The
database, bot files, and matching `.env` are not reconstructible and therefore travel together.

First validate the source and destination without stopping or writing anything:

```powershell
.\scripts\windows-dev\Backup-RakazoDevState.ps1 `
  -DestinationDirectory "E:\Rakazo-Backups" `
  -ValidateOnly
```

Then create the recovery point:

```powershell
.\scripts\windows-dev\Backup-RakazoDevState.ps1 `
  -DestinationDirectory "E:\Rakazo-Backups"
```

`E:\Rakazo-Backups` is only an example. Replace it with an existing directory on an encrypted
external drive or encrypted remote storage. A backup on another folder of the same physical disk
does not protect against that disk failing.

The backup script briefly stops only the `rakazo-dev` environment so the database and bot files
describe the same moment. It starts only the development PostgreSQL service, creates a logical dump,
archives `.local/data`, copies `.env`, records the code and tool versions, calculates checksums, and
returns port 5300 to its previous running or stopped state. It never addresses the release project.

Verify the completed recovery point immediately and again before any restore:

```powershell
.\scripts\windows-dev\Test-RakazoDevRecoveryPoint.ps1 `
  -RecoveryPointDirectory "E:\Rakazo-Backups\rakazo-dev-state-..."
```

Create a recovery point before an upstream update, database migration, or substantial experiment,
and periodically whenever the development conversations or bot files matter. Never commit a
recovery point: it contains secrets and private data.

## 9. Disaster recovery

### Scenario A: the disk fails and only the GitHub fork survives

You can recover the application software, all pushed branches, this handbook, and the start scripts.
You cannot recover old accounts, chats, bots, groups, files, secrets, or model downloads.

Recovery procedure:

1. Install PowerShell 7 and Git using the commands or official links in section 3.
2. Clone the fork, add `upstream`, and check out `integration/rakazo-dev` as shown in section 4.
3. Run `Test-RakazoDevPrerequisites.ps1`.
4. Install each failed component from its official source, start Docker Desktop and Ollama, then
   rerun the audit until it reports no failures.
5. Pull the required Ollama models or sign in for cloud models.
6. Run `Initialize-RakazoDev.ps1` to create new secrets and an empty configuration.
7. Run `Start-RakazoDev.ps1` and open port 5300.
8. Create a new Rakazo account and rebuild the desired bot configuration manually.

Result: a working, empty development installation.

### Scenario B: the disk fails and an off-machine development recovery point survives

1. Install PowerShell 7 and Git, then clone the fork so the recovery tools are available.
2. Run `Test-RakazoDevRecoveryPoint.ps1` against the surviving directory. Stop if any file or
   checksum fails.
3. Read the exact Git commit printed by the verifier and check out that commit. This recreates the
   code version that wrote the backup.
4. Run `Test-RakazoDevPrerequisites.ps1`, install every failed component, and rerun it until clean.
5. Restore or download the Ollama models named by the recovered `.env`.
6. Keep Rakazo stopped. Preserve any new local state before replacing it.
7. Restore the recovery point's `.env`, database dump, and `.local/data` into only the isolated
   `rakazo-dev` environment.
8. Start the recorded baseline and verify sign-in, bots, group history, bot files, model access, and
   one disposable bot run.
9. Only after that baseline works, return to `integration/rakazo-dev` and update deliberately.

Result: the application and its saved state can be recovered.

Why restore the old code first? A backup is easiest to validate against the schema and encryption
behaviour that created it. Upgrade after proving the restored baseline.

The backup and verification operations are automated because they do not replace current data. The
actual restore is deliberately not a one-click script: it overwrites a database, `.local/data`, and
`.env`. Use `RECOVERY.txt` to identify the recovery-point contents and recorded code revision, then
follow this sequence with the exact recovery-point path. Ask for help before performing the
destructive replacement rather than improvising against the only copy. This boundary protects the
release deployment and any newer development state.

### Scenario C: the disk fails and an encrypted personal-stable recovery repository survives

1. Install PowerShell 7 and Git, clone the fork, and check out the integration commit recorded by
   the selected recovery point.
2. Run `Test-RakazoPersonalPrerequisites.ps1 -RequireRestic`; install Docker Desktop, Ollama, and
   Restic if marked missing.
3. Restore the separately stored restic password file or supply the password through a protected
   recovery process. Do not put it in Git or command history.
4. Run `Initialize-RakazoPersonal.ps1` with the recovered off-machine repository settings. This
   creates a new empty target but does not start it.
5. Retrieve the chosen snapshot into a new, empty download directory. The command verifies and
   imports the point into the local catalogue used by Restore:

   ```powershell
   .\scripts\windows-personal\Get-RakazoPersonalRecoveryPoint.ps1 `
     -Latest `
     -DestinationDirectory "<new-empty-download-directory>"
   ```
6. Use the Restore action. It re-verifies the selected point, loads the archived images, and
   restores database/appdata/configuration
   only into `rakazo-personal`, and verifies ports 5400 and 3300.
7. Sign in and check representative bots, groups, conversations, files, configured models, and one
   disposable model interaction.

Result: source, exact runtime images, secrets, and personal state are recoverable without a Docker
registry. If only GitHub survives and no state repository survives, the result is necessarily an
empty Rakazo.

### Scenario D: Docker images disappear from their registry

The source development images can be rebuilt from the fork. Published-release and personal-stable
backups store exact image sets so they can be restored even if a registry image later disappears.
This is useful, but saved images do not replace database and application-data backups.

## 10. A recovery drill worth doing

Every few months:

1. Confirm all feature and integration commits are pushed to `origin`.
2. Create a fresh personal-stable recovery point.
3. Run Sync and verify that encrypted off-machine storage is current.
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
    Where-Object LocalPort -In 5200, 5300, 5400, 3100, 3200, 3300, 5433, 7091, 11434 |
    Format-Table LocalAddress, LocalPort, OwningProcess
```

Do not “solve” this by stopping an unknown process. Identify it first. In the suggested layout,
5200 is the separate reference release, 5300 is development, and 5400 is personal stable. If your
local choices differ, inspect their configured equivalents before stopping anything.

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
- [`scripts/windows-dev`](../scripts/windows-dev): canonical Windows source-development operation;
  the included defaults use port 5300.
- [`scripts/windows-personal`](../scripts/windows-personal): personal image, deployment, backup,
  encrypted replication, retrieval, and restore commands.
- [`scripts/windows-ops`](../scripts/windows-ops): shared safety primitives and disposable recovery
  tests.
- [`scripts/windows-release`](../scripts/windows-release): canonical published-image backup and
  restore adapters.
- [`CONTRIBUTING.md`](../CONTRIBUTING.md): upstream contribution requirements.
- [`AGENTS.md`](../AGENTS.md): repository safety and quality rules.
