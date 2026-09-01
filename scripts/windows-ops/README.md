# Windows operations core

`Rakazo.Operations.psm1` contains the shared safety and recovery primitives used by the personal
and release deployment scripts. It does not select a deployment implicitly: every Docker operation
must receive an explicit context, project, volume, or image reference from its adapter.

Run the deterministic offline checks with PowerShell 7:

```powershell
.\scripts\windows-ops\tests\Test-RakazoOperations.ps1
.\scripts\windows-ops\tests\Test-RakazoMigration.ps1
```

The tests use fake paths, manifests, secrets, and container-inspection objects. They do not connect
to Docker or modify a Rakazo environment.

Disposable Docker checks are separate and explicit:

- `tests/Invoke-PersonalImageSmokeTest.ps1` verifies a candidate image set in a generated project.
- `tests/Invoke-RakazoPersonalRecoveryIntegration.ps1` backs up, alters, and restores generated
database and appdata fixtures.
- `tests/Invoke-RakazoImageArchiveRoundTrip.ps1` removes only unused generated personal image tags,
  reloads them from a local archive, and verifies every recorded image ID without a registry pull.

## One-time release-to-personal migration

`..\windows-migration\Import-RakazoReleaseRecoveryPoint.ps1` handles the exceptional first import
of a verified official-release recovery point into personal stable. It is deliberately separate
from normal personal backup and restore:

1. `-Mode Rehearse` restores the selected source into a generated disposable Docker project, starts
   no worker, proves the original release image can read it, upgrades the copy to the active personal
   image, and records private evidence under the ignored personal log directory.
2. `-Mode Apply` accepts only the exact rehearsed source and target image set. It creates and verifies
   a normal personal safety backup, requires `IMPORT rakazo INTO rakazo-personal`, replaces only the
   personal volumes, and leaves the personal worker stopped pending a separate cutover decision.

The source recovery tree is opened read-only and hashed before and after each operation. Release
5200 and development 5300 are not migration targets.
