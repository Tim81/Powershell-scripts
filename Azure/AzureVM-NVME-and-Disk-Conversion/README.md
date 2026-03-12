# AzureVM-NVME-and-localdisk-Conversion

A PowerShell script to convert Azure VMs between SCSI and NVMe disk controllers, and to handle the VM recreation that Windows requires when moving between local-disk and diskless VM sizes.

> **Version:** 2.14.0 · **PowerShell:** 5.1 and 7+

---

## Table of contents

- [Why this script exists](#why-this-script-exists)
- [Two execution paths](#two-execution-paths)
- [Requirements](#requirements)
- [Parameters](#parameters)
- [OS fixes](#os-fixes)
- [TrustedLaunch VMs](#trustedlaunch-vms)
- [Managed identity and RBAC (PATH B)](#managed-identity-and-rbac-path-b)
- [Examples](#examples)
- [What to do if the script fails mid-run](#what-to-do-if-the-script-fails-mid-run)
- [Rollback](#rollback)
- [Extension reinstallation (PATH B)](#extension-reinstallation-path-b)
- [NVMe temp disk (v6/v7 d-sizes)](#nvme-temp-disk-v6v7-d-sizes)
- [Error handling and pipeline use](#error-handling-and-pipeline-use)
- [Implementation notes](#implementation-notes)
- [Known limitations](#known-limitations)
- [References](#references)

---

## Why this script exists

Azure v6/v7 VM sizes are NVMe-only. But NVMe conversion is only part of what this script solves.

Azure also blocks direct resize on **Windows** VMs when the source and target size are in different local-disk architecture categories, even when NVMe is not involved at all:

- **Local disk to diskless** (e.g. `D4ds_v5` to `D4as_v5`): Azure blocks this because the pagefile is typically on the temp disk.
- **Diskless to local disk** (e.g. `D4as_v5` to `D4ds_v5`): the reverse direction is blocked as well.
- **SCSI temp disk to NVMe temp disk** (e.g. `E8bds_v5` to `E8ads_v7`): blocked because the NVMe temp disk comes up raw and unformatted after a deallocate or host move, unlike the pre-formatted SCSI temp disk.

In all three cases, Microsoft's documented migration path is to capture the VM configuration, delete the VM shell, and recreate it from the original OS disk. Done by hand this is fiddly work, especially keeping track of NICs, tags, extensions, managed identity, availability configuration, and DeleteOptions on all resources.

This script covers these use cases:

1. **NVMe conversion to v6/v7** — moving to a generation that requires NVMe.
2. **Dropping the temp disk** — moving a Windows VM from a local-disk size to a diskless size (e.g. `D4ds_v5` to `D4as_v5`), with or without an NVMe change.
3. **Adding a temp disk** — the reverse of the above.
4. **SCSI temp disk to NVMe temp disk** — e.g. `E8bds_v5` to `E8ads_v7`, where the NVMe temp disk arrives raw and unformatted after a deallocate or host move.

On Linux, none of these resizes are blocked by Azure. Linux VMs always take PATH A (simple resize) regardless of disk architecture.

---

## Two execution paths

The script picks the right path automatically based on the source and target VM sizes.

### PATH A — Resize (`Update-AzVM`)

Used for all Linux VMs, and for Windows VMs where source and target are in the same disk architecture category.

```
OS prep (STEP 1)
  ->  Stop VM (STEP 2)
  ->  [TrustedLaunch downgrade to Standard (STEP 2a) — only with -AllowTrustedLaunchDowngrade]
  ->  Patch OS disk controller type (STEP 3A)
  ->  Resize VM (STEP 4A)
  ->  [Re-enable TrustedLaunch (STEP 4Aa) — only with -AllowTrustedLaunchDowngrade]
  ->  Start VM (STEP 5A)
```

### PATH B — Recreate (`New-AzVM`)

Used for Windows VMs where source and target are in different disk architecture categories. Azure blocks direct resize for all six cross-category combinations:

| From | To |
|---|---|
| SCSI temp disk (e.g. `E8bds_v5`) | NVMe temp disk (e.g. `E8ads_v7`) |
| NVMe temp disk (e.g. `E8ads_v7`) | SCSI temp disk (e.g. `E8bds_v5`) |
| SCSI temp disk | Diskless (e.g. `E8as_v7`) |
| Diskless | SCSI temp disk |
| NVMe temp disk | Diskless |
| Diskless | NVMe temp disk |

Linux VMs are not affected and always use PATH A.

```
OS prep (STEP 1)
  ->  Pagefile migration D:\ -> C:\ (STEP 1b) — when source has SCSI temp disk
  ->  Install NVMe temp disk startup task (STEP 1c) — when target has NVMe temp disk
  ->  Stop VM (STEP 2)
  ->  [TrustedLaunch downgrade to Standard (STEP 2a) — only with -AllowTrustedLaunchDowngrade]
  ->  Snapshot OS disk — safety backup, taken BEFORE any modification (STEP 3B)
  ->  Patch OS disk controller type (STEP 4B)
  ->  Capture full VM configuration (STEP 5B)
  ->  Set DeleteOption=Detach on all resources, then delete VM shell (STEP 6B)
  ->  Recreate VM reusing original OS disk + NICs + data disks (STEP 7B)
       TrustedLaunch is restored here via SecurityProfile when -AllowTrustedLaunchDowngrade was used
  ->  Reinstall VM extensions (STEP 8B)
  ->  Restore system-assigned managed identity RBAC assignments (STEP 9B)
       Only when -RestoreSystemAssignedRBAC is specified
  ->  Delete snapshot (STEP 10B) — unless -KeepSnapshot
```

The following VM properties are carried over to the recreated VM: NICs (including original DeleteOptions), data disks, tags, managed identity, proximity placement groups, availability sets, capacity reservations, load balancer backend pool associations, TrustedLaunch security profile, EncryptionAtHost, boot diagnostics, Marketplace plan, Spot priority/eviction policy, dedicated host or host group, VMSS Flexible membership, platform fault domain, UserData, ScheduledEventsProfile (terminate notification), VM Gallery Applications, VmSizeProperties (constrained vCPU/SMT), and ExtendedLocation (Edge Zones).

> **Automanage:** Azure Automanage enrollment is tied to the VM resource and is **lost** when the VM shell is deleted. The script detects enrollment and warns you before proceeding. After recreation, re-enroll via Azure Portal → Automanage → Enable on VM.

---

## Requirements

### Azure PowerShell modules

| Module | Minimum version | Notes |
|---|---|---|
| Az.Compute | 7.2.0 | PATH B property capture requires SDK model properties introduced across 5.7–7.x. Tested with 11.3.0+. |
| Az.Accounts | 2.13.0 | `Get-AzAccessToken`, `Invoke-AzRestMethod`, `Get-AzConfig`. Works with both string and SecureString token (< 4.0 and ≥ 4.0). |
| Az.Resources | 6.0 | `Get-AzResourceLock`, `Get-AzResource` |
| Az.Network | 5.0 | `Get-AzNetworkInterface`, `Set-AzNetworkInterface` |

Optional modules — loaded automatically if present. If absent, affected extensions fall back to a MANUAL reinstall notice in the log:

- `Az.OperationalInsights` — needed for MMA/OMS extension workspace key lookup
- `Az.SqlVirtualMachine` — needed for SqlIaasAgent extension registration

### Permissions

The permissions needed depend on which path the script takes.

**PATH A — Resize**

| Scope | Required |
|---|---|
| VM resource | `Microsoft.Compute/virtualMachines/read`, `write`, `start/action`, `deallocate/action`, `runCommand/action` |
| OS disk resource | `Microsoft.Compute/disks/read`, `write` (REST PATCH to `diskControllerTypes`) |
| Resource group | `Microsoft.Resources/locks/read` (lock check only, no write access needed) |
| Subscription | `Microsoft.Compute/skus/read`, `Microsoft.Compute/locations/usages/read` (SKU and quota checks) |

**Virtual Machine Contributor** on the VM plus a role with `disks/write` on the OS disk is enough for PATH A. Contributor at resource group level is not needed.

---

**PATH B — Recreate**

PATH B does everything PATH A does, plus it creates and deletes a snapshot, deletes the VM shell, and creates a new VM resource.

| Scope | Required |
|---|---|
| VM resource | Same as PATH A, plus `Microsoft.Compute/virtualMachines/delete` |
| OS disk resource | Same as PATH A |
| NIC resources | `Microsoft.Network/networkInterfaces/read`, `write` (to set `DeleteOption` and Accelerated Networking) |
| Data disk resources | `Microsoft.Compute/disks/read`, `write` (to set `DeleteOption`) |
| Resource group | **Contributor** — needed to create the snapshot and the new VM resource |
| Subscription | Same as PATH A |

If the VM is enrolled in Automanage, `Microsoft.Automanage/configurationProfileAssignments/read` is also needed for detection. The script silently skips the check if access is denied.

When `-RestoreSystemAssignedRBAC` is used, the script additionally needs:

| Scope | Required |
|---|---|
| Role assignments (all scopes held by the old MI) | `Microsoft.Authorization/roleAssignments/read`, `write` |

A role that includes `Microsoft.Authorization/roleAssignments/write` (such as **Owner** or **User Access Administrator**) must be granted at or above each scope where the old principal had assignments.

---

> **Quick setup:** Contributor on the resource group plus Reader on the subscription (for SKU availability and quota checks) covers both paths. The per-resource breakdown above is for environments with stricter least-privilege requirements.

### VM requirements

- Generation 2 VM **when converting to NVMe**. Gen1 is blocked at the platform level for NVMe. SCSI-to-SCSI resizes and local-disk-to-diskless recreations work fine on Gen1.
- Windows Server 2019 or later **when converting to NVMe** (checked automatically unless `-IgnoreWindowsVersionCheck` is specified; not checked for SCSI-to-SCSI or local-disk-to-diskless).
- Linux: any NVMe-supported marketplace image. The script rebuilds the initrd and configures GRUB automatically with `-FixOperatingSystemSettings`.
- Managed OS disk (not an ephemeral disk or unmanaged VHD). Both PATH A and PATH B require a managed disk for the REST PATCH and snapshot operations.

### Pre-flight checks

The script validates the following before making any changes:

- **Azure module versions** — Az.Compute, Az.Accounts, Az.Resources, Az.Network at their minimum required versions.
- **Resource locks** — `CanNotDelete` and `ReadOnly` locks on the VM, its OS disk, all data disks, and all NICs are detected and the script aborts before any changes. Checks four scopes: VM resource, VM resource group, all attached disks, all attached NICs.
- **Azure Disk Encryption** — ADE is incompatible with NVMe. The script blocks the conversion and notes that ADE is scheduled for retirement (September 2028); Encryption at Host is the recommended replacement.
- **Azure Site Recovery** — ASR Mobility Service extension is detected and a warning is shown before proceeding.
- **Ephemeral OS disk** — VMs with an ephemeral OS disk (`DiffDiskSettings.Option = Local`) are blocked. The script requires a managed disk for snapshotting and patching.
- **Unmanaged OS disk** — VMs using a VHD in a Storage Account (`ManagedDisk = null`) are blocked. Migrate to a managed disk first with `Convert-AzVMManagedDisk`.
- **Generation check** — Generation 1 VMs are blocked when the target controller is NVMe.
- **Windows version** — Windows Server 2019 (build 17763) or later is required for NVMe. Stage 1 reads the imageReference SKU for first-party marketplace images; Stage 2 falls back to a RunCommand registry query for custom images and Shared Image Gallery VMs.
- **Shared Disks on Windows Server 2019** — Shared Disks with NVMe are not supported on Windows Server 2019. Data disks with `MaxShares > 1` are detected and the script blocks.
- **TrustedLaunch / ConfidentialVM** — ConfidentialVMs are blocked unconditionally. TrustedLaunch VMs targeting NVMe are blocked unless `-AllowTrustedLaunchDowngrade` is specified.
- **SKU availability** — target size must be available in the VM's region and zone, and not restricted for the subscription (`NotAvailableForSubscription`).
- **TrustedLaunch support on target size** — when `-AllowTrustedLaunchDowngrade` is used, the target size must not have `TrustedLaunchDisabled=True`.
- **vCPU quota** — family quota, regional quota, and Spot/low-priority quota are checked, accounting for vCPUs freed when the source VM is deallocated.
- **Data disk count** — the current number of data disks must not exceed the target size's `MaxDataDiskCount`.
- **NIC count** — the current number of NICs must not exceed the target size's `MaxNetworkInterfaces`.
- **Premium IO** — if the target size does not support Premium IO, the script blocks when Premium SSD disks are attached.
- **Write Accelerator** — warns if Write Accelerator is enabled but the target size does not support it.
- **Unmanaged data disks (PATH B)** — PATH B reattaches data disks by managed disk ID. Unmanaged data disks are detected after path selection, before the VM is stopped.
- **Uniform VMSS membership (PATH B)** — VMs that are members of a Uniform-orchestration scale set cannot be independently deleted and recreated. The script blocks PATH B for Uniform VMSS members and suggests `-ForcePathA` or `Update-AzVmssInstance` instead. Flexible-mode VMSS members are supported.
- **System-assigned MI RBAC** — when PATH B is selected and the VM has a system-assigned managed identity, all direct role assignments are enumerated and logged at pre-flight. If any are found and `-RestoreSystemAssignedRBAC` is not specified, you will be asked to confirm before proceeding (skipped with `-Force`).
- **v6+ SCSI mismatch** — when `-IgnoreSKUCheck` is used and the target looks like a v6+ size (NVMe-only generation) but `-NewControllerType SCSI` was specified, a warning is shown because most v6+ sizes do not support SCSI.

---

## Parameters

### Required

| Parameter | Description |
|---|---|
| `-ResourceGroupName` | Resource group of the VM |
| `-VMName` | Name of the VM |
| `-VMSize` | Target VM size (e.g. `Standard_E8as_v7`) |

### Commonly used

| Parameter | Description |
|---|---|
| `-NewControllerType` | `NVMe` or `SCSI`. Default: `NVMe` |
| `-FixOperatingSystemSettings` | Fix OS settings via RunCommand before conversion (see [OS fixes](#os-fixes)) |
| `-DryRun` | Show what would happen without making any changes. Run this first |
| `-StartVM` | Start the VM after conversion. PATH A only — PATH B always starts via `New-AzVM` |
| `-Force` | Skip all interactive confirmation prompts, for use in pipelines |
| `-WriteLogfile` | Write a timestamped log file to the current directory |

### Safety and security

| Parameter | Description |
|---|---|
| `-AllowTrustedLaunchDowngrade` | Enable conversion on TrustedLaunch VMs (see [TrustedLaunch](#trustedlaunch-vms)) |
| `-KeepSnapshot` | Keep the OS disk snapshot after recreation, as a manual rollback point |

### Path control

| Parameter | Description |
|---|---|
| `-ForcePathA` | Force the resize path even when the script would normally pick recreation |
| `-ForcePathB` | Force the recreation path even when resize would work |

### OS preparation and temp disk

| Parameter | Description |
|---|---|
| `-SkipPagefileFix` | Skip pagefile migration (use if already migrated manually) |
| `-NVMEDiskInitScriptLocation` | Folder on the VM where the NVMe temp disk init scripts are written. Default: `C:\AdminScripts` |
| `-NVMEDiskInitScriptSkip` | Skip installation of the NVMe temp disk startup task |

### Networking

| Parameter | Description |
|---|---|
| `-EnableAcceleratedNetworking` | Enable Accelerated Networking on all NICs if the target size supports it. PATH B only — on PATH A the script logs an advisory instead, since NICs are not modified during a resize |

### Managed identity (PATH B)

| Parameter | Description |
|---|---|
| `-RestoreSystemAssignedRBAC` | Automatically save and restore system-assigned managed identity RBAC role assignments during PATH B. Without this switch the script still detects and logs all assignments at pre-flight, but does not restore them — you will be asked to confirm before proceeding. See [Managed identity and RBAC](#managed-identity-and-rbac-path-b). |

### Skip and ignore flags

Listed from least to most impactful. Using these flags means the script cannot verify the corresponding prerequisite — use only when you have confirmed the condition manually.

| Parameter | Description |
|---|---|
| `-IgnoreAzureModuleCheck` | Skip Az module version check |
| `-IgnoreQuotaCheck` | Skip vCPU quota check |
| `-IgnoreSKUCheck` | Skip SKU availability and capability checks |
| `-IgnoreWindowsVersionCheck` | Skip Windows version check (>= 2019 required for NVMe) |
| `-IgnoreOSCheck` | Skip the NVMe driver compatibility checks in STEP 1. Does **not** suppress STEP 1b (pagefile migration) or STEP 1c (NVMe temp disk startup task installation) — those still run when required. Use when the VM agent is unavailable or unreachable. |
| `-SkipExtensions` | Skip automatic reinstallation of one or more specific extensions by **Name** during PATH B recreation. Use for extensions managed externally (e.g. by Azure Policy, Microsoft Defender for Cloud, or a third-party platform) that will redeploy automatically. Example: `-SkipExtensions 'QualysAgent'` |
| `-SkipExtensionReinstall` | Skip automatic extension reinstallation after PATH B recreation entirely |

### Other

| Parameter | Description |
|---|---|
| `-SleepSeconds` | Seconds to wait before starting the VM after resize (PATH A). Default: `15` |

---

## OS fixes

When `-FixOperatingSystemSettings` is specified, the script runs OS preparation via RunCommand before the conversion takes place.

**Windows:**
- Sets the `stornvme` driver to Boot start and removes the `StartOverride` registry key, so the NVMe controller is available at boot.
- Migrates the pagefile from `D:\` to `C:\` when moving away from a SCSI temp disk.
- Installs `NVMeTempDiskInit.ps1` as a scheduled startup task when the target size has an NVMe temp disk. See [NVMe temp disk](#nvme-temp-disk-v6v7-d-sizes) for details.

**Linux:**
- Rebuilds initrd/initramfs to include the NVMe driver. Uses `update-initramfs` on Debian/Ubuntu and `dracut -f --kver $(uname -r)` on RHEL, Rocky, SLES, and Azure Linux. Both explicitly target the currently running kernel to avoid false results when multiple kernels are installed.
- Adds `nvme_core.io_timeout=240` to the GRUB kernel parameters. This is the value Microsoft recommends for Azure NVMe storage. If a different value is already set, the script warns rather than overwriting it.
- Installs `azure-vm-utils` to create stable `/dev/disk/azure/data/by-lun/X` NVMe symlinks. These replace the SCSI `scsi1/lunX` paths from waagent, which stop working after the controller switch. The package is pre-installed on Ubuntu 22.04/24.04/25.04, Azure Linux 2.0, Fedora 42, and Flatcar.
- Checks `fstab` for raw `/dev/sd*` device names that will break after the controller switch, and flags `/dev/sdb*` temp disk entries for removal. Also warns about raw `/dev/nvme*` paths, which are unstable on v7+ sizes where Azure distributes disks across multiple controllers based on caching policy.
- Checks `/etc/waagent.conf` for `ResourceDisk.Format=y` and `ResourceDisk.EnableSwap=y`. Both should be set to `n` after conversion, since waagent can no longer find the temp disk at `/dev/sdb`.

Without `-FixOperatingSystemSettings`, the script runs the same checks and logs warnings, but makes no changes.

---

## TrustedLaunch VMs

Azure blocks SCSI-to-NVMe conversion on TrustedLaunch VMs at the platform level. The `-AllowTrustedLaunchDowngrade` switch works around this by temporarily setting the security type to `Standard`, running the conversion, then restoring `TrustedLaunch` with the original `SecureBoot` and `vTPM` settings.

> **Data loss warning — read before using `-AllowTrustedLaunchDowngrade`**
>
> The following vTPM-stored state is permanently destroyed when TrustedLaunch is removed and cannot be recovered:
> - BitLocker keys sealed to the vTPM. The disk may enter BitLocker recovery on first boot if no alternative protector (such as a standard recovery key) exists.
> - FIDO2 and Windows Hello for Business keys bound to the vTPM.
> - Attestation certificates and any other secrets sealed to the vTPM state.
>
> The TrustedLaunch security posture — SecureBoot and the vTPM chip itself — is fully restored after conversion. Only the credentials stored inside the vTPM are lost and need to be re-provisioned.

> **PATH B (VM recreation) also destroys vTPM state — even without `-AllowTrustedLaunchDowngrade`**
>
> The vTPM chip is bound to the VM resource, not to the OS disk. When PATH B deletes the VM shell (STEP 6B), the vTPM is destroyed permanently regardless of whether the security type was downgraded first. This applies to any TrustedLaunch VM that takes PATH B — for example, a Windows VM moving between disk architecture categories (local-disk ↔ diskless ↔ NVMe temp disk) while staying on SCSI. The TrustedLaunch security posture is restored on the new VM via the SecurityProfile in STEP 7B, but vTPM-stored credentials (BitLocker keys sealed to vTPM, FIDO2/WHfB keys, attestation certs) must be re-provisioned. The script warns before proceeding.

Run with `-DryRun` first to see exactly what will happen.

**ConfidentialVMs** cannot be converted to NVMe. This is a hard platform restriction with no workaround.

---

## Managed identity and RBAC (PATH B)

PATH B deletes the VM shell and recreates it. This affects managed identities differently depending on their type.

### User-assigned managed identities

User-assigned identities are separate Azure resources and are **not** deleted when the VM shell is removed. Their principal ID is stable across recreation. All RBAC role assignments on user-assigned identities continue to work without any action.

### System-assigned managed identity

A system-assigned managed identity is bound to the VM resource. When PATH B deletes the VM shell:

- The old managed identity is permanently destroyed.
- The recreated VM gets a **brand-new** system-assigned identity with a **different principal ID**.
- Any RBAC role assignments on the old principal — for example Storage Blob Data Contributor on a storage account, Key Vault Secrets User on a key vault, Automation Operator on an Automation account — **silently stop working** until they are updated to the new principal ID.

> **"Managed identity restored" does not mean "RBAC is working."** The identity object is passed to `New-AzVM` and a new system-assigned identity is created, but the RBAC role assignments on the old principal are gone. The script always makes this distinction explicit in the log.

### Default behaviour: detect, log, and ask

Without `-RestoreSystemAssignedRBAC`, the script always:

1. Enumerates all direct role assignments on the old system-assigned principal (before the VM is touched).
2. Logs each assignment with its scope and role name.
3. If any assignments are found, asks for confirmation before proceeding. Use `-Force` to suppress the prompt in pipelines.

No export file is created and no automatic restore is performed. Re-assign the RBAC roles manually after recreation using the new principal ID.

### Automatic restore with `-RestoreSystemAssignedRBAC`

Add `-RestoreSystemAssignedRBAC` to opt into automatic restore. The prompt is suppressed because restore is explicitly requested.

1. The enumerated assignments are saved to `<VM>-<timestamp>-rbac-export.json` before the VM is deleted.
2. After recreation, the new principal ID is read from the recreated VM (with a 20-second ARM propagation retry if needed).
3. Each assignment is re-created on the new principal. Results are written to `<VM>-<timestamp>-rbac-restore-results.json`.

Restore is idempotent: existing assignments on the new principal are detected and skipped. Per-assignment failures are non-fatal and are logged as ACTION REQUIRED in the results file.

> **Note on Key Vault extension ordering:** Extension reinstall (STEP 8B) runs before RBAC restore (STEP 9B). The Key Vault VM extension installs and starts immediately; it will authenticate successfully once STEP 9B completes. Without `-RestoreSystemAssignedRBAC`, the Key Vault RBAC or access policy must be updated manually before the extension can authenticate.

### Manual restore

If you prefer not to use automatic restore (for example, because role assignments are managed by policy or a deployment pipeline), the pre-flight log lists all assignments. After recreation, retrieve the new principal ID and re-create each assignment:

```powershell
$newPrincipalId = (Get-AzVM -ResourceGroupName "myRG" -Name "myVM").Identity.PrincipalId
New-AzRoleAssignment -ObjectId $newPrincipalId `
    -Scope "/subscriptions/.../resourceGroups/.../providers/..." `
    -RoleDefinitionName "Storage Blob Data Contributor"
```

---

## Examples

```powershell
# Check what would happen without touching anything
.\AzureVM-NVME-and-localdisk-Conversion.ps1 `
    -ResourceGroupName "myRG" -VMName "myVM" `
    -NewControllerType NVMe -VMSize "Standard_E8as_v7" `
    -FixOperatingSystemSettings -DryRun
```

```powershell
# Windows VM: convert to NVMe, move to diskless v7 size, fix OS settings
.\AzureVM-NVME-and-localdisk-Conversion.ps1 `
    -ResourceGroupName "myRG" -VMName "myVM" `
    -NewControllerType NVMe -VMSize "Standard_E8as_v7" `
    -FixOperatingSystemSettings -StartVM -WriteLogfile
```

```powershell
# Windows VM: move from local-disk to diskless within the same generation, no NVMe change
.\AzureVM-NVME-and-localdisk-Conversion.ps1 `
    -ResourceGroupName "myRG" -VMName "myVM" `
    -NewControllerType SCSI -VMSize "Standard_D4as_v5" `
    -FixOperatingSystemSettings -StartVM -WriteLogfile
```

```powershell
# Linux VM: convert to NVMe with full OS prep
.\AzureVM-NVME-and-localdisk-Conversion.ps1 `
    -ResourceGroupName "myRG" -VMName "myLinuxVM" `
    -NewControllerType NVMe -VMSize "Standard_E8as_v7" `
    -FixOperatingSystemSettings -StartVM -WriteLogfile
```

```powershell
# TrustedLaunch VM — read the vTPM warning above before running this
.\AzureVM-NVME-and-localdisk-Conversion.ps1 `
    -ResourceGroupName "myRG" -VMName "myTLVM" `
    -NewControllerType NVMe -VMSize "Standard_E8as_v7" `
    -AllowTrustedLaunchDowngrade -FixOperatingSystemSettings -StartVM -WriteLogfile
```

```powershell
# VM with system-assigned managed identity: auto-restore RBAC after recreation
.\AzureVM-NVME-and-localdisk-Conversion.ps1 `
    -ResourceGroupName "myRG" -VMName "myVM" `
    -NewControllerType NVMe -VMSize "Standard_E8as_v7" `
    -FixOperatingSystemSettings -StartVM -WriteLogfile `
    -RestoreSystemAssignedRBAC
```

```powershell
# Pipeline run: no prompts, keep snapshot as a fallback, auto-restore RBAC
.\AzureVM-NVME-and-localdisk-Conversion.ps1 `
    -ResourceGroupName "myRG" -VMName "myVM" `
    -NewControllerType NVMe -VMSize "Standard_E8as_v7" `
    -FixOperatingSystemSettings -StartVM -WriteLogfile `
    -Force -KeepSnapshot -RestoreSystemAssignedRBAC
```

```powershell
# Rollback: revert to SCSI and the original size
.\AzureVM-NVME-and-localdisk-Conversion.ps1 `
    -ResourceGroupName "myRG" -VMName "myVM" `
    -NewControllerType SCSI -VMSize "Standard_E8bds_v5" `
    -StartVM -WriteLogfile
```

---

## What to do if the script fails mid-run

The script is designed to be restartable. Each step checks current state before acting, so re-running with the same parameters will pick up where things left off in most cases.

A few specific situations to be aware of:

**Failure after STEP 2a (TrustedLaunch downgrade) but before STEP 4Aa/7B (restore):**
TrustedLaunch has been removed but not yet restored. The VM is sitting at `Standard` security type. Re-run with the same parameters and `-AllowTrustedLaunchDowngrade`. Because the VM is already at `Standard`, STEP 2a is skipped automatically — the script continues with the remaining steps from where it left off. However, STEP 4Aa (re-enable TrustedLaunch on PATH A) is also skipped on re-run for the same reason. The first run's log and `finally` block already printed a manual restore command (`ACTION REQUIRED`); use that to re-enable TrustedLaunch by hand before or after re-running.

**Failure after STEP 6B (VM deleted) but before STEP 7B (VM recreated):**
The VM shell has been deleted but the OS disk and NICs are intact — `DeleteOption` was set to `Detach` before deletion. Re-run with the same parameters. The script recreates the VM from the original OS disk directly — the snapshot is a safety backup only and is not used for recreation itself.

> **Note:** If you re-run the script and it reports "VM not found", this is the expected state after a STEP 6B failure. The script detects this situation and provides manual recovery instructions. The OS disk, data disks, and NICs were preserved because `DeleteOption=Detach` was verified before deletion. To recover manually: find the OS disk in the resource group, create a new VM with `Set-AzVMOSDisk -CreateOption Attach`, and reattach the NICs and data disks.

**Failure during extension reinstall (STEP 8B):**
The VM is running at this point. Extension failures are logged as warnings and do not roll back the VM. Reinstall the affected extensions manually.

**Failure during RBAC restore (STEP 9B):**
RBAC failures are non-fatal. The VM is already running. The results file (`<VM>-<timestamp>-rbac-restore-results.json`) lists which assignments were restored and which failed. Re-assign the failed ones manually using the new principal ID printed in the log.

For anything else, check the log file (use `-WriteLogfile`) for the last completed step and the exact error before deciding what to do next.

---

## Rollback

**PATH A (resize):** Run the script again with `-NewControllerType SCSI` and the original VM size. `-AllowTrustedLaunchDowngrade` is not needed for rollback — the TrustedLaunch restriction only applies to SCSI-to-NVMe conversion, not the reverse.

**PATH B (recreation):** The simplest rollback is to re-run the script with the original controller type and size:

```powershell
.\AzureVM-NVME-and-localdisk-Conversion.ps1 `
    -ResourceGroupName "myRG" -VMName "myVM" `
    -NewControllerType SCSI -VMSize "Standard_E8bds_v5" `
    -StartVM
```

If that is not possible, restore from the OS disk snapshot (only available if `-KeepSnapshot` was used), or from the most recent Azure Backup recovery point.

> **TrustedLaunch note:** If `-AllowTrustedLaunchDowngrade` was used during the original conversion, the vTPM state was permanently destroyed. A rollback restores the disk controller and VM size but does **not** recover vTPM-stored credentials (BitLocker keys sealed to TPM, FIDO2 keys, attestation certificates). These must be re-provisioned regardless of whether the conversion is rolled back.

> **RBAC rollback note:** If the VM has a system-assigned managed identity and PATH B is taken on rollback, the principal ID changes again. Add `-RestoreSystemAssignedRBAC` to the rollback command if needed, or re-assign manually.

---

## Extension reinstallation (PATH B)

After VM recreation the script reinstalls VM extensions automatically. Extensions fall into four categories.

### MANUAL — protected settings, must reinstall by hand

These extensions cannot be reinstalled automatically because their protected settings are never returned by the Azure API. A MANUAL notice is logged for each one.

| Extension type | Reason |
|---|---|
| `AzureDiskEncryption` / `AzureDiskEncryptionForLinux` | Multi-step reinstall required |
| `CustomScriptExtension` / `customScript` | Re-execution is dangerous and may contain secrets |
| `ADDomainExtension` | Active Directory domain join password in protected settings |
| `Microsoft.Powershell.DSC` / `DSCForLinux` | May contain credentials in protected settings |
| `IaaSDiagnostics` / `LinuxDiagnostic` | Storage account key in protected settings |
| `ServiceFabricNode` | Cluster/client certificate config in protected settings |
| `VMAccessAgent` / `VMAccessForLinux` | Credentials in protected settings; reinstall with new credentials |
| `DockerExtension` | TLS certs and registry credentials in protected settings; also retired since November 2018 |

### SKIP — Azure-managed, redeploys automatically via service plane

These extensions are managed by an Azure service and redeploy themselves automatically after recreation. Attempting to install them via `Set-AzVMExtension` would conflict with the managing service.

| Extension type | Managed by |
|---|---|
| `VMSnapshot` / `VMSnapshotLinux` | Azure Backup — reinstalls on next scheduled backup job; existing recovery points and backup schedules are preserved because the VM resource ID is unchanged |
| `MDE.Windows` / `MDE.Linux` | Microsoft Defender for Cloud — redetects and re-pushes MDE onboarding automatically |
| `AzurePolicyforWindows` / `ConfigurationforWindows` / `ConfigurationforLinux` | Azure Policy — re-evaluates compliance and redeploys within ~15 minutes |
| `GuestAttestation` / `GuestAttestationLinux` | Azure platform — re-pushed automatically for TrustedLaunch VMs |

### SKIP — `-SkipExtensions` or `-SkipExtensionReinstall`

Extensions explicitly excluded by the operator are skipped regardless of their type. This is the right approach for extensions deployed by external systems such as Azure Policy, Microsoft Defender for Cloud, or third-party management platforms that push their own extensions with correct onboarding settings.

### AUTO — reinstalled automatically by STEP 8B

All other extensions are reinstalled via `Set-AzVMExtension`. Some have additional internal handling:

- **Key Vault VM extension** (`KeyVaultForWindows` / `KeyVaultForLinux`) — uses managed identity, no protected settings. When the VM has only a system-assigned identity, the extension installs in STEP 8B before RBAC is restored in STEP 9B. With `-RestoreSystemAssignedRBAC` the extension will work once STEP 9B completes; without it, update the Key Vault RBAC or access policy to the new principal ID manually.
- **Azure Monitor Agent** (`AzureMonitorWindowsAgent` / `AzureMonitorLinuxAgent`) — uses managed identity. Data Collection Rule associations reference the VM resource ID and are preserved across recreation.
- **AAD SSH login / Azure AD login** (`AADSSHLoginForLinux` / `AADLoginForWindows`) — no protected settings. RBAC roles (e.g. Virtual Machine Administrator Login) are assigned on the VM resource ID, which is unchanged after recreation with the same name and resource group.
- **MMA/OMS** (`MicrosoftMonitoringAgent` / `OmsAgentForLinux`) — workspace key is looked up automatically from the Log Analytics workspace via `Az.OperationalInsights` if available. Falls back to MANUAL if the module is absent or the workspace cannot be found.
- **SqlIaasAgent** — the `Microsoft.SqlVirtualMachine/SqlVirtualMachines` resource survives VM deletion and re-links automatically once the VM is recreated with the same name. The script verifies this and only calls `New-AzSqlVM` if the resource is missing (using PAYG as a safe default).

After reinstall, the script performs a post-validation check: it waits 15 seconds and then reads the provisioning state of each extension from Azure. Any extension that did not reach `Succeeded` is flagged as ACTION REQUIRED in the log.

---

## NVMe temp disk (v6/v7 d-sizes)

v6 and v7 VM sizes with a local disk (`d` in the name, e.g. `E8ads_v7`) present the temp disk as a raw, unformatted NVMe device after a deallocate or when the VM moves to a new host. A normal reboot on the same host leaves the disk intact. This differs from v5 and older, where Azure always delivered a pre-formatted NTFS or ext4 temp disk.

**Windows:** When the target size is a `d`-size, the script installs a scheduled startup task (`NVMeTempDiskInit.ps1`) that checks on each boot whether the disk needs initialization, and formats it as `D:\` if so. The task runs at SYSTEM startup at priority 0 (highest) with a 2-attempt restart policy. For multi-disk VM sizes (e.g. `D16ads_v7`, `D32ads_v7`), a striped Storage Pool is created across all NVMe temp disks. A `Wait-ForDrive-D.ps1.snippet.txt` helper is also written to the same folder for use in any dependent startup tasks.

The install location can be changed with `-NVMEDiskInitScriptLocation`. Note: the pagefile remains on `C:\` after conversion — the init task does not move it back to `D:\`. If you want the pagefile on the temp disk for performance, reconfigure it manually after verifying `D:\` is available.

**Linux:** The Azure Linux Agent (waagent) or cloud-init handles NVMe temp disk initialization on v6/v7. However, NVMe temp disk support requires waagent version 2.8 or later — older versions look for `/dev/sdb` and will fail silently. Verify the agent version on the VM if the temp disk does not appear after conversion.

> If you need to change a disk's caching policy after NVMe conversion, stop the VM first, make the change, then start it again. Changing caching settings on a running NVMe VM can cause the disk to reassign to a different controller, which changes device paths and can cause remapping issues. On v7+ sizes this is particularly important: Azure distributes cached and uncached disks across two separate NVMe controllers, and a caching change silently moves the disk between controllers on the next boot.

---

## Error handling and pipeline use

Fatal errors are raised internally with `throw` (via a `Stop-Script` helper) rather than `exit 1`. This ensures the script's own `finally` block always runs — restoring breaking-change warning settings and emitting any pending TrustedLaunch restore instructions — before the process exits.

The top-level `catch` block converts the thrown exception into a clean `exit 1`, giving external callers a reliable non-zero exit code. A custom `AzVMFatalError` class lets the catch block distinguish expected termination (message already written to the log by `Stop-Script`) from unhandled exceptions (which are logged automatically by the outer catch).

If you call this script from automation, check `$LASTEXITCODE`:

```powershell
.\AzureVM-NVME-and-localdisk-Conversion.ps1 -ResourceGroupName myRG -VMName myVM ...
if ($LASTEXITCODE -ne 0) {
    Write-Host "Conversion failed (exit code $LASTEXITCODE)"
}
```

> **Note:** wrapping the call in `try/catch` will not catch script-termination errors because the script exits via `exit 1`, not an uncaught throw. Use `$LASTEXITCODE` instead.

---

## Implementation notes

### ARM throttling and retry logic

Azure ARM APIs can return transient errors under load. The script retries all mutating API calls automatically using exponential back-off:

| Retried call | Retryable conditions |
|---|---|
| `Update-AzVM` (resize, security profile, STEP 6B DeleteOption) | 429, 409 Conflict, 500, 503, RetryableError |
| `Remove-AzVM` (STEP 6B) | same |
| `New-AzSnapshot` / `Remove-AzSnapshot` | same |
| OS disk controller PATCH (`Invoke-RestMethod`) | same |
| `Set-AzNetworkInterface` (AccelNet enable/disable) | same |
| `New-AzRoleAssignment` (STEP 9B RBAC restore) | same |

The default is 3 attempts with a starting delay of 5 seconds, doubling on each retry up to a maximum of 60 seconds. Non-retryable errors (authentication failures, resource not found, validation errors) are re-thrown immediately without delay.

`New-AzVM` is not wrapped in the retry helper because it typically takes 2–3 minutes and its failure modes are handled by STEP 7B's dedicated recovery log block.

### Parallel NIC and disk fetching (PS7)

On PowerShell 7+, the script fetches NIC and data disk objects in parallel using `ForEach-Object -Parallel`. This is relevant for VMs with many NICs (e.g. network-intensive workloads, NVAs) or many data disks (e.g. database servers):

- **Pre-flight** accelerated networking advisory check — all NICs fetched in parallel before any changes.
- **Pre-flight** MaxShares check (Windows Server 2019 + NVMe) — all managed data disks fetched in parallel.
- **Pre-flight** Premium IO check — all managed data disks fetched in parallel.
- **STEP 5B** — all NICs fetched once in parallel for both backend-pool detection and STEP 7B reattachment. No second NIC fetch in STEP 7B.

On PowerShell 5.1, all fetching is sequential (same result, slightly slower for VMs with 3+ NICs or disks). The throttle limit defaults to 5 parallel fetches for both NICs and disks.

> **Note:** Azure SDK objects can lose properties when serialised across PS7 parallel runspace boundaries. Both batch helpers (`Get-AzNICBatch` and `Get-AzDiskBatch`) pre-extract the needed ID and Name fields into plain `PSCustomObject` instances before entering the parallel block to avoid this.

### OS disk controller PATCH and token handling

The `diskControllerTypes` property is updated via a direct ARM REST PATCH rather than `Update-AzVM`. On PowerShell 7+, the access token is kept as a `SecureString` and passed directly to `Invoke-RestMethod -Authentication Bearer`, so it is never materialised as a plaintext CLR string in memory. On PowerShell 5.1, the token is briefly marshalled to a plain string (unavoidable), then immediately cleared from the variable scope after the request completes.

---

## Known limitations

- Generation 1 VMs cannot be converted to NVMe (hard platform block). SCSI-to-SCSI resizes and local-disk-to-diskless recreations on Gen1 VMs are fully supported.
- ConfidentialVMs cannot be converted to NVMe (hard platform block, no workaround).
- Ephemeral OS disks are not supported — the script requires a managed OS disk for snapshotting and patching.
- Unmanaged disks (VHDs in Storage Accounts) are not supported — migrate to managed disks first with `Convert-AzVMManagedDisk`. Unmanaged data disks are detected after path selection, before the VM is stopped.
- Uniform VMSS members cannot use PATH B (recreation). PATH A (in-place resize) works fine. Use `-ForcePathA` or use `Update-AzVmssInstance` for model changes.
- Management locks (`CanNotDelete` or `ReadOnly`) on the VM, its OS disk, data disks, or NICs must be removed before running the script. The script detects these and aborts before making any changes.
- NVMe VMs are not supported by Azure Site Recovery. The script detects an active ASR Mobility Service extension and warns before continuing. If you proceed, ASR replication for that VM breaks and needs to be re-evaluated afterwards.
- Azure Disk Encryption (ADE) is not compatible with NVMe. Note: ADE is scheduled for retirement on September 15, 2028 — Microsoft recommends migrating to Encryption at Host.
- Extensions with protected settings must be reinstalled manually after PATH B recreation.
- PATH B applies to Windows only. Linux always uses PATH A.
- The script is not fully idempotent when re-run after a failure between STEP 6B (VM deleted) and STEP 7B (VM recreated). In that case the VM shell is gone but all disks and NICs are intact. The script detects this situation and provides manual recovery instructions.
- System-assigned managed identity RBAC assignments are **not** automatically restored unless `-RestoreSystemAssignedRBAC` is specified. The script always enumerates and logs the assignments at pre-flight, and asks for confirmation if any are found. Automatic restore is an explicit opt-in.
- Boot diagnostics using a storage account in a different subscription cannot be restored automatically. The script falls back to managed boot diagnostics (Azure-managed storage) in this case.
- Parallel NIC and disk fetching (`ForEach-Object -Parallel`) requires PowerShell 7 or later. On PS5.1 fetching is sequential, which is slightly slower for VMs with 3 or more NICs or data disks but functionally identical.
- Fatal errors exit the script with `exit 1`. In calling scripts or pipelines, check `$LASTEXITCODE` — wrapping the call in `try/catch` will not intercept `exit 1`. See [Error handling and pipeline use](#error-handling-and-pipeline-use).

---

## References

- [Convert Azure VMs from SCSI to NVMe](https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-interface)
- [NVMe General FAQ](https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-faqs)
- [NVMe Temp Disk FAQ](https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-temp-faqs)
- [Azure VMs with no local temporary disk](https://learn.microsoft.com/en-us/azure/virtual-machines/azure-vms-no-temp-disk)
- [SCSI to NVMe for Linux VMs](https://learn.microsoft.com/en-us/azure/virtual-machines/nvme-linux)
- [azure-vm-utils (NVMe udev symlinks)](https://github.com/Azure/azure-vm-utils)
