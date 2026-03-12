# Changelog — AzureVM-NVME-and-localdisk-Conversion.ps1

All notable changes between the original script and the current v2.14.0 release are documented here.
Changes are grouped by logical feature area and roughly ordered as they were introduced.

---

## [v2.14.0] — Current release

See individual sections below for the full history of changes that make up this version.

---

## [v2.0.0] — Structural refactor and core reliability improvements

### Added
- **`AzVMFatalError` exception class** — a dedicated .NET exception type that replaces bare `exit 1` calls throughout the script, allowing the `finally` block to always run on termination (e.g. restoring `DisplayBreakingChangeWarning`).
- **`Stop-Script` function** — centralised fatal-error termination. All error exit paths now call `Stop-Script` instead of inlining `exit 1`, making the flow easier to follow and guaranteeing the `finally` block executes.
- **`AskToContinue` internal `-Force` and `-DryRun` guards** — the function now honours these flags automatically, so every call site gets consistent behaviour without repeating the check.
- **`Invoke-AzWithRetry`** — wraps Azure API calls with exponential back-off retry for transient HTTP 429, 409, 500, and 503 errors. Write operations (`Update-AzVM`, `Remove-AzVM`, `New-AzVM`, `New-AzSnapshot`, `Set-AzNetworkInterface`, `New-AzRoleAssignment`, REST disk patches) now use this wrapper.
- **`Invoke-AzVMUpdate`** — centralises the repetitive `Get-AzVM → modify → Update-AzVM` pattern into a single helper that accepts a `scriptblock` for the modification logic.
- **`Get-RegionVMSkus` with per-region caching** — replaces the single slow `Get-AzComputeResourceSku` call. Uses `-Location` to filter server-side (~400–500 results in 2–5 s vs the ~63,000-entry global catalog). Results are cached per region so source and target SKU lookups in the same region cost only one API call.
- **`Get-SKUCapability` helper** — single-line inline wrapper for `($sku.Capabilities | Where-Object Name -eq X).Value`, reducing repetition across all SKU checks.
- **`Get-ArmName` / `Get-ArmRG` helpers** — extract the resource name and resource group from an ARM ID; replace the repetitive `.Split('/')[-1]` and `.Split('/')[4]` patterns.
- **`Get-VMResourcesWithBadDeleteOption`** — encapsulates the STEP 6B verification logic into a reusable helper so callers need no inline loops.
- **`Invoke-CheckedRunCommand`** — combines `Invoke-RunCommand` + `ParseAndLogOutput` + the `Force`/`AskToContinue` error-handling pattern into one call. Used by the stornvme fix, Linux driver prep, and NVMe startup-task install steps.
- **`Get-AzNICBatch` / `Get-AzDiskBatch`** — fetch multiple NIC or disk objects in parallel on PowerShell 7+ (using `ForEach-Object -Parallel`), with sequential fallback on PS 5.1. Avoid N serial round-trips on VMs with many NICs or data disks.
- **`script:_azContext` cache** — the Azure context is captured once at startup and reused by `Set-OSDiskControllerTypes`, avoiding repeated `Get-AzContext` calls.
- **Helper functions organised into six named groups** — Logging & interaction, Pure utilities, VM state management, RunCommand pipeline, Azure update operations, Domain-specific helpers.
- **`Stop-AzVM -NoWait`** in STEP 2 — returns immediately and lets `WaitForVMPowerState` do all polling, eliminating the redundant synchronous wait that previously added 2–5 minutes of silent blocking.
- **Script version banner** — `v2.14.0` displayed in the startup header so log files are self-identifying.
- **Elapsed duration in completion summary** — shows total wall-clock time in minutes and seconds.

### Changed
- **Log timestamp format** changed from `mm:ss` to `hh:mm:ss` to support scripts running longer than one hour.
- **Log file encoding** changed from `Out-File -Encoding utf8` (which writes a UTF-8 BOM in PS 5.1) to `File.AppendAllText` with a no-BOM `UTF8Encoding` encoder, preventing grep and log-ingestion breakage.
- **`ParseAndLogOutput`** updated to match bracketed `[ERROR]` and `[WARNING]` prefixes emitted by bash scripts in addition to the bare `ERROR`/`WARNING` prefixes used by the PowerShell pagefile script.
- **`Invoke-RunCommand`** now separates `StdOut` and `StdErr` by `Code` field rather than merging them, so unhandled PowerShell exceptions in the remote script are surfaced as warnings before `ParseAndLogOutput` runs.
- **`WaitForVMPowerState`** and **`EnsureVMRunning`** updated to use `Select-Object -First 1` on the `PowerState*` status to avoid errors when multiple status entries are present.
- **`CheckModule`** moved to Group 2 (Pure utilities) and refactored to call `Stop-Script` directly, removing the inline `exit 1` pattern.
- **`Set-OSDiskControllerTypes`** refactored: uses `$script:_azContext` instead of a fresh `Get-AzContext`, and uses the environment's `ResourceManagerUrl` instead of hardcoded `management.azure.com` for sovereign cloud compatibility.
- **`Set-OSDiskControllerTypes` token handling** — PS 7+ path uses `-Authentication Bearer -Token <SecureString>` so the plaintext token is never materialised in CLR memory; PS 5.1 path marshals to string only when unavoidable and zeroes the variable afterwards. API version bumped to `2025-01-02`.
- **Az module minimum version requirements** updated: `Az.Compute >= 7.2.0`, `Az.Accounts >= 2.13.0`, `Az.Resources >= 6.0`, `Az.Network >= 5.0` (previously only three modules were checked with lower minimums).
- **Parameters reorganised** into logical groups in the `param()` block with inline comments.
- **`-Force` scope expanded** — now suppresses ALL interactive confirmation prompts (VM deletion, ASR warning, MANUAL extension acknowledgment, OS check errors, pagefile data-loss warnings, startup-task install failures, quota API failures), not only the PATH B VM-deletion prompt.
- **`-SleepSeconds`** validated with `[ValidateRange(0, 300)]`.
- **vCPU quota check refactored to use `Get-SKUCapability`** — the existing inline `.Capabilities | Where-Object { $_.Name -eq "vCPUs" }` expressions for `$targetVCPUs` and `$sourceVCPUs` are replaced with `[int](Get-SKUCapability $targetSKU "vCPUs")` and its source equivalent, consistent with all other capability lookups in the script.

---

## [v2.1.0] — Pre-flight safety checks

### Added
- **ADE check extended to Windows** — previously only checked `AzureDiskEncryptionForLinux`; now filters by `ExtensionType` for both `AzureDiskEncryption` and `AzureDiskEncryptionForLinux`, catching extensions installed under custom names. Includes retirement advisory (September 15, 2028).
- **Azure Site Recovery (ASR) detection** — warns before any changes if the Microsoft.Azure.RecoveryServices SiteRecovery Mobility Service extension is present. NVMe VMs are not supported by ASR; converting will silently break DR replication.
- **Resource lock check** — detects `CanNotDelete` and `ReadOnly` management locks on the VM, its resource group, attached OS and data disks, and NICs before any changes are made. `ReadOnly` blocks both PATH A and PATH B; `CanNotDelete` blocks PATH B. Aborts with a clear `Remove-AzResourceLock` instruction.
- **Ephemeral OS disk check** — detects `DiffDiskSettings.Option = Local` and aborts early; all subsequent steps require a standalone managed OS disk.
- **Unmanaged OS disk check** — detects `ManagedDisk = null` (classic VHD) and aborts, directing the operator to `Convert-AzVMManagedDisk`.
- **Subscription restriction check** — detects `NotAvailableForSubscription` restrictions on the target SKU before stopping the VM, rather than failing at resize/recreation time with a cryptic allocation error.
- **Max data disk count check** — aborts with a clear message if the VM currently has more data disks than the target size supports.
- **Max NIC count check** — aborts if the VM has more NICs than the target size allows.
- **Premium IO support check** — if the target size has `PremiumIO=False`, scans OS disk and all data disks for Premium SKUs and aborts before stopping the VM.
- **Write Accelerator support check** — warns (and asks to confirm) if the VM has Write Accelerator enabled on any disk but the target size does not support it.
- **Uniform VMSS member check (PATH B)** — detects Uniform-orchestration VMSS membership after path selection and aborts PATH B with guidance to use `-ForcePathA` or `Update-AzVmssInstance`; Flexible orchestration is fully supported.
- **Unmanaged data disk check (PATH B)** — detects VHD data disks before deletion; `New-AzVM` reattaches by managed disk ID, so unmanaged disks would cause a null-reference crash after the VM is already deleted.
- **Windows version Stage 2 RunCommand fallback** — when `imageReference` is absent or non-marketplace (custom images, SIG, RHEL-for-Windows), queries `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion` directly from the running OS and maps `CurrentBuildNumber` to a 4-digit Windows Server year. Skipped in DryRun mode (no side effects).
- **Windows Server 2019 + Shared Disk check** — Microsoft documents NVMe + Shared Disks as unsupported on WS2019. Fetches `MaxShares` for all data disks (via `Get-AzDiskBatch`) and aborts if any have `MaxShares > 1`. Uses `\d{4}` regex to safely extract the 4-digit year from the SKU name (the previous `[^0-9]` replace produced incorrect values like `"20162"` for `"2016-datacenter-server-core-g2"`).
- **VM-not-found recovery guidance** — when the VM does not exist on startup, checks whether the error is a 404 and, if so, outputs a recovery checklist for operators who interrupted a previous PATH B run between STEP 6B (delete) and STEP 7B (recreate).
- **`DiskControllerType` null handling** — VMs created before Azure began tracking this property (~2022) return `null`; the script now defaults to SCSI and logs a warning instead of crashing on a null comparison.

### Changed
- **PATH B description in `.SYNOPSIS`** updated to list all six cross-category combinations (not just three).
- **Path selection warning message** updated to mention all six combinations explicitly.

---

## [v2.2.0] — VM configuration capture completeness (STEP 5B)

### Added
The following properties are now captured before VM deletion and restored on the new VM:

- **OS disk caching** (`$vm.StorageProfile.OsDisk.Caching`) — passed to `Set-AzVMOSDisk -Caching`; previously the platform default was silently applied, which could change I/O behaviour on non-default settings.
- **OS disk `DeleteOption`** — captured in STEP 5B before STEP 6B forces it to `Detach`. Restored on `newVMConfig.StorageProfile.OsDisk.DeleteOption` after `Set-AzVMOSDisk` (which has no `-DeleteOption` parameter).
- **OS disk `WriteAcceleratorEnabled`** (M-series) — captured and re-applied to the new VM config.
- **Data disk `DeleteOption`** per disk — preserved on `$newVMConfig.StorageProfile.DataDisks[-1].DeleteOption` after `Add-AzVMDataDisk`; prevents scratch disks from silently reverting to `Detach`.
- **Data disk `WriteAcceleratorEnabled`** per disk — passed as `-WriteAccelerator` to `Add-AzVMDataDisk`.
- **NIC `DeleteOption`** per NIC — captured in `$_nics` (the STEP 5B snapshot of `$vm.NetworkProfile.NetworkInterfaces`) and preserved on `$newVMConfig.NetworkProfile.NetworkInterfaces[-1].DeleteOption` after `Add-AzVMNetworkInterface`. The `$_nics` variable is isolated from the STEP 6B `$vm` re-fetch: STEP 6B calls `Get-AzVM` into a new `$vm` object and sets all `DeleteOption` values to `Detach` on it. If STEP 7B iterated `$vm.NetworkProfile.NetworkInterfaces` instead of `$_nics`, every NIC's original `DeleteOption` would already be `Detach`, silently losing any `Delete` intent on disposable NICs.
- **Spot eviction policy** (`$vm.EvictionPolicy`) and **max price cap** (`$vm.BillingProfile.MaxPrice`) — restored on the new VM config for Spot/Low priority VMs.
- **Dedicated Host** (`$vm.Host.Id`) and **Host Group** (`$vm.HostGroup.Id`) — restored as `SubResource` objects; mutually exclusive, only one is applied.
- **Hibernation** (`AdditionalCapabilities.HibernationEnabled`) — written together with `UltraSSDEnabled` on the same `AdditionalCapabilities` object to prevent one from clearing the other.
- **Security profile** (`SecurityType`, `SecureBootEnabled`, `VTpmEnabled`, `EncryptionAtHost`) — fully restored on the new VM. Without this, TrustedLaunch VMs either fail to boot or silently lose their security posture; EncryptionAtHost causes a quiet security regression.
- **Capacity Reservation Group** — restored via `CapacityReservationProfile` so the reservation slot remains consumed.
- **UserData** (base64 payload for cloud-init) — restored directly on the new VM config.
- **Marketplace Plan** (`$vm.Plan`: Publisher, Product, Name, PromotionCode) — restored via `Set-AzVMPlan`; without it `New-AzVM` may fail or start without its billing plan.
- **`VmSizeProperties`** (custom reduced-vCPU / SMT-disabled config) — restored; a warning is logged if the target size differs from the source, since the values may need adjustment.
- **VM Gallery Applications** (`ApplicationProfile.GalleryApplications`) — restored via `Add-AzVmGalleryApplication` with `Order`, `TreatFailureAsDeploymentFailure`, and `ConfigurationReference`.
- **ScheduledEventsProfile** (graceful Spot termination window) — restored; without this, Spot VM evictions arrive with no warning window.
- **VMSS Flexible orchestration membership** (`VirtualMachineScaleSet.Id`) and **`PlatformFaultDomain`** — restored at creation time (cannot be applied via `Update-AzVM` after the fact). Load balancer backend pool membership is logged as a known limitation.
- **ExtendedLocation** (Azure Edge Zone) — passed as `@{ ExtendedLocation = ... }` to `New-AzVM`; without it the VM lands in the parent region, not the edge node.
- **OS disk caching splat** — `Set-AzVMOSDisk` now uses splatting (`$_osDiskSplat`) to pass `-Windows`/`-Linux` as a switch, preventing the "parameter set cannot be resolved" error when both are named explicitly.
- **NIC object pre-fetch in STEP 5B** — all NIC objects are fetched once with `Get-AzNICBatch` before deletion and reused in STEP 7B, avoiding N extra API calls in the NIC loop.
- **STEP 4B disk controller patch runs unconditionally** — unlike PATH A's STEP 3A (which skips the patch when the controller is already correct), STEP 4B always calls `Set-OSDiskControllerTypes` regardless of `$_controllerAlreadyCorrect`. After VM recreation the new VM object must carry the correct `diskControllerTypes` value; the REST PATCH is idempotent when patching to the same value and is always safe to run.
- **Boot diagnostics storage account RG lookup** — `Set-AzVMBootDiagnostic` requires `-ResourceGroupName`. The script now searches the subscription for the storage account to find its actual RG, preventing a silent fallback to managed storage when the account is in a different RG.
- **Snapshot name truncation** — Azure snapshot names have an 80-character limit. When the OS disk name is too long, the prefix is truncated and a warning is logged. Previously, long disk names silently caused `New-AzSnapshot` to fail.
- **Snapshot ZRS for zone-pinned VMs** — uses `Standard_ZRS` instead of `Standard_LRS` for VMs in availability zones, with automatic fallback to LRS if ZRS is unavailable in the region.
- **Backend pool detection** — STEP 5B fetches NIC IP configurations and warns if any NIC has LB or Application Gateway backend pool associations, noting that NIC-level associations are preserved on the NIC resource and survive recreation.
- **Azure Automanage detection** — checks for `Microsoft.Automanage/configurationProfileAssignments` and warns that PATH B removes the enrollment, with re-enrollment instructions.
- **TrustedLaunch PATH B warning** — explains that `Remove-AzVM` permanently destroys the vTPM state (BitLocker keys, FIDO2 keys, attestation certs), even though the security posture is restored on the new VM.
- **`$vm` re-fetch in STEP 5B** — re-reads the VM from ARM after deallocation to capture the settled state; the in-memory object from the initial fetch may reflect pre-deallocation transient properties.

### Changed
- **PATH B step numbering** reordered: snapshot (previously STEP 4B) moved to **STEP 3B** (before the disk patch) so the safety backup captures the disk in its original, unmodified state. Disk patch is now **STEP 4B**; VM config capture is **STEP 5B**; deletion is **STEP 6B**; recreation is **STEP 7B**.
- **DeleteOption verification** in STEP 6B now uses up to 3 retries with 10-second back-off instead of a fixed 30-second sleep, to handle ARM eventual-consistency more gracefully.
- **`imageReference` post-recreation note** — after `New-AzVM` succeeds, the script logs that Azure does not allow setting or patching `storageProfile.imageReference` on an existing VM (`PropertyChangeNotAllowed`), so the Portal's image field will appear blank after recreation. The source image info is preserved on the OS disk resource itself (in `creationData.imageReference`) and was logged in STEP 5B for reference.

---

## [v2.3.0] — Extension management (STEP 8B)

### Added
- **Extension pre-flight check (PATH B)** — enumerates all VM extensions before any changes are made and classifies each as `AUTO`, `MANUAL`, or `SKIP`. Operators are prompted to acknowledge MANUAL extensions before the VM is deleted, and the full list is shown in DryRun output.
- **`Get-ExtensionManualReason`** — returns a human-readable reason for each extension type that cannot be auto-reinstalled (ADE, CustomScript, ADDomainExtension, DSC, IaaSDiagnostics, ServiceFabricNode, VMAccess, DockerExtension), used in both the pre-flight report and STEP 8B.
- **`Test-ExtensionRequiresManual`** — centralises the "cannot auto-reinstall" predicate, including the KeyVault-without-MI edge case.
- **`$_azureManagedExtTypes` list** — extensions managed by Azure service planes (VMSnapshot, MDE.Windows/Linux, Azure Policy configuration, GuestAttestation) that re-deploy automatically and must be skipped in STEP 8B to avoid conflicting with their managing service.
- **`$_manualExtTypes` list** — extensions that always require manual reinstall due to protected settings or re-execution risk.
- **STEP 8B** — automatic reinstall of all non-manual, non-Azure-managed extensions via `Set-AzVMExtension`. Includes:
  - **KeyVaultForWindows/Linux** — installs without protected settings; warns about system-assigned MI principal ID change.
  - **SqlIaasAgent** — uses `New-AzSqlVM`/`Get-AzSqlVM` (Az.SqlVirtualMachine) instead of `Set-AzVMExtension`; re-links the surviving `SqlVirtualMachines` ARM resource or creates it with PAYG as a safe default.
  - **MicrosoftMonitoringAgent / OmsAgentForLinux** — retrieves the workspace key from the Log Analytics workspace via `Get-AzOperationalInsightsWorkspaceSharedKey` (Az.OperationalInsights), enabling fully automatic reinstall.
  - **AzureMonitorWindowsAgent / AzureMonitorLinuxAgent** — installs without protected settings; notes that DCR associations reference the VM resource ID and survive recreation.
  - **AADSSHLoginForLinux / AADLoginForWindows** — installs without protected settings; notes that AAD login RBAC is on the VM resource ID and is preserved.
- **`-SkipExtensionReinstall`** parameter — skips STEP 8B entirely; all extensions must be reinstalled manually.
- **`-SkipExtensions`** parameter — skips specific extensions by name (e.g. extensions managed by Azure Policy or a third-party platform that will re-deploy automatically).
- **`TypeHandlerVersion` null guard** — defaults to `'1.0'` when the version is null, preventing a parameter validation error.
- **`AutoUpgradeMinorVersion` / `EnableAutomaticUpgrade` version guard** — checks at runtime which parameters `Set-AzVMExtension` actually accepts in the installed Az.Compute version, preventing "parameter cannot be found" errors.
- **Extension post-validation** — 15 seconds after reinstall, calls `Get-AzVMExtension` and logs any extension not in `Succeeded` state as `ACTION REQUIRED`. Azure-managed, `SkipExtensions`, MMA/OMS (slow to provision), and KeyVault (RBAC not yet restored) extensions are excluded from this check.
- **Completion summary** shows extension count and STEP 8B reinstall status.

---

## [v2.4.0] — System-assigned managed identity RBAC (STEP 9B)

### Added
- **Pre-flight RBAC enumeration** — before any changes, enumerates direct RBAC role assignments for the system-assigned managed identity principal. Logged with scope and role name. If assignments are found and `-RestoreSystemAssignedRBAC` is not specified, the operator is prompted to confirm (or `-Force` auto-continues).
- **`$_preflightRbacAssignments` cache** — STEP 5B reuses the pre-flight results to write the export file without a redundant `Get-AzRoleAssignment` call.
- **`Restore-SystemAssignedRBACAssignments` function** — re-creates role assignments from the export file onto the new principal ID. Idempotent (pre-fetches existing assignments in one call, skips duplicates). Per-assignment failures are non-fatal; results written to `*-rbac-restore-results.json`. Handles the PS 5.1 bug where `ConvertTo-Json` serialises a single-item array as `{}` instead of `[{}]`.
- **`-RestoreSystemAssignedRBAC`** parameter — opt-in to automatic export and restore in STEP 9B.
- **STEP 9B** — runs after STEP 8B. Reads the new system-assigned principal ID (with a 20-second ARM-propagation retry), then calls `Restore-SystemAssignedRBACAssignments`. Results and failures are summarised in the log and completion block.
- **Export file** (`*-rbac-export.json`) written in STEP 5B with no-BOM UTF-8 so `ConvertFrom-Json` can read it back reliably in STEP 9B.
- **User-assigned MI advisory** — notes that user-assigned identity principal IDs are stable across VM recreation and require no RBAC re-assignment.
- **Completion RBAC summary** — reports restored / already-existed / failed counts and links to the results file.

---

## [v2.5.0] — TrustedLaunch support

### Added
- **TrustedLaunch / ConfidentialVM + NVMe pre-flight check** — detects `SecurityType = TrustedLaunch` or `ConfidentialVM` on a SCSI VM targeting NVMe. ConfidentialVM is a hard block (no workaround); TrustedLaunch aborts unless `-AllowTrustedLaunchDowngrade` is specified.
- **`-AllowTrustedLaunchDowngrade`** parameter — opts in to the temporary downgrade workflow with a detailed vTPM data-loss warning (BitLocker keys sealed to TPM, FIDO2 keys, attestation certs). Requires explicit confirmation (skipped with `-Force`).
- **STEP 2a** — while the VM is deallocated, nulls `SecurityProfile` via `Invoke-AzVMUpdate` to remove TrustedLaunch temporarily, lifting the Azure platform block on SCSI→NVMe conversion.
- **STEP 4Aa (PATH A)** — re-enables TrustedLaunch after resize, restoring `SecurityType`, `SecureBootEnabled`, `VTpmEnabled`, and `EncryptionAtHost` from pre-downgrade captured values. If this step fails, STEP 5A is suppressed so the operator can restore TrustedLaunch manually while the VM is still deallocated.
- **PATH B TrustedLaunch restore** — `$newVMConfig.SecurityProfile` is set from the pre-downgrade values captured in STEP 5B (overriding the STEP 2a-nulled ARM state). The new VM is born with a full TrustedLaunch posture; no extra `Update-AzVM` is needed.
- **`Write-TrustedLaunchRestoreNote` function** — emits the exact PowerShell commands to re-enable TrustedLaunch manually, logged at ERROR level on any error exit path reachable after STEP 2a. No-op when `$script:_needTrustedLaunchRestore` is `$false`.
- **`Write-VTPMDataLossWarning` function** — standard advisory about the fresh empty vTPM emitted at STEP 4Aa (PATH A) and STEP 7B (PATH B).
- **`$script:_needTrustedLaunchRestore` flag** — set after STEP 2a succeeds; cleared after STEP 4Aa or STEP 7B succeeds; read by the `finally` block to emit the restore note if the script exits unexpectedly between the two steps.
- **`$_isTrustedLaunchDowngrade` boolean** — pre-computed from `$AllowTrustedLaunchDowngrade -and $_secTypeForCheck -eq 'TrustedLaunch'`; used in DryRun, STEP 2a, STEP 4Aa, STEP 7B, and the completion block.
- **TrustedLaunch support check on target SKU** — when `-AllowTrustedLaunchDowngrade` is active, verifies the target size does not have `TrustedLaunchDisabled=True` before any changes are made.
- **Completion banner** distinguishes `Conversion complete (with warnings - TrustedLaunch NOT restored)` from normal `Conversion complete`.
- **`-AllowTrustedLaunchDowngrade` example** added to `.EXAMPLE` block.

---

## [v2.6.0] — Linux OS preparation improvements

### Changed
- **initrd check targets the running kernel** — `lsinitramfs` and `lsinitrd` now use `uname -r` to target the specific running kernel's initrd file, rather than a glob across all kernels. A non-existent initrd triggers a warning rather than a false-negative pass.
- **GRUB io_timeout handling** — now distinguishes three cases: already set to 240 (INFO), set to a different value (WARNING, not overwritten), and not set at all (ERROR, fixed when `-FixOperatingSystemSettings`). The `sed` commands use per-case patterns for both `GRUB_CMDLINE_LINUX` and `GRUB_CMDLINE_LINUX_DEFAULT`, handling the empty-value edge case correctly.
- **GRUB config path** — probes for the EFI grub.cfg path under `/boot/efi/EFI/` before falling back to the BIOS path, then `update-grub`. Gen2 Azure VMs use EFI; the previous hardcoded `/boot/grub2/grub.cfg` path was wrong for them.
- **fstab check extended** — in addition to `/dev/sd*` and SCSI paths, now also warns about raw `/dev/nvme*` paths in fstab. On v7+ sizes, disk-to-controller assignment changes silently when caching policy is changed, making raw NVMe paths unreliable. Also specifically calls out `/dev/sdb` entries (temp disk) as lines to remove rather than replace.
- **Flatcar support** — new `flatcar` distro case: NVMe drivers are compiled into the kernel; no initrd rebuild needed.
- **RHEL/Rocky/SLES `dracut` command** — now passes `--kver $(uname -r)` to rebuild only the running kernel's initrd.
- **Supported distro list** expanded in `case` — adds `fedora`, `mariner`, `azurelinux` alongside the existing `rhel|centos|rocky|almalinux|sles|suse|ol`.

### Added
- **`waagent.conf` ResourceDisk check** — after SCSI→NVMe conversion (or scsi-temp→diskless), `waagent` can no longer find `/dev/sdb`. If `ResourceDisk.Format=y` or `ResourceDisk.EnableSwap=y` is set in `/etc/waagent.conf`, waagent repeatedly fails and swap/temp-mount silently stops working. The check warns and instructs the operator to set these to `n`.
- **`azure-vm-utils` check and install** — checks whether the package is installed (via `azure-nvme-id`, `dpkg -l`, or `rpm -q`). Warns if absent with per-distro install commands. If `-FixOperatingSystemSettings` is specified, attempts `apt-get` / `dnf` / `zypper` install. Notes that `/dev/disk/azure/scsi1/lunX` symlinks stop working after NVMe conversion regardless of the package.
- **Linux NVMe completion advisory** — printed at script completion whenever a SCSI→NVMe conversion occurred. Explains the `/dev/disk/azure/scsi1/` path change, lists distributions where `azure-vm-utils` is pre-installed vs must be installed, and recommends `UUID=` or `/dev/disk/azure/data/by-lun/X` paths in fstab.
- **v7+ multi-controller NVMe advisory** — when the target size is v7 or later, explains that Azure distributes disks between a cached controller (nvme0) and an uncached controller (nvme1) based on per-disk caching policy. A caching policy change silently moves the disk to the other controller on next boot, making raw `/dev/nvme*nX` paths unreliable. Recommends `UUID=` or `by-lun/X` paths and stopping the VM before changing caching on NVMe.
- **Linux NVMe temp disk STEP 1c note** — adds a warning that NVMe temp disk support requires `waagent >= 2.8` or cloud-init; older agents look for `/dev/sdb` and fail silently.

---

## [v2.7.0] — DryRun mode (`-DryRun`)

### Added
- **`-DryRun`** parameter — runs all pre-flight checks (module, SKU, quota, lock, extension enumeration, RBAC detection) without making any changes to the VM or its resources. Exits with code 0 after printing a complete execution plan.
- **DryRun summary block** — lists:
  - VM identity, current and target size/controller/disk-arch.
  - Execution path and the reason it was selected.
  - Numbered steps that would be performed (including conditional steps: stornvme fix, pagefile migration, NVMe task install, TrustedLaunch downgrade/re-enable, snapshot, disk patch, config capture, VM deletion and recreation, extension reinstall, RBAC restore, snapshot cleanup).
  - Resources that would be modified, created, or deleted.
  - Full extension table with `AUTO` / `MANUAL` / `SKIP` classification.
  - System-assigned MI RBAC assignment count and restore status.
  - Pagefile warning if `-FixOperatingSystemSettings` is missing and would cause a real-run abort.
- **`AskToContinue` DryRun guard** — all confirmation prompts are suppressed in DryRun mode, preventing any interactive pause that would block non-interactive CI runs.
- **RunCommand skipped in DryRun** — `EnsureVMRunning` and `Invoke-AzVMRunCommand` are side effects; they are not called during a DryRun, so the Windows version Stage 2 fallback is also skipped with a clear note.
- **Pre-computed booleans before DryRun block** — `$_needWindowsNvmePrep`, `$_needLinuxNvmePrep`, `$_needNvmeTempDiskTask` defined after disk architecture is known so the DryRun summary and actual execution share the same conditions.
- **`-DryRun` example** added to `.EXAMPLE` block.

---

## [v2.8.0] — Operational robustness

### Added
- **NVMEDiskInitScriptLocation injection-safety check** — validates that the path contains no double-quote, semicolon, backtick, `$`, space, or newline characters before interpolating it into a RunCommand here-string. A malformed path could inject commands into the remote script.
- **Base64 encoding for embedded NVMe init script** — the `$nvmeInitScript` content is encoded as UTF-16LE Base64 and decoded on the remote VM, replacing the fragile `"'@" → "' @"` replacement. Eliminates the risk of script content accidentally terminating the outer here-string.
- **Post-creation power state verification** — after `New-AzVM`, calls `Get-AzVM -Status` to confirm the VM is in `PowerState/running` and logs a warning if it is not.
- **VMSS load balancer advisory in STEP 7B** — reminds the operator that backend pool memberships are not automatically restored after recreation and must be verified before returning the VM to service.
- **Pagefile script updated to `Get-CimInstance`** — replaces deprecated `Get-WmiObject` and `.Put()`/`.Delete()` COM methods with `Get-CimInstance`, `Invoke-CimMethod`, and `Remove-CimInstance`.
- **`stornvme` check updated** — now handles the case where the registry key does not exist at all (driver not installed), reporting `Start:ERROR (stornvme registry key not found)` instead of silently returning `Start:OK` on a null value.
- **`-IgnoreSKUCheck` name-based detection warnings** — when `-IgnoreSKUCheck` is active, warns that older sizes without a `d` in their name (e.g. B2ms, D2s_v3) are indistinguishable from diskless sizes by name alone and may be misclassified. Also warns if the target looks like a v6+ (NVMe-only) size but `-NewControllerType SCSI` was specified.
- **`-IgnoreOSCheck` documentation clarified** — specifies that STEP 1b (pagefile migration) and STEP 1c (NVMe temp disk task) are unaffected by this switch; only the NVMe driver checks in STEP 1 are skipped.
- **Completion rollback block** for PATH B now includes `-AllowTrustedLaunchDowngrade` rollback note (not needed for rollback since the restriction only applies to SCSI→NVMe).

---

## [v2.9.0] — Network pre-flight checks and backend pool awareness

### Added
- **Accelerated networking pre-flight check** — validates whether the target size supports `AcceleratedNetworkingEnabled` via `Get-SKUCapability`. When the target supports it and `-EnableAcceleratedNetworking` was not specified, the script fetches all NIC objects in one batch and warns for each NIC that has the feature currently disabled, with both a re-run instruction and a portal path. When `-EnableAcceleratedNetworking` is specified but PATH A is selected, a warning is emitted explaining that NIC properties are not changed on resize, with the manual `Set-AzNetworkInterface` command to use afterwards. When `-IgnoreSKUCheck` is active, `$_accelNetSupported` is set to `$false` and NICs are not polled.
- **Accelerated networking enforcement in STEP 7B** — when the target size does not support accelerated networking, any NIC with it enabled is updated via `Set-AzNetworkInterface` with `Invoke-AzWithRetry` before attachment; when `-EnableAcceleratedNetworking` was specified and the target supports it, all NICs are enabled.
- **Backend pool detection in STEP 5B** — after capturing the NIC list, the script inspects each NIC IP configuration for Load Balancer and Application Gateway backend pool associations. If any are found, a `WARNING` is logged per NIC, noting that these are NIC-level references that remain on the preserved NIC resource and should be verified in the Portal after recreation. Both standard Load Balancer (`LoadBalancerBackendAddressPools`) and Application Gateway (`ApplicationGatewayBackendAddressPools`) memberships are checked.
- **NIC batch reused from STEP 5B in STEP 7B** — the NIC object batch fetched for backend-pool detection in STEP 5B is stored in `$_nicObjects` and reused by the STEP 7B NIC attachment loop, avoiding duplicate API calls. If a NIC is absent from the cache (transient fetch failure), STEP 7B falls back to a fresh `Get-AzNetworkInterface` call for that NIC rather than crashing or silently operating on a null object.

---

## [v2.10.0] — RBAC pre-flight refactor

### Changed
- **`Export-SystemAssignedRBACAssignments` function removed** — this standalone export function was eliminated. Its role is replaced by the new pre-flight RBAC enumeration block, which runs before any VM changes are made and stores results in `$_preflightRbacAssignments` for later reuse.
- **RBAC enumeration moved to the pre-flight block** — system-assigned MI role assignments are now fetched immediately after path selection, before the VM is stopped. This means the operator is informed of what RBAC will break (and prompted to confirm) before any side effects occur, rather than discovering this mid-execution.
- **STEP 5B reuses pre-flight data** — when writing the RBAC export file, STEP 5B uses `$_preflightRbacAssignments` directly instead of calling `Get-AzRoleAssignment` a second time, eliminating a redundant API round-trip.

### Added
- **`$_preflightRbacFetchFailed` flag** — tracks whether the pre-flight `Get-AzRoleAssignment` call failed. If it did, STEP 5B marks the export as failed (`$_rbacExportFailed = $true`) and skips writing the export file; STEP 9B skips the restore with a clear log message; the completion summary reports the failure accurately.
- **Pre-flight RBAC confirmation prompt** — if assignments are found and `-RestoreSystemAssignedRBAC` was not specified, `AskToContinue` is called with the count of assignments that will not be auto-restored. Prompt is suppressed by `-Force` and skipped in `-DryRun` mode.
- **Manual restore instructions in pre-flight log** — when auto-restore is not requested and assignments are found, the log emits the exact two-step command sequence to obtain the new principal ID and re-create each assignment after recreation.
- **DryRun summary includes RBAC assignment count** — the assignment count discovered at pre-flight is shown in the DryRun execution plan next to the `[9B]` step, enabling operators to audit without running.

---

## [v2.11.0] — User-assigned managed identity distinction

### Added
- **`$_hasUserMI` flag** — set at startup alongside `$_hasSystemMI` by inspecting `$vm.Identity.UserAssignedIdentities.Count`. Available throughout all pre-flight sections and extension classification.
- **MI summary in STEP 5B** — the config-capture log now distinguishes four MI states: `SystemAssigned` (with old PrincipalId), `UserAssigned` (count, stable across recreation), `SystemAssigned + UserAssigned` (combined), and no identity. User-assigned identities include an explicit note that their principal IDs survive recreation and their RBAC assignments are unaffected.
- **STEP 6B user-assigned MI note** — immediately after logging the system-assigned identity outcome, a separate line confirms that user-assigned identity principal IDs are unchanged and RBAC on user-assigned identities is unaffected.
- **RBAC-aware KeyVault extension classification** — the extension pre-flight and STEP 8B reinstall logic now has three distinct paths for `KeyVaultForWindows` / `KeyVaultForLinux`: (1) no MI on VM → classified as `MANUAL` with a message to configure MI first; (2) user-assigned MI present → classified as `AUTO` with a note that Key Vault RBAC is preserved (user-assigned principal is stable); (3) system-assigned MI only → classified as `AUTO` with a note that RBAC must be updated for the new principal, referencing `-RestoreSystemAssignedRBAC` as the automated path.

---

## [v2.12.0] — Restore function robustness and PS5.1 JSON fixes

### Changed
- **`Restore-SystemAssignedRBACAssignments` — single pre-fetch for idempotency** — before iterating over assignments to restore, the function calls `Get-AzRoleAssignment -ObjectId $NewPrincipalId` once and builds an in-memory hash (`$existingKeys`) keyed on `Scope|RoleDefinitionId`. Each assignment is checked against this hash before calling `New-AzRoleAssignment`, avoiding N separate API calls and preventing duplicate-assignment errors on partial-failure reruns.
- **PS5.1 `ConvertTo-Json` empty-array serialization fix** — PS5.1 serializes empty arrays as `null` instead of `[]`. The results file writer now explicitly emits `'[]'` for any of the three result buckets (`Restored`, `AlreadyExisted`, `Failed`) that are empty, preventing `ConvertFrom-Json` failures when the completion summary re-reads the file.
- **PS5.1 `ConvertTo-Json` single-item serialization fix** — PS5.1 serializes a single-element array as a bare `{}` object instead of `[{}]`. The results file writer wraps each single-item `ConvertTo-Json` result in square brackets, ensuring the JSON stays an array regardless of item count.
- **PS5.1 `ConvertFrom-Json` null-injection filter in restore** — when reading the export file, `$null` items that PS5.1 may inject when deserializing a `'null'` JSON value are filtered out via `Where-Object { $_ -and $_.Scope -and $_.RoleDefinitionId }` before the restore loop.
- **Export and results files use no-BOM UTF-8** — both the `*-rbac-export.json` and `*-rbac-restore-results.json` files are written with `[System.IO.File]::WriteAllText` and `[System.Text.UTF8Encoding]::new($false)`, preventing the UTF-8 BOM that `Set-Content -Encoding UTF8` adds in PS5.1 from causing `ConvertFrom-Json` to fail with an unexpected character error on the leading `\ufeff`.

---

## [v2.13.0] — Extension post-validation RBAC awareness and STEP 9B reliability

### Changed
- **Extension post-validation excludes KeyVault extensions** — `KeyVaultForWindows` and `KeyVaultForLinux` are excluded from the post-STEP 8B provisioning state check. Because STEP 9B (RBAC restore) runs after STEP 8B, the Key Vault RBAC may not yet be in place when the check runs, causing a spurious `ACTION REQUIRED` for an extension that will work correctly once STEP 9B completes. A comment in the filter explains this ordering dependency explicitly.
- **Extension post-validation excludes MMA/OMS extensions** — `MicrosoftMonitoringAgent` and `OmsAgentForLinux` are excluded from the 15-second post-validation check because they regularly take longer than 15 seconds to fully provision, producing false `ACTION REQUIRED` noise.
- **STEP 9B ARM propagation retry** — after `New-AzVM`, the new system-assigned principal ID may not yet be visible via `Get-AzVM`. STEP 9B now retries once after a 20-second wait if the first `Get-AzVM` call returns a `null` `PrincipalId`, before giving up and logging a clear recovery instruction.
- **STEP 9B logs both old and new PrincipalId** — immediately before calling `Restore-SystemAssignedRBACAssignments`, the step logs `Old PrincipalId` and `New PrincipalId` for audit trail and manual recovery reference.
- **STEP 9B skip paths log clearly** — all four skip conditions emit their own distinct log line: export-failed-in-STEP-5B, `-RestoreSystemAssignedRBAC` not requested with or without assignments found, and no system-assigned identity on VM.

---

## [v2.14.0] — Completion summary RBAC outcomes and final hardening

### Added
- **Completion summary — full RBAC outcome matrix** — the completion block now handles seven distinct paths for the system-assigned MI RBAC section: (1) restore succeeded (results file present, zero failures); (2) restore partial (results file present, one or more failures); (3) results file unreadable (parse error); (4) restore results file absent despite `-RestoreSystemAssignedRBAC` (STEP 9B could not read new principal — fallback with old/new principal instructions); (5) export failed in STEP 5B; (6) restore not requested but assignments found (count + old principal + how to get new principal); (7) restore not requested and no direct assignments found. Each path is logged at the appropriate level (`IMPORTANT`, `WARNING`, or `INFO`) so the operator gets actionable output regardless of which failure mode occurred.
- **DryRun extension count — mutually exclusive bucket calculation** — the DryRun execution plan now computes `$_manualCount`, `$_azMgdCount`, `$_skipExtCount`, and `$_autoCount` in strict priority order (SkipExtensionReinstall → SkipExtensions → azure-managed → MANUAL → AUTO) so each extension is counted in exactly one bucket. Previously an extension matching both a MANUAL type and a `-SkipExtensions` name could be double-counted, making the auto-reinstall count go negative.

### Changed
- **REST API version for disk controller PATCH updated to `2025-01-02`** — `Set-OSDiskControllerTypes` now uses the `2025-01-02` ARM Compute API version, replacing the previous value and ensuring the `diskControllerTypes` property is present in the API contract for all currently available VM sizes.

---

## [v1.0.0] — Initial release

### Summary
Original script implementing the core SCSI ↔ NVMe conversion workflow:

- Two execution paths: PATH A (resize via `Update-AzVM`) and PATH B (VM recreation for Windows cross-category disk architecture changes).
- Three disk architecture categories: `scsi-temp`, `nvme-temp`, `diskless`.
- STEP 1: Windows `stornvme` driver check/fix and Linux initrd/GRUB check.
- STEP 1b: Pagefile migration from D:\ to C:\ when moving away from a SCSI temp disk.
- STEP 1c: NVMe temp disk startup script and Scheduled Task installation (single-disk and multi-disk striped Storage Pool support).
- STEP 2: VM deallocation.
- PATH A — STEP 3A: OS disk `diskControllerTypes` REST PATCH (skipped when controller is already correct); STEP 4A: `Update-AzVM` resize; STEP 5A: `Start-AzVM`.
- PATH B — STEP 4B: snapshot; STEP 5B: VM config capture (NICs, data disks, tags, identity, zones, license type, availability set, PPG, boot diagnostics, UltraSSD, priority); STEP 6B: `DeleteOption=Detach` verification and `Remove-AzVM`; STEP 7B: `New-AzVM` with full config restored; STEP 8B: snapshot cleanup.
- Pre-flight checks: Az module versions, Azure context, ADE (Linux only), VM generation (V1 block for NVMe), Windows version (marketplace imageReference only), SKU availability, zone compatibility, disk controller support, disk architecture detection, quota (family, regional, Spot — see below).
- Parameters: `ResourceGroupName`, `VMName`, `VMSize`, `NewControllerType`, `StartVM`, `WriteLogfile`, `IgnoreSKUCheck`, `IgnoreQuotaCheck`, `IgnoreWindowsVersionCheck`, `FixOperatingSystemSettings`, `IgnoreAzureModuleCheck`, `IgnoreOSCheck`, `SkipPagefileFix`, `ForcePathA`, `ForcePathB`, `KeepSnapshot`, `NVMEDiskInitScriptLocation`, `NVMEDiskInitScriptSkip`, `EnableAcceleratedNetworking`, `Force`, `SleepSeconds`.
- Logging: colour-coded `WriteLog` with INFO/WARNING/ERROR/IMPORTANT categories, optional log file, rollback commands in completion summary.

### Notable baseline behaviours present from v1.0.0

- **`DisplayBreakingChangeWarning` suppression** — at startup the script reads `Get-AzConfig -DisplayBreakingChangeWarning`, and if it was enabled, disables it for the duration of the run to prevent Az module deprecation noise from drowning out structured log output. The original value is restored unconditionally in the `finally` block regardless of how the script exits.

- **Controller/size already-correct early exit** — before any API calls, the script compares `$script:_originalController` and `$script:_originalSize` against the requested values. If both already match, it logs "nothing to do" and exits with code 0. If only the controller or only the size is already correct, a warning is logged and the redundant change is skipped for that dimension.

- **`-StartVM` is PATH A only** — the `-StartVM` switch controls whether the VM is started after a PATH A resize. It has no effect on PATH B: `New-AzVM` always starts the VM immediately on creation and there is no deferred-start option. Pipeline callers that specify `-StartVM` expecting to control startup behaviour on PATH B should be aware the flag is silently ignored on that path.

- **Windows NVMe temp disk completion advisory** — when STEP 1c installs the `AzureNVMeTempDiskInit` scheduled task (i.e. `$_needNvmeTempDiskTask` is true), the completion block prints a detailed advisory explaining that D:\ is initialised on every boot by the task, that the pagefile remains on C:\ and must be reconfigured manually if desired on D:\, and that any other startup task depending on D:\ should add the `Wait-ForDrive-D.ps1.snippet.txt` snippet at its top. The snippet content is printed inline for immediate reference.

- **vCPU quota check** — before stopping the VM, the script calls `Get-AzVMUsage` for the target region and verifies headroom across three independent buckets, all crediting source vCPUs that will be freed on deallocation:
  - **VM family quota** — checks `$targetSKU.Family`. When source and target share the same family the source vCPUs are credited as freed capacity. Logs used/limit/freed/available and the signed net change. Calls `Stop-Script` if headroom is insufficient with a link to the Azure quota portal.
  - **Spot / `lowPriorityCores` quota** — Spot and Low priority VMs consume the shared `lowPriorityCores` bucket instead of their family quota. The `Priority` field is checked for both `"Spot"` and `"Low"` — `"Low"` is the legacy pre-GA name for Spot priority and must be handled so that VMs created before Spot reached GA are correctly routed to the shared quota bucket rather than the family quota check. Source cores are credited when the source is also Spot/Low. The family check is skipped entirely for these VMs.
  - **Regional total quota** — checks the subscription-wide `cores` limit. Source vCPUs are always credited regardless of family or priority match.
  - Each bucket skips gracefully with a `WARNING` if the usage entry is absent from the API response. If `Get-AzVMUsage` itself fails, `AskToContinue` prompts the operator; suppressed by `-Force`. Skipped entirely when `-IgnoreQuotaCheck` or `-IgnoreSKUCheck` is specified, each with its own `WARNING`.

- **`_needPagefileFix` scsi-temp-only condition** — pagefile migration is only triggered when the source disk architecture is `scsi-temp`. When the source is `nvme-temp` the disk is raw and unformatted so a pagefile could never have been placed on D:\; when the source is `diskless` D:\ never existed. Only `scsi-temp` sources require migration.

- **D:\ non-standard content check** — the pagefile RunCommand script scans D:\ and filters against a known-safe allowlist (`pagefile.sys`, `swapfile.sys`, `hiberfil.sys`, `Temp`, `Windows`, `CollectGuestLogsTemp`, `DATALOSS_WARNING_README.txt`). If any item outside this list is found, each path is logged and `AskToContinue` warns the operator that the content will be lost after the resize.

- **`New-AzVM` verbose streaming** — `New-AzVM` is called with `-Verbose 4>&1 | Tee-Object` so Azure's real-time provisioning messages are captured and written line-by-line to the log as `[Azure] <message>` entries during the ~2–3 minute creation window, rather than showing a silent gap until the call returns.
