# AzureVM-NVME-and-localdisk-Conversion

A PowerShell script to convert Azure VMs between SCSI and NVMe disk controllers, and to handle the VM recreation that Windows requires when moving between local-disk and diskless VM sizes.


---

## Table of contents

- [Why this script exists](#why-this-script-exists)
- [Two execution paths](#two-execution-paths)
- [Requirements](#requirements)
- [Parameters](#parameters)
- [OS fixes](#os-fixes)
- [TrustedLaunch VMs](#trustedlaunch-vms)
- [Azure Site Recovery](#azure-site-recovery)
- [Examples](#examples)
- [Rollback](#rollback)
- [What to do if the script fails mid-run](#what-to-do-if-the-script-fails-mid-run)
- [Extension reinstallation (PATH B)](#extension-reinstallation-path-b)
- [NVMe temp disk (v6/v7 d-sizes)](#nvme-temp-disk-v6v7-d-sizes)
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
OS prep  ->  Stop VM  ->  Patch OS disk controller type  ->  Resize  ->  Start
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
OS prep  ->  Pagefile migration  ->  Stop VM  ->  Snapshot OS disk (safety backup)
  ->  Patch OS disk controller type  ->  Capture VM config
  ->  Set DeleteOption=Detach on all resources  ->  Delete VM shell
  ->  Recreate VM (original OS disk + NICs + data disks)
  ->  Reinstall extensions  ->  Delete snapshot
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

---

> **Quick setup:** Contributor on the resource group plus Reader on the subscription (for SKU availability and quota checks) covers both paths. The per-resource breakdown above is for environments with stricter least-privilege requirements.

### VM requirements

- Generation 2 VM **when converting to NVMe**. Gen1 is blocked at the platform level for NVMe. SCSI-to-SCSI resizes and local-disk-to-diskless recreations work fine on Gen1.
- Windows Server 2019 or later **when converting to NVMe** (checked automatically unless `-IgnoreWindowsVersionCheck` is specified; not checked for SCSI-to-SCSI or local-disk-to-diskless).
- Linux: any NVMe-supported marketplace image. The script rebuilds the initrd and configures GRUB automatically with `-FixOperatingSystemSettings`.

### Pre-flight checks

The script validates the following before making any changes:

- **Azure module versions** — Az.Compute, Az.Accounts, Az.Resources, Az.Network at their minimum required versions.
- **Resource locks** — `CanNotDelete` and `ReadOnly` locks on the VM or resource group are detected and the script aborts before any changes.
- **Azure Disk Encryption** — ADE is incompatible with NVMe. The script blocks the conversion and notes that ADE is scheduled for retirement (September 2028); Encryption at Host is the recommended replacement.
- **Azure Site Recovery** — ASR Mobility Service extension is detected and a warning is shown before proceeding.
- **SKU availability** — target size must be available in the VM's region and zone, and not restricted for the subscription.
- **vCPU quota** — family quota, regional quota, and Spot quota are checked.
- **Data disk count** — the current number of data disks must not exceed the target size's `MaxDataDiskCount`.
- **NIC count** — the current number of NICs must not exceed the target size's `MaxNetworkInterfaces`.
- **Premium IO** — if the target size does not support Premium IO, the script blocks when Premium SSD disks are attached.
- **Write Accelerator** — warns if Write Accelerator is enabled but the target size does not support it.
- **TrustedLaunch compatibility** — when `-AllowTrustedLaunchDowngrade` is used, the target size must support TrustedLaunch (`TrustedLaunchDisabled` must not be True).
- **Shared Disks** — Shared Disks with NVMe are not supported on Windows Server 2019.
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

### Skip and ignore flags

Listed from least to most impactful. Using these flags means the script cannot verify the corresponding prerequisite — use only when you have confirmed the condition manually.

| Parameter | Description |
|---|---|
| `-IgnoreAzureModuleCheck` | Skip Az module version check |
| `-IgnoreQuotaCheck` | Skip vCPU quota check |
| `-IgnoreSKUCheck` | Skip SKU availability and capability checks |
| `-IgnoreWindowsVersionCheck` | Skip Windows version check (>= 2019 required for NVMe) |
| `-IgnoreOSCheck` | Skip all OS-level checks (no RunCommand is executed at all) |
| `-SkipExtensionReinstall` | Skip automatic extension reinstallation after PATH B recreation |

### Other

| Parameter | Description |
|---|---|
| `-SleepSeconds` | Seconds to wait before starting the VM after resize. Default: `15` |

---

## OS fixes

When `-FixOperatingSystemSettings` is specified, the script runs OS preparation via RunCommand before the conversion takes place.

**Windows:**
- Sets the `stornvme` driver to Boot start and removes the `StartOverride` registry key, so the NVMe controller is available at boot.
- Migrates the pagefile from `D:\` to `C:\` when moving away from a SCSI temp disk.
- Installs `NVMeTempDiskInit.ps1` as a scheduled startup task when the target size has an NVMe temp disk. See [NVMe temp disk](#nvme-temp-disk-v6v7-d-sizes) for details.

**Linux:**
- Rebuilds initrd/initramfs to include the NVMe driver. Uses `update-initramfs` on Debian/Ubuntu and `dracut` on RHEL, Rocky, SLES, and Azure Linux.
- Adds `nvme_core.io_timeout=240` to the GRUB kernel parameters. This is the value Microsoft recommends for Azure NVMe storage.
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
> The vTPM chip is bound to the VM resource, not to the OS disk. When PATH B deletes the VM shell (STEP 6B), the vTPM is destroyed permanently regardless of whether the security type was downgraded first. This applies to any TrustedLaunch VM that takes PATH B — for example, a Windows VM moving between disk architecture categories (local-disk ↔ diskless ↔ NVMe temp disk) while staying on SCSI. The TrustedLaunch security posture is restored on the new VM, but vTPM-stored credentials (BitLocker keys sealed to vTPM, FIDO2/WHfB keys, attestation certs) must be re-provisioned. The script warns before proceeding.

Run with `-DryRun` first to see exactly what will happen.

**ConfidentialVMs** cannot be converted to NVMe. This is a hard platform restriction with no workaround.

---

## Azure Site Recovery

VMs with an NVMe disk controller are not supported by Azure Site Recovery (ASR). The script checks for an active ASR Mobility Service extension and warns before continuing. If you proceed with the conversion, ASR replication for that VM will break and needs to be re-evaluated afterwards.

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
# Pipeline run: no prompts, keep snapshot as a fallback
.\AzureVM-NVME-and-localdisk-Conversion.ps1 `
    -ResourceGroupName "myRG" -VMName "myVM" `
    -NewControllerType NVMe -VMSize "Standard_E8as_v7" `
    -FixOperatingSystemSettings -StartVM -WriteLogfile `
    -Force -KeepSnapshot
```

```powershell
# Rollback: revert to SCSI and the original size
.\AzureVM-NVME-and-localdisk-Conversion.ps1 `
    -ResourceGroupName "myRG" -VMName "myVM" `
    -NewControllerType SCSI -VMSize "Standard_E8bds_v5" `
    -StartVM -WriteLogfile
```

---

## Rollback

**PATH A (resize):** Run the script again with `-NewControllerType SCSI` and the original VM size. `-AllowTrustedLaunchDowngrade` is not needed for rollback.

**PATH B (recreation):** The simplest rollback is to re-run the script with the original controller type and size:

```powershell
.\AzureVM-NVME-and-localdisk-Conversion.ps1 `
    -ResourceGroupName "myRG" -VMName "myVM" `
    -NewControllerType SCSI -VMSize "Standard_E8bds_v5" `
    -IgnoreSKUCheck -StartVM
```

If that is not possible, restore from the OS disk snapshot (only available if `-KeepSnapshot` was used), or from the most recent Azure Backup recovery point.

> **TrustedLaunch note:** If `-AllowTrustedLaunchDowngrade` was used during the original conversion, the vTPM state was permanently destroyed. A rollback restores the disk controller and VM size but does **not** recover vTPM-stored credentials (BitLocker keys sealed to TPM, FIDO2 keys, attestation certificates). These must be re-provisioned regardless of whether the conversion is rolled back.

---

## What to do if the script fails mid-run

The script is designed to be restartable. Each step checks current state before acting, so re-running with the same parameters will pick up where things left off in most cases.

A few specific situations to be aware of:

**Failure after STEP 2a (TrustedLaunch downgrade) but before STEP 4Aa/7B (restore):**
TrustedLaunch has been removed but not yet restored. The VM is sitting at `Standard` security type. Re-run with the same parameters and `-AllowTrustedLaunchDowngrade` — STEP 2a will run again and call `Update-AzVM` with `SecurityProfile=null`, which is a no-op on a VM already at Standard, then continue with the remaining steps. The log also contains a manual restore command in case you prefer to restore TrustedLaunch by hand before retrying.

**Failure after STEP 6B (VM deleted) but before STEP 7B (VM recreated):**
The VM shell has been deleted but the OS disk and NICs are intact — `DeleteOption` was set to `Detach` before deletion. Re-run with the same parameters. The script recreates the VM from the original OS disk directly — the snapshot is a safety backup only and is not used for recreation itself.

> **Note:** If you re-run the script and it reports "VM not found", this is the expected state after a STEP 6B failure. The script detects this situation and provides manual recovery instructions. The OS disk, data disks, and NICs were preserved because `DeleteOption=Detach` was verified before deletion. To recover manually: find the OS disk in the resource group, create a new VM with `Set-AzVMOSDisk -CreateOption Attach`, and reattach the NICs and data disks.

**Failure during extension reinstall (STEP 8B):**
The VM is running at this point. Extension failures are logged as warnings and do not roll back the VM. Reinstall the affected extensions manually.

For anything else, check the log file (use `-WriteLogfile`) for the last completed step and the exact error before deciding what to do next.

---

## Extension reinstallation (PATH B)

After VM recreation the script reinstalls VM extensions automatically. Extensions that require protected settings cannot be reinstalled without operator input and are always skipped, with a MANUAL action notice in the log:

- `AzureDiskEncryption` / `AzureDiskEncryptionForLinux` — multi-step reinstall required
- `CustomScriptExtension` / `CustomScript` — re-execution is dangerous and may contain secrets
- `ADDomainExtension` — Active Directory domain join password is in protected settings
- `Microsoft.Powershell.DSC` / `DSCForLinux` — may contain credentials in protected settings
- `IaaSDiagnostics` / `LinuxDiagnostic` — storage account key is in protected settings
- `ServiceFabricNode` — cluster/client certificate config is in protected settings
- `VMAccessAgent` / `VMAccessForLinux` — credentials are in protected settings; reinstall with new credentials
- `DockerExtension` — TLS certs and registry credentials in protected settings; also retired since November 2018

Reinstall these manually once the VM is running.

**Azure Backup** (`VMSnapshot` / `VMSnapshotLinux`) needs no manual action. PATH B recreates the VM with the same name and resource group, so the ARM resource ID is unchanged. Azure Backup treats it as the same VM and existing recovery points and backup schedules carry over automatically.

---

## NVMe temp disk (v6/v7 d-sizes)

v6 and v7 VM sizes with a local disk (`d` in the name, e.g. `E8ads_v7`) present the temp disk as a raw, unformatted NVMe device after a deallocate or when the VM moves to a new host. A normal reboot on the same host leaves the disk intact. This differs from v5 and older, where Azure always delivered a pre-formatted NTFS or ext4 temp disk.

**Windows:** When the target size is a `d`-size, the script installs a scheduled startup task (`NVMeTempDiskInit.ps1`) that checks on each boot whether the disk needs initialization, and formats it as `D:\` if so. For multi-disk VM sizes (e.g. `D16ads_v7`, `D32ads_v7`), a striped Storage Pool is created. The install location can be changed with `-NVMEDiskInitScriptLocation`. Note: the pagefile remains on `C:\` after conversion — the init task does not move it back to `D:\`. If you want the pagefile on the temp disk for performance, reconfigure it manually after verifying `D:\` is available.

**Linux:** The Azure Linux Agent (waagent) or cloud-init handles NVMe temp disk initialization on v6/v7. However, NVMe temp disk support requires waagent version 2.8 or later — older versions look for `/dev/sdb` and will fail silently. Verify the agent version on the VM if the temp disk does not appear after conversion.

> If you need to change a disk's caching policy after NVMe conversion, stop the VM first, make the change, then start it again. Changing caching settings on a running NVMe VM can cause the disk to reassign to a different controller, which changes device paths and can cause remapping issues.

---

## Known limitations

- Generation 1 VMs cannot be converted to NVMe (hard platform block). SCSI-to-SCSI resizes and local-disk-to-diskless recreations on Gen1 VMs are fully supported.
- ConfidentialVMs cannot be converted to NVMe (hard platform block, no workaround).
- Ephemeral OS disks are not supported — the script requires a managed OS disk for snapshotting and patching.
- Unmanaged disks (VHDs in Storage Accounts) are not supported — migrate to managed disks first with `Convert-AzVMManagedDisk`.
- Uniform VMSS members cannot use PATH B (recreation). PATH A (in-place resize) works fine. Use `-ForcePathA` or use `Update-AzVmssInstance` for model changes.
- Management locks (`CanNotDelete` or `ReadOnly`) on the VM or resource group must be removed before running the script. The script detects these and aborts before making any changes.
- NVMe VMs are not supported by Azure Site Recovery.
- Azure Disk Encryption (ADE) is not compatible with NVMe. Note: ADE is scheduled for retirement on September 15, 2028 — Microsoft recommends migrating to Encryption at Host.
- Extensions with protected settings must be reinstalled manually after PATH B recreation.
- PATH B applies to Windows only. Linux always uses PATH A.
- The script is not fully idempotent when re-run after a failure between STEP 6B (VM deleted) and STEP 7B (VM recreated). In that case the VM shell is gone but all disks and NICs are intact. The script detects this situation and provides manual recovery instructions.

---

## References

- [Convert Azure VMs from SCSI to NVMe](https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-interface)
- [NVMe General FAQ](https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-faqs)
- [NVMe Temp Disk FAQ](https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-temp-faqs)
- [Azure VMs with no local temporary disk](https://learn.microsoft.com/en-us/azure/virtual-machines/azure-vms-no-temp-disk)
- [SCSI to NVMe for Linux VMs](https://learn.microsoft.com/en-us/azure/virtual-machines/nvme-linux)
- [azure-vm-utils (NVMe udev symlinks)](https://github.com/Azure/azure-vm-utils)
