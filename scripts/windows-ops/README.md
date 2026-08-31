# Windows operations core

`Rakazo.Operations.psm1` contains the shared safety and recovery primitives used by the personal
and release deployment scripts. It does not select a deployment implicitly: every Docker operation
must receive an explicit context, project, volume, or image reference from its adapter.

Run the deterministic offline checks with PowerShell 7:

```powershell
.\scripts\windows-ops\tests\Test-RakazoOperations.ps1
```

The tests use fake paths, manifests, secrets, and container-inspection objects. They do not connect
to Docker or modify a Rakazo environment.

Disposable Docker checks are separate and explicit:

- `tests/Invoke-PersonalImageSmokeTest.ps1` verifies a candidate image set in a generated project.
- `tests/Invoke-RakazoPersonalRecoveryIntegration.ps1` backs up, alters, and restores generated
  database and appdata fixtures.
- `tests/Invoke-RakazoImageArchiveRoundTrip.ps1` removes only unused generated personal image tags,
  reloads them from a local archive, and verifies every recorded image ID without a registry pull.
