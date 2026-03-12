<#
.SYNOPSIS
    Convert Azure Virtual Machines between SCSI and NVMe disk controller,
    with full support for Windows VMs migrating from a size with local temp disk
    to a size without (e.g. E8bds_v5 -> E8as_v7), which requires VM recreation.

.DESCRIPTION
    Combines NVMe conversion with the Microsoft-documented migration path for
    Windows VMs moving between local-disk and diskless VM sizes.

    Two execution paths:

    PATH A  -  RESIZE  (Update-AzVM)
      Used when: Linux VM (always), or Windows VM staying in the same disk category
                 (disk->disk or diskless->diskless). Can be forced with -ForcePathA.
      Steps: OS prep -> stop -> update OS disk capabilities -> resize -> start.

    PATH B  -  RECREATE  (snapshot -> new VM)
      Used when: Windows VM where source and target are in different disk architecture
                 categories. Azure blocks direct resize for all six cross-category
                 combinations on Windows (platform restriction):
                   - SCSI temp disk <-> NVMe temp disk  (e.g. E8bds_v5 <-> E8ads_v7)
                   - Any size with temp disk  <-> diskless  (e.g. E8ds_v5 <-> E8as_v5, E8ads_v7 <-> E8as_v7)
                   - Diskless <-> any size with temp disk
                 Linux VMs are not affected and always use PATH A.

      Disk architecture categories:
                   scsi-temp : MaxResourceVolumeMB > 0  (reliable for all sizes, incl. older
                               sizes like B2ms/D2s_v3 that predate the 'd' naming convention)
                   nvme-temp : MaxResourceVolumeMB = 0 AND name has 'd'  (v6 and v7)
                   diskless  : MaxResourceVolumeMB = 0 AND name has no 'd'

      PATH B is triggered whenever source and target are in different categories.
      Can be forced with -ForcePathB (e.g. to test recreation on a Windows VM
      that would otherwise qualify for PATH A).
      Steps: NVMe driver prep (if needed) -> pagefile migration (if needed)
             -> stop -> snapshot OS disk (safety backup, BEFORE any modification)
             -> patch OS disk controller type -> capture VM config
             -> set DeleteOption=Detach on all resources -> delete VM shell
             -> recreate VM reusing original OS disk + NICs + data disks
             -> reinstall extensions -> delete snapshot.

    Step overview  (naming convention: no suffix = shared; uppercase A/B suffix = PATH A/B):
      [shared]  STEP 1    OS prep: Windows stornvme driver  /  Linux initrd + GRUB + azure-vm-utils
      [shared]  STEP 1b   Pagefile migration D:\ -> C:\  (cross-category only: effectively PATH B)
      [shared]  STEP 1c   Install NVMe temp disk startup task  (cross-category only: effectively PATH B)
      [shared]  STEP 2    Stop VM (deallocate)
      [shared]  STEP 2a   TrustedLaunch downgrade to Standard  (only with -AllowTrustedLaunchDowngrade)
      [PATH A]  STEP 3A   Patch OS disk diskControllerTypes  (REST API)
      [PATH A]  STEP 4A   Resize VM: new size + controller  (Update-AzVM)
      [PATH A]  STEP 4Aa  Re-enable TrustedLaunch  (only with -AllowTrustedLaunchDowngrade)
      [PATH A]  STEP 5A   Start VM
      [PATH B]  STEP 3B   Snapshot OS disk  (safety backup, before any changes)
      [PATH B]  STEP 4B   Patch OS disk diskControllerTypes  (REST API)
      [PATH B]  STEP 5B   Capture full VM configuration
      [PATH B]  STEP 6B   Set DeleteOption=Detach on all resources, then delete VM shell
      [PATH B]  STEP 7B   Recreate VM  (New-AzVM; restores TrustedLaunch via SecurityProfile)
      [PATH B]  STEP 8B   Reinstall VM extensions
      [PATH B]  STEP 9B   Restore system-assigned managed identity RBAC assignments
      [PATH B]  STEP 10B  Delete snapshot  (unless -KeepSnapshot)

    Path selection logic:
      Auto   : PATH B when Windows + source and target are in different disk architecture
               categories (scsi-temp, nvme-temp, or diskless). Linux always uses PATH A.
      -ForcePathA : Always use resize, even when the script would select PATH B.
                    Use only if you are certain the platform allows it.
      -ForcePathB : Always use recreation, even when PATH A would suffice.

.PARAMETER ResourceGroupName
    Name of the Resource Group where the VM is located.
.PARAMETER VMName
    Name of the VM to convert.
.PARAMETER NewControllerType
    Target disk controller type: NVMe or SCSI. Default: NVMe.
.PARAMETER VMSize
    Target VM size (e.g. Standard_E8as_v7). Required.
.PARAMETER StartVM
    Start the VM automatically after conversion (resize path only;
    recreation path always starts the VM via New-AzVM).
.PARAMETER WriteLogfile
    Write a log file to the current directory.
.PARAMETER IgnoreSKUCheck
    Skip SKU availability and capability checks.
.PARAMETER IgnoreQuotaCheck
    Skip the vCPU quota check. Use when you have confirmed quota is sufficient
    or when the quota API is not returning accurate results.
.PARAMETER IgnoreWindowsVersionCheck
    Skip the Windows OS version check (>= 2019 required for NVMe).
.PARAMETER FixOperatingSystemSettings
    Automatically fix OS settings via RunCommand:
      Windows:
        - Set stornvme driver to Boot start, remove StartOverride key.
        - Migrate pagefile from D:\ to C:\ when moving away from a SCSI temp disk.
      Linux:
        - Rebuild initrd to include the NVMe driver
          (update-initramfs on Debian/Ubuntu; dracut on RHEL/Rocky/SLES).
        - Update GRUB to add nvme_core.io_timeout=240 kernel parameter.
        - Install azure-vm-utils package (provides /dev/disk/azure/data/by-lun/X
          NVMe udev symlinks to replace the SCSI waagent /dev/disk/azure/scsi1/lunX
          symlinks that become inactive after SCSI -> NVMe conversion).
          Already pre-installed on marketplace images: Ubuntu 22.04/24.04/25.04,
          Azure Linux 2.0, Fedora 42, Flatcar. No-op if already present.
          Must be installed on: RHEL/Rocky, SLES, Debian, older Ubuntu.
    Without this switch the script checks and warns but does not fix.
.PARAMETER IgnoreAzureModuleCheck
    Skip the Az module version check.
.PARAMETER IgnoreOSCheck
    Skip the NVMe driver compatibility checks in STEP 1 (no RunCommand for stornvme/Linux driver prep).
    STEP 1b (pagefile migration) and STEP 1c (NVMe temp disk task install) are not affected by this
    switch and will still run when required. Use when the VM agent is unavailable or unreachable.
.PARAMETER SkipPagefileFix
    Skip pagefile migration even when a disk mismatch is detected.
    Use when the pagefile was already migrated manually.
.PARAMETER ForcePathA
    Force PATH A (resize via Update-AzVM) even when the script would normally select
    PATH B. On Windows, Azure blocks direct resize between disk and diskless sizes
    in both directions. Use only if you are certain the platform allows it.

.PARAMETER ForcePathB
    Force PATH B (VM recreation) even when PATH A would normally be used.
    Useful for testing, or for cases where you prefer recreation over resize.

.PARAMETER KeepSnapshot
    Keep the OS disk snapshot after recreation (useful as a rollback point).
    Default: snapshot is deleted once the new VM is created successfully.
.PARAMETER NVMEDiskInitScriptLocation
    Folder on the VM where NVMeTempDiskInit.ps1 and Wait-ForDrive-D.ps1.snippet.txt
    are written during STEP 1c. Default: C:\AdminScripts.
    Must be a plain Windows path (no quotes, semicolons, backticks, or newlines);
    the value is interpolated directly into a script string sent via RunCommand.
.PARAMETER NVMEDiskInitScriptSkip
    Skip installation of the NVMe temp disk startup script and scheduled task (STEP 1c).
    Use when the task is already present from a previous run, or when you prefer to
    manage temp disk initialization yourself.
.PARAMETER EnableAcceleratedNetworking
    Enable Accelerated Networking on all NICs, if the target VM size supports it.
    Has no effect if the target size does not support it (a warning is logged instead).
    Use this when the target size supports Accelerated Networking and you want it
    enabled automatically during the conversion.
.PARAMETER Force
    Suppress ALL interactive confirmation prompts throughout the script.
    Use in automated/unattended pipelines where interactive prompts are not possible.
    This includes the VM deletion confirmation (PATH B), the ASR replication break
    warning, the MANUAL extension acknowledgment, OS check errors, pagefile data-loss
    warnings, NVMe task install failures, and quota API failures. In each case
    -Force logs the condition as a WARNING and proceeds automatically.
.PARAMETER SkipExtensionReinstall
    Skip automatic reinstallation of VM extensions after recreation (PATH B).
    Extensions requiring protected settings (e.g. AzureDiskEncryption, CustomScript)
    are always skipped regardless of this flag and must be reinstalled manually.
    Use when you manage extensions via a deployment pipeline or prefer manual control.
.PARAMETER SkipExtensions
    One or more extension NAMES (not types) to skip during automatic reinstallation
    in STEP 8B (PATH B only). Use this for extensions that are pushed and managed by
    an external system such as Azure Policy, Microsoft Defender for Cloud, or a third-
    party management platform — these will re-appear automatically after recreation and
    should not be reinstalled by the script.

    Example: extensions deployed by Azure Policy (e.g. QualysAgent, Tanium) will be
    re-deployed when the Policy engine next evaluates compliance (~15 minutes after the
    VM is running). Attempting to install them via Set-AzVMExtension may conflict with
    the managing policy or install with incorrect settings.

    Accepts the extension Name as shown in the pre-flight log and in Get-AzVMExtension
    (the -Name field, e.g. 'QualysAgent', not the ExtensionType).

    To skip all extensions, use -SkipExtensionReinstall instead.
.PARAMETER RestoreSystemAssignedRBAC
    Enable automatic export and restore of system-assigned managed identity RBAC
    role assignments during PATH B (VM recreation).

    Default behaviour (without this switch):
      The script always detects whether the VM has a system-assigned managed identity
      and enumerates its direct role assignments before anything is deleted. If any
      assignments are found you will be asked to confirm before proceeding (skipped
      with -Force). No export file is created and no automatic restore is performed.
      Re-assign the RBAC roles manually after recreation using the new principal ID.

    With -RestoreSystemAssignedRBAC:
      1. Saves all role assignments for the old principal to *-rbac-export.json before
         deleting the VM.
      2. After recreation, reads the new system-assigned principal ID and restores each
         assignment. Results are written to *-rbac-restore-results.json.
      The prompt shown in default mode is suppressed because the operator has
      explicitly opted into automatic restore.

    Note: user-assigned managed identities are NOT affected by this switch. Their
    principal IDs are stable across VM recreation and their RBAC assignments survive
    the delete/recreate cycle unchanged.
.PARAMETER DryRun
    Show exactly what would happen without making any changes to the VM or its resources.
    All pre-flight checks (module, quota, SKU, extension enumeration) still run so you
    get a complete picture. Exits with code 0 after printing the plan.
    Note: named DryRun instead of WhatIf to avoid collision with PowerShell's built-in
    common parameter (which is wired to SupportsShouldProcess and behaves differently).
.PARAMETER AllowTrustedLaunchDowngrade
    Allow SCSI -> NVMe conversion of a TrustedLaunch VM by automatically performing a
    temporary SecurityType downgrade (TrustedLaunch -> Standard) before the conversion
    and re-enabling TrustedLaunch (Standard -> TrustedLaunch) afterwards.

    Why this is needed: Azure blocks SCSI -> NVMe conversion on TrustedLaunch VMs at
    the platform level. Temporarily removing TrustedLaunch lifts this restriction.

    Sequence (PATH A):
      STEP 2a  Downgrade: Update-AzVM -SecurityType Standard  (VM deallocated)
      STEP 3A  OS disk diskControllerTypes patch (now allowed)
      STEP 4A  Resize to NVMe size
      STEP 4Aa Re-enable: Update-AzVM -SecurityType TrustedLaunch (VM still deallocated)
      STEP 5A  Start VM  (boots with full TrustedLaunch posture restored;
               SKIPPED and left deallocated if STEP 4Aa failed - restore TrustedLaunch manually first)

    Sequence (PATH B):
      STEP 2a  Downgrade: Update-AzVM -SecurityType Standard  (VM deallocated, precaution)
      STEP 3B-6B  Snapshot -> patch OS disk -> capture config -> delete VM
      STEP 7B  New-AzVM with SecurityType=TrustedLaunch restored from captured config
               (new VM is created with full TrustedLaunch posture, no extra Update-AzVM needed)

    DATA LOSS WARNING - the following vTPM-stored state is permanently destroyed
    at STEP 2a and CANNOT be recovered:
      - BitLocker keys sealed to the vTPM (disk may enter BitLocker recovery on first boot
        if no alternative protector exists; standard recovery keys are unaffected).
      - FIDO2 / Windows Hello for Business keys bound to the vTPM.
      - Attestation certificates and any secrets sealed to the vTPM state.
    The TrustedLaunch security posture (SecureBoot + vTPM chip) IS fully restored after
    the conversion. Only the vTPM-stored credentials are lost and must be re-provisioned.

    Not applicable to ConfidentialVMs: they cannot be converted to NVMe regardless.
    Use -DryRun first to review the exact steps before committing.

.PARAMETER SleepSeconds
    Seconds to wait before starting the VM after resize. Default: 15.

.EXAMPLE
    # Full conversion: NVMe + resize to diskless + auto pagefile fix
    .\AzureVM-NVME-and-localdisk-Conversion.ps1 `
        -ResourceGroupName "myRG" -VMName "myVM" `
        -NewControllerType NVMe -VMSize "Standard_E8as_v7" `
        -FixOperatingSystemSettings -IgnoreSKUCheck `
        -StartVM -WriteLogfile

.EXAMPLE
    # Rollback: revert to SCSI + original size (resize path)
    .\AzureVM-NVME-and-localdisk-Conversion.ps1 `
        -ResourceGroupName "myRG" -VMName "myVM" `
        -NewControllerType SCSI -VMSize "Standard_E8bds_v5" `
        -StartVM -WriteLogfile

.EXAMPLE
    # Preview what would happen without making any changes (DryRun mode)
    .\AzureVM-NVME-and-localdisk-Conversion.ps1 `
        -ResourceGroupName "myRG" -VMName "myVM" `
        -NewControllerType NVMe -VMSize "Standard_E8as_v7" `
        -FixOperatingSystemSettings -WriteLogfile -DryRun

.EXAMPLE
    # Unattended pipeline run: suppress all prompts, write log, keep snapshot as rollback point
    .\AzureVM-NVME-and-localdisk-Conversion.ps1 `
        -ResourceGroupName "myRG" -VMName "myVM" `
        -NewControllerType NVMe -VMSize "Standard_E8as_v7" `
        -FixOperatingSystemSettings -StartVM -WriteLogfile `
        -Force -KeepSnapshot

.EXAMPLE
    # Linux VM: NVMe conversion with OS prep (initrd rebuild + GRUB + azure-vm-utils)
    .\AzureVM-NVME-and-localdisk-Conversion.ps1 `
        -ResourceGroupName "myRG" -VMName "myLinuxVM" `
        -NewControllerType NVMe -VMSize "Standard_E8as_v7" `
        -FixOperatingSystemSettings -StartVM -WriteLogfile

.EXAMPLE
    # TrustedLaunch VM: convert SCSI -> NVMe (temporarily disables TrustedLaunch, auto re-enables)
    # WARNING: vTPM state (BitLocker keys sealed to TPM, FIDO2 keys) will be permanently lost.
    # Re-provision any vTPM-bound credentials after the VM restarts.
    .\AzureVM-NVME-and-localdisk-Conversion.ps1 `
        -ResourceGroupName "myRG" -VMName "myTLVM" `
        -NewControllerType NVMe -VMSize "Standard_E8as_v7" `
        -AllowTrustedLaunchDowngrade -FixOperatingSystemSettings -StartVM -WriteLogfile

.NOTES
    Version: 2.14.0

    Module requirements (verified at runtime unless -IgnoreAzureModuleCheck is specified):
      Az.Compute   >= 7.2.0   (DiskControllerType, SecurityProfile, Add-AzVmGalleryApplication,
                                VmSizeProperties, HibernationEnabled, ScheduledEventsProfile,
                                ExtendedLocation - all require SDK model properties introduced
                                across Az.Compute 5.7-7.x. Tested with 11.3.0+.)
      Az.Accounts  >= 2.13.0  (Get-AzAccessToken, Invoke-AzRestMethod, Get-AzConfig, Update-AzConfig.
                                The script handles both String and SecureString Token, so it works
                                with both Az.Accounts < 4.0 and >= 4.0.)
      Az.Resources >= 6.0     (Get-AzResourceLock, Get-AzResource - basic cmdlets stable since 1.x;
                                6.0 ensures compatibility with ARM API changes through 2024.)
      Az.Network   >= 5.0     (Get-AzNetworkInterface, Set-AzNetworkInterface with
                                EnableAcceleratedNetworking property - stable since early versions.)
    Optional modules (loaded automatically if present; fall back to MANUAL if absent):
      Az.OperationalInsights  - required for MMA/OMS extension workspace key lookup
      Az.SqlVirtualMachine    - required for SqlIaasAgent extension registration

    PowerShell compatibility: Windows PowerShell 5.1 and PowerShell 7+.

.LINK
    https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-interface
    https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-faqs
    https://learn.microsoft.com/en-us/azure/virtual-machines/azure-vms-no-temp-disk
    https://github.com/Azure/azure-vm-utils
#>

[CmdletBinding()]
param (
    # ── Identity: what to convert ──
    [Parameter(Mandatory=$true)][string]  $ResourceGroupName,
    [Parameter(Mandatory=$true)][string]  $VMName,
    [Parameter(Mandatory=$true)][string]  $VMSize,
    [ValidateSet("NVMe","SCSI")]
    [string]  $NewControllerType = "NVMe",

    # ── Execution mode ──
    [switch]  $DryRun,
    [switch]  $Force,
    [switch]  $StartVM,
    [switch]  $WriteLogfile,

    # ── OS preparation ──
    [switch]  $FixOperatingSystemSettings,
    [switch]  $SkipPagefileFix,
    [string]  $NVMEDiskInitScriptLocation = "C:\AdminScripts",
    [switch]  $NVMEDiskInitScriptSkip,

    # ── Path control ──
    [switch]  $ForcePathA,
    [switch]  $ForcePathB,

    # ── Security ──
    [switch]  $AllowTrustedLaunchDowngrade,

    # ── Networking ──
    [switch]  $EnableAcceleratedNetworking,

    # ── Recreation (PATH B) ──
    [switch]  $KeepSnapshot,
    [switch]  $SkipExtensionReinstall,
    [string[]]$SkipExtensions = @(),
    [switch]  $RestoreSystemAssignedRBAC,

    # ── Skip / ignore checks (ordered least → most impactful) ──
    [switch]  $IgnoreAzureModuleCheck,
    [switch]  $IgnoreQuotaCheck,
    [switch]  $IgnoreSKUCheck,
    [switch]  $IgnoreWindowsVersionCheck,
    [switch]  $IgnoreOSCheck,

    # ── Misc ──
    [ValidateRange(0, 300)]
    [int]     $SleepSeconds = 15
)

$ErrorActionPreference = "Stop"

# Normalise controller type casing  -  ValidateSet is case-insensitive on input
# but preserves what the user typed, which breaks -eq comparisons later.
$NewControllerType = switch ($NewControllerType.ToUpper()) {
    "NVME" { "NVMe" }
    "SCSI" { "SCSI" }
    default { $NewControllerType }
}

##############################################################################################################
# Logging initialisation
##############################################################################################################

$script:_starttime = Get-Date
$script:_logfile   = "AzureVM-NVME-and-localdisk-Conversion-$($VMName)-$((Get-Date).ToString('yyyyMMdd-HHmmss')).log"
$script:_skuCache  = @{}   # location -> SKU object[]  cache for Get-RegionVMSkus

##############################################################################################################
# Helper functions
#   Group 1 : Logging and user interaction  (WriteLog, AskToContinue, Stop-Script)
#   Group 2 : Pure utilities (no Azure calls, no side effects)  (Get-ArmName/RG, Get-AzNICBatch, Get-AzDiskBatch, Get-SKUCapability, CheckModule)
#   Group 3 : VM state management  (WaitForVMPowerState, EnsureVMRunning)
#   Group 4 : RunCommand pipeline  (Invoke-RunCommand, ParseAndLogOutput, Invoke-CheckedRunCommand)
#   Group 5 : Azure update operations  (Invoke-AzWithRetry, Invoke-AzVMUpdate, Get-RegionVMSkus, Set-OSDiskControllerTypes)
#   Group 6 : Domain-specific helpers  (Get-DiskArchitecture, Get-VMResourcesWithBadDeleteOption,
#              Restore-SystemAssignedRBACAssignments, Write-TrustedLaunchRestoreNote, Write-VTPMDataLossWarning)
#
# Note: Get-ExtensionManualReason and Test-ExtensionRequiresManual are defined inline just before
# the EXTENSION CHECK pre-flight section. They depend on $_manualExtTypes, a pre-flight variable
# that does not exist at script startup, so they cannot be hoisted into the groups above.
##############################################################################################################

# Fatal-error exception class used by Stop-Script and AskToContinue.
# Defined here, before the functions that throw it, so the reader sees the type
# before its first use at Stop-Script / AskToContinue.
# A distinct class lets the top-level catch block distinguish expected script
# termination (message already logged by Stop-Script) from unhandled exceptions
# (which the catch block logs itself).
class AzVMFatalError : System.Exception {
    AzVMFatalError([string]$msg) : base($msg) {}
}

# ── Group 1: Logging and user interaction ────────────────────────────────────────────────────

function WriteLog {
    [CmdletBinding()]
    param(
        [string]$Message,
        [ValidateSet("INFO","WARNING","ERROR","IMPORTANT")][string]$Category = "INFO"
    )
    $colors   = @{ INFO="Green"; WARNING="Yellow"; ERROR="Red"; IMPORTANT="Cyan" }
    $prefixes = @{ INFO="INFO      - "; WARNING="WARNING   - "; ERROR="ERROR     - "; IMPORTANT="IMPORTANT - " }
    $offset   = ((Get-Date) - $script:_starttime).ToString("hh\:mm\:ss")
    $entry    = "$offset - $($prefixes[$Category])$Message"
    Write-Host $entry -ForegroundColor $colors[$Category]
    if ($WriteLogfile -and $script:_logfile) {
        # Use StreamWriter with explicit UTF-8-without-BOM encoding.
        # Out-File -Encoding utf8 writes a UTF-8 BOM in PS5.1, which trips up
        # grep, Azure Monitor log ingestion, and most log-parsing tools.
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::AppendAllText($script:_logfile, "$entry`n", $utf8NoBom)
    }
}

function AskToContinue {
    param([string]$Message)
    # Internal $Force guard: prevents missed checks at every call site when new prompts are added.
    # All callers may rely on this function to honour -Force automatically.
    if ($Force) {
        WriteLog "$Message  (auto-continuing, -Force specified)" "WARNING"
        return
    }
    # Internal $DryRun guard: DryRun must never pause for input because it makes no changes.
    # Any call site reachable before the DryRun summary block exits is automatically suppressed
    # here, without requiring every call site to add its own -DryRun gate.
    if ($DryRun) {
        WriteLog "$Message  (skipping prompt - DryRun mode)" "WARNING"
        return
    }
    WriteLog $Message "IMPORTANT"
    $answer = Read-Host "Continue? (Y/N)"
    if ($answer -notin @("Y","y")) {
        WriteLog "Script aborted by user." "ERROR"
        throw [AzVMFatalError]::new("Script aborted by user.")
    }
}


function Stop-Script {
    # Terminates the script with a fatal error.
    # Logs $Message (when provided), then throws AzVMFatalError so:
    #   - The top-level catch block catches it cleanly and exits with code 1.
    #   - The finally block (BCW restore, TrustedLaunch note) always runs.
    #   - PowerShell pipeline callers see a terminating error ($? = $false)
    #     rather than having the entire host process killed by exit 1.
    # For the abort-after-prompt path in AskToContinue, AzVMFatalError is
    # thrown directly (message already logged) rather than calling Stop-Script.
    param([string]$Message = '')
    if ($Message) { WriteLog $Message "ERROR" }
    throw [AzVMFatalError]::new($Message)
}

# ── Group 2: Pure utilities ──────────────────────────────────────────────────────────────────

function Get-ArmName([string]$ResourceId) {
    # Extracts the resource name (last segment) from an ARM resource ID.
    return $ResourceId.Split('/')[-1]
}

function Get-ArmRG([string]$ResourceId) {
    # Extracts the resource group name (5th segment, index 4) from an ARM resource ID.
    return $ResourceId.Split('/')[4]
}


function Get-AzNICBatch {
    # Fetches multiple NIC objects: parallel on PS7+, sequential on PS5.1.
    # Returns a hashtable keyed by NIC resource ID.
    # Call once per loop context instead of one Get-AzNetworkInterface per NIC,
    # which is expensive on VMs with many NICs (parallel saves N * ~1s round trips).
    # NIC refs are pre-extracted to plain strings before the parallel block to avoid
    # Azure SDK object serialisation issues across PS7 runspace boundaries
    # (same approach as Get-AzDiskBatch).
    param([object[]]$NicRefs, [int]$ThrottleLimit = 5)
    $result = @{}
    if (-not $NicRefs -or $NicRefs.Count -eq 0) { return $result }
    $nicList = @($NicRefs | ForEach-Object { [PSCustomObject]@{ Id = $_.Id } })
    if ($PSVersionTable.PSVersion.Major -ge 7 -and $nicList.Count -gt 1) {
        WriteLog "  Fetching $($nicList.Count) NIC(s) in parallel (PS7, throttle=$ThrottleLimit)..."
        $parallelOut = $nicList | ForEach-Object -Parallel {
            [PSCustomObject]@{
                Id  = $_.Id
                Obj = Get-AzNetworkInterface -Name ($_.Id.Split('/')[-1]) `
                          -ResourceGroupName ($_.Id.Split('/')[4]) -ErrorAction SilentlyContinue
            }
        } -ThrottleLimit $ThrottleLimit
        foreach ($r in $parallelOut) { $result[$r.Id] = $r.Obj }
        # Completeness check: warn for any NIC that came back $null (fetch failed or resource not found).
        foreach ($n in $nicList) {
            if (-not $result.ContainsKey($n.Id) -or $null -eq $result[$n.Id]) {
                WriteLog "  WARNING: NIC '$($n.Id.Split('/')[-1])' could not be fetched (parallel). Status checks for this NIC may be inaccurate." "WARNING"
            }
        }
    } else {
        foreach ($n in $nicList) {
            $result[$n.Id] = Get-AzNetworkInterface `
                -Name ($n.Id.Split('/')[-1]) `
                -ResourceGroupName ($n.Id.Split('/')[4]) `
                -ErrorAction SilentlyContinue
            if ($null -eq $result[$n.Id]) {
                WriteLog "  WARNING: NIC '$($n.Id.Split('/')[-1])' could not be fetched. Status checks for this NIC may be inaccurate." "WARNING"
            }
        }
    }
    return $result
}

function Get-AzDiskBatch {
    # Fetches multiple managed disk objects: parallel on PS7+, sequential on PS5.1.
    # Input: array of DataDisk references from $vm.StorageProfile.DataDisks.
    # Returns: hashtable keyed by ManagedDisk.Id -> disk object ($null if fetch failed).
    # Only managed disks (those with a non-null ManagedDisk.Id) are included;
    # unmanaged (VHD) disks are silently skipped and will not appear in the result.
    # Azure SDK objects can lose properties when serialised across PS7 parallel runspace
    # boundaries, so we pre-extract Name and Id into plain PSCustomObjects before
    # entering the parallel block.
    param([object[]]$DataDiskRefs, [int]$ThrottleLimit = 5)
    $result = @{}
    $managed = @($DataDiskRefs |
        Where-Object { $_.ManagedDisk -and $_.ManagedDisk.Id } |
        ForEach-Object { [PSCustomObject]@{ Name = $_.Name; Id = $_.ManagedDisk.Id } })
    if ($managed.Count -eq 0) { return $result }
    if ($PSVersionTable.PSVersion.Major -ge 7 -and $managed.Count -gt 1) {
        WriteLog "  Fetching $($managed.Count) data disk(s) in parallel (PS7, throttle=$ThrottleLimit)..."
        $parallelOut = $managed | ForEach-Object -Parallel {
            [PSCustomObject]@{
                Id  = $_.Id
                Obj = Get-AzDisk -Name $_.Name -ResourceGroupName ($_.Id.Split('/')[4]) -ErrorAction SilentlyContinue
            }
        } -ThrottleLimit $ThrottleLimit
        foreach ($r in $parallelOut) { $result[$r.Id] = $r.Obj }
        # Completeness check: warn for any disk that came back $null (fetch failed or resource not found).
        foreach ($d in $managed) {
            if (-not $result.ContainsKey($d.Id) -or $null -eq $result[$d.Id]) {
                WriteLog "  WARNING: Disk '$($d.Name)' could not be fetched (parallel). Status checks for this disk may be inaccurate." "WARNING"
            }
        }
    } else {
        foreach ($d in $managed) {
            $result[$d.Id] = Get-AzDisk -Name $d.Name `
                -ResourceGroupName ($d.Id.Split('/')[4]) -ErrorAction SilentlyContinue
            if ($null -eq $result[$d.Id]) {
                WriteLog "  WARNING: Disk '$($d.Name)' could not be fetched. Status checks for this disk may be inaccurate." "WARNING"
            }
        }
    }
    return $result
}

function Get-SKUCapability {
    # Returns a single capability value from a VM SKU object, or $null if SKU is null or
    # the capability is absent.
    #   ($sku.Capabilities | Where-Object { $_.Name -eq "XXX" }).Value
    param($SKU, [string]$CapabilityName)
    if (-not $SKU) { return $null }
    return ($SKU.Capabilities | Where-Object { $_.Name -eq $CapabilityName }).Value
}

function CheckModule {
    # Verifies that a required Az module is installed and meets the minimum version.
    # Calls Stop-Script (fatal) if the module is absent or too old, so callers need
    # no error handling. Defined here (Group 2) rather than at the MODULE CHECK call
    # site so all helper functions are grouped together at the top of the script.
    param([string]$Name, [version]$MinVersion)
    $found = Get-Module -ListAvailable -Name $Name
    if (-not $found) {
        Stop-Script "Module '$Name' not installed. Run: Install-Module -Name $Name -Force"
    }
    if ($MinVersion -and (@($found | Where-Object { $_.Version -ge $MinVersion }).Count -eq 0)) {
        Stop-Script "Module '$Name' requires version >= $MinVersion. Run: Update-Module -Name $Name"
    }
    WriteLog "Module '$Name' OK (required >= $MinVersion)."
}

# ── Group 3: VM state management ─────────────────────────────────────────────────────────────

function WaitForVMPowerState {
    param(
        [string]$ExpectedState,
        [int]$TimeoutSeconds = 300,
        [int]$PollInterval   = 15
    )
    WriteLog "Waiting for VM power state: '$ExpectedState' (timeout: ${TimeoutSeconds}s)..."
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        try {
            $status = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status -ErrorAction SilentlyContinue
            if ($status) {
                $power = ($status.Statuses | Where-Object { $_.Code -like 'PowerState*' } | Select-Object -First 1).Code
                if ($power -eq $ExpectedState) {
                    WriteLog "VM reached power state: $ExpectedState"
                    return $true
                }
                WriteLog "  Current: $power  -  waiting..."
            }
        } catch {
            WriteLog "  Error retrieving status: $_  -  retrying..." "WARNING"
        }
        Start-Sleep -Seconds $PollInterval
    }
    WriteLog "Timeout waiting for power state '$ExpectedState'." "ERROR"
    return $false
}

function EnsureVMRunning {
    try {
        $s = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status -ErrorAction Stop
        $p = ($s.Statuses | Where-Object { $_.Code -like 'PowerState*' } | Select-Object -First 1).Code
        if ($p -ne "PowerState/running") {
            WriteLog "VM is not running ($p)  -  starting VM for RunCommand..."
            Start-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction Stop | Out-Null
            if (-not (WaitForVMPowerState -ExpectedState "PowerState/running" -TimeoutSeconds 360)) {
                WriteLog "VM could not be started." "ERROR"
                Stop-Script
            }
        }
    } catch {
        WriteLog "Error ensuring VM is running: $_" "ERROR"
        Stop-Script
    }
}

# ── Group 4: RunCommand pipeline ─────────────────────────────────────────────────────────────

function Invoke-RunCommand {
    param(
        [string]$ScriptString,
        [string]$CommandId   = "RunPowerShellScript",
        [string]$Description = "RunCommand"
    )
    WriteLog "Executing RunCommand: $Description..."
    try {
        $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VMName -CommandId $CommandId -ScriptString $ScriptString

        # RunCommand returns Value[0]=StdOut and Value[1]=StdErr (identified by Code field).
        # Both must be checked separately: StdErr from an unhandled exception does NOT start
        # with "ERROR", so merging them causes ParseAndLogOutput to silently classify the
        # exception dump as INFO with errorCount=0.
        $stdOut = (($result.Value | Where-Object { $_.Code -like '*StdOut*' } |
                    ForEach-Object { $_.Message }) -join "`n")
        $stdErr = (($result.Value | Where-Object { $_.Code -like '*StdErr*' } |
                    ForEach-Object { $_.Message }) -join "`n")

        # Surface any StdErr content immediately as a warning so it appears in the log
        # even before ParseAndLogOutput runs.
        if ($stdErr -and $stdErr.Trim()) {
            WriteLog "  RunCommand StdErr [$Description]:" "WARNING"
            foreach ($line in ($stdErr -split "`n")) {
                $line = $line.Trim(); if (-not $line) { continue }
                WriteLog "  OS(err) > $line" "WARNING"
            }
        }

        return ($stdOut -split "`n")
    } catch {
        WriteLog "Error executing RunCommand ($Description): $_" "ERROR"
        throw
    }
}

function ParseAndLogOutput {
    param([string[]]$Lines)
    $errorCount = 0
    foreach ($line in $Lines) {
        $line = $line.Trim()
        if (-not $line) { continue }
        # Match bare "ERROR"/"WARNING" (PS pagefile script) and bracketed "[ERROR]"/"[WARNING]"
        # (bash scripts). Without the \[? prefix, all [ERROR] lines from Linux bash are
        # silently classified as INFO and never increment $errorCount.
        $lvl = if ($line -match "^\[?ERROR")       { "ERROR"   }
               elseif ($line -match "^\[?WARNING")  { "WARNING" }
               else                                { "INFO"    }
        WriteLog "  OS > $line" $lvl
        if ($lvl -eq "ERROR") { $errorCount++ }
    }
    return $errorCount
}

function Invoke-CheckedRunCommand {
    # Runs a RunCommand script, parses its output with ParseAndLogOutput, and handles
    # errors uniformly with the Force / AskToContinue pattern:
    #   $out = Invoke-RunCommand; $errors = ParseAndLogOutput; if errors: ask/force
    # Used by: stornvme fix, Linux driver prep, NVMe startup task install.
    # Not used for the pagefile block, which has an additional $pfWarn check path
    # that makes it structurally different.
    # Returns the error count (0 = clean run) so callers can branch on success.
    param(
        [Parameter(Mandatory)][string]$ScriptString,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$ErrorPrompt,
        [string]$CommandId = "RunPowerShellScript"
    )
    $out    = Invoke-RunCommand -ScriptString $ScriptString -Description $Description -CommandId $CommandId
    $errors = ParseAndLogOutput -Lines $out
    if ($errors -gt 0) {
        if (-not $Force) { AskToContinue $ErrorPrompt }
        else { WriteLog "$ErrorPrompt  -  proceeding (-Force specified)." "WARNING" }
    }
    return $errors
}

# ── Group 5: Azure update operations ─────────────────────────────────────────────────────────


function Invoke-AzWithRetry {
    # Wraps an Azure API call with exponential back-off retry for transient errors.
    # Retries on HTTP 429 (ARM throttling / Too Many Requests), 409 (Conflict /
    # concurrent update), 500 / 503 (transient service errors), and any message
    # matching 'RetryableError'. Non-retryable errors are re-thrown immediately.
    # Use this for write operations (Update-AzVM, Remove-AzVM, New-AzVM, New-AzSnapshot,
    # Set-AzNetworkInterface, New-AzRoleAssignment, Invoke-RestMethod disk patches).
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string]$Description  = 'Azure API call',
        [int]$MaxAttempts     = 3,
        [int]$InitialDelaySec = 5
    )
    $delaySec = $InitialDelaySec
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return (& $ScriptBlock)
        } catch {
            $errMsg     = $_.Exception.Message
            $statusCode = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
            $isRetryable = ($errMsg    -match '429|Too Many Requests|RetryableError|Conflict|ServiceUnavailable|InternalServerError') `
                        -or ($statusCode -in @(409, 429, 500, 503))
            if ($isRetryable -and $attempt -lt $MaxAttempts) {
                WriteLog "  $Description - attempt $attempt/$MaxAttempts failed (retryable): $errMsg  -  retrying in ${delaySec}s..." "WARNING"
                Start-Sleep -Seconds $delaySec
                $delaySec = [math]::Min($delaySec * 2, 60)   # exponential back-off, max 60 s
            } else {
                throw   # non-retryable or max attempts reached - propagate to caller
            }
        }
    }
}

function Invoke-AzVMUpdate {
    # Centralises the repetitive Get-AzVM -> modify -> Update-AzVM pattern.
    # Accepts a scriptblock that receives $vm and modifies its properties in-place.
    # PowerShell objects are reference types, so property assignments inside the
    # scriptblock are visible to the caller without needing explicit return values.
    #
    # Returns the Update-AzVM result object so callers can inspect StatusCode if needed.
    # Logs a WARNING when StatusCode is not 'OK' so callers don't need to check unless
    # they want to treat it as an error (e.g. STEP 4A does; STEP 2a/4Aa don't need to).
    param(
        [Parameter(Mandatory)][scriptblock]$Modify,
        [string]$Description = 'Update-AzVM'
    )
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
    & $Modify $vm
    $result = Invoke-AzWithRetry -Description 'Update-AzVM' -ScriptBlock { Update-AzVM -ResourceGroupName $ResourceGroupName -VM $vm }
    if ($result.StatusCode -and $result.StatusCode -ne 'OK') {
        WriteLog "  $Description`: unexpected status '$($result.StatusCode)'" "WARNING"
    }
    return $result
}

function Get-RegionVMSkus {
    # Returns all VM SKUs for a region using Get-AzComputeResourceSku -Location.
    # The -Location parameter filters server-side to one region, returning ~400-500
    # VM sizes in 2-5 seconds.
    #
    # The raw REST SKUs API ($filter=location+resourceType) does NOT reliably honour its
    # filters: in practice it returns the full global catalog (~63,000 entries) and ignores
    # the location and resourceType conditions. Iterating that list twice (once per size)
    # takes 2+ minutes. Get-AzComputeResourceSku -Location avoids this entirely.
    #
    # Results are cached per region. Because both source and target sizes are typically in
    # the same region, the second lookup is a free cache hit.
    #
    # Returns an array of SKU objects. Callers filter by .Name for the specific size.
    param([string]$Location)

    if ($script:_skuCache.ContainsKey($Location)) {
        return $script:_skuCache[$Location]
    }

    WriteLog "Retrieving VM SKUs for '$Location'..."
    $allSkus = @(Get-AzComputeResourceSku -Location $Location -ErrorAction Stop |
                 Where-Object { $_.ResourceType -eq 'virtualMachines' })
    WriteLog "  Retrieved $($allSkus.Count) VM SKUs for '$Location'."

    $script:_skuCache[$Location] = $allSkus
    return $allSkus
}

function Set-OSDiskControllerTypes {
    param([string]$DiskName, [string]$DiskResourceGroup, [string]$ControllerTypes)

    # Use the script-scoped context captured at startup (Get-AzContext is expensive; the context
    # does not change mid-run under normal circumstances). Falls back to a fresh Get-AzContext
    # call if the script-scoped value is missing (e.g. function called before script start).
    $_ctx = if ($script:_azContext) { $script:_azContext } else { Get-AzContext }
    if (-not $_ctx) { throw "No Azure context. Run Connect-AzAccount first." }
    $_armBase    = ($_ctx.Environment.ResourceManagerUrl).TrimEnd('/')
    $diskUrl     = "$_armBase/subscriptions/$($_ctx.Subscription.Id)" +
                   "/resourceGroups/$DiskResourceGroup/providers/Microsoft.Compute/disks/$DiskName" +
                   "?api-version=2025-01-02"
    $body = @{ properties = @{ supportedCapabilities = @{ diskControllerTypes = $ControllerTypes } } } |
            ConvertTo-Json -Depth 5 -Compress
    WriteLog "Patching OS disk '$DiskName': diskControllerTypes = '$ControllerTypes'..."

    try {
        # Do NOT append a trailing '/' to the ResourceUrl. Some identity providers and
        # sovereign cloud endpoints treat 'https://management.azure.com' and
        # 'https://management.azure.com/' as different audiences, causing a token-scope
        # mismatch that fails the REST call with a 401.
        $tokenObj = Get-AzAccessToken -ResourceUrl $_armBase -ErrorAction Stop
    } catch {
        WriteLog "Failed to retrieve Azure access token: $_" "ERROR"
        throw
    }

    # Az.Accounts 3.x / Az 14+ returns Token as SecureString everywhere
    # (interactive, CI/CD pipelines, Azure Automation, Cloud Shell).
    # PowerShell 7+ Invoke-RestMethod natively accepts -Authentication Bearer -Token <SecureString>,
    # so the token is never materialised as a plaintext CLR string in memory.
    # PowerShell 5.1 does not support -Authentication Bearer; we must marshal to string.
    if ($PSVersionTable.PSVersion.Major -ge 7 -and $tokenObj.Token -is [System.Security.SecureString]) {
        WriteLog "  Using PS7 native SecureString bearer auth (token not materialised as plaintext)."
        Invoke-AzWithRetry -Description 'PATCH diskControllerTypes (PS7)' -ScriptBlock { Invoke-RestMethod -Uri $diskUrl -Method PATCH -Authentication Bearer -Token $tokenObj.Token -ContentType 'application/json' -Body $body | Out-Null }
    } else {
        # PS 5.1 path: materialise token to string only when unavoidable
        $rawToken = $tokenObj.Token
        if ($rawToken -is [System.Security.SecureString]) {
            $ptr      = [System.Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemUnicode($rawToken)
            $rawToken = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($ptr)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeCoTaskMemUnicode($ptr)
        }
        try {
            $headers = @{ 'Content-Type' = 'application/json'; 'Authorization' = "Bearer $rawToken" }
            Invoke-AzWithRetry -Description 'PATCH diskControllerTypes (PS5)' -ScriptBlock { Invoke-RestMethod -Uri $diskUrl -Method PATCH -Headers $headers -Body $body | Out-Null }
        } finally {
            # Clear the variable references so the plaintext token string does not linger
            # in the PowerShell variable scope. Note: .NET strings are immutable and managed
            # by the GC, so this does NOT guarantee the bytes are wiped from process memory.
            # For true zero-on-free, the PS7 SecureString path above should be used.
            $rawToken = $null
            $headers  = $null
        }
    }
    WriteLog "OS disk updated."
}

# ── Group 6: Domain-specific helpers ─────────────────────────────────────────────────────────

function Get-DiskArchitecture {
    # Returns one of three disk architecture categories for a given VM size:
    #   'scsi-temp' : SCSI-based local temp disk. Detected by MaxResourceVolumeMB > 0.
    #                 Covers all sizes that have a local disk, including older sizes like B2ms,
    #                 D2s_v3, E4s_v3 that predate the 'd' naming convention, as well as modern
    #                 sizes like E8bds_v5, E8ds_v5 that do use the 'd' flag.
    #   'nvme-temp' : NVMe-based local temp disk (v6/v7 only). MaxResourceVolumeMB = 0 in the API
    #                 (Azure reports 0 because the disk is presented raw/unformatted on each boot),
    #                 but the size name contains 'd' (e.g. E8ads_v7, E8bds_v6).
    #                 Windows cannot use this for pagefile without extra configuration.
    #   'diskless'  : No local temp disk. MaxResourceVolumeMB = 0 AND no 'd' in name.
    #
    # PATH B (VM recreation) is required whenever source and target are in DIFFERENT categories.
    # This restriction applies to WINDOWS ONLY  -  Linux VMs always use PATH A regardless of category.
    param([string]$SizeName, $SKU)

    $_apiValue  = $null
    $_apiHasDisk = $false
    if ($SKU) {
        $_apiValue   = Get-SKUCapability $SKU "MaxResourceVolumeMB"
        $_apiHasDisk = ($null -ne $_apiValue -and [int]$_apiValue -gt 0)
    }

    # Name parsing  -  'd' in capability letters means local disk (SCSI or NVMe depending on generation)
    $_nameHasDisk = $false
    if ($SizeName -match '_[A-Z]+\d+([a-z]+)_v\d+') {
        $_nameHasDisk = ($Matches[1] -like '*d*')
    }

    # Determine category:
    #   API > 0              -> scsi-temp  (reliable for all sizes, including older ones like B2ms,
    #                          D2s_v3, E4s_v3 that predate the 'd' naming convention entirely)
    #   API = 0, name has d  -> nvme-temp  (v6/v7: API reports 0 but disk exists as raw NVMe)
    #   API = 0, no d        -> diskless   (no local disk at all)
    #
    # The 'd' in the name is ONLY used to distinguish nvme-temp from diskless when API = 0.
    # It is NOT used to detect disk presence for older sizes, where the API value is authoritative.
    if ($_apiHasDisk) {
        $_category = 'scsi-temp'   # API confirms SCSI temp disk (all generations, all naming styles)
    } elseif ($_nameHasDisk) {
        $_category = 'nvme-temp'   # API = 0 but name has 'd' -> v6/v7 NVMe temp disk (raw on each boot)
    } else {
        $_category = 'diskless'    # API = 0 and no 'd' in name -> truly diskless
    }

    WriteLog "  $SizeName  -  MaxResourceVolumeMB='$_apiValue', name-has-d=$_nameHasDisk -> category: $_category"
    return $_category
}

function Get-VMResourcesWithBadDeleteOption {
    # Returns a list of VM resources (OS disk, data disks, NICs) where DeleteOption != 'Detach'.
    # Used in STEP 6B to verify that all resources are safe before Remove-AzVM.
    # Accepts the VM object directly to avoid an extra Get-AzVM call from the caller.
    param($VMObject)
    $items = @()
    if ($VMObject.StorageProfile.OsDisk.DeleteOption -ne "Detach") {
        $items += "OS disk '$($VMObject.StorageProfile.OsDisk.Name)' (DeleteOption=$($VMObject.StorageProfile.OsDisk.DeleteOption))"
    }
    foreach ($dd in $VMObject.StorageProfile.DataDisks) {
        if ($dd.DeleteOption -ne "Detach") {
            $items += "Data disk '$($dd.Name)' LUN $($dd.Lun) (DeleteOption=$($dd.DeleteOption))"
        }
    }
    foreach ($nic in $VMObject.NetworkProfile.NetworkInterfaces) {
        if ($nic.DeleteOption -ne "Detach") {
            $items += "NIC '$(Get-ArmName $nic.Id)' (DeleteOption=$($nic.DeleteOption))"
        }
    }
    return $items
}

# Note: Export-SystemAssignedRBACAssignments was removed in v2.10.0.
# RBAC assignment enumeration was moved to the pre-flight block (before any VM changes)
# so the operator can be informed early and confirm/deny proceeding. STEP 5B now writes
# the export file directly from $_preflightRbacAssignments without a redundant API call.

function Restore-SystemAssignedRBACAssignments {
    # Re-creates role assignments from an export file onto a new system-assigned principal.
    # Idempotent: existing assignments are detected and skipped rather than re-created,
    # so the function is safe to call multiple times (e.g. after a partial failure).
    # Per-assignment failures are non-fatal: they are collected into the results file so
    # the operator can see exactly what needs manual follow-up.
    # Returns a hashtable with keys 'Restored', 'AlreadyExisted', 'Failed' (arrays).
    param(
        [Parameter(Mandatory)][string]$NewPrincipalId,
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$ResultsPath
    )
    $result = @{ Restored = @(); AlreadyExisted = @(); Failed = @() }

    if (-not (Test-Path $InputPath)) {
        WriteLog "  RBAC restore: export file '$InputPath' not found  -  skipping." "WARNING"
        return $result
    }
    try {
        $raw = Get-Content -Path $InputPath -Raw -ErrorAction Stop
        $assignments = @($raw | ConvertFrom-Json)
    } catch {
        WriteLog "  RBAC restore: could not read '$InputPath': $_  -  skipping." "WARNING"
        return $result
    }
    # Filter out any $null items that PS5.1 ConvertFrom-Json may inject when
    # deserializing a 'null' JSON value (can occur if the export file was written
    # with an older PS version and contained an empty array serialized as 'null').
    $assignments = @($assignments | Where-Object { $_ -and $_.Scope -and $_.RoleDefinitionId })
    if ($assignments.Count -eq 0) {
        WriteLog "  RBAC restore: no valid assignments in export file  -  nothing to restore."
        return $result
    }

    # Pre-fetch all current assignments for the new principal once, then check in-memory.
    # Avoids N separate Get-AzRoleAssignment API calls (one per assignment to restore).
    WriteLog "  Fetching existing role assignments for new principal '$NewPrincipalId'..."
    $existingAssignments = @(Get-AzRoleAssignment -ObjectId $NewPrincipalId -ErrorAction SilentlyContinue)
    $existingKeys = @{}
    foreach ($e in $existingAssignments) {
        $existingKeys["$($e.Scope)|$($e.RoleDefinitionId)"] = $true
    }

    WriteLog "  Restoring $($assignments.Count) role assignment(s) to new principal '$NewPrincipalId'..."
    foreach ($a in $assignments) {
        try {
            # Idempotency check: in-memory lookup against pre-fetched assignments
            $key = "$($a.Scope)|$($a.RoleDefinitionId)"
            if ($existingKeys.ContainsKey($key)) {
                WriteLog "    Already exists : '$($a.RoleDefinitionName)' on '$($a.Scope)'"
                $result.AlreadyExisted += $a
                continue
            }
            Invoke-AzWithRetry -Description "New-AzRoleAssignment ($($a.RoleDefinitionName))" -ScriptBlock { New-AzRoleAssignment -ObjectId $NewPrincipalId -Scope $a.Scope -RoleDefinitionId $a.RoleDefinitionId -ErrorAction Stop | Out-Null }
            WriteLog "    Restored       : '$($a.RoleDefinitionName)' on '$($a.Scope)'" "INFO"
            $result.Restored += $a
        } catch {
            WriteLog "    FAILED         : '$($a.RoleDefinitionName)' on '$($a.Scope)': $_" "WARNING"
            $result.Failed += $a
        }
    }

    # Write results file for audit - operator can verify what was restored and what needs follow-up.
    # Use a JSON string built via individual ConvertTo-Json calls to avoid the PS5.1 bug where
    # ConvertTo-Json serializes empty arrays as 'null' rather than '[]'.
    $_rRestored = if ($result.Restored.Count -gt 0) { $result.Restored | ConvertTo-Json -Depth 5 -Compress } else { '[]' }
    $_rExisted  = if ($result.AlreadyExisted.Count -gt 0) { $result.AlreadyExisted | ConvertTo-Json -Depth 5 -Compress } else { '[]' }
    $_rFailed   = if ($result.Failed.Count -gt 0) { $result.Failed | ConvertTo-Json -Depth 5 -Compress } else { '[]' }
    # Wrap single-item ConvertTo-Json results (PS5.1 gives {} instead of [{}]) in brackets
    if ($result.Restored.Count -eq 1)      { $_rRestored = "[$_rRestored]" }
    if ($result.AlreadyExisted.Count -eq 1) { $_rExisted  = "[$_rExisted]"  }
    if ($result.Failed.Count -eq 1)         { $_rFailed   = "[$_rFailed]"   }
    $_resultsJson = @"
{
  "NewPrincipalId": "$NewPrincipalId",
  "Restored": $_rRestored,
  "AlreadyExisted": $_rExisted,
  "Failed": $_rFailed
}
"@
    # Use WriteAllText with a no-BOM UTF-8 encoder.
    # Set-Content -Encoding UTF8 writes a UTF-8 BOM in PS5.1; the leading \ufeff makes
    # ConvertFrom-Json fail when this results file is re-read during completion reporting.
    [System.IO.File]::WriteAllText($ResultsPath, $_resultsJson, [System.Text.UTF8Encoding]::new($false))
    WriteLog "  RBAC restore results written to '$ResultsPath'."
}

function Write-TrustedLaunchRestoreNote {
    # Emits a log entry with exact PowerShell commands to restore TrustedLaunch manually.
    # Two modes controlled by -AsReminder:
    #
    #   Default (error-path mode):
    #     Called from every error exit path reachable after STEP 2a, and from the finally block.
    #     Emits ERROR-level output so the instruction is prominent and captured in the log file.
    #     Safe to call unconditionally: returns immediately when _needTrustedLaunchRestore is $false.
    #     For PATH B: _needTrustedLaunchRestore is cleared after Remove-AzVM, so this is a no-op
    #     once the VM has been deleted (TrustedLaunch is embedded in $newVMConfig for STEP 7B).
    #
    #   -AsReminder (post-downgrade mode):
    #     Called immediately after STEP 2a succeeds, before _needTrustedLaunchRestore is set.
    #     Emits WARNING-level output as a proactive reminder that re-enable is still pending.
    #     Callers must check _isTrustedLaunchDowngrade themselves; this mode has no guard.
    #
    # Why WriteLog and not Write-Host:
    #   Write-Host only outputs to the console. When operators investigate failures via the log
    #   file, the restore instructions would be invisible. WriteLog writes to both, ensuring
    #   the actionable commands are always captured in the audit trail.
    param([switch]$AsReminder)
    if (-not $AsReminder -and -not $script:_needTrustedLaunchRestore) { return }
    $cat  = if ($AsReminder) { 'WARNING' } else { 'ERROR' }
    $head = if ($AsReminder) { 'REMINDER: TrustedLaunch re-enable is still pending (automatic)' } else { 'ACTION REQUIRED: TrustedLaunch was NOT re-enabled' }
    $ctx  = if ($AsReminder) { '  If this script exits unexpectedly before re-enable, restore manually:' } else { '  Re-enable manually while the VM is still DEALLOCATED:' }
    WriteLog "" 
    WriteLog "  ============================================================" $cat
    WriteLog "  $head" $cat
    if (-not $AsReminder) {
        WriteLog "  The VM is in Standard security mode (no TrustedLaunch)." $cat
    }
    WriteLog $ctx $cat
    WriteLog "    `$vm = Get-AzVM -ResourceGroupName '$ResourceGroupName' -Name '$VMName'" $cat
    WriteLog "    `$vm.SecurityProfile = [Microsoft.Azure.Management.Compute.Models.SecurityProfile]@{" $cat
    WriteLog "        SecurityType     = 'TrustedLaunch'" $cat
    WriteLog "        EncryptionAtHost = `$$_origEncryptionAtHost" $cat
    WriteLog "        UefiSettings     = [Microsoft.Azure.Management.Compute.Models.UefiSettings]@{" $cat
    WriteLog "            SecureBootEnabled = `$$_origSecureBoot; VTpmEnabled = `$$_origVTpm }}" $cat
    WriteLog "    Update-AzVM -ResourceGroupName '$ResourceGroupName' -VM `$vm" $cat
    WriteLog "  Then: Start-AzVM -ResourceGroupName '$ResourceGroupName' -Name '$VMName'" $cat
    WriteLog "  ============================================================" $cat
    WriteLog "" 
}

function Write-VTPMDataLossWarning {
    # Standard vTPM data-loss advisory emitted after TrustedLaunch is restored with a fresh,
    # empty vTPM (STEP 4Aa in PATH A, STEP 7B in PATH B). Centralised here to guarantee
    # consistent wording across all call sites.
    WriteLog "  A fresh, empty vTPM has been provisioned. The previous vTPM state is gone." "WARNING"
    WriteLog "  Actions required after the VM boots:" "WARNING"
    WriteLog "    - If BitLocker used TPM-only protector: have the BitLocker recovery key ready;" "WARNING"
    WriteLog "      the disk will enter recovery mode on first boot." "WARNING"
    WriteLog "    - Re-provision any FIDO2 / Windows Hello for Business keys." "WARNING"
    WriteLog "    - Re-provision any attestation certificates or vTPM-sealed secrets." "WARNING"
}


##############################################################################################################
# SCRIPT START
##############################################################################################################

WriteLog "=======================================================" "IMPORTANT"
WriteLog " AzureVM-NVME-and-localdisk-Conversion.ps1  v2.14.0" "IMPORTANT"
WriteLog "=======================================================" "IMPORTANT"
if ($WriteLogfile) {
    WriteLog "Log file: $(Resolve-Path -Path '.' -ErrorAction SilentlyContinue)\$script:_logfile" "IMPORTANT"
}
WriteLog "Parameters:"
foreach ($key in $MyInvocation.BoundParameters.Keys) {
    WriteLog "  $key -> $((Get-Variable -Name $key -ErrorAction SilentlyContinue).Value)"
}

$_bcw = Get-AzConfig -DisplayBreakingChangeWarning | Select-Object -First 1
$_bcwWasEnabled = ($_bcw -and $_bcw.Value -eq $true)
if ($_bcwWasEnabled) { Update-AzConfig -DisplayBreakingChangeWarning $false | Out-Null }
try {

##############################################################################################################
# MODULE CHECK
##############################################################################################################

if (-not $IgnoreAzureModuleCheck) {
    CheckModule -Name "Az.Compute"   -MinVersion "7.2.0"
    CheckModule -Name "Az.Accounts"  -MinVersion "2.13.0"
    CheckModule -Name "Az.Resources" -MinVersion "6.0"
    CheckModule -Name "Az.Network"   -MinVersion "5.0"
} else {
    WriteLog "Module check skipped (IgnoreAzureModuleCheck)." "WARNING"
}

##############################################################################################################
# AZURE CONTEXT + VM
##############################################################################################################

try {
    $script:_azContext = Get-AzContext
    if (-not $script:_azContext) { Stop-Script "No Azure context. Run 'Connect-AzAccount' first." }
    WriteLog "Subscription: $($script:_azContext.Subscription.Name) ($($script:_azContext.Subscription.Id))"
} catch { Stop-Script "Error getting Azure context: $_" }

try {
    # Use two separate calls: the plain Get-AzVM returns the full VM model
    # (HardwareProfile, StorageProfile, SecurityProfile, Identity, etc.).
    # Get-AzVM -Status returns ONLY the instance view (power state, disk statuses)
    # in some Az.Compute versions and is NOT guaranteed to populate the model properties.
    # Merging both into a single -Status call is unreliable across Az module versions.
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
    WriteLog "VM found: $VMName"
} catch {
    # If the VM does not exist, it may have been deleted by a previous PATH B run that
    # crashed between STEP 6B (delete VM) and STEP 7B (recreate VM). In that case the
    # OS disk, NICs, and data disks are still intact (DeleteOption was set to Detach).
    # Detect this case and give actionable guidance instead of a generic error.
    if ($_ -match "404|NotFound|was not found") {
        WriteLog "VM '$VMName' not found in '$ResourceGroupName'." "ERROR"
        WriteLog "" 
        WriteLog "  If this VM was previously being converted with PATH B (recreation), it may" "ERROR"
        WriteLog "  have been deleted by STEP 6B of a previous run that did not complete STEP 7B." "ERROR"
        WriteLog "  In that case the OS disk, NICs, and data disks are still intact." "ERROR"
        WriteLog "" 
        WriteLog "  To recover, recreate the VM manually from the original OS disk:" "ERROR"
        WriteLog "    1. Find the OS disk in RG '$ResourceGroupName' (it was not deleted)." "ERROR"
        WriteLog "    2. If -KeepSnapshot was used, a snapshot named '<diskname>-snap-<timestamp>' exists." "ERROR"
        WriteLog "    3. Create a new VM: New-AzVMConfig ... | Set-AzVMOSDisk -ManagedDiskId <diskId> -CreateOption Attach" "ERROR"
        WriteLog "    4. Reattach NICs and data disks, then start the VM." "ERROR"
    } else {
        WriteLog "VM '$VMName' not found in '$ResourceGroupName': $_" "ERROR"
    }
    Stop-Script
}

$script:_originalSize       = $vm.HardwareProfile.VmSize
# DiskControllerType is null on VMs created before Azure started tracking this property (~2022).
# Those VMs are always SCSI; default to SCSI and warn so the operator is aware.
$script:_originalController = if ($vm.StorageProfile.DiskControllerType) {
                                  $vm.StorageProfile.DiskControllerType
                              } else {
                                  WriteLog "DiskControllerType not reported by Azure (pre-2022 VM)  -  defaulting to SCSI." "WARNING"
                                  "SCSI"
                              }
$_os                        = $vm.StorageProfile.OsDisk.OsType
# Managed identity flags: set early so pre-flight checks (RBAC, extension classification)
# can use them without forward-reference hazards.
$_hasSystemMI = ($vm.Identity -and ($vm.Identity.Type -like '*SystemAssigned*'))
$_hasUserMI   = ($vm.Identity -and $vm.Identity.UserAssignedIdentities -and $vm.Identity.UserAssignedIdentities.Count -gt 0)
WriteLog "Current size        : $script:_originalSize"
WriteLog "Current controller  : $script:_originalController"
WriteLog "OS                  : $_os"

# ADE check (Windows and Linux)
# NVMe is not supported with Azure Disk Encryption on either OS. Detecting early prevents the
# script from stopping the VM or deleting it (PATH B) before surfacing this hard blocker.
# Filter by ExtensionType rather than -Name to catch extensions installed with custom names.
# ADE is scheduled for retirement September 15, 2028; Encryption at Host is the replacement.
if ($NewControllerType -eq "NVMe") {
    try {
        $_adeExt = Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $VMName -ErrorAction SilentlyContinue |
                   Where-Object { $_.ExtensionType -in @('AzureDiskEncryption','AzureDiskEncryptionForLinux') -and
                                  $_.ProvisioningState -eq 'Succeeded' } | Select-Object -First 1
        if ($_adeExt) {
            WriteLog "Azure Disk Encryption found: '$($_adeExt.Name)' ($($_adeExt.ExtensionType))  -  NVMe is not supported with ADE." "ERROR"
            WriteLog "  Disable ADE (decrypt the VM) before converting to NVMe." "ERROR"
            WriteLog "  Note: ADE is scheduled for retirement on September 15, 2028. Microsoft recommends" "ERROR"
            WriteLog "  migrating to Encryption at Host, which IS compatible with NVMe." "ERROR"
            WriteLog "  See: https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption-overview" "ERROR"
            Stop-Script
        }
        WriteLog "ADE check: no active Azure Disk Encryption found  -  OK."
    } catch {
        WriteLog "Warning: could not check ADE extension status: $_  -  proceeding." "WARNING"
    }
}

# Azure Site Recovery (ASR) compatibility check
# NVMe VMs are NOT supported by Azure Site Recovery (Azure-to-Azure replication).
# https://learn.microsoft.com/en-us/azure/site-recovery/azure-to-azure-support-matrix
# If the VM is protected by ASR and is converted to NVMe, replication will silently break.
# We detect the ASR Mobility Service extension (publisher: Microsoft.Azure.RecoveryServices,
# type contains 'SiteRecovery') and warn the operator before any changes are made.
# This check only runs when the target controller is NVMe.
if ($NewControllerType -eq "NVMe") {
    try {
        $_asrExts = @(Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $VMName -ErrorAction SilentlyContinue |
                      Where-Object { $_.Publisher -like '*RecoveryServices*' -and
                                     $_.ExtensionType -like '*SiteRecovery*' })
        if ($_asrExts.Count -gt 0) {
            WriteLog "WARNING: Azure Site Recovery (ASR) Mobility Service extension detected:" "WARNING"
            foreach ($_asr in $_asrExts) {
                WriteLog "  $($_asr.Name) ($($_asr.Publisher) / $($_asr.ExtensionType))" "WARNING"
            }
            WriteLog "  NVMe VMs are NOT supported by Azure Site Recovery." "WARNING"
            WriteLog "  Converting to NVMe will silently break DR replication for this VM." "WARNING"
            WriteLog "  Recommended action before converting:" "WARNING"
            WriteLog "    1. Disable ASR replication for this VM in the Recovery Services Vault." "WARNING"
            WriteLog "    2. Run this conversion script." "WARNING"
            WriteLog "    3. After conversion, evaluate DR strategy (ASR does not support NVMe)." "WARNING"
            AskToContinue "ASR replication will break after NVMe conversion. Continue anyway?"
        } else {
            WriteLog "ASR extension check: no Site Recovery Mobility Service found  -  OK."
        }
    } catch {
        WriteLog "Warning: could not check for ASR extension: $_  -  proceeding." "WARNING"
    }
}

# Resource lock check
# CanNotDelete locks block Remove-AzVM (PATH B). ReadOnly locks block both Remove-AzVM (PATH B)
# AND Update-AzVM (PATH A). Neither error is obvious from the ARM response. Detecting them here,
# before any changes are made, gives a clear explanation and keeps the VM fully intact.
#
# Checks four scopes:
#   VM resource        - direct lock on the VM object itself.
#   VM resource group  - inherited RG-level lock (no ResourceName on lock object).
#   Attached disks     - OS disk and all data disks. PATH B patches the OS disk (STEP 4B)
#                        and reattaches all disks (STEP 7B); a ReadOnly lock on any disk
#                        will block the REST PATCH in Set-OSDiskControllerTypes.
#   Attached NICs      - PATH B reattaches NICs; a ReadOnly lock prevents Set-AzNetworkInterface.
#
# NOTE: this check runs BEFORE path selection. CanNotDelete only blocks PATH B (Remove-AzVM);
# PATH A is unaffected. This is an intentional conservative trade-off: a false-positive abort
# (safe - VM untouched) is far preferable to a false-negative where PATH B runs into a lock
# mid-execution after the VM has already been stopped or deleted.
try {
    $_vmLocks = @(Get-AzResourceLock -ResourceGroupName $ResourceGroupName -ResourceName $VMName -ResourceType "Microsoft.Compute/virtualMachines" -ErrorAction SilentlyContinue |
        Where-Object { $_.Properties.Level -in @('CanNotDelete','ReadOnly') })
    # RG-level locks are inherited by all resources; they have no ResourceName on the lock object.
    $_rgLocks = @(Get-AzResourceLock -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue |
        Where-Object { $_.Properties.Level -in @('CanNotDelete','ReadOnly') -and
                       -not $_.ResourceName })

    # OS disk lock (may be in a different resource group from the VM)
    $_diskLocks = @()
    try {
        $_osDiskRGForLock = Get-ArmRG $vm.StorageProfile.OsDisk.ManagedDisk.Id
        $_diskLocks += @(Get-AzResourceLock -ResourceGroupName $_osDiskRGForLock `
            -ResourceName $vm.StorageProfile.OsDisk.Name `
            -ResourceType "Microsoft.Compute/disks" -ErrorAction SilentlyContinue |
            Where-Object { $_.Properties.Level -in @('CanNotDelete','ReadOnly') })
    } catch { <# non-fatal: unmanaged OS disk already caught above #> }

    # Data disk locks
    foreach ($_dd in $vm.StorageProfile.DataDisks) {
        if (-not $_dd.ManagedDisk -or -not $_dd.ManagedDisk.Id) { continue }
        try {
            $_ddRG = Get-ArmRG $_dd.ManagedDisk.Id
            $_diskLocks += @(Get-AzResourceLock -ResourceGroupName $_ddRG `
                -ResourceName $_dd.Name `
                -ResourceType "Microsoft.Compute/disks" -ErrorAction SilentlyContinue |
                Where-Object { $_.Properties.Level -in @('CanNotDelete','ReadOnly') })
        } catch { <# non-fatal: skip this disk #> }
    }

    # NIC locks
    $_nicLocks = @()
    foreach ($_nicRef in $vm.NetworkProfile.NetworkInterfaces) {
        try {
            $_nicRG   = Get-ArmRG $_nicRef.Id
            $_nicName = Get-ArmName $_nicRef.Id
            $_nicLocks += @(Get-AzResourceLock -ResourceGroupName $_nicRG `
                -ResourceName $_nicName `
                -ResourceType "Microsoft.Network/networkInterfaces" -ErrorAction SilentlyContinue |
                Where-Object { $_.Properties.Level -in @('CanNotDelete','ReadOnly') })
        } catch { <# non-fatal: skip this NIC #> }
    }

    $_allLocks = @($_vmLocks) + @($_rgLocks) + @($_diskLocks) + @($_nicLocks)
    if ($_allLocks.Count -gt 0) {
        WriteLog "ABORTING  -  $($_allLocks.Count) management lock(s) detected that would block this operation:" "ERROR"
        foreach ($_lk in $_allLocks) {
            $_scope = if     ($_lk.ResourceType -eq 'Microsoft.Compute/disks')              { "Disk"  }
                      elseif ($_lk.ResourceType -eq 'Microsoft.Network/networkInterfaces')  { "NIC"   }
                      elseif ($_lk.ResourceName)                                             { "VM"    }
                      else                                                                   { "Resource Group" }
            WriteLog "  Lock: '$($_lk.Name)'  Level: $($_lk.Properties.Level)  Scope: $_scope$(if ($_lk.ResourceName) { " ('$($_lk.ResourceName)')" })" "ERROR"
        }
        WriteLog "  CanNotDelete  blocks Remove-AzVM (PATH B  -  recreation)." "ERROR"
        WriteLog "  ReadOnly      blocks Update-AzVM (PATH A), Remove-AzVM (PATH B), and disk/NIC patches." "ERROR"
        WriteLog "Remove the lock(s) before re-running. To remove: Remove-AzResourceLock -LockId <LockId>" "ERROR"
        Stop-Script
    }
    WriteLog "Resource lock check: no blocking locks on VM, disks, or NICs  -  OK."
} catch {
    WriteLog "Warning: could not check resource locks: $_  -  proceeding." "WARNING"
}

# Power state  -  requires a separate Get-AzVM -Status call; the plain Get-AzVM
# used above returns only the model and does not populate the Statuses property.
$_vmStatus  = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status -ErrorAction SilentlyContinue
$powerState = ($_vmStatus.Statuses | Where-Object { $_.Code -like 'PowerState*' } | Select-Object -First 1).Code
WriteLog "Current power state : $powerState"

# Windows version
# Two-stage check:
#   Stage 1 (fast, no RunCommand): extract year from imageReference SKU when the image is a
#            first-party MicrosoftWindowsServer marketplace image.
#   Stage 2 (RunCommand fallback): when Stage 1 cannot determine the version (custom images,
#            Shared Image Gallery, RHEL-for-Windows, non-marketplace deployments, or VMs where
#            imageReference was cleared by platform updates) the script queries the registry
#            directly from the running OS. This is only attempted when -IgnoreOSCheck is NOT set.
#
# Both stages produce the same $skuNum variable (4-digit Windows Server year or 'client')
# which is consumed by the version gate and the WS2019 SharedDisk check below.
#
# Build-number to year mapping used by Stage 2:
#   >= 26100  -> 2025   (Windows Server 2025 / Windows 11 24H2)
#   >= 20348  -> 2022   (Windows Server 2022)
#   >= 17763  -> 2019   (Windows Server 2019 / Windows 10 1809+ / Windows 11)
#   >= 14393  -> 2016   (Windows Server 2016 / Windows 10 1607)
#   <  14393  -> 2012   (Windows Server 2012 R2 and older)
# NVMe requires build >= 17763 (year >= 2019).
# Stage 2 is skipped when -DryRun is active (EnsureVMRunning and RunCommand are side effects).
if ($_os -eq "Windows" -and $NewControllerType -eq "NVMe" -and -not $IgnoreWindowsVersionCheck) {

    $skuNum  = ''   # will hold the 4-digit year string (e.g. '2019') after either stage
    $imgRef  = $vm.StorageProfile.ImageReference

    # ── Stage 1: imageReference ──────────────────────────────────────────────────────────────
    if ($imgRef -and $imgRef.Publisher -eq "MicrosoftWindowsServer") {
        # Extract the first 4-digit group from the SKU name (the Windows year, e.g. 2016, 2019, 2022).
        # Using -replace "[^0-9]","" is incorrect: SKUs like "2016-datacenter-server-core-g2"
        # become "20162" which is > 2019 and silently bypasses the version block.
        # Similarly "2019-datacenter-smalldisk-g2" becomes "20192" which fails the -eq "2019"
        # shared-disk guard, silently skipping the MaxShares check on WS2019 Gen2 VMs.
        # -match '\d{4}' reliably extracts the leading year regardless of any suffix digits.
        $skuNum = if ($imgRef.Sku -match '(\d{4})') { $Matches[1] } else { '' }
        if ($skuNum) {
            WriteLog "Windows version (from image SKU '$($imgRef.Sku)'): $skuNum"
        } else {
            WriteLog "Cannot parse Windows year from SKU '$($imgRef.Sku)'  -  falling back to RunCommand." "WARNING"
        }
    } else {
        $_imgSource = if   ($imgRef -and $imgRef.Publisher) { "publisher: $($imgRef.Publisher)" }
                      elseif ($imgRef -and $imgRef.Id)       { "Shared Image Gallery / custom image" }
                      else                                   { "imageReference unavailable" }
        WriteLog "Windows version: imageReference check skipped ($_imgSource)  -  falling back to RunCommand." "WARNING"
    }

    # ── Stage 2: RunCommand fallback ─────────────────────────────────────────────────────────
    # Only attempted when Stage 1 did not produce a version AND -IgnoreOSCheck is not set
    # AND -DryRun is not active.
    # Skipped during DryRun because:
    #   a) EnsureVMRunning may START a stopped VM (violates "no changes" guarantee).
    #   b) Invoke-AzVMRunCommand executes code on the VM (a real side effect).
    # During DryRun, if Stage 1 had no result, a warning is logged and the version is
    # treated as unconfirmed; the DryRun summary will show the version as "unknown".
    if (-not $skuNum -and -not $IgnoreOSCheck -and -not $DryRun) {
        WriteLog "Querying Windows version via RunCommand..."
        EnsureVMRunning

        $winVerScript = @'
try {
    $reg = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction Stop
    Write-Output "BUILD:$($reg.CurrentBuildNumber)"
    Write-Output "PRODUCT:$($reg.ProductName)"
} catch {
    Write-Output "ERROR: Registry read failed: $_"
}
'@
        try {
            $verOut      = Invoke-RunCommand -ScriptString $winVerScript -Description "Windows version (RunCommand)"
            $buildLine   = $verOut | Where-Object { $_ -like "BUILD:*"   } | Select-Object -First 1
            $productLine = $verOut | Where-Object { $_ -like "PRODUCT:*" } | Select-Object -First 1
            $errLine     = $verOut | Where-Object { $_ -like "ERROR:*"   } | Select-Object -First 1

            if ($errLine) {
                WriteLog "  RunCommand reported: $($errLine -replace '^ERROR:\s*','')" "WARNING"
            }

            if ($buildLine) {
                $buildNum    = [int]($buildLine -replace "^BUILD:", "").Trim()
                $productName = if ($productLine) { ($productLine -replace "^PRODUCT:", "").Trim() } else { "Unknown" }

                # Map build number to a 4-digit Windows Server year.
                # Windows 10/11 client OS VMs (Azure Virtual Desktop) share the same build
                # range as the server counterparts and are equally valid for NVMe; they map
                # to the nearest server year for the version gate and SharedDisk check.
                $skuNum = if     ($buildNum -ge 26100) { '2025' }
                          elseif ($buildNum -ge 20348) { '2022' }
                          elseif ($buildNum -ge 17763) { '2019' }
                          elseif ($buildNum -ge 14393) { '2016' }
                          else                         { '2012' }

                WriteLog "Windows version (from RunCommand): $productName  build $buildNum  -> mapped to year $skuNum"
            } else {
                WriteLog "  RunCommand did not return a build number  -  cannot confirm OS version." "WARNING"
                WriteLog "  NVMe requires Windows Server 2019 (build 17763) or later." "WARNING"
                WriteLog "  Use -IgnoreWindowsVersionCheck to bypass after manually confirming compatibility." "WARNING"
                AskToContinue "Continue without confirmed Windows version?"
            }
        } catch {
            WriteLog "  RunCommand failed for Windows version check: $_" "WARNING"
            WriteLog "  NVMe requires Windows Server 2019 (build 17763) or later." "WARNING"
            WriteLog "  Use -IgnoreWindowsVersionCheck to bypass after manually confirming compatibility." "WARNING"
            AskToContinue "Continue without confirmed Windows version?"
        }

    } elseif (-not $skuNum -and ($IgnoreOSCheck -or $DryRun)) {
        # Stage 1 had no result and Stage 2 is blocked by -IgnoreOSCheck or -DryRun.
        if ($DryRun) {
            WriteLog "Windows version could not be determined from imageReference (Stage 2 RunCommand skipped in DryRun mode)." "WARNING"
            WriteLog "  Re-run without -DryRun to trigger the RunCommand fallback, or use -IgnoreWindowsVersionCheck to bypass." "WARNING"
        } else {
            WriteLog "Windows version could not be determined (imageReference unavailable, RunCommand skipped via -IgnoreOSCheck)." "WARNING"
            WriteLog "  NVMe requires Windows Server 2019 (build 17763) or later. Verify manually." "WARNING"
            AskToContinue "Continue without confirmed Windows version?"
        }
    }

    # ── Version gate ─────────────────────────────────────────────────────────────────────────
    if ($skuNum) {
        if ([int]$skuNum -lt 2019) {
            WriteLog "Windows version $skuNum is below the minimum required for NVMe (2019 / build 17763)." "ERROR"
            WriteLog "  Upgrade to Windows Server 2019 or later before converting to NVMe." "ERROR"
            Stop-Script
        }
        WriteLog "Windows version $skuNum >= 2019  -  OK."
    }

    # ── Shared Disk + NVMe restriction (Windows Server 2019 only) ────────────────────────────
    # Microsoft explicitly documents: Shared Disks with NVMe are not supported on WS2019.
    # https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-remote-faqs
    # "Shared Disks using NVMe isn't supported with the OS Windows Server 2019."
    # WS2019 maps to build range [17763, 20347]; $skuNum = '2019' covers this range.
    if ($skuNum -eq "2019" -and $vm.StorageProfile.DataDisks.Count -gt 0) {
        WriteLog "Windows Server 2019 + NVMe: checking data disks for shared disk configuration (MaxShares > 1)..."
        $_sharedDisks = @()
        $_ddDiskCache = Get-AzDiskBatch $vm.StorageProfile.DataDisks
        foreach ($_dd in $vm.StorageProfile.DataDisks) {
            if (-not $_dd.ManagedDisk -or -not $_dd.ManagedDisk.Id) {
                WriteLog "  Warning: data disk '$($_dd.Name)' (LUN $($_dd.Lun)) has no managed disk ID (unmanaged disk) - skipping MaxShares check." "WARNING"
                continue
            }
            $_ddDisk = $_ddDiskCache[$_dd.ManagedDisk.Id]
            if (-not $_ddDisk) {
                WriteLog "  Warning: could not read MaxShares for disk '$($_dd.Name)': disk not found or fetch failed." "WARNING"
                continue
            }
            if ($_ddDisk.MaxShares -gt 1) { $_sharedDisks += $_dd.Name }
        }
        if ($_sharedDisks.Count -gt 0) {
            WriteLog "ABORTING  -  Shared Disks with NVMe are not supported on Windows Server 2019." "ERROR"
            WriteLog "  The following data disk(s) are configured as shared (MaxShares > 1):" "ERROR"
            foreach ($_sd in $_sharedDisks) { WriteLog "    $_sd" "ERROR" }
            WriteLog "  Options: upgrade OS to Windows Server 2022+, or keep SCSI controller." "ERROR"
            Stop-Script
        }
        WriteLog "  No shared disks (MaxShares > 1) found  -  OK."
    }

} elseif ($IgnoreWindowsVersionCheck) {
    WriteLog "Windows version check skipped (-IgnoreWindowsVersionCheck)." "WARNING"
}

# TrustedLaunch / ConfidentialVM + NVMe platform restriction
# Microsoft explicitly documents: "VMs configured with Trusted Launch cannot move from SCSI to NVMe."
# https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-faqs
# The same restriction applies to Confidential VMs (SecurityType = "ConfidentialVM"):
# the vTPM is part of the VM's confidential hardware root-of-trust and cannot survive a
# controller change that requires re-provisioning the hardware stack from SCSI to NVMe.
# Both SecurityTypes are a SCSI->NVMe conversion restriction only. VMs already on NVMe
# with either SecurityType are fully valid; only the FROM-SCSI conversion is blocked.
#
# Workaround for TrustedLaunch (not available for ConfidentialVM):
# Temporarily downgrade SecurityType to Standard before conversion, then re-enable afterwards.
# This is safe for the security posture (SecureBoot + vTPM are restored) but permanently
# destroys vTPM-stored state (BitLocker keys sealed to TPM, FIDO2 keys, attestation certs).
# Use -AllowTrustedLaunchDowngrade to opt in; the script performs the downgrade/re-enable
# automatically as STEP 2a and STEP 4Aa (PATH A) or within STEP 7B (PATH B).
$_secTypeForCheck = if ($vm.SecurityProfile) { $vm.SecurityProfile.SecurityType } else { $null }
# Capture SecureBoot and vTPM settings now for re-enable after conversion (PATH A STEP 4Aa).
# These are also re-captured in STEP 5B for PATH B, but PATH A never reaches that step.
$_origSecureBoot        = ($vm.SecurityProfile -and $vm.SecurityProfile.UefiSettings -and $vm.SecurityProfile.UefiSettings.SecureBootEnabled -eq $true)
$_origVTpm              = ($vm.SecurityProfile -and $vm.SecurityProfile.UefiSettings -and $vm.SecurityProfile.UefiSettings.VTpmEnabled       -eq $true)
# EncryptionAtHost is also part of SecurityProfile. STEP 2a nulls the entire SecurityProfile,
# so this value must be captured here (before STEP 2a) and restored in STEP 4Aa.
# Capturing only in STEP 5B is insufficient for PATH A, which never reaches STEP 5B.
$_origEncryptionAtHost  = ($vm.SecurityProfile -and $vm.SecurityProfile.EncryptionAtHost -eq $true)
# Tracks whether STEP 2a successfully downgraded TrustedLaunch so that error paths can warn
# the operator that Update-AzVM -SecurityType TrustedLaunch must be run to restore it.
$script:_needTrustedLaunchRestore = $false

if ($NewControllerType -eq "NVMe" -and
    $script:_originalController -ne "NVMe" -and
    $_secTypeForCheck -in @("TrustedLaunch", "ConfidentialVM")) {

    if ($_secTypeForCheck -eq "ConfidentialVM") {
        # ConfidentialVM: no workaround exists - hardware root-of-trust is architecturally incompatible.
        WriteLog "ABORTING  -  Azure does not support SCSI -> NVMe conversion on ConfidentialVM VMs." "ERROR"
        WriteLog "  Confidential VMs have a hardware-bound vTPM root-of-trust that cannot survive" "ERROR"
        WriteLog "  a controller change. The VM must remain on SCSI." "ERROR"
        WriteLog "  Option: Use a SCSI-capable VM size (v5/older) for Confidential VMs." "ERROR"
        Stop-Script
    }

    # TrustedLaunch: workaround available via -AllowTrustedLaunchDowngrade
    if (-not $AllowTrustedLaunchDowngrade) {
        WriteLog "ABORTING  -  Azure does not support SCSI -> NVMe conversion on TrustedLaunch VMs." "ERROR"
        WriteLog "  This is a hard platform restriction. The VM is on SCSI with SecurityType=TrustedLaunch." "ERROR"
        WriteLog "  Options:" "ERROR"
        WriteLog "    1. Keep the VM on SCSI and use a SCSI-capable VM size (v5/older)." "ERROR"
        WriteLog "    2. Use -AllowTrustedLaunchDowngrade to let the script temporarily disable" "ERROR"
        WriteLog "       TrustedLaunch, perform the NVMe conversion, and re-enable TrustedLaunch." "ERROR"
        WriteLog "       WARNING: vTPM state (BitLocker keys sealed to TPM, FIDO2 keys, attestation" "ERROR"
        WriteLog "         certs) is permanently destroyed during downgrade. Use -DryRun to preview." "ERROR"
        WriteLog "    3. Remove TrustedLaunch manually (Update-AzVM -SecurityType Standard)," "ERROR"
        WriteLog "       run this script, then re-enable TrustedLaunch manually." "ERROR"
        Stop-Script
    }

    # -AllowTrustedLaunchDowngrade: warn and confirm, then continue - STEP 2a does the actual work.
    WriteLog "TrustedLaunch detected on SCSI VM targeting NVMe (-AllowTrustedLaunchDowngrade specified)." "WARNING"
    WriteLog "  The script will temporarily downgrade SecurityType to Standard (STEP 2a)," "WARNING"
    WriteLog "  perform the NVMe conversion, then re-enable TrustedLaunch." "WARNING"
    WriteLog "  *** PERMANENT DATA LOSS ***" "WARNING"
    WriteLog "    - BitLocker keys sealed to vTPM -> disk may enter BitLocker recovery on first boot." "WARNING"
    WriteLog "      (Only affects keys sealed to vTPM; standard recovery keys are unaffected.)" "WARNING"
    WriteLog "    - FIDO2 / Windows Hello for Business keys bound to vTPM -> must be re-provisioned." "WARNING"
    WriteLog "    - Attestation certificates / secrets sealed to vTPM state -> permanently lost." "WARNING"
    WriteLog "  The TrustedLaunch security posture (SecureBoot + vTPM chip) WILL be restored after." "WARNING"
    AskToContinue "TrustedLaunch VM: vTPM state will be permanently destroyed before re-enable. Continue?"
}
# Single boolean capturing the compound TrustedLaunch-downgrade condition.
# Used throughout the script (DryRun, STEP 2a, STEP 4Aa, STEP 7B, completion) in place of the
# repeated inline expression: $AllowTrustedLaunchDowngrade -and $_secTypeForCheck -eq 'TrustedLaunch'
$_isTrustedLaunchDowngrade = $AllowTrustedLaunchDowngrade -and $_secTypeForCheck -eq 'TrustedLaunch'
if ($NewControllerType -eq "NVMe" -and -not $_isTrustedLaunchDowngrade) {
    WriteLog "Security type check: SecurityType = '$(if ($_secTypeForCheck) { $_secTypeForCheck } else { 'Standard/none' })' (source controller: $script:_originalController)  -  OK."
}

# Ephemeral OS disk check
# Ephemeral OS disks (DiffDiskSettings.Option = "Local") have no standalone managed disk
# resource. The entire script depends on a managed OS disk: the generation check below reads
# ManagedDisk.Id (null crash for ephemeral), PATH B snapshots and reattaches it, and PATH A
# patches its diskControllerTypes via the REST API. All three operations are impossible
# without a managed disk. Detect early and abort with a clear message.
if ($vm.StorageProfile.OsDisk.DiffDiskSettings -and
    $vm.StorageProfile.OsDisk.DiffDiskSettings.Option -eq "Local") {
    WriteLog "ABORTING  -  This VM uses an Ephemeral OS disk (DiffDiskSettings.Option = Local)." "ERROR"
    WriteLog "  Ephemeral OS disks have no standalone managed disk resource and cannot be" "ERROR"
    WriteLog "  snapshotted, reattached, or patched. This script requires a managed OS disk." "ERROR"
    WriteLog "  To convert an ephemeral VM, redeploy it with a managed OS disk first," "ERROR"
    WriteLog "  then run this script on the redeployed VM." "ERROR"
    Stop-Script
}

# Unmanaged OS disk check
# Unmanaged disks (VHDs stored in Azure Storage accounts) have ManagedDisk = null.
# The generation check below, PATH A's REST patch, and PATH B's snapshot all require
# a managed disk resource. The ephemeral check above covers DiffDiskSettings=Local;
# this guard covers the older unmanaged/classic disk case.
if (-not $vm.StorageProfile.OsDisk.ManagedDisk -or
    -not $vm.StorageProfile.OsDisk.ManagedDisk.Id) {
    WriteLog "ABORTING  -  This VM uses an unmanaged OS disk (VHD in a Storage Account)." "ERROR"
    WriteLog "  Unmanaged disks cannot be snapshotted, patched, or reattached via the" "ERROR"
    WriteLog "  managed disk API. This script requires a managed OS disk." "ERROR"
    WriteLog "  Migrate the VM to a managed disk first (Convert-AzVMManagedDisk)," "ERROR"
    WriteLog "  then re-run this script." "ERROR"
    Stop-Script
}

# Generation check
# NVMe requires Generation 2. Gen1 VMs converting to or staying on SCSI are fully valid.
# The guard here is intentionally NVMe-only: blocking a Gen1 SCSI->SCSI resize would be
# incorrect. We still always fetch $osDisk here because it is used throughout the script
# (PATH A disk patch, PATH B snapshot, DryRun summary). If the fetch fails we abort
# regardless of target controller because later steps would crash without $osDisk.
try {
    $diskRg = Get-ArmRG $vm.StorageProfile.OsDisk.ManagedDisk.Id
    $osDisk = Get-AzDisk -Name $vm.StorageProfile.OsDisk.Name -ResourceGroupName $diskRg
    if ($osDisk.HyperVGeneration -eq "V1" -and $NewControllerType -eq "NVMe") {
        WriteLog "Generation 1 VM  -  NVMe requires Generation 2." "ERROR"
        WriteLog "  To convert to NVMe you must first migrate the VM to Generation 2." "ERROR"
        WriteLog "  SCSI conversions and resizes on Generation 1 VMs are fully supported." "ERROR"
        Stop-Script
    }
    WriteLog "VM Generation: $($osDisk.HyperVGeneration)  -  OK."
} catch { Stop-Script "Error retrieving Hyper-V Generation: $_" }

# Controller / size already correct?
$_controllerAlreadyCorrect = ($script:_originalController -eq $NewControllerType)
$_sizeAlreadyCorrect       = ($script:_originalSize -eq $VMSize)

if ($_controllerAlreadyCorrect -and $_sizeAlreadyCorrect) {
    WriteLog "VM is already $NewControllerType at size $VMSize  -  nothing to do." "WARNING"
    exit 0
}
if ($_controllerAlreadyCorrect) {
    WriteLog "Controller already $NewControllerType  -  controller update and OS driver steps will be skipped." "WARNING"
}
if ($_sizeAlreadyCorrect) {
    WriteLog "Size already $VMSize  -  only controller type will be changed." "WARNING"
}

##############################################################################################################
# SKU CHECK + LOCAL DISK DETECTION
##############################################################################################################

$_sourceDiskArch = 'diskless'   # will be set by SKU check, or by name-based fallback if -IgnoreSKUCheck
$_targetDiskArch = 'diskless'   # will be set by SKU check, or by name-based fallback if -IgnoreSKUCheck

if (-not $IgnoreSKUCheck) {
    $allSKUs   = Get-RegionVMSkus -Location $vm.Location
    $targetSKU = $allSKUs | Where-Object { $_.Name -eq $VMSize }               | Select-Object -First 1
    $sourceSKU = $allSKUs | Where-Object { $_.Name -eq $script:_originalSize } | Select-Object -First 1

    if (-not $targetSKU) {
        Stop-Script "VM size '$VMSize' not found in region '$($vm.Location)'."
    }
    if (-not $sourceSKU) {
        WriteLog "Current size '$script:_originalSize' not in SKU list  -  name-based detection only." "WARNING"
    }

    # TrustedLaunch support check on target size
    # Some VM sizes (e.g. certain M-series, NV-series) have TrustedLaunchDisabled=True in their
    # SKU capabilities. If the source VM has TrustedLaunch and -AllowTrustedLaunchDowngrade is used,
    # the script will fail at STEP 4Aa / STEP 7B when trying to re-enable TrustedLaunch on a size
    # that does not support it. Detect early before any changes are made.
    if ($_isTrustedLaunchDowngrade) {
        $_tlDisabled = Get-SKUCapability $targetSKU "TrustedLaunchDisabled"
        if ($_tlDisabled -eq "True") {
            WriteLog "ABORTING  -  Target size '$VMSize' has TrustedLaunchDisabled=True." "ERROR"
            WriteLog "  The script cannot re-enable TrustedLaunch after conversion on this size." "ERROR"
            WriteLog "  Options:" "ERROR"
            WriteLog "    1. Choose a target size that supports TrustedLaunch." "ERROR"
            WriteLog "    2. Remove TrustedLaunch manually before running this script" "ERROR"
            WriteLog "       (Update-AzVM -SecurityType Standard while deallocated)." "ERROR"
            Stop-Script
        }
        WriteLog "TrustedLaunch support on target: '$VMSize' supports TrustedLaunch  -  OK."
    }

    # Subscription restriction check
    # A SKU can appear in the catalog for a region but still carry a Restriction that blocks it
    # for this specific subscription (ReasonCode = NotAvailableForSubscription). If undetected
    # here, the script would run all pre-flight steps and fail only at Update-AzVM or New-AzVM
    # with a cryptic "allocation failed" error after the VM has already been stopped (PATH A) or
    # deleted (PATH B). Catching it here keeps the VM running and gives a clear action to take.
    $_targetRestrictions = @($targetSKU.Restrictions | Where-Object {
        $_.ReasonCode -eq 'NotAvailableForSubscription' -and $_.Type -eq 'Location'
    })
    if ($_targetRestrictions.Count -gt 0) {
        WriteLog "VM size '$VMSize' is NOT available for this subscription in '$($vm.Location)'." "ERROR"
        WriteLog "  ReasonCode: NotAvailableForSubscription" "ERROR"
        WriteLog "  To request access: https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas" "ERROR"
        Stop-Script
    }
    WriteLog "Subscription restriction check: '$VMSize' available  -  OK."

    # Zone check
    $_vmZones = @($vm.Zones | Where-Object { $_ })
    if ($_vmZones.Count -gt 0) {
        $zone = $_vmZones[0]
        if (-not ($targetSKU.LocationInfo | Where-Object { $_.Zones -contains $zone })) {
            Stop-Script "Size '$VMSize' not available in zone $zone."
        }
        WriteLog "SKU available in zone $zone  -  OK."
    } else {
        WriteLog "VM is not zone-pinned  -  zone check skipped."
    }

    # Disk controller support check
    # Note: older SCSI-only SKUs do not list DiskControllerTypes in their capabilities at all.
    # Absence of the capability = SCSI only. Treat null/empty as "SCSI".
    $controllerTypes = Get-SKUCapability $targetSKU "DiskControllerTypes"
    $effectiveControllerTypes = if ($controllerTypes) { $controllerTypes } else { "SCSI" }
    if (-not ($effectiveControllerTypes -like "*$NewControllerType*")) {
        WriteLog "Size '$VMSize' does not support $NewControllerType controller. Supported: $effectiveControllerTypes" "ERROR"
        if ($NewControllerType -eq "SCSI") {
            WriteLog "  Hint: '$VMSize' is NVMe-only. Use -NewControllerType NVMe instead." "ERROR"
        } elseif ($NewControllerType -eq "NVMe") {
            WriteLog "  Hint: '$VMSize' is SCSI-only. Use -NewControllerType SCSI instead." "ERROR"
        }
        Stop-Script
    }
    if (-not $_controllerAlreadyCorrect) {
        WriteLog "Controller check OK: $VMSize supports $effectiveControllerTypes"
    }

    # Disk architecture detection
    WriteLog "Detecting disk architecture category..."
    $_sourceDiskArch = Get-DiskArchitecture -SizeName $script:_originalSize -SKU $sourceSKU
    $_targetDiskArch = Get-DiskArchitecture -SizeName $VMSize               -SKU $targetSKU
    WriteLog "Source disk architecture: $_sourceDiskArch ($script:_originalSize)"
    WriteLog "Target disk architecture: $_targetDiskArch ($VMSize)"

} else {
    WriteLog "SKU check skipped (-IgnoreSKUCheck)  -  using name-based detection only." "WARNING"
    $_sourceDiskArch = Get-DiskArchitecture -SizeName $script:_originalSize -SKU $null
    $_targetDiskArch = Get-DiskArchitecture -SizeName $VMSize               -SKU $null
    WriteLog "Source disk architecture (name-based): $_sourceDiskArch"
    WriteLog "Target disk architecture (name-based): $_targetDiskArch"
    # Name-based detection relies on the 'd' capability letter in the VM size name to identify
    # a local disk (e.g. E8bds_v5, E8ads_v7). Older sizes like B2ms, D2s_v3, and E4s_v3 predate
    # this convention and do NOT have 'd' in their name, even though they have a local SCSI temp disk.
    # Without the SKU API, these are indistinguishable from diskless sizes by name alone and will be
    # classified as 'diskless' instead of 'scsi-temp'. This can cause incorrect PATH A/B selection
    # on Windows and missed pagefile warnings. If source or target is an older-style size name,
    # remove -IgnoreSKUCheck for accurate detection, or use -ForcePathB to guarantee VM recreation.
    WriteLog "  NOTE: Name-based detection may misclassify older sizes without 'd' (e.g. B2ms, D2s_v3)" "WARNING"
    WriteLog "  as 'diskless' even if they have a local SCSI disk. Remove -IgnoreSKUCheck or use" "WARNING"
    WriteLog "  -ForcePathB if source or target is such an older size." "WARNING"

    # v6+ sizes are typically NVMe-only. If -IgnoreSKUCheck is used with -NewControllerType SCSI
    # and the target looks like a v6+ size, warn that this combination is likely invalid.
    # Without SKU data we cannot confirm, but the name pattern is a strong indicator.
    if ($NewControllerType -eq "SCSI" -and $VMSize -match '_v(\d+)' -and [int]$Matches[1] -ge 6) {
        WriteLog "WARNING: Target size '$VMSize' appears to be v$($Matches[1]) (NVMe-only generation) but -NewControllerType is SCSI." "WARNING"
        WriteLog "  Most v6+ sizes do not support SCSI. Without -IgnoreSKUCheck, the script would verify this." "WARNING"
        WriteLog "  If the target size is NVMe-only, the resize/recreation will fail." "WARNING"
        AskToContinue "Target appears to be NVMe-only but SCSI was requested. Continue anyway?"
    }
}

##############################################################################################################
# QUOTA CHECK
##############################################################################################################

# Check if there is enough vCPU quota for the target size before making any changes.
# Accounts for the source vCPUs being freed (VM is deallocated before resize/recreation).
# Spot VMs consume from a shared 'lowPriorityCores' quota rather than their family quota.
# Skipped when -IgnoreSKUCheck or -IgnoreQuotaCheck is specified.
if (-not $IgnoreSKUCheck -and -not $IgnoreQuotaCheck) {
    WriteLog "Checking vCPU quota..."
    try {
        $targetVCPUs  = [int](Get-SKUCapability $targetSKU "vCPUs")
        $sourceVCPUs  = if ($sourceSKU) { [int](Get-SKUCapability $sourceSKU "vCPUs") } else { 0 }
        $targetFamily = $targetSKU.Family
        $sourceFamily = if ($sourceSKU) { $sourceSKU.Family } else { $null }

        # Spot/Low priority VMs use a shared quota bucket regardless of VM family.
        # 'lowPriorityCores' covers both Spot and Low priority.
        $isSpot = ($vm.Priority -eq "Spot" -or $vm.Priority -eq "Low")  # "Low" is the legacy pre-GA name for Spot priority
        if ($isSpot) {
            WriteLog "  VM priority   : $($vm.Priority) - quota will be checked against 'lowPriorityCores' (shared Spot quota)"
        }

        $usages = Get-AzVMUsage -Location $vm.Location

        # Family quota check - skipped for Spot/Low VMs as they use the shared Spot pool
        if (-not $isSpot) {
            $familyUsage = $usages | Where-Object { $_.Name.Value -eq $targetFamily } | Select-Object -First 1
            if ($familyUsage) {
                # If source and target are in the same family, source vCPUs will be freed first
                $freedVCPUs = if ($sourceFamily -eq $targetFamily) { $sourceVCPUs } else { 0 }
                $available  = $familyUsage.Limit - $familyUsage.CurrentValue + $freedVCPUs
                $netChange  = $targetVCPUs - $freedVCPUs
                WriteLog "  Family quota  : $targetFamily - Used: $($familyUsage.CurrentValue)/$($familyUsage.Limit), Target needs: $targetVCPUs vCPUs, Freed: $freedVCPUs vCPUs, Available: $available vCPUs"
                if ($targetVCPUs -gt $available) {
                    WriteLog "  QUOTA EXCEEDED: Not enough $targetFamily quota. Need $targetVCPUs vCPUs, only $available available." "ERROR"
                    WriteLog "  Request a quota increase: https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas" "ERROR"
                    Stop-Script
                }
                WriteLog "  Family quota  : OK (net change: $(if ($netChange -ge 0) { "+$netChange" } else { "$netChange" }) vCPUs)"
            } else {
                WriteLog "  Family quota  : could not find usage entry for '$targetFamily' - skipping family check." "WARNING"
            }
        } else {
            # Spot VMs: check shared lowPriorityCores quota instead of family quota
            $spotUsage = $usages | Where-Object { $_.Name.Value -eq "lowPriorityCores" } | Select-Object -First 1
            if ($spotUsage) {
                # Source VM is also Spot (we are in the $isSpot branch), so its cores are freed too
                $freedSpot     = $sourceVCPUs
                $availableSpot = $spotUsage.Limit - $spotUsage.CurrentValue + $freedSpot
                WriteLog "  Spot quota    : lowPriorityCores - Used: $($spotUsage.CurrentValue)/$($spotUsage.Limit), Target needs: $targetVCPUs vCPUs, Freed: $freedSpot vCPUs, Available: $availableSpot vCPUs"
                if ($targetVCPUs -gt $availableSpot) {
                    WriteLog "  QUOTA EXCEEDED: Not enough Spot (lowPriorityCores) quota. Need $targetVCPUs vCPUs, only $availableSpot available." "ERROR"
                    WriteLog "  Request a quota increase: https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas" "ERROR"
                    Stop-Script
                }
                WriteLog "  Spot quota    : OK"
            } else {
                WriteLog "  Spot quota    : could not find 'lowPriorityCores' usage entry - skipping Spot check." "WARNING"
            }
        }

        # Regional total vCPU quota - applies to all VM types including Spot
        $regionalUsage = $usages | Where-Object { $_.Name.Value -eq "cores" } | Select-Object -First 1
        if ($regionalUsage) {
            $freedRegional = $sourceVCPUs   # source is always freed regardless of family or priority
            $availRegional = $regionalUsage.Limit - $regionalUsage.CurrentValue + $freedRegional
            WriteLog "  Regional quota: Total vCPUs - Used: $($regionalUsage.CurrentValue)/$($regionalUsage.Limit), Target needs: $targetVCPUs vCPUs, Freed: $freedRegional vCPUs, Available: $availRegional vCPUs"
            if ($targetVCPUs -gt $availRegional) {
                WriteLog "  QUOTA EXCEEDED: Not enough regional vCPU quota. Need $targetVCPUs vCPUs, only $availRegional available." "ERROR"
                WriteLog "  Request a quota increase: https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas" "ERROR"
                Stop-Script
            }
            WriteLog "  Regional quota: OK"
        } else {
            WriteLog "  Regional quota: could not find regional usage entry - skipping regional check." "WARNING"
        }
    } catch {
        WriteLog "Warning: quota check failed: $_  -  use -IgnoreQuotaCheck to skip." "WARNING"
        AskToContinue "Could not verify quota. Continue anyway?"
    }
} elseif ($IgnoreQuotaCheck) {
    WriteLog "Quota check skipped (-IgnoreQuotaCheck)." "WARNING"
} else {
    WriteLog "Quota check skipped (-IgnoreSKUCheck)." "WARNING"
}

##############################################################################################################
# RESOURCE LIMIT CHECKS (data disks, NICs, Premium IO, Write Accelerator)
##############################################################################################################

# Verify the target VM size can accommodate the current number of data disks and NICs.
# Without this, the script would fail at Update-AzVM (PATH A) or New-AzVM (PATH B) AFTER
# the VM has already been stopped or even deleted, leaving the operator in a difficult state.
# Also check PremiumIO support when Premium SSD disks are attached.
if (-not $IgnoreSKUCheck -and $targetSKU) {

    # Max data disk count check
    $_targetMaxDataDisks = Get-SKUCapability $targetSKU "MaxDataDiskCount"
    if ($_targetMaxDataDisks) {
        $_currentDataDisks = $vm.StorageProfile.DataDisks.Count
        if ([int]$_currentDataDisks -gt [int]$_targetMaxDataDisks) {
            WriteLog "ABORTING  -  VM has $_currentDataDisks data disk(s) but target size '$VMSize' supports at most $_targetMaxDataDisks." "ERROR"
            WriteLog "  Detach $([int]$_currentDataDisks - [int]$_targetMaxDataDisks) data disk(s) before re-running, or choose a larger target size." "ERROR"
            Stop-Script
        }
        WriteLog "Data disk count : $_currentDataDisks / $_targetMaxDataDisks  -  OK."
    }

    # Max NIC count check
    $_targetMaxNICs = Get-SKUCapability $targetSKU "MaxNetworkInterfaces"
    if ($_targetMaxNICs) {
        $_currentNICs = $vm.NetworkProfile.NetworkInterfaces.Count
        if ([int]$_currentNICs -gt [int]$_targetMaxNICs) {
            WriteLog "ABORTING  -  VM has $_currentNICs NIC(s) but target size '$VMSize' supports at most $_targetMaxNICs." "ERROR"
            WriteLog "  Detach $([int]$_currentNICs - [int]$_targetMaxNICs) NIC(s) before re-running, or choose a larger target size." "ERROR"
            Stop-Script
        }
        WriteLog "NIC count       : $_currentNICs / $_targetMaxNICs  -  OK."
    }

    # Premium IO support check
    $_targetPremiumIO = Get-SKUCapability $targetSKU "PremiumIO"
    if ($_targetPremiumIO -eq "False") {
        $_premiumDisks = @()
        # Check OS disk
        if ($osDisk.Sku.Name -like "Premium*") { $_premiumDisks += "OS disk '$($osDisk.Name)' ($($osDisk.Sku.Name))" }
        # Check data disks
        $_ddDiskCache = Get-AzDiskBatch $vm.StorageProfile.DataDisks
        foreach ($_dd in $vm.StorageProfile.DataDisks) {
            if ($_dd.ManagedDisk -and $_dd.ManagedDisk.Id) {
                $_ddDisk = $_ddDiskCache[$_dd.ManagedDisk.Id]
                if (-not $_ddDisk) {
                    WriteLog "  Warning: could not check disk type for '$($_dd.Name)': disk not found or fetch failed." "WARNING"
                    continue
                }
                if ($_ddDisk.Sku.Name -like "Premium*") { $_premiumDisks += "Data disk '$($_dd.Name)' LUN $($_dd.Lun) ($($_ddDisk.Sku.Name))" }
            }
        }
        if ($_premiumDisks.Count -gt 0) {
            WriteLog "ABORTING  -  Target size '$VMSize' does not support Premium IO, but the VM has Premium disks:" "ERROR"
            foreach ($_pd in $_premiumDisks) { WriteLog "    $_pd" "ERROR" }
            WriteLog "  Migrate the disk(s) to Standard SSD/HDD, or choose a target size that supports Premium IO." "ERROR"
            Stop-Script
        }
        WriteLog "Premium IO check: target does not support Premium IO, no Premium disks attached  -  OK."
    } else {
        WriteLog "Premium IO check: target supports Premium IO  -  OK."
    }

    # Write Accelerator support check (M-series feature)
    $_hasWriteAccelerator = $false
    if ($vm.StorageProfile.OsDisk.WriteAcceleratorEnabled) { $_hasWriteAccelerator = $true }
    foreach ($_dd in $vm.StorageProfile.DataDisks) { if ($_dd.WriteAcceleratorEnabled) { $_hasWriteAccelerator = $true; break } }
    if ($_hasWriteAccelerator) {
        $_targetWA = Get-SKUCapability $targetSKU "MaxWriteAcceleratorDisksAllowed"
        if (-not $_targetWA -or [int]$_targetWA -eq 0) {
            WriteLog "WARNING: VM has Write Accelerator enabled on one or more disks, but target size '$VMSize' does not support Write Accelerator." "WARNING"
            WriteLog "  Write Accelerator settings will be preserved in the config but may be silently ignored by Azure." "WARNING"
            AskToContinue "Continue without Write Accelerator support on target size?"
        } else {
            WriteLog "Write Accelerator: supported on target size  -  OK."
        }
    }
}

# Determine which execution path to use
# Path selection
# Azure blocks direct resize on Windows whenever source and target are in different
# disk architecture categories. Three categories exist:
#   scsi-temp   -  SCSI local temp disk (v5/older)
#   nvme-temp   -  NVMe local temp disk (v6/v7), raw on each boot
#   diskless    -  no local temp disk
# Any cross-category combination requires PATH B (VM recreation).
# Linux VMs are not subject to this restriction and always use PATH A.
$_crossCategory   = ($_os -eq "Windows") -and ($_sourceDiskArch -ne $_targetDiskArch)
# Pagefile fix only needed when moving away from a SCSI temp disk (where pagefile lives on D:\).
# When source is nvme-temp, the disk is raw/unformatted so pagefile was never on D:\ to begin with.
# When source is diskless, D:\ never existed, so there is nothing to migrate.
# Only scsi-temp sources require migration.
$_needPagefileFix    = ($_os -eq "Windows") -and ($_sourceDiskArch -eq 'scsi-temp') -and ($_targetDiskArch -ne 'scsi-temp')
# Pre-computed booleans for STEP 1 conditions - each used twice (DryRun summary + execution).
# Defined here, after disk architecture is known and before the DryRun summary block reads them.
$_needWindowsNvmePrep = (-not $_controllerAlreadyCorrect) -and ($_os -eq "Windows") -and ($NewControllerType -eq "NVMe") -and (-not $IgnoreOSCheck)
$_needLinuxNvmePrep   = (-not $_controllerAlreadyCorrect) -and ($_os -eq "Linux")   -and ($NewControllerType -eq "NVMe") -and (-not $IgnoreOSCheck)
$_needNvmeTempDiskTask = ($_os -eq "Windows") -and ($_targetDiskArch -eq "nvme-temp") -and ($_sourceDiskArch -ne "nvme-temp") -and (-not $NVMEDiskInitScriptSkip)

if ($_crossCategory) {
    WriteLog "Windows disk architecture change: $_sourceDiskArch -> $_targetDiskArch" "IMPORTANT"
    switch ("$_sourceDiskArch->$_targetDiskArch") {
        "scsi-temp->nvme-temp" { WriteLog "  SCSI temp disk -> NVMe temp disk (v6/v7). D:\ will reappear as raw NVMe disk." "IMPORTANT" }
        "scsi-temp->diskless"  { WriteLog "  SCSI temp disk -> diskless. D:\ will be lost." "IMPORTANT" }
        "nvme-temp->scsi-temp" { WriteLog "  NVMe temp disk (v6/v7) -> SCSI temp disk." "IMPORTANT" }
        "nvme-temp->diskless"  { WriteLog "  NVMe temp disk -> diskless. D:\ will be lost." "IMPORTANT" }
        "diskless->scsi-temp"  { WriteLog "  Diskless -> SCSI temp disk. D:\ will appear after recreation." "IMPORTANT" }
        "diskless->nvme-temp"  { WriteLog "  Diskless -> NVMe temp disk (v6/v7). D:\ will appear as raw NVMe disk." "IMPORTANT" }
    }
}

# Validate mutually exclusive overrides
if ($ForcePathA -and $ForcePathB) {
    WriteLog "-ForcePathA and -ForcePathB cannot be used together." "ERROR"
    Stop-Script
}

if ($ForcePathA) {
    $_useRecreationPath = $false
    if ($_crossCategory) {
        WriteLog "-ForcePathA specified  -  overriding automatic PATH B selection." "WARNING"
        WriteLog "Azure may reject resize between '$_sourceDiskArch' and '$_targetDiskArch' on Windows. Proceeding anyway." "WARNING"
    }
    WriteLog "PATH A selected: VM RESIZE (forced via -ForcePathA)." "IMPORTANT"
} elseif ($ForcePathB) {
    $_useRecreationPath = $true
    WriteLog "PATH B selected: VM RECREATION (forced via -ForcePathB)." "IMPORTANT"
} elseif ($_crossCategory) {
    $_useRecreationPath = $true
    WriteLog "====================================================================" "IMPORTANT"
    WriteLog " PATH B selected: VM RECREATION" "IMPORTANT"
    WriteLog " Azure blocks direct resize on Windows when the source and target have" "IMPORTANT"
    WriteLog " different disk architectures (scsi-temp / nvme-temp / diskless)." "IMPORTANT"
    WriteLog " This includes all six cross-category combinations:" "IMPORTANT"
    WriteLog "   scsi-temp<->diskless, nvme-temp<->diskless, and scsi-temp<->nvme-temp." "IMPORTANT"
    WriteLog " The VM will be deleted and recreated with the same NICs and disks." "IMPORTANT"
    WriteLog " Use -ForcePathA to attempt a direct resize instead (not recommended)." "IMPORTANT"
    WriteLog "====================================================================" "IMPORTANT"
} else {
    $_useRecreationPath = $false
    WriteLog "PATH A selected: VM RESIZE (Update-AzVM)." "IMPORTANT"
}


# Unmanaged data disk check (PATH B only)
# PATH B reattaches data disks by ManagedDisk.Id in STEP 7B. If any data disk is unmanaged
# (VHD in a Storage Account, ManagedDisk = $null), STEP 7B would crash with a null reference
# after the VM has already been deleted. PATH A (resize via Update-AzVM) passes data disk
# objects through as-is and does not reattach by ID, so it is unaffected.
# This check runs after path selection so we only abort when PATH B is actually selected.
if ($_useRecreationPath -and $vm.StorageProfile.DataDisks.Count -gt 0) {
    $_unmanagedDataDisks = @($vm.StorageProfile.DataDisks | Where-Object {
        -not $_.ManagedDisk -or -not $_.ManagedDisk.Id
    })
    if ($_unmanagedDataDisks.Count -gt 0) {
        WriteLog "ABORTING  -  $($_unmanagedDataDisks.Count) unmanaged data disk(s) detected (VHDs in Storage Account)." "ERROR"
        WriteLog "  PATH B reattaches data disks by managed disk ID. Unmanaged disks cannot be reattached." "ERROR"
        foreach ($_ud in $_unmanagedDataDisks) {
            WriteLog "    LUN $($_ud.Lun): '$($_ud.Name)' (no ManagedDisk.Id)" "ERROR"
        }
        WriteLog "  Migrate the data disk(s) to managed disks first, then re-run this script." "ERROR"
        WriteLog "  To migrate: use Convert-AzVMManagedDisk in the Azure Portal or CLI." "ERROR"
        Stop-Script
    }
}

# Uniform VMSS member check (PATH B only)
# A Uniform-orchestration VMSS manages its VM instances centrally: instances are identified
# by an integer index and their VMs cannot exist as standalone ARM resources. New-AzVM cannot
# create or re-register a Uniform VMSS member - the correct API is Update-AzVmssInstance.
# PATH A (resize via Update-AzVM) is safe for Uniform VMSS members because it modifies the
# existing VM in-place without deleting it. Only abort when PATH B is selected.
if ($_useRecreationPath -and $vm.VirtualMachineScaleSet) {
    $_vmssIdPre    = $vm.VirtualMachineScaleSet.Id
    $_vmssNamePre  = Get-ArmName $_vmssIdPre
    $_vmssRgPre    = Get-ArmRG $_vmssIdPre
    try {
        $vmssObj = Get-AzVmss -ResourceGroupName $_vmssRgPre -VMScaleSetName $_vmssNamePre -ErrorAction Stop
        if ($vmssObj.OrchestrationMode -eq 'Uniform') {
            WriteLog "ABORTING  -  VM '$VMName' is a member of Uniform VMSS '$_vmssNamePre'." "ERROR"
            WriteLog "  Uniform VMSS instances are managed by the scale set and cannot be independently" "ERROR"
            WriteLog "  deleted and recreated with New-AzVM. PATH B (recreation) is not supported." "ERROR"
            WriteLog "  Options:" "ERROR"
            WriteLog "    1. Use -ForcePathA to attempt a direct resize (Update-AzVM) instead." "ERROR"
            WriteLog "       PATH A is safe for Uniform VMSS members: it modifies the VM in-place." "ERROR"
            WriteLog "    2. Use the VMSS upgrade API if you need to change the model (Update-AzVmssInstance)." "ERROR"
            Stop-Script
        }
        # Flexible orchestration: PATH B is supported. VM detaches from VMSS on Remove-AzVM
        # and is re-registered via VirtualMachineScaleSet.Id on New-AzVMConfig in STEP 7B.
        WriteLog "VMSS orchestration mode: $($vmssObj.OrchestrationMode)  -  PATH B supported." "INFO"
    } catch {
        WriteLog "Warning: could not verify VMSS orchestration mode for '$_vmssNamePre': $_" "WARNING"
        WriteLog "  If this is a Uniform VMSS, PATH B will fail after VM deletion. Use -ForcePathA to be safe." "WARNING"
        if (-not $Force) { AskToContinue "Could not verify VMSS mode. Continue with PATH B?" }
        else { WriteLog "  Proceeding anyway (-Force specified)." "WARNING" }
    }
}

##############################################################################################################
# SYSTEM-ASSIGNED MI RBAC DETECTION  (PATH B only)
# Runs right after path selection so it is visible in DryRun output AND before any changes are made.
# Enumerates direct role assignments for the old system-assigned principal:
#   - Always logs what was found (deduped).
#   - Without -RestoreSystemAssignedRBAC: asks for confirmation if any assignments exist
#     (because the new principal will be different and RBAC will silently break).
#   - With -RestoreSystemAssignedRBAC: informs the operator that STEP 9B will auto-restore.
# Results are stored in $_preflightRbacAssignments so STEP 5B can write the export file
# without an extra API call.
##############################################################################################################

$_preflightRbacAssignments = @()
$_preflightRbacFetchFailed = $false
if ($_useRecreationPath -and $_hasSystemMI) {
    $_preflightMIPrincipalId = $vm.Identity.PrincipalId
    WriteLog "System-assigned MI RBAC check (PATH B pre-flight):" "IMPORTANT"
    WriteLog "  Old principal ID : $_preflightMIPrincipalId"
    WriteLog "  PATH B (VM recreation) assigns a NEW system-assigned principal after recreation."
    WriteLog "  Any RBAC role assignments on the old principal will silently break until updated."
    try {
        $_rawAssignments = @(Get-AzRoleAssignment -ObjectId $_preflightMIPrincipalId -ErrorAction Stop |
            ForEach-Object {
                [PSCustomObject]@{
                    OriginalPrincipalId = $_preflightMIPrincipalId
                    Scope               = $_.Scope
                    RoleDefinitionId    = $_.RoleDefinitionId
                    RoleDefinitionName  = $_.RoleDefinitionName
                }
            })
        $_preflightRbacAssignments = @($_rawAssignments | Sort-Object Scope, RoleDefinitionId -Unique)
        if ($_preflightRbacAssignments.Count -gt 0) {
            WriteLog "  Direct role assignments found ($($_preflightRbacAssignments.Count)):"
            foreach ($_ra in $_preflightRbacAssignments) {
                WriteLog "    '$($_ra.RoleDefinitionName)' on '$($_ra.Scope)'"
            }
            if ($RestoreSystemAssignedRBAC) {
                WriteLog "  RBAC restore: ENABLED (-RestoreSystemAssignedRBAC). Assignments will be saved before" "IMPORTANT"
                WriteLog "    deletion and restored to the new principal in STEP 9B." "IMPORTANT"
            } else {
                WriteLog "  RBAC restore: NOT requested. These assignments will NOT be automatically restored." "WARNING"
                WriteLog "    To auto-restore: re-run with -RestoreSystemAssignedRBAC." "WARNING"
                WriteLog "    To restore manually after recreation:" "WARNING"
                WriteLog "      1. Get new principal: (Get-AzVM -ResourceGroupName '$ResourceGroupName' -Name '$VMName').Identity.PrincipalId" "WARNING"
                WriteLog "      2. Re-create each assignment above with the new principal ID." "WARNING"
                # AskToContinue handles both -Force (auto-continue) and -DryRun (skip prompt) internally.
                AskToContinue "$($_preflightRbacAssignments.Count) RBAC assignment(s) will NOT be auto-restored after recreation. Continue?"
            }
        } else {
            WriteLog "  No direct role assignments found  -  nothing to restore." "INFO"
        }
    } catch {
        $_preflightRbacFetchFailed = $true
        WriteLog "  Warning: could not enumerate RBAC assignments: $_  -  proceeding." "WARNING"
        WriteLog "    Verify and re-assign RBAC manually after recreation if needed." "WARNING"
    }
}

# Accelerated networking advisory/action check (runs for both PATH A and PATH B)
# When target size supports accel networking:
#   -EnableAcceleratedNetworking specified -> will be enabled on NICs in STEP 7B.
#   Not specified -> warn if any NIC currently has it disabled.
# When target size does not support it: disabled on NICs in STEP 7B if needed.
if (-not $IgnoreSKUCheck) {
    $_accelNetCapability = Get-SKUCapability $targetSKU "AcceleratedNetworkingEnabled"
    $_accelNetSupported  = $_accelNetCapability -eq "True"
    if ($EnableAcceleratedNetworking -and -not $_accelNetSupported) {
        WriteLog "  -EnableAcceleratedNetworking specified but target size $VMSize does not support it - flag will be ignored." "WARNING"
    } elseif ($EnableAcceleratedNetworking -and $_accelNetSupported) {
        if (-not $_useRecreationPath) {
            WriteLog "  -EnableAcceleratedNetworking specified but PATH A (resize) is selected - NICs are not modified on resize." "WARNING"
            WriteLog "    To enable AcceleratedNetworking after conversion, stop the VM and run per NIC:" "WARNING"
            WriteLog "      `$nic = Get-AzNetworkInterface -Name <nicName> -ResourceGroupName '$ResourceGroupName'" "WARNING"
            WriteLog "      `$nic.EnableAcceleratedNetworking = `$true; Set-AzNetworkInterface -NetworkInterface `$nic" "WARNING"
            WriteLog "    Or re-run with -ForcePathB to use VM recreation, which updates NICs as part of STEP 7B." "WARNING"
        } else {
            WriteLog "  -EnableAcceleratedNetworking specified - AcceleratedNetworking will be enabled on all NICs." "INFO"
        }
    } elseif ($_accelNetSupported) {
        $_preflightNicCache = Get-AzNICBatch $vm.NetworkProfile.NetworkInterfaces
        $vm.NetworkProfile.NetworkInterfaces | ForEach-Object {
            $nicName = Get-ArmName $_.Id
            $nicObj  = $_preflightNicCache[$_.Id]
            if (-not $nicObj) {
                # NIC fetch failed (auth/throttle/transient ARM error) - do not report a false advisory.
                WriteLog "  Advisory: NIC '$nicName' could not be fetched - AcceleratedNetworking status unknown." "WARNING"
            } elseif (-not $nicObj.EnableAcceleratedNetworking) {
                WriteLog "  Advisory: NIC '$nicName' has AcceleratedNetworking disabled. Target size $VMSize supports it." "WARNING"
                WriteLog "    Enable automatically : re-run with -EnableAcceleratedNetworking" "WARNING"
                WriteLog "    Enable manually      : Azure Portal > NIC '$nicName' > Accelerated networking > Enabled" "WARNING"
            }
        }
    }
} else {
    # IgnoreSKUCheck: SKU data unavailable - assume AcceleratedNetworking NOT supported to be safe.
    # STEP 5B/STEP 7B NIC loop reads $_accelNetSupported directly, no recalculation needed.
    $_accelNetSupported = $false
    WriteLog "  Accel network check: skipped (-IgnoreSKUCheck) - assuming not supported, will disable on NICs if needed." "WARNING"
}

##############################################################################################################
# EXTENSION CHECK  (PATH B only  -  runs before any changes are made)
##############################################################################################################

# Helper: returns a human-readable explanation for why an extension type requires manual reinstall.
# Centralising this avoids the identical switch block appearing in both the pre-flight log
# (extension enumeration) and STEP 8B (actual reinstall), which was a maintenance hazard.
function Get-ExtensionManualReason {
    param([string]$ExtensionType)
    switch ($ExtensionType) {
        { $_ -in 'AzureDiskEncryption','AzureDiskEncryptionForLinux' } { return 'disk encryption - multi-step reinstall required' }
        { $_ -in 'CustomScriptExtension','customScript' }               { return 're-execution dangerous; may contain secrets' }
        'ADDomainExtension'                                              { return 'domain password in protected settings' }
        { $_ -in 'Microsoft.Powershell.DSC','DSCForLinux' }            { return 'may contain credentials in protected settings' }
        { $_ -in 'IaaSDiagnostics','LinuxDiagnostic' }                 { return 'storage account key in protected settings' }
        'ServiceFabricNode'                                              { return 'cluster/client certificate config in protected settings' }
        { $_ -in 'VMAccessAgent','VMAccessForLinux' }                   { return 'credentials (password/SSH key) in protected settings - reinstall with new credentials' }
        'DockerExtension'                                                { return 'TLS certs/registry credentials in protected settings; also retired since Nov 2018' }
        default                                                          { return 'protected settings or complex reinstall required; check extension documentation' }
    }
}

# Extensions managed by Azure service planes that re-deploy themselves automatically.
# These must be SKIPPED in STEP 8B: attempting to install them via Set-AzVMExtension
# either conflicts with the managing service's own deployment or installs with wrong
# onboarding settings that the service must provide. They will re-appear on the VM
# within minutes after recreation once their respective service detects the VM.
$_azureManagedExtTypes = @(
    # Azure Backup: reinstalls on the next scheduled backup job. RSV protection is
    # preserved because the VM resource ID is identical after same-name recreation.
    'VMSnapshot', 'VMSnapshotLinux',
    # Microsoft Defender for Cloud / Defender for Servers: MDE onboarding is managed
    # entirely by MDC. After recreation MDC detects the VM (same resource ID) and
    # re-pushes the extension automatically with the correct onboarding package.
    'MDE.Windows', 'MDE.Linux',
    # Azure Policy guest configuration: the Policy engine re-evaluates compliance after
    # VM recreation and re-pushes this extension automatically within ~15 minutes.
    # ExtensionType on Windows is 'ConfigurationforWindows' (not 'AzurePolicyforWindows',
    # which is only the extension Name). Both are listed; the check uses ExtensionType.
    'AzurePolicyforWindows', 'ConfigurationforWindows', 'ConfigurationforLinux',
    # Guest Attestation: pushed automatically by Azure for TrustedLaunch VMs to
    # enable measured boot and vTPM attestation. No operator action required.
    'GuestAttestation', 'GuestAttestationLinux'
)
# Extensions that cannot be auto-reinstalled by STEP 8B due to one or more of:
#   - Protected settings that the Azure API never returns (no recovery path without the original values).
#   - Multi-step installation procedures that go beyond a simple Set-AzVMExtension call (ADE).
#   - Re-execution risk: running the extension again has destructive side effects (CustomScriptExtension).
# These are logged as MANUAL in the pre-flight report and STEP 8B. Operator must reinstall after recreation.
# Note: -SkipExtensions takes precedence over this list — an extension listed by name in -SkipExtensions
# is always SKIP, even if its type appears here (operator has explicitly opted out).
$_manualExtTypes = @(
    # Disk encryption: multi-step process (BitLocker/dm-crypt + KV). Never just an extension install.
    'AzureDiskEncryption', 'AzureDiskEncryptionForLinux',
    # Custom script: re-execution is dangerous (side-effects); may have secrets in protected settings.
    'CustomScriptExtension', 'customScript',
    # Domain join: Active Directory password is in protected settings, no recovery path.
    'ADDomainExtension',
    # DSC: configuration may embed credential objects in protected settings.
    'Microsoft.Powershell.DSC', 'DSCForLinux',
    # Legacy diagnostics (WAD/LAD): storage account keys are in protected settings.
    'IaaSDiagnostics', 'LinuxDiagnostic',
    # Service Fabric node: cluster/client certificate thumbprints are in protected settings.
    'ServiceFabricNode',
    # VMAccess (Windows/Linux): resets passwords and SSH keys; credentials are in protected settings.
    # Operator must provide new credentials on reinstall (they have them - they set it up originally).
    'VMAccessAgent', 'VMAccessForLinux',
    # Docker extension: TLS certs and registry credentials are in protected settings.
    # Also officially retired by Microsoft in November 2018 - consider removing rather than reinstalling.
    'DockerExtension'
)

# Managed identity flags: moved to just after the initial VM fetch (above the pre-flight
# checks) so $_hasSystemMI / $_hasUserMI are available throughout all pre-flight sections.

function Test-ExtensionRequiresManual {
    # Returns $true when an extension type cannot be auto-reinstalled by STEP 8B.
    # Centralises the compound condition that checks both the definitive manual list
    # AND the KeyVault-without-MI edge case. Used in pre-flight, DryRun, and STEP 8B.
    param([string]$ExtensionType)
    return ($ExtensionType -in $_manualExtTypes) -or
           ($ExtensionType -in @('KeyVaultForWindows','KeyVaultForLinux') -and -not $_hasSystemMI -and -not $_hasUserMI)
}

$_extensionList = @()

if ($_useRecreationPath) {
    WriteLog "Checking VM extensions (PATH B: extensions are lost on recreation)..."
    try {
        $_extensionList = @(Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $VMName -ErrorAction SilentlyContinue)
        if ($_extensionList.Count -gt 0) {
            WriteLog "  $($_extensionList.Count) extension(s) found:" "WARNING"
            foreach ($_ext in $_extensionList) {
                if ($SkipExtensionReinstall) {
                    $_action = "SKIP    (-SkipExtensionReinstall)"
                } elseif ($SkipExtensions -and $_ext.Name -in $SkipExtensions) {
                    $_action = "SKIP    (-SkipExtensions: managed externally, will re-appear automatically)"
                } elseif ($_ext.ExtensionType -in $_azureManagedExtTypes) {
                    $_action = "SKIP    (Azure-managed: will re-appear automatically via service plane)"
                } elseif ($_ext.ExtensionType -in $_manualExtTypes) {
                    $_reason = Get-ExtensionManualReason -ExtensionType $_ext.ExtensionType
                    $_action = "MANUAL  - $_reason"
                } elseif ($_ext.ExtensionType -in @('KeyVaultForWindows','KeyVaultForLinux')) {
                    # KeyVault extension authenticates via managed identity - no protected settings needed.
                    # System-assigned MI gets a new principal ID after recreation -> RBAC must be updated.
                    if (-not $_hasSystemMI -and -not $_hasUserMI) {
                        $_action = "MANUAL  - no managed identity on VM; configure MI then reinstall"
                    } elseif ($_hasUserMI) {
                        $_action = "AUTO    - user-assigned MI preserves Key Vault RBAC (identity survives recreation)"
                    } else {
                        $_action = if ($RestoreSystemAssignedRBAC) { "AUTO    - will install; Key Vault RBAC restored in STEP 9B (-RestoreSystemAssignedRBAC)" } else { "AUTO    - will install; Key Vault RBAC must be manually updated for new system-assigned MI principal" }
                    }
                } elseif ($_ext.ExtensionType -eq 'SqlIaasAgent') {
                    # SQL IaaS Agent has no protected settings. Registration is via a separate
                    # Microsoft.SqlVirtualMachine/SqlVirtualMachines ARM resource (New-AzSqlVM).
                    # Remove-AzVM does NOT delete this resource - it survives PATH B and is
                    # automatically re-linked once the VM is recreated with the same resource ID.
                    # STEP 8B verifies this and only calls New-AzSqlVM if the resource is missing.
                    $_action = "AUTO    - SQL VM resource survives VM deletion and re-links automatically (verified in STEP 8B)"
                } elseif ($_ext.ExtensionType -in @('MicrosoftMonitoringAgent','OmsAgentForLinux')) {
                    # Workspace key (protected setting) will be retrieved from the Log Analytics workspace.
                    $_action = "AUTO    - workspace key will be fetched from Log Analytics in STEP 8B"
                } elseif ($_ext.ExtensionType -in @('AzureMonitorWindowsAgent','AzureMonitorLinuxAgent')) {
                    # New Azure Monitor Agent uses managed identity; no protected settings needed.
                    # Data Collection Rule associations reference the VM resource ID and survive recreation.
                    $_action = "AUTO    - uses managed identity; Data Collection Rule associations survive recreation"
                } elseif ($_ext.ExtensionType -in @('AADSSHLoginForLinux','AADLoginForWindows')) {
                    # No protected settings. AAD SSH/login RBAC is assigned on the VM resource ID
                    # (e.g. Virtual Machine Administrator Login role). Since the VM resource ID is
                    # identical after recreation with the same name and RG, RBAC is fully preserved.
                    $_action = "AUTO    - no protected settings; AAD login RBAC is on the VM resource ID (preserved after recreation)"
                } elseif ($_ext.ExtensionType -in @('VMSnapshot','VMSnapshotLinux')) {
                    # Managed by Azure Backup / Recovery Services Vault.
                    # The extension itself auto-reinstalls on the next scheduled backup job.
                    # Because PATH B recreates the VM with the same name and resource group,
                    # the resource ID is identical. Azure Backup recognises it as the same VM
                    # and existing recovery points and backup protection are automatically preserved.
                    $_action = "AUTO    - extension reinstalls on next backup job; RSV backup protection is preserved (same resource ID after recreation)"
                } elseif ($_ext.ExtensionType -in @('MDE.Windows','MDE.Linux')) {
                    # Managed by Microsoft Defender for Cloud / Defender for Servers.
                    # MDC identifies VMs by resource ID. After recreation (same name + RG = same
                    # resource ID) MDC automatically re-pushes the MDE onboarding package.
                    # Installing via Set-AzVMExtension would conflict with MDC's deployment.
                    $_action = "AUTO    - re-pushed automatically by Microsoft Defender for Cloud (same resource ID after recreation)"
                } elseif ($_ext.ExtensionType -in @('AzurePolicyforWindows','ConfigurationforWindows','ConfigurationforLinux')) {
                    # Managed by Azure Policy. The Policy engine re-evaluates compliance after
                    # VM recreation and re-deploys this extension automatically within ~15 minutes.
                    $_action = "AUTO    - re-pushed automatically by Azure Policy engine after compliance evaluation"
                } elseif ($_ext.ExtensionType -in @('GuestAttestation','GuestAttestationLinux')) {
                    # Pushed automatically by Azure for TrustedLaunch VMs to enable measured boot
                    # and vTPM attestation. No operator action or manual install needed.
                    $_action = "AUTO    - re-pushed automatically by Azure for TrustedLaunch VMs"
                } else {
                    $_action = "AUTO    - will be reinstalled in STEP 8B"
                }
                WriteLog "    [$_action]  $($_ext.Name) ($($_ext.Publisher) / $($_ext.ExtensionType) v$($_ext.TypeHandlerVersion))" "WARNING"
            }
            if (-not $DryRun) {
                # Only count as MANUAL if not already handled by -SkipExtensions.
                # An extension in -SkipExtensions is intentionally skipped in STEP 8B
                # even if its type is in $_manualExtTypes; prompting about it would be
                # misleading since the operator has already signalled they will handle it.
                # Azure-managed types are skipped in STEP 8B regardless of Test-ExtensionRequiresManual;
                # exclude them here so they never trigger the MANUAL acknowledgment prompt.
                # NOTE: comments between -and and the next expression break PS5.1 parsing.
                # All comments are placed before the Where-Object block; function calls wrapped in ().
                $_hasManual = $_extensionList | Where-Object {
                    -not ($SkipExtensions -and $_.Name -in $SkipExtensions) -and
                    $_.ExtensionType -notin $_azureManagedExtTypes -and
                    (Test-ExtensionRequiresManual $_.ExtensionType)
                }
                if ($_hasManual) {
                    WriteLog "  Extensions marked MANUAL cannot be auto-reinstalled - you must handle them after the script completes." "WARNING"
                    if (-not $Force) {
                        AskToContinue "Confirm you have noted the MANUAL extensions above. Continue?"
                    } else {
                        WriteLog "  Proceeding with MANUAL extensions noted (-Force specified). Reinstall them manually after conversion." "WARNING"
                    }
                }
            }
        } else {
            WriteLog "  No extensions found."
        }
    } catch {
        WriteLog "  Could not enumerate extensions: $_  -  verify manually after recreation." "WARNING"
    }
}


##############################################################################################################
# DRYRUN SUMMARY  (exits here when -DryRun is specified  -  no changes are made)
##############################################################################################################

if ($DryRun) {
    WriteLog "=======================================================" "IMPORTANT"
    WriteLog " DRYRUN MODE  -  no changes will be made" "IMPORTANT"
    WriteLog "=======================================================" "IMPORTANT"
    WriteLog "VM              : $VMName  (RG: $ResourceGroupName)"
    WriteLog "Current         : $script:_originalSize / $script:_originalController / $_sourceDiskArch"
    WriteLog "Target          : $VMSize / $NewControllerType / $_targetDiskArch"
    WriteLog "OS              : $_os"
    WriteLog "Execution path  : $(if ($_useRecreationPath) { 'PATH B  (Recreation)' } else { 'PATH A  (Resize)' })"
    if    ($ForcePathA)           { WriteLog "Path reason     : Forced via -ForcePathA" }
    elseif ($ForcePathB)          { WriteLog "Path reason     : Forced via -ForcePathB" }
    elseif ($_useRecreationPath)  { WriteLog "Path reason     : Windows cross-category disk architecture change ($_sourceDiskArch -> $_targetDiskArch)" }
    else                          { WriteLog "Path reason     : Same disk architecture category  -  direct in-place resize" }
    WriteLog ""
    WriteLog "STEPS THAT WOULD BE PERFORMED:" "IMPORTANT"

    # Shared OS prep steps (identical for PATH A and PATH B)
    if ($_needWindowsNvmePrep) {
        WriteLog "  [1 ] $(if ($FixOperatingSystemSettings) { 'Fix' } else { 'Check' }) stornvme NVMe driver on OS (RunCommand)"
    }
    if ($_needLinuxNvmePrep) {
        WriteLog "  [1 ] $(if ($FixOperatingSystemSettings) { 'Fix' } else { 'Check' }) Linux NVMe driver (initrd rebuild), GRUB io_timeout, fstab paths, azure-vm-utils (RunCommand)"
    }
    if ($_needPagefileFix -and -not $SkipPagefileFix -and $FixOperatingSystemSettings) {
        WriteLog "  [1b] Pagefile migration D:\ -> C:\ (RunCommand)"
    } elseif ($_needPagefileFix -and -not $SkipPagefileFix -and -not $FixOperatingSystemSettings) {
        WriteLog "  [1b] Pagefile migration D:\ -> C:\  *** REQUIRED - real run will ABORT here ***" "WARNING"
        WriteLog "       Source has a SCSI temp disk (D:\) but target does not  -  pagefile must" "WARNING"
        WriteLog "       be migrated before the VM is stopped. Add one of:" "WARNING"
        WriteLog "         -FixOperatingSystemSettings  (migrate automatically via RunCommand)" "WARNING"
        WriteLog "         -SkipPagefileFix             (skip if migrated manually)" "WARNING"
    }
    if ($_needNvmeTempDiskTask) {
        WriteLog "  [1c] Install NVMe temp disk startup task on VM (RunCommand)"
    }
    WriteLog "  [2 ] Stop VM (deallocate)"

    # Path-specific steps
    if (-not $_useRecreationPath) {
        if ($_isTrustedLaunchDowngrade) {
            WriteLog "  [2a] *** Downgrade TrustedLaunch -> Standard (vTPM state permanently destroyed) ***" "WARNING"
        }
        if (-not $_controllerAlreadyCorrect) {
            WriteLog "  [3A] Patch OS disk diskControllerTypes -> '$(if ($NewControllerType -eq 'NVMe') { 'SCSI, NVMe' } else { 'SCSI' })' (REST API)"
        }
        WriteLog "  [4A] Resize VM: $script:_originalSize -> $VMSize, controller -> $NewControllerType (Update-AzVM)"
        if ($_isTrustedLaunchDowngrade) {
            WriteLog "  [4Aa] Re-enable TrustedLaunch (SecurityType -> TrustedLaunch, fresh empty vTPM)" "WARNING"
        }
        if ($StartVM) { WriteLog "  [5A] Start VM" }
        WriteLog ""
        WriteLog "RESOURCES THAT WOULD BE MODIFIED:" "IMPORTANT"
        if (-not $_controllerAlreadyCorrect) { WriteLog "  OS disk '$($osDisk.Name)': diskControllerTypes updated (disk preserved)" }
        WriteLog "  VM '$VMName': resized in-place  (no deletion, all resources preserved)"
    } else {
        if ($_isTrustedLaunchDowngrade) {
            WriteLog "  [2a] *** Downgrade TrustedLaunch -> Standard (vTPM state permanently destroyed) ***" "WARNING"
            WriteLog "       TrustedLaunch is restored automatically in STEP 7B on the new VM." "WARNING"
        }
        WriteLog "  [3B] Create OS disk snapshot: $($osDisk.Name)-snap-<timestamp>  (safety backup  -  taken BEFORE any modification)"
        WriteLog "  [4B] Patch OS disk diskControllerTypes -> '$(if ($NewControllerType -eq 'NVMe') { 'SCSI, NVMe' } else { 'SCSI' })' (REST API)"
        WriteLog "  [5B] Capture VM config  (NICs, data disks, OS disk caching, DeleteOptions, tags, identity, priority, host, extensions, backend pools ...) + Automanage enrollment detection (enrollment will be lost - re-enroll after recreation)"
        WriteLog "  [6B] Set DeleteOption=Detach on all resources, verify, then DELETE VM shell '$VMName'"
        WriteLog "       OS disk '$($osDisk.Name)', NICs and data disks are PRESERVED throughout"
        if ($_secTypeForCheck -eq 'TrustedLaunch') {
            WriteLog "       *** TrustedLaunch WARNING: vTPM state is permanently destroyed at this step (VM deletion) ***" "WARNING"
            WriteLog "       The TrustedLaunch security posture (SecureBoot + vTPM chip) IS restored in STEP 7B." "WARNING"
        }
        WriteLog "  [7B] CREATE new VM '$VMName'  (size: $VMSize, controller: $NewControllerType)"
        # Correct counts: compute mutually exclusive buckets in the same priority order as the
        # STEP 8B foreach loop (SkipExtensionReinstall > SkipExtensions > azure-managed > MANUAL > AUTO).
        # Without this order, an extension that matches BOTH MANUAL (by type) AND SkipExtensions
        # (by name) would be double-counted, making $_autoCount go negative.
        $_manualCount  = @($_extensionList | Where-Object {
            -not ($SkipExtensions -and $_.Name -in $SkipExtensions) -and
            -not ($_.ExtensionType -in $_azureManagedExtTypes) -and
            (Test-ExtensionRequiresManual $_.ExtensionType) }).Count
        $_azMgdCount   = @($_extensionList | Where-Object {
            -not ($SkipExtensions -and $_.Name -in $SkipExtensions) -and
            $_.ExtensionType -in $_azureManagedExtTypes }).Count
        $_skipExtCount = @($_extensionList | Where-Object { $SkipExtensions -and $_.Name -in $SkipExtensions }).Count
        $_autoCount    = $_extensionList.Count - $_manualCount - $_azMgdCount - $_skipExtCount
        if (-not $SkipExtensionReinstall -and $_extensionList.Count -gt 0) {
            $_skipNote = if (($_azMgdCount + $_skipExtCount) -gt 0) { ", $($_azMgdCount + $_skipExtCount) skipped (azure-managed/-SkipExtensions)" } else { "" }
            WriteLog "  [8B] Auto-reinstall $_autoCount extension(s)  ($_manualCount require manual reinstall$_skipNote)"
        } elseif ($SkipExtensionReinstall -and $_extensionList.Count -gt 0) {
            WriteLog "  [8B] SKIP extension reinstall (-SkipExtensionReinstall)  -  $($_extensionList.Count) extension(s) need manual reinstall" "WARNING"
        }
        if ($_hasSystemMI -and $RestoreSystemAssignedRBAC) {
            WriteLog "  [9B] Restore system-assigned managed identity RBAC assignments (-RestoreSystemAssignedRBAC)"
        } elseif ($_hasSystemMI -and -not $RestoreSystemAssignedRBAC -and $_preflightRbacAssignments.Count -gt 0) {
            WriteLog "  [9B] SKIP RBAC auto-restore (-RestoreSystemAssignedRBAC not specified)  -  re-assign manually" "WARNING"
        }
        WriteLog "  [10B] $(if ($KeepSnapshot) { 'RETAIN' } else { 'Delete' }) OS disk snapshot"
        WriteLog ""
        WriteLog "RESOURCES THAT WOULD BE MODIFIED / CREATED / DELETED:" "IMPORTANT"
        WriteLog "  OS disk '$($osDisk.Name)': diskControllerTypes updated  (disk is PRESERVED)"
        WriteLog "  VM '$VMName': shell DELETED and RECREATED  (OS disk, NICs and data disks are PRESERVED)"
        WriteLog "  Snapshot: CREATED as backup  ($(if ($KeepSnapshot) { 'retained  -  delete manually when done' } else { 'auto-deleted after successful recreation' }))"
        if ($_hasSystemMI) {
            if ($RestoreSystemAssignedRBAC) {
                WriteLog "  System-assigned MI RBAC: $($_preflightRbacAssignments.Count) assignment(s) will be saved before deletion and restored to new principal in STEP 9B"
            } elseif ($_preflightRbacAssignments.Count -gt 0) {
                WriteLog "  System-assigned MI RBAC: $($_preflightRbacAssignments.Count) assignment(s) detected  -  NOT auto-restored (use -RestoreSystemAssignedRBAC to auto-restore)" "WARNING"
            } else {
                WriteLog "  System-assigned MI RBAC: no direct assignments found  -  nothing to restore" "INFO"
            }
        }
    }
    if ($_extensionList.Count -gt 0) {
        WriteLog ""
        WriteLog "EXTENSIONS  ($($_extensionList.Count) found  -  will be lost on PATH B recreation):" "IMPORTANT"
        foreach ($_ext in $_extensionList) {
            $_action = if     ($SkipExtensionReinstall)                                      { "SKIP  " }
                        elseif ($SkipExtensions -and $_ext.Name -in $SkipExtensions)          { "SKIP  " }
                        elseif ($_ext.ExtensionType -in $_azureManagedExtTypes)               { "SKIP  " }
                        elseif (Test-ExtensionRequiresManual $_ext.ExtensionType)             { "MANUAL" }
                        else                                                                  { "AUTO  " }
            WriteLog "    [$_action]  $($_ext.Name) ($($_ext.Publisher) / $($_ext.ExtensionType) v$($_ext.TypeHandlerVersion))" "WARNING"
        }
        WriteLog "  AUTO   = reinstalled automatically in STEP 8B (KeyVault via MI; MMA/OMS via workspace key lookup; SQL IaaS auto-relinks)"
        WriteLog "  MANUAL = protected settings / multi-step install / re-execution risk  -  reinstall manually after recreation" "WARNING"
        WriteLog "  SKIP   = -SkipExtensionReinstall, -SkipExtensions, or Azure-managed (re-deploys automatically via service plane)" "WARNING"
        $_azureManagedInList = @($_extensionList | Where-Object { $_.ExtensionType -in $_azureManagedExtTypes })
        if ($_azureManagedInList.Count -gt 0) {
            WriteLog "  Note: Azure-managed extensions (MDE, Azure Policy, GuestAttestation, VMSnapshot) re-deploy automatically via their service plane after recreation."
        }
    }
    WriteLog ""
    WriteLog "No changes were made. Re-run without -DryRun to apply." "IMPORTANT"
    WriteLog "=======================================================" "IMPORTANT"
    exit 0
}

# Pagefile guard  -  must fix before proceeding
if ($_needPagefileFix -and -not $SkipPagefileFix) {
    if (-not $FixOperatingSystemSettings) {
        WriteLog "Source has a SCSI temp disk (D:\) and target does not  -  pagefile on D:\ must be migrated to C:\ first." "IMPORTANT"
        WriteLog "STOPPING  -  re-run with one of:" "ERROR"
        WriteLog "  -FixOperatingSystemSettings   Migrate pagefile automatically (recommended)" "ERROR"
        WriteLog "  -SkipPagefileFix              Skip if already migrated manually" "ERROR"
        Stop-Script
    }
}

##############################################################################################################
# STEP 1  -  NVMe DRIVER PREPARATION (Windows, controller not yet NVMe)
##############################################################################################################

if ($_needWindowsNvmePrep) {
    WriteLog "--- STEP 1: Windows NVMe driver preparation ---" "IMPORTANT"
    EnsureVMRunning

    $checkNVMe = @'
$reg   = "HKLM:\SYSTEM\CurrentControlSet\Services\stornvme"
if (-not (Test-Path $reg)) {
    Write-Output "Start:ERROR (stornvme registry key not found - driver may not be installed)"
} else {
    $start = (Get-ItemProperty -Path $reg -Name Start -ErrorAction SilentlyContinue).Start
    if ($null -eq $start)  { Write-Output "Start:ERROR (Start value missing from registry key)" }
    elseif ($start -eq 0)  { Write-Output "Start:OK" }
    else                   { Write-Output "Start:ERROR (value=$start)" }
    $so = Get-ItemProperty -Path "$reg\StartOverride" -ErrorAction SilentlyContinue
    if ($so) { Write-Output "StartOverride:ERROR (present)" } else { Write-Output "StartOverride:OK" }
}
'@

    $fixNVMe = @'
$reg = "HKLM:\SYSTEM\CurrentControlSet\Services\stornvme"
if (-not (Test-Path $reg)) {
    Write-Output "ERROR: stornvme registry key not found - driver may not be installed. Cannot set Boot start."
} else {
    $so  = Get-ItemProperty -Path "$reg\StartOverride" -ErrorAction SilentlyContinue
    if ($so) { Remove-Item -Path "$reg\StartOverride" -Force; Write-Output "INFO: StartOverride removed." }
    else { Write-Output "INFO: StartOverride not present - OK." }
    $sc = & sc.exe config stornvme start=boot 2>&1
    Write-Output "SC: $sc"
    $after = (Get-ItemProperty -Path $reg -Name Start -ErrorAction SilentlyContinue).Start
    if ($null -eq $after)  { Write-Output "ERROR: Could not read Start value after sc.exe - verify manually." }
    elseif ($after -eq 0)  { Write-Output "INFO: stornvme Start=Boot - OK." }
    else                   { Write-Output "ERROR: stornvme Start=$after - manual check required!" }
}
'@

    if ($FixOperatingSystemSettings) {
        WriteLog "Fixing stornvme driver (set to Boot)..."
        Invoke-CheckedRunCommand -ScriptString $fixNVMe -Description "stornvme fix" -ErrorPrompt "Errors in NVMe driver fix. Continue?" | Out-Null
    } else {
        WriteLog "Checking stornvme driver (check only)..."
        $out    = Invoke-RunCommand -ScriptString $checkNVMe -Description "stornvme check"
        $errors = 0
        foreach ($line in $out) {
            $line = $line.Trim(); if (-not $line) { continue }
            if ($line -like "Start:ERROR*")         { WriteLog "stornvme NOT set to Boot!" "ERROR"; $errors++ }
            elseif ($line -like "Start:OK*")        { WriteLog "stornvme Start=Boot  -  OK." }
            if ($line -like "StartOverride:ERROR*") { WriteLog "StartOverride present  -  may override Boot!" "ERROR"; $errors++ }
            elseif ($line -like "StartOverride:OK*"){ WriteLog "StartOverride not present  -  OK." }
        }
        if ($errors -gt 0) {
            WriteLog "OS not ready for NVMe. Use -FixOperatingSystemSettings to fix." "WARNING"
            if (-not $Force) { AskToContinue "Continue despite errors?" }
            else { WriteLog "Continuing despite OS check errors (-Force specified)." "WARNING" }
        }
    }

} elseif ($_needLinuxNvmePrep) {
    WriteLog "--- STEP 1: Linux NVMe driver preparation ---" "IMPORTANT"
    EnsureVMRunning

    $linuxScript = @'
#!/bin/bash
fix=false
if [ -f /etc/os-release ]; then source /etc/os-release; distro="$ID"; else distro="unknown"; fi
echo "[INFO] Distro: $distro"
case "$distro" in
    ubuntu|debian)
        # Target the running kernel's initrd specifically.
        # lsinitramfs accepts only one argument; using the glob /boot/initrd.img-* with
        # multiple kernels installed would silently check only the first file in glob order,
        # which may not be the running kernel. $(uname -r) is always the right target.
        _running_initrd="/boot/initrd.img-$(uname -r)"
        if [ ! -f "$_running_initrd" ]; then
            echo "[WARNING] Running kernel initrd not found at $_running_initrd - skipping initrd check."
        else
            lsinitramfs "$_running_initrd" 2>/dev/null | grep -q nvme && echo "[INFO] NVMe in initrd ($(uname -r)) - OK." || {
                echo "[ERROR] NVMe NOT in initrd for running kernel $(uname -r)."
                $fix && { update-initramfs -u -k all; echo "[INFO] initrd rebuilt for all kernels."; }
            }
        fi ;;
    rhel|centos|rocky|almalinux|sles|suse|ol|fedora|mariner|azurelinux)
        # Target the running kernel's initramfs specifically (dracut naming convention).
        # lsinitrd without arguments inspects the most-recently-built image, which may differ
        # from the running kernel when multiple kernels are installed (e.g. after a yum/zypper
        # update that installed a new kernel but has not yet rebooted into it).
        _running_initrd="/boot/initramfs-$(uname -r).img"
        if [ ! -f "$_running_initrd" ]; then
            echo "[WARNING] Running kernel initrd not found at $_running_initrd - skipping initrd check."
        else
            lsinitrd "$_running_initrd" 2>/dev/null | grep -q nvme && echo "[INFO] NVMe in initrd ($(uname -r)) - OK." || {
                echo "[ERROR] NVMe NOT in initrd for running kernel $(uname -r)."
                $fix && { mkdir -p /etc/dracut.conf.d; echo 'add_drivers+=" nvme nvme-core "' > /etc/dracut.conf.d/nvme.conf; dracut -f --kver "$(uname -r)"; echo "[INFO] initrd rebuilt for running kernel $(uname -r)."; }
            }
        fi ;;
    flatcar)
        # Flatcar uses a read-only rootfs; NVMe drivers are compiled into the kernel.
        echo "[INFO] Flatcar detected - NVMe driver is built into the kernel, no initrd rebuild needed." ;;
    *) echo "[WARNING] Unknown distro '$distro' - initrd check skipped. Verify NVMe driver is in initrd manually." ;;
esac
# Check nvme_core.io_timeout. Distinguish three cases:
#   (1) =240 already set        -> INFO, no action.
#   (2) Set to a different value -> WARNING, do NOT overwrite (operator may have set it intentionally).
#   (3) Not set at all           -> ERROR when checking; fix when -FixOperatingSystemSettings.
if grep -q "nvme_core.io_timeout=240" /etc/default/grub /boot/grub/grub.cfg 2>/dev/null; then
    echo "[INFO] nvme_core.io_timeout=240 - OK."
elif grep -q "nvme_core.io_timeout" /etc/default/grub 2>/dev/null; then
    _cur=$(grep -o 'nvme_core.io_timeout=[^ "]*' /etc/default/grub | head -1)
    echo "[WARNING] nvme_core.io_timeout is set to $_cur (not 240). Azure recommends 240. Not overwriting - verify this value is sufficient for your workload."
else
    echo "[ERROR] nvme_core.io_timeout not set in /etc/default/grub."
    if $fix; then
        # Append to GRUB_CMDLINE_LINUX (covers both the base and _DEFAULT variant).
        # The sed handles two cases: empty value ("") -> no leading space added;
        # non-empty value -> single space separator before the new parameter.
        sed -i \
            -e 's/^\(GRUB_CMDLINE_LINUX="\)\(.*[^ ]\)\(".*\)$/\1\2 nvme_core.io_timeout=240\3/' \
            -e 's/^\(GRUB_CMDLINE_LINUX="\)\(".*\)$/\1nvme_core.io_timeout=240\2/' \
            -e 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="\)\(.*[^ ]\)\(".*\)$/\1\2 nvme_core.io_timeout=240\3/' \
            -e 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="\)\(".*\)$/\1nvme_core.io_timeout=240\2/' \
            /etc/default/grub
        # Gen2 Azure VMs use EFI; grub.cfg lives under /boot/efi/EFI/<distro>/.
        # Probe for the EFI grub.cfg path first; fall back to BIOS /boot/grub2/grub.cfg;
        # finally fall back to update-grub (Debian/Ubuntu).
        if command -v grub2-mkconfig >/dev/null 2>&1; then
            _efi_cfg=$(find /boot/efi/EFI -name grub.cfg 2>/dev/null | head -1)
            if [ -n "$_efi_cfg" ]; then
                grub2-mkconfig -o "$_efi_cfg"
                echo "[INFO] GRUB config written to EFI path: $_efi_cfg"
            else
                grub2-mkconfig -o /boot/grub2/grub.cfg
                echo "[INFO] GRUB config written to BIOS path: /boot/grub2/grub.cfg"
            fi
        else
            update-grub
        fi
        echo "[INFO] GRUB updated."
    fi
fi
# Check fstab for SCSI device paths.
# /dev/sdb is the SCSI temp disk - fstab entries for it should be REMOVED (not replaced),
# since the temp disk disappears after NVMe conversion (or becomes raw NVMe on nvme-temp targets).
# Other /dev/sd* paths (data disks, /dev/sda) should be replaced with UUID= or by-lun/ paths.
if grep -Eq '/dev/sd[a-z][0-9]*|/dev/disk/azure/scsi' /etc/fstab; then
    _sdb_entries=$(grep -E '/dev/sdb[0-9]*' /etc/fstab || true)
    _other_entries=$(grep -E '/dev/sd[ac-z][0-9]*|/dev/disk/azure/scsi' /etc/fstab || true)
    if [ -n "$_sdb_entries" ]; then
        echo "[ERROR] fstab has /dev/sdb entries (SCSI temp disk) - REMOVE these lines; the temp disk is not persistent."
        echo "$_sdb_entries" | while IFS= read -r line; do echo "[ERROR]   $line"; done
    fi
    if [ -n "$_other_entries" ]; then
        echo "[ERROR] fstab has /dev/sd* or SCSI paths for non-temp disks - replace with UUID= or /dev/disk/azure/data/by-lun/X."
        echo "$_other_entries" | while IFS= read -r line; do echo "[ERROR]   $line"; done
    fi
else
    echo "[INFO] fstab: no SCSI device paths found - OK."
fi
# Also check for raw NVMe device paths (/dev/nvme0n* etc.) in fstab.
# On v7+ VM sizes Azure distributes disks across two controllers based on caching policy;
# a caching change silently moves a disk to the other controller on next boot, making
# /dev/nvme0nX and /dev/nvme1nX paths point to the wrong disk without warning.
grep -Eq '/dev/nvme[0-9]+n[0-9]+' /etc/fstab \
    && echo "[WARNING] fstab has raw /dev/nvme* paths - use UUID= or /dev/disk/azure/data/by-lun/X instead (stable across controller reassignment on v7+ sizes)." \
    || echo "[INFO] fstab: no raw /dev/nvme* paths found - OK."
# Check waagent.conf for ResourceDisk settings.
# After SCSI->NVMe conversion (or scsi-temp->diskless), waagent can no longer find or
# format the temp disk. If ResourceDisk.Format=y or ResourceDisk.EnableSwap=y is set,
# waagent will repeatedly fail to find /dev/sdb on each boot, generating error log noise
# and leaving swap/temp-mount silently non-functional.
if [ -f /etc/waagent.conf ]; then
    _rd_format=$(grep -i '^\s*ResourceDisk\.Format\s*=' /etc/waagent.conf | tail -1 | grep -io 'y$' || true)
    _rd_swap=$(grep -i '^\s*ResourceDisk\.EnableSwap\s*=' /etc/waagent.conf | tail -1 | grep -io 'y$' || true)
    if [ -n "$_rd_format" ] || [ -n "$_rd_swap" ]; then
        echo "[WARNING] waagent.conf has ResourceDisk settings enabled that may fail after NVMe conversion:"
        [ -n "$_rd_format" ] && echo "[WARNING]   ResourceDisk.Format=y  - waagent will fail to format the temp disk (set to n after conversion)"
        [ -n "$_rd_swap"   ] && echo "[WARNING]   ResourceDisk.EnableSwap=y  - waagent-managed swap will silently stop working (set to n and configure swap separately)"
        echo "[WARNING]   Edit /etc/waagent.conf after conversion and set these to n."
    else
        echo "[INFO] waagent.conf ResourceDisk settings: Format/EnableSwap not active - OK."
    fi
else
    echo "[INFO] /etc/waagent.conf not found - skipping ResourceDisk check."
fi
# Check for azure-vm-utils (provides NVMe udev rules; replaces SCSI waagent rules).
# After NVMe conversion, /dev/disk/azure/scsi1/lunX symlinks are no longer created.
# azure-vm-utils creates /dev/disk/azure/data/by-lun/X as the NVMe replacement.
if command -v azure-nvme-id &>/dev/null || \
   (command -v dpkg &>/dev/null && dpkg -l azure-vm-utils 2>/dev/null | grep -q '^ii') || \
   (command -v rpm  &>/dev/null && rpm -q azure-vm-utils &>/dev/null); then
    echo "[INFO] azure-vm-utils installed - /dev/disk/azure/data/by-lun/X NVMe symlinks will be available."
    echo "[INFO] Note: /dev/disk/azure/scsi1/lunX symlinks will stop working after NVMe conversion"
    echo "[INFO] regardless of azure-vm-utils (waagent SCSI udev rules only fire for SCSI disks)."
else
    echo "[WARNING] azure-vm-utils not installed."
    echo "[WARNING] Note 1: /dev/disk/azure/scsi1/lunX symlinks stop working after NVMe conversion regardless"
    echo "[WARNING]         (waagent SCSI udev rules only fire for SCSI disks, not NVMe)."
    echo "[WARNING] Note 2: Without azure-vm-utils there are no stable NVMe replacement symlinks at"
    echo "[WARNING]         /dev/disk/azure/data/by-lun/ for data disk identification."
    echo "[WARNING] Pre-installed on marketplace images: Ubuntu 22.04/24.04/25.04, Azure Linux 2.0, Fedora 42, Flatcar."
    echo "[WARNING] Must be installed on: RHEL/Rocky, SLES, Debian, older Ubuntu."
    if $fix; then
        echo "[INFO] Attempting to install azure-vm-utils..."
        if   command -v apt-get &>/dev/null; then DEBIAN_FRONTEND=noninteractive apt-get install -y azure-vm-utils 2>&1 && echo "[INFO] azure-vm-utils installed." || echo "[WARNING] Install failed - install manually: apt-get install azure-vm-utils"
        elif command -v dnf     &>/dev/null; then dnf install -y azure-vm-utils 2>&1 && echo "[INFO] azure-vm-utils installed." || echo "[WARNING] Install failed - install manually: dnf install azure-vm-utils"
        elif command -v zypper  &>/dev/null; then zypper install -y azure-vm-utils 2>&1 && echo "[INFO] azure-vm-utils installed." || echo "[WARNING] Install failed - install manually: zypper install azure-vm-utils"
        else echo "[WARNING] Unknown package manager - install azure-vm-utils manually."; fi
    fi
fi
'@
    if ($FixOperatingSystemSettings) { $linuxScript = $linuxScript.Replace("fix=false","fix=true") }
    try {
        Invoke-CheckedRunCommand -ScriptString $linuxScript -CommandId "RunShellScript" `
            -Description "Linux NVMe driver prep" `
            -ErrorPrompt "Linux OS check errors (use -FixOperatingSystemSettings to fix). Continue?" | Out-Null
    } catch { Stop-Script "Error in Linux RunCommand: $_" }

} elseif ($IgnoreOSCheck) {
    WriteLog "OS check skipped (IgnoreOSCheck)." "WARNING"
} else {
    WriteLog "STEP 1: No OS preparation needed (controller already $NewControllerType or target is SCSI, $_os)."
}

##############################################################################################################
# STEP 1b  -  PAGEFILE MIGRATION (independent of controller change)
##############################################################################################################

if ($_needPagefileFix -and -not $SkipPagefileFix -and $FixOperatingSystemSettings) {
    WriteLog "--- STEP 1b: Pagefile migration D:\ -> C:\ ---" "IMPORTANT"
    EnsureVMRunning

    $pagefileScript = @'
# Use Get-CimInstance instead of Get-WmiObject.
# RunCommand (RunPowerShellScript) always executes via the VM Agent using Windows PowerShell 5.1,
# regardless of whether PS7 is installed on the VM - so Get-WmiObject would work here today.
# Get-CimInstance is used because Get-WmiObject is marked deprecated by Microsoft and may be
# removed in a future Windows release. Get-CimInstance is the supported replacement and works
# identically on PS 5.1. CIM objects do not support .Put()/.Delete() - use Invoke-CimMethod and
# Remove-CimInstance instead.
$existing = Get-CimInstance Win32_PageFileSetting
$cs       = Get-CimInstance Win32_ComputerSystem
# Check if pagefile is already correctly set to C:\ only
$hasC  = $existing | Where-Object { $_.Name -like "C:\*" }
$hasD  = $existing | Where-Object { $_.Name -like "D:\*" }
$isAuto = $cs.AutomaticManagedPagefile
if ($hasC -and -not $hasD -and -not $isAuto) {
    Write-Output "INFO: Pagefile already configured on C:\ only - no changes needed."
    exit 0
}
if ($isAuto) {
    Invoke-CimMethod -InputObject $cs -MethodName SetAutomaticManagedPagefile -Arguments @{ AutomaticManagedPagefile = $false } | Out-Null
    Write-Output "INFO: Automatic managed pagefile disabled."
}
foreach ($pf in (Get-CimInstance Win32_PageFileSetting)) {
    Write-Output "INFO: Removing pagefile: $($pf.Name)"
    Remove-CimInstance -InputObject $pf
}
$newPF = New-CimInstance -ClassName Win32_PageFileSetting -Property @{ Name = "C:\pagefile.sys"; InitialSize = [uint32]0; MaximumSize = [uint32]0 }
if (-not $newPF) {
    Write-Output "ERROR: Failed to create pagefile setting on C:\pagefile.sys - verify WMI repository health."
} else {
    Write-Output "INFO: Pagefile configured on C:\pagefile.sys (system managed)."
}
$dDrive = Get-PSDrive -Name D -ErrorAction SilentlyContinue
if ($dDrive) {
    $nonStd = Get-ChildItem -Path "D:\" -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -notin @(
                  "pagefile.sys","swapfile.sys","hiberfil.sys",
                  "Temp","Windows",
                  "CollectGuestLogsTemp",
                  "DATALOSS_WARNING_README.txt"
              ) }
    if ($nonStd) {
        Write-Output "WARNING: The following items on D:\ will be lost after resize:"
        $nonStd | ForEach-Object { Write-Output "WARNING:   $($_.FullName)" }
    } else { Write-Output "INFO: D:\ contains only standard items - safe to proceed." }
} else { Write-Output "INFO: D:\ not present." }
Write-Output "INFO: Pagefile setting updated. Change takes effect on next boot - no reboot needed now."
'@

    try {
        $pfOut    = Invoke-RunCommand -ScriptString $pagefileScript -Description "Pagefile migration"
        $pfErrors = ParseAndLogOutput -Lines $pfOut
        $pfWarn   = $pfOut | Where-Object { $_ -like "WARNING:*" }
        if ($pfWarn) {
            if (-not $Force) { AskToContinue "Non-standard data found on D:\  -  it will be lost. Continue?" }
            else { WriteLog "Non-standard data on D:\ will be lost  -  proceeding (-Force specified)." "WARNING" }
        }
        if ($pfErrors -gt 0) {
            if (-not $Force) { AskToContinue "Errors during pagefile migration. Continue?" }
            else { WriteLog "Errors during pagefile migration  -  proceeding (-Force specified)." "WARNING" }
        }
        # No reboot needed: the registry change takes effect on next boot.
        # The VM is about to be deallocated anyway; Windows will use the new
        # pagefile setting when the resized/recreated VM starts up.
        WriteLog "Pagefile setting updated - change will activate on next boot (no reboot required now)."
    } catch { Stop-Script "Error during pagefile migration: $_" }

} elseif ($_needPagefileFix -and $SkipPagefileFix) {
    WriteLog "Pagefile migration skipped (SkipPagefileFix)  -  assuming already done manually." "WARNING"
}

##############################################################################################################
# STEP 1c  -  INSTALL NVME TEMP DISK STARTUP SCRIPT (only when target is nvme-temp)
#
# On v6/v7 VMs the NVMe temp disk is presented RAW and unpartitioned on every boot.
# Windows will not automatically initialize it or assign a drive letter.
# We install a Scheduled Task that runs at SYSTEM startup to safely find and format it.
#
# IDENTIFICATION STRATEGY:
#   Uses the official Azure method (https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-temp-faqs):
#     Get-PhysicalDisk | where { $_.FriendlyName.contains("NVMe Direct Disk") }
#   The physical disk is correlated to a logical disk number via SerialNumber.
#   A final safety check confirms all disks are still RAW before initializing.
#
# MULTI-DISK SUPPORT:
#   Larger VM sizes (e.g. D16ads_v7 = 2 disks, D32ads_v7 = 4 disks) present multiple
#   NVMe temp disks. When more than one is found, a Windows Storage Pool with a striped
#   Virtual Disk is created so all disks appear as a single D:\ volume.
##############################################################################################################

if ($_needNvmeTempDiskTask) {

    WriteLog "--- STEP 1c: Installing NVMe temp disk startup task ---" "IMPORTANT"

    # Validate the script location path before it is interpolated into the RunCommand here-string.
    # The value is embedded inside a double-quoted here-string (@"..."@) sent via Invoke-AzVMRunCommand.
    # Blocked characters and their risks:
    #   "          -> breaks the double-quoted here-string syntax
    #   ; \r \n    -> injects additional commands or breaks the line
    #   ` (backtick) -> PowerShell escape in double-quoted strings
    #   $          -> local subexpression expansion (e.g. $(whoami)) before the string is sent
    #   (space)    -> breaks the -File path in the scheduled task -Argument (path would need quotes
    #                 that cannot be reliably nested inside the here-string)
    if ($NVMEDiskInitScriptLocation -match '["\r\n;`$ ]') {
        WriteLog "NVMEDiskInitScriptLocation contains unsafe characters (`", ;, backtick, `$, space, or newline)." "ERROR"
        Stop-Script "  Use a plain path without spaces or special characters, e.g. 'C:\AdminScripts'."
    }

    EnsureVMRunning

    # The initializer script content  -  will be written to $NVMEDiskInitScriptLocation\NVMeTempDiskInit.ps1
    $nvmeInitScript = @'
# ============================================================
# Azure NVMe Temp Disk Initializer - NVMeTempDiskInit.ps1
# Installed by AzureVM-NVME-and-localdisk-Conversion.ps1
# Runs at system startup via Scheduled Task.
#
# IDENTIFICATION:
#   Uses the official Azure method: Get-PhysicalDisk | where FriendlyName contains "NVMe Direct Disk"
#   Source: https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-temp-faqs
#
# MULTI-DISK SUPPORT:
#   Larger VM sizes (e.g. D16ads_v7, D32ads_v7) present multiple NVMe temp disks.
#   When more than one disk is found, a striped Storage Pool is created so all disks
#   appear as a single D:\ volume for maximum sequential throughput.
#   Single disk: standard GPT + NTFS partition.
#
# SAFETY:
#   Only disks that are still RAW are touched. Already-initialized disks (normal reboot
#   without host reallocation) are detected and skipped without any changes.
# ============================================================

$logFile    = "C:\Windows\Temp\NVMeTempDiskInit.log"
$maxLogSize = 500KB
$maxLogs    = 4

# Log rotation
if (Test-Path $logFile) {
    if ((Get-Item $logFile).Length -ge $maxLogSize) {
        $oldest = "$logFile.$maxLogs"
        if (Test-Path $oldest) { Remove-Item $oldest -Force }
        for ($i = $maxLogs - 1; $i -ge 1; $i--) {
            $src = "$logFile.$i"
            $dst = "$logFile.$($i + 1)"
            if (Test-Path $src) { Rename-Item $src $dst -Force }
        }
        Rename-Item $logFile "$logFile.1" -Force
    }
}

function Log { param($msg) $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"; "$ts  $msg" | Out-File $logFile -Append -Encoding UTF8 }

Log "NVMe temp disk initializer started."

# Step 1: find all NVMe temp disks using the official Azure FriendlyName method
$physDisks = @(Get-PhysicalDisk | Where-Object { $_.FriendlyName -like "*NVMe Direct Disk*" })

if ($physDisks.Count -eq 0) {
    Log "No physical disks with FriendlyName 'NVMe Direct Disk' found - VM may have no temp disk."
    exit 0
}
Log "Found $($physDisks.Count) NVMe temp disk(s):"
$physDisks | ForEach-Object { Log "  FriendlyName='$($_.FriendlyName)', Serial='$($_.SerialNumber.Trim())', Size=$([math]::Round($_.Size/1GB,1)) GB" }

# Step 2: correlate each physical disk to a logical disk via SerialNumber
$candidates = @()
foreach ($pd in $physDisks) {
    $d = Get-Disk | Where-Object { $_.SerialNumber.Trim() -eq $pd.SerialNumber.Trim() } | Select-Object -First 1
    if (-not $d) { Log "ERROR: Could not correlate physical disk '$($pd.SerialNumber.Trim())' to a logical disk. Aborting."; exit 1 }
    $candidates += $d
}

# Step 3: safety check - all disks must be RAW
# If none are RAW the pool/disk is already set up (normal reboot, no host reallocation).
$rawDisks = @($candidates | Where-Object { $_.PartitionStyle -eq "RAW" })
if ($rawDisks.Count -eq 0) {
    Log "All NVMe temp disks are already initialized - nothing to do."
    exit 0
}
if ($rawDisks.Count -ne $candidates.Count) {
    Log "WARNING: $($rawDisks.Count) of $($candidates.Count) NVMe temp disks are RAW. Partial initialization detected - aborting to be safe."
    exit 1
}
Log "All $($candidates.Count) disk(s) are RAW - proceeding with initialization."

function Set-DriveLetter {
    param($DiskNumber, $PartitionNumber, $Letter)
    $dUsed = Get-Partition | Where-Object { $_.DriveLetter -eq $Letter }
    if ($dUsed) {
        Log "WARNING: Drive letter ${Letter}: is already in use. Keeping auto-assigned letter."
        return $false
    }
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -NewDriveLetter $Letter
    return $true
}

try {
    if ($candidates.Count -eq 1) {
        # ---- Single disk: GPT + partition + NTFS ----
        $disk = $candidates[0]
        Log "Single disk mode: initializing Disk $($disk.Number) as GPT..."
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT -PassThru | Out-Null
        $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
        if ($partition.DriveLetter -ne "D") {
            if (Set-DriveLetter -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -Letter "D") {
                $partition = Get-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber
                Log "Drive letter reassigned to D:."
            }
        }
        Log "Formatting as NTFS (label: Temporary Storage)..."
        Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel "Temporary Storage" -Confirm:$false | Out-Null
        Log "SUCCESS: NVMe temp disk initialized as $($partition.DriveLetter):\"

    } else {
        # ---- Multiple disks: striped Storage Pool -> single D:\ volume ----
        $poolName  = "NVMeTempPool"
        $vdiskName = "NVMeTempDisk"
        $totalGB   = [math]::Round(($candidates | Measure-Object -Property Size -Sum).Sum / 1GB, 1)
        Log "Multi-disk mode: creating striped Storage Pool '$poolName' across $($candidates.Count) disks ($totalGB GB total)..."

        # Remove any leftover pool/vdisk with the same name (e.g. from a failed previous run)
        $existingPool = Get-StoragePool -FriendlyName $poolName -ErrorAction SilentlyContinue
        if ($existingPool) {
            Log "Removing existing storage pool '$poolName'..."
            $existingPool | Get-VirtualDisk -ErrorAction SilentlyContinue | Remove-VirtualDisk -Confirm:$false -ErrorAction SilentlyContinue
            $existingPool | Remove-StoragePool -Confirm:$false
        }

        # Create the storage pool from all NVMe temp physical disks
        $subsystem = Get-StorageSubSystem | Where-Object { $_.FriendlyName -like "Windows Storage*" } | Select-Object -First 1
        if (-not $subsystem) { Log "ERROR: Windows Storage subsystem not found - cannot create storage pool."; exit 1 }
        $pool = New-StoragePool `
            -FriendlyName        $poolName `
            -StorageSubSystemUniqueId $subsystem.UniqueId `
            -PhysicalDisks       $physDisks

        # Create a striped virtual disk (Simple = stripe, no redundancy - appropriate for temp storage)
        # NumberOfColumns = number of physical disks for full stripe width
        Log "Creating striped virtual disk (Simple/stripe, $($candidates.Count) columns)..."
        $vdisk = New-VirtualDisk `
            -StoragePoolFriendlyName $poolName `
            -FriendlyName            $vdiskName `
            -ResiliencySettingName   Simple `
            -NumberOfColumns         $candidates.Count `
            -UseMaximumSize

        # Initialize the virtual disk - may need a brief wait to surface as logical disk
        $disk = $null
        for ($i = 0; $i -lt 10 -and -not $disk; $i++) {
            $disk = $vdisk | Get-Disk -ErrorAction SilentlyContinue
            if (-not $disk) { Start-Sleep -Seconds 2 }
        }
        if (-not $disk) { Log "ERROR: Virtual disk did not surface as a logical disk after 20 seconds. Aborting."; exit 1 }
        Log "Initializing virtual disk (Disk $($disk.Number)) as GPT..."
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT -PassThru | Out-Null

        $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
        if ($partition.DriveLetter -ne "D") {
            if (Set-DriveLetter -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -Letter "D") {
                $partition = Get-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber
                Log "Drive letter reassigned to D:."
            }
        }
        Log "Formatting striped volume as NTFS (label: Temporary Storage)..."
        Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel "Temporary Storage" -Confirm:$false | Out-Null
        Log "SUCCESS: Striped NVMe temp disk pool initialized as $($partition.DriveLetter):\ ($totalGB GB, $($candidates.Count)-disk stripe)"
    }
} catch {
    Log "ERROR during disk initialization: $_"
    exit 1   # Stop-Script is not available here; this script runs on the VM as a Scheduled Task
}
'@

    # Encode the initializer script as base64 so it can be safely embedded in the RunCommand
    # here-string without any risk of the content accidentally terminating the outer here-string.
    # The previous approach of replacing "'@" with "' @" was fragile: if the embedded script ever
    # contained "'@" as valid syntax (unlikely but possible), the replacement would silently corrupt it.
    # Base64 is immune to any content in the script and decodes identically on the remote VM.
    $nvmeInitScriptBytes  = [System.Text.Encoding]::Unicode.GetBytes($nvmeInitScript)
    $nvmeInitScriptBase64 = [System.Convert]::ToBase64String($nvmeInitScriptBytes)

    # Full RunCommand script: decodes the initializer from base64, writes it to disk, and registers a Scheduled Task
    $installCmd = @"
`$initContent = [System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String('$nvmeInitScriptBase64'))
if (-not (Test-Path "$NVMEDiskInitScriptLocation")) { New-Item -ItemType Directory -Path "$NVMEDiskInitScriptLocation" -Force | Out-Null }
Set-Content -Path "$NVMEDiskInitScriptLocation\NVMeTempDiskInit.ps1" -Value `$initContent -Encoding UTF8 -Force
Write-Output "INFO: Initializer script written to $NVMEDiskInitScriptLocation\NVMeTempDiskInit.ps1"

`$action    = New-ScheduledTaskAction -Execute "powershell.exe" ``
                  -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File \`"$NVMEDiskInitScriptLocation\NVMeTempDiskInit.ps1\`""
# Priority 0 = highest Windows task priority (scale is 0-10, default is 7).
# Combined with no startup delay, this makes the task fire as early as possible.
# NOTE: priority alone cannot guarantee ordering between simultaneous AtStartup tasks.
# Dependent tasks (e.g. SQL tempdb init) should use the Wait-ForDrive snippet below.
`$trigger   = New-ScheduledTaskTrigger -AtStartup
`$settings  = New-ScheduledTaskSettingsSet ``
                  -ExecutionTimeLimit (New-TimeSpan -Minutes 5) ``
                  -Priority 0 ``
                  -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 1)
`$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest

Unregister-ScheduledTask -TaskName "AzureNVMeTempDiskInit" -Confirm:`$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName "AzureNVMeTempDiskInit" ``
    -Action `$action -Trigger `$trigger -Settings `$settings -Principal `$principal ``
    -Description "Initializes Azure NVMe temp disk (D:) on each boot - Priority 0 (highest)" | Out-Null
Write-Output "INFO: Scheduled task 'AzureNVMeTempDiskInit' registered (Priority 0, runs at system startup as SYSTEM)."

# Write a Wait-ForDrive helper snippet so dependent startup tasks can wait for D:\ to be ready.
# Paste this at the TOP of any task that needs D:\ (e.g. SQL tempdb initializer).
# Note: all $ are backtick-escaped because this block is inside a @"..."@ here-string.
`$snippetLines = @(
    '# -----------------------------------------------------------------------',
    '# Wait for D:\ to be initialized by AzureNVMeTempDiskInit before proceeding.',
    '# Paste this at the top of any startup task that depends on D:\.',
    '# -----------------------------------------------------------------------',
    '`$maxWait = 120   # seconds to wait for D:\ before giving up',
    '`$interval = 5',
    '`$elapsed = 0',
    'while (-not (Test-Path "D:\") -and `$elapsed -lt `$maxWait) {',
    '    Start-Sleep -Seconds `$interval',
    '    `$elapsed += `$interval',
    '}',
    'if (-not (Test-Path "D:\")) {',
    '    Write-Error "D:\ not available after `$maxWait seconds. AzureNVMeTempDiskInit may have failed."',
    '    exit 1',
    '}',
    '# -----------------------------------------------------------------------'
)
`$snippetContent = `$snippetLines -join "`r`n"
[System.IO.File]::WriteAllText("$NVMEDiskInitScriptLocation\Wait-ForDrive-D.ps1.snippet.txt", `$snippetContent, [System.Text.Encoding]::UTF8)
Write-Output "INFO: Wait-ForDrive snippet written to $NVMEDiskInitScriptLocation\Wait-ForDrive-D.ps1.snippet.txt"

# The task will run automatically on first boot of the new VM.
# Do NOT run it here  -  this is still the original VM with no NVMe temp disk.
Write-Output "INFO: Task registered. It will run automatically on first boot of the new VM."
"@

    try {
        $errors = Invoke-CheckedRunCommand -ScriptString $installCmd -Description "NVMe temp disk startup task install" -ErrorPrompt "Errors installing NVMe temp disk startup task. Continue?"
        if ($errors -eq 0) {
            WriteLog "NVMe temp disk startup task installed successfully."
            WriteLog "D:\ will be initialized automatically on every boot of the new VM."
            WriteLog "  Task priority: 0 (highest). For dependent tasks (e.g. SQL tempdb), add" "INFO"
            WriteLog "  the Wait-ForDrive snippet: $NVMEDiskInitScriptLocation\Wait-ForDrive-D.ps1.snippet.txt" "INFO"
        }
    } catch {
        WriteLog "Error installing NVMe temp disk startup task: $_" "ERROR"
        if (-not $Force) { AskToContinue "Could not install startup task. D:\ will not be auto-initialized. Continue?" }
        else { WriteLog "Could not install startup task  -  D:\ will not be auto-initialized (-Force specified)." "WARNING" }
    }

} elseif ($_os -eq "Windows" -and $_targetDiskArch -eq "nvme-temp" -and $_sourceDiskArch -eq "nvme-temp") {
    WriteLog "STEP 1c: Skipped - source is already nvme-temp (startup task was installed during the original conversion to nvme-temp)."
} elseif ($_os -eq "Windows" -and $_targetDiskArch -eq "nvme-temp" -and $NVMEDiskInitScriptSkip) {
    WriteLog "STEP 1c: Skipped (-NVMEDiskInitScriptSkip). NVMe temp disk startup task will NOT be installed." "WARNING"
} elseif ($_os -eq "Linux" -and $_targetDiskArch -eq "nvme-temp") {
    WriteLog "STEP 1c: Linux NVMe temp disk  -  waagent or cloud-init handles temp disk initialization on v6/v7." "INFO"
    WriteLog "  Note: NVMe temp disk support requires waagent >= 2.8 or cloud-init with appropriate config." "WARNING"
    WriteLog "  Older waagent versions look for /dev/sdb and will fail silently. Verify the agent version" "WARNING"
    WriteLog "  on the VM if the temp disk does not appear after conversion." "WARNING"
} else {
    WriteLog "STEP 1c: NVMe temp disk setup not needed (target arch: $_targetDiskArch)."
}

##############################################################################################################
# STEP 2  -  STOP VM (DEALLOCATE)
##############################################################################################################

# Compute the diskControllerTypes string once - used by STEP 3A (PATH A) and STEP 4B (PATH B).
$_diskControllerTypes = if ($NewControllerType -eq "NVMe") { "SCSI, NVMe" } else { "SCSI" }

WriteLog "--- STEP 2: Stop VM (deallocate) ---" "IMPORTANT"

try {
    # Use -NoWait so Stop-AzVM returns immediately. WaitForVMPowerState then handles
    # the polling with progress logging, timeout control, and a single consistent wait
    # mechanism. Without -NoWait, Stop-AzVM waits synchronously (blocking 2-5 minutes
    # with no progress output) and then WaitForVMPowerState polls again redundantly.
    Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Force -NoWait | Out-Null
    if (-not (WaitForVMPowerState -ExpectedState "PowerState/deallocated" -TimeoutSeconds 360)) {
        WriteLog "VM could not be deallocated within 6 minutes." "ERROR"
        WriteLog "  No disk changes have been made yet." "ERROR"
        WriteLog "  The VM may still be stopping or stuck. Check the Azure Portal." "ERROR"
        WriteLog "  To return to normal: Start-AzVM -ResourceGroupName '$ResourceGroupName' -Name '$VMName'" "ERROR"
        Stop-Script
    }
    WriteLog "VM deallocated."
} catch {
    WriteLog "Error stopping VM: $_" "ERROR"
    WriteLog "  No disk changes have been made yet. VM state is unknown." "ERROR"
    WriteLog "  Check the Azure Portal. If the VM is deallocated, start it manually:" "ERROR"
    WriteLog "    Start-AzVM -ResourceGroupName '$ResourceGroupName' -Name '$VMName'" "ERROR"
    Stop-Script
}

##############################################################################################################
# STEP 2a  -  TRUSTEDLAUNCH DOWNGRADE (only when -AllowTrustedLaunchDowngrade and SecurityType=TrustedLaunch)
##############################################################################################################

if ($_isTrustedLaunchDowngrade) {
    WriteLog "--- STEP 2a: Downgrading TrustedLaunch -> Standard to lift NVMe conversion block ---" "IMPORTANT"
    WriteLog "  The vTPM state (BitLocker keys sealed to TPM, FIDO2 keys, attestation certs)" "WARNING"
    WriteLog "  is being permanently destroyed now. TrustedLaunch will be re-enabled after conversion." "WARNING"
    try {
        # Null out the SecurityProfile. Azure interprets a null SecurityProfile (or SecurityType=Standard)
        # as the Standard security type, removing the Secure Boot / vTPM configuration and lifting
        # the platform block on SCSI->NVMe conversion. The VM must be deallocated (done in STEP 2).
        # EncryptionAtHost is also part of SecurityProfile - we captured it as $_origEncryptionAtHost
        # at pre-flight and will restore it in STEP 4Aa alongside SecureBoot and vTPM.
        Invoke-AzVMUpdate -Description "TrustedLaunch downgrade" -Modify { param($vm) $vm.SecurityProfile = $null } | Out-Null
        WriteLog "TrustedLaunch downgraded to Standard. vTPM state permanently destroyed." "WARNING"
        WriteLog "  Re-enable is performed automatically after conversion." "WARNING"
        $script:_needTrustedLaunchRestore = $true
        Write-TrustedLaunchRestoreNote -AsReminder   # logs the manual restore command at WARNING level
    } catch {
        WriteLog "Error downgrading TrustedLaunch to Standard: $_" "ERROR"
        WriteLog "VM is deallocated. TrustedLaunch was NOT changed." "ERROR"
        WriteLog "  OS disk was NOT modified. The VM is safe to restart." "ERROR"
        WriteLog "Start the VM manually to restore normal operations: Start-AzVM -ResourceGroupName '$ResourceGroupName' -Name '$VMName'" "ERROR"
        Stop-Script
    }
}

##############################################################################################################
# PATH A  -  RESIZE
##############################################################################################################

if (-not $_useRecreationPath) {

    # STEP 3A  -  Update OS disk controller types
    if (-not $_controllerAlreadyCorrect) {
        WriteLog "--- STEP 3A: Update OS disk diskControllerTypes ---" "IMPORTANT"
        try {
            Set-OSDiskControllerTypes -DiskName $osDisk.Name -DiskResourceGroup $diskRg -ControllerTypes $_diskControllerTypes
        } catch {
            WriteLog "Error patching OS disk: $_" "ERROR"
            WriteLog "  VM state: deallocated (stopped). The disk was NOT modified." "ERROR"
            WriteLog "  Start the VM manually, resolve the error, then re-run." "ERROR"
            Write-TrustedLaunchRestoreNote   # no-op if -AllowTrustedLaunchDowngrade was not used
            Stop-Script
        }
    } else {
        WriteLog "STEP 3A: Skipped  -  controller already $NewControllerType."
    }

    # STEP 4A  -  Resize VM
    WriteLog "--- STEP 4A: Resize VM ($script:_originalSize -> $VMSize, controller -> $NewControllerType) ---" "IMPORTANT"
    try {
        $result = Invoke-AzVMUpdate -Description "Resize to $VMSize / $NewControllerType" -Modify {
            param($vm)
            $vm.HardwareProfile.VmSize            = $VMSize
            $vm.StorageProfile.DiskControllerType = $NewControllerType
        }
        if ($result.StatusCode -eq 'OK') {
            WriteLog "VM resized to $VMSize with $NewControllerType controller."
        }
    } catch {
        WriteLog "Error resizing VM: $_" "ERROR"
        WriteLog "ROLLBACK: -NewControllerType $script:_originalController -VMSize '$script:_originalSize' -StartVM" "IMPORTANT"
        WriteLog "  (VM is currently deallocated; -StartVM restarts it after rollback)" "IMPORTANT"
        WriteLog "  OS disk diskControllerTypes was already patched (STEP 3A). Only size/controller on VM object failed." "ERROR"
        WriteLog "  The disk patch is reversible: re-running rollback also re-patches the disk." "ERROR"
        Write-TrustedLaunchRestoreNote   # no-op if -AllowTrustedLaunchDowngrade was not used
        Stop-Script
    }

    # STEP 4Aa (PATH A only)  -  Re-enable TrustedLaunch after NVMe conversion
    # Runs while VM is still deallocated (Update-AzVM requires deallocated state for SecurityType changes).
    # Must come BEFORE STEP 5A (Start-AzVM) so the VM boots with the full TrustedLaunch posture.
    if ($script:_needTrustedLaunchRestore) {
        WriteLog "--- STEP 4Aa: Re-enabling TrustedLaunch (SecurityType -> TrustedLaunch) ---" "IMPORTANT"
        try {
            # Restore the full SecurityProfile: SecurityType=TrustedLaunch, UefiSettings, AND
            # EncryptionAtHost. STEP 2a nulled the entire SecurityProfile; omitting EncryptionAtHost
            # here would silently leave it disabled even if it was enabled on the original VM.
            Invoke-AzVMUpdate -Description "TrustedLaunch re-enable" -Modify {
                param($vm)
                $vm.SecurityProfile = [Microsoft.Azure.Management.Compute.Models.SecurityProfile]@{
                    SecurityType     = $_secTypeForCheck   # 'TrustedLaunch'
                    EncryptionAtHost = $_origEncryptionAtHost
                    UefiSettings     = [Microsoft.Azure.Management.Compute.Models.UefiSettings]@{
                        SecureBootEnabled = $_origSecureBoot
                        VTpmEnabled       = $_origVTpm
                    }
                }
            } | Out-Null
            WriteLog "TrustedLaunch re-enabled (SecureBoot=$_origSecureBoot, vTPM=$_origVTpm, EncryptionAtHost=$_origEncryptionAtHost)." "IMPORTANT"
            Write-VTPMDataLossWarning
            $script:_needTrustedLaunchRestore = $false
        } catch {
            WriteLog "Error re-enabling TrustedLaunch: $_" "ERROR"
            WriteLog "VM is still deallocated. The conversion is complete but TrustedLaunch is NOT restored." "ERROR"
            # Non-fatal: conversion is complete, only the re-enable failed. Operator can fix manually.
            # Do NOT exit 1 - the VM is in a valid state (deallocated, NVMe, Standard security type).
            # Do NOT start the VM (-StartVM suppressed below) so the operator can re-enable first.
            Write-TrustedLaunchRestoreNote   # logs the manual restore command at ERROR level
            $script:_needTrustedLaunchRestore = $true   # keep flag set so finally block also emits note
        }
    }

    # STEP 5A: Start VM
    # Guard: if STEP 4Aa failed to re-enable TrustedLaunch (_needTrustedLaunchRestore was reset to
    # $true in the catch block), do not start the VM. The operator must first restore TrustedLaunch
    # manually while the VM is deallocated; starting it in Standard mode would boot without the
    # security posture and potentially trigger BitLocker recovery.
    if ($script:_needTrustedLaunchRestore) {
        WriteLog "STEP 5A: SKIPPED  -  TrustedLaunch re-enable failed. Restore TrustedLaunch before starting the VM." "WARNING"
        WriteLog "  Follow the ACTION REQUIRED instructions above, then start manually:" "WARNING"
        WriteLog "  Start-AzVM -ResourceGroupName '$ResourceGroupName' -Name '$VMName'" "WARNING"
    } elseif ($StartVM) {
        WriteLog "--- STEP 5A: Start VM ---" "IMPORTANT"
        Start-Sleep -Seconds $SleepSeconds
        try {
            $sr = Start-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
            if ($sr.Status -eq "Succeeded") { WriteLog "VM started." }
            else { WriteLog "Start status: $($sr.Status)  -  check manually." "WARNING" }
        } catch {
            WriteLog "Error starting VM: $_" "ERROR"
            WriteLog "  The VM is fully converted (controller=$NewControllerType, size=$VMSize). Disks are intact." "ERROR"
            WriteLog "  Start manually: Start-AzVM -ResourceGroupName '$ResourceGroupName' -Name '$VMName'" "ERROR"
            WriteLog "ROLLBACK: -NewControllerType $script:_originalController -VMSize '$script:_originalSize' -StartVM" "IMPORTANT"
            Write-TrustedLaunchRestoreNote   # no-op: if we reach here TrustedLaunch was already re-enabled
            Stop-Script
        }
    } else {
        WriteLog "VM is OFF. Add -StartVM to start automatically, or start manually." "IMPORTANT"
    }

##############################################################################################################
# PATH B  -  RECREATE
##############################################################################################################

} else {

# STEP 3B  -  Snapshot OS disk  (safety backup BEFORE any modification)
    # Taken before the disk controller type patch so it captures the disk in its original,
    # unmodified state. If the patch or any subsequent step fails, this snapshot is a clean
    # starting point: create a new managed disk from it and recreate the VM from scratch.
    # Azure snapshot names have an 80-character maximum. Linux VM names can be up to 64 chars,
    # and auto-generated OS disk names add ~42 chars (VMName_OsDisk_1_<32-char GUID>), so the
    # combined disk name can easily exceed 60 chars. Adding "-snap-yyyyMMddHHmmss" (20 chars)
    # can push the total past 80. Truncate the disk name prefix to ensure the snapshot name fits.
    $_snapSuffix    = "-snap-$((Get-Date).ToString('yyyyMMddHHmmss'))"  # always 20 chars
    $_maxPrefixLen  = 80 - $_snapSuffix.Length                          # 60 chars available for disk name
    $_snapDiskName  = if ($osDisk.Name.Length -gt $_maxPrefixLen) {
                          WriteLog "  OS disk name ($($osDisk.Name.Length) chars) exceeds prefix budget; truncating for snapshot name." "WARNING"
                          $osDisk.Name.Substring(0, $_maxPrefixLen)
                      } else {
                          $osDisk.Name
                      }
    $snapshotName = "$_snapDiskName$_snapSuffix"
    WriteLog "--- STEP 3B: Creating snapshot '$snapshotName' of OS disk (before any changes) ---" "IMPORTANT"
    try {
        # Use Standard_ZRS for zone-pinned VMs so the snapshot survives a zonal outage.
        # Standard_LRS only replicates within a single physical location - if the rack
        # hosting the snapshot fails, the recovery point is gone. Fall back to Standard_LRS
        # if ZRS is not available in this region.
        $_snapSku = if ($vm.Zones -and $vm.Zones.Count -gt 0) { 'Standard_ZRS' } else { 'Standard_LRS' }
        WriteLog "  Snapshot SKU: $_snapSku$(if ($_snapSku -eq 'Standard_ZRS') { ' (zone-pinned VM - ZRS preferred)' })"
        $snapConfig = New-AzSnapshotConfig -SourceUri $osDisk.Id -Location $vm.Location -CreateOption Copy -SkuName $_snapSku
        try {
            $snapshot = Invoke-AzWithRetry -Description 'New-AzSnapshot (ZRS)' -ScriptBlock { New-AzSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $snapshotName -Snapshot $snapConfig }
        } catch {
            # ZRS rejection happens at New-AzSnapshot time (ARM validation), not at config creation.
            # Fall back to LRS only when the error message indicates ZRS is genuinely unavailable
            # in this region. Other errors (429 throttling, transient 5xx) are re-thrown so the
            # outer catch can surface them as a hard failure rather than silently downgrading.
            $isZrsUnavailable = ($_snapSku -eq 'Standard_ZRS') -and
                                ($_.Exception.Message -match 'ZRS|zone.redundant|SkuNotAvailable|not.*supported|not.*available')
            if ($isZrsUnavailable) {
                WriteLog "  Standard_ZRS not available in this region - falling back to Standard_LRS." "WARNING"
                $snapConfig = New-AzSnapshotConfig -SourceUri $osDisk.Id -Location $vm.Location -CreateOption Copy -SkuName Standard_LRS
                $snapshot   = Invoke-AzWithRetry -Description 'New-AzSnapshot (LRS fallback)' -ScriptBlock { New-AzSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $snapshotName -Snapshot $snapConfig }
            } else { throw }
        }
        WriteLog "Snapshot created: $($snapshot.Id)"
    } catch {
        WriteLog "Error creating snapshot: $_" "ERROR"
        WriteLog "  VM state: deallocated (stopped). No disk changes have been made." "ERROR"
        WriteLog "  Start the VM manually, resolve the snapshot error, then re-run." "ERROR"
        Write-TrustedLaunchRestoreNote   # no-op if -AllowTrustedLaunchDowngrade was not used
        Stop-Script
    }

    # STEP 4B  -  Update OS disk controller types
    # Note: unlike PATH A (STEP 3A), this patch runs unconditionally even when
    # $_controllerAlreadyCorrect is true. After VM recreation the new VM object must
    # carry the correct diskControllerTypes value, and the REST PATCH is idempotent -
    # patching to the same value is a no-op from Azure's perspective.
    WriteLog "--- STEP 4B: Update OS disk diskControllerTypes ---" "IMPORTANT"
    try {
        Set-OSDiskControllerTypes -DiskName $osDisk.Name -DiskResourceGroup $diskRg -ControllerTypes $_diskControllerTypes
    } catch {
        WriteLog "Error patching OS disk: $_" "ERROR"
        WriteLog "  VM state: deallocated (stopped). Snapshot '$snapshotName' is intact as a safety backup." "ERROR"
        WriteLog "  Start the VM manually, resolve the error, then re-run." "ERROR"
        WriteLog "  If needed: restore from snapshot '$snapshotName' (RG: $ResourceGroupName)." "ERROR"
        Write-TrustedLaunchRestoreNote   # no-op if -AllowTrustedLaunchDowngrade was not used
        Stop-Script
    }

    # STEP 5B  -  Capture VM configuration before deletion
    # The original OS disk is preserved when the VM shell is deleted and will be reattached directly.
    # The snapshot above serves as a safety backup only  -  it is NOT used for recreation.
    WriteLog "--- STEP 5B: Capturing VM configuration ---" "IMPORTANT"
    # Re-fetch VM from ARM to capture the settled state after deallocation (STEP 2).
    # The in-memory $vm object from the initial Get-AzVM may reflect pre-deallocation
    # transient properties; a fresh call ensures we read the final committed config.
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName

    # Capture full NIC objects (not just IDs) so STEP 7B can read Primary flag and the original
    # DeleteOption. STEP 6B assigns a brand-new $vm object (Get-AzVM re-fetch) and sets all
    # DeleteOptions to Detach on it. The STEP 7B NIC loop iterates over $vm.NetworkProfile.NetworkInterfaces
    # which is that STEP 6B object - so $nic.DeleteOption there is always 'Detach', silently losing
    # any 'Delete' intent on NICs provisioned as ephemeral/disposable. $_nics is isolated from STEP 6B.
    $_nics          = $vm.NetworkProfile.NetworkInterfaces
    $_nicIds        = $_nics | ForEach-Object { $_.Id }
    $_dataDisks     = $vm.StorageProfile.DataDisks
    # OS disk DeleteOption: captured here from the STEP 5B $vm object so STEP 7B can restore it.
    # STEP 6B forces DeleteOption=Detach on the OS disk for safety before Remove-AzVM.
    # Without this capture the recreated VM always gets 'Detach' on its OS disk, silently losing
    # any 'Delete' intent configured by the operator (e.g. on single-use / ephemeral deployments).
    $_osDiskDeleteOption = $vm.StorageProfile.OsDisk.DeleteOption
    # OS disk caching: must be explicitly passed to Set-AzVMOSDisk in STEP 7B.
    # If omitted, Azure silently applies the per-OS-type default (ReadWrite for Windows,
    # ReadOnly for Linux). Non-default settings (e.g. None on write-heavy workloads) would
    # be silently reset, changing I/O behaviour after recreation without any error or warning.
    $_osDiskCaching = $vm.StorageProfile.OsDisk.Caching   # 'None', 'ReadOnly', or 'ReadWrite'
    # OS disk WriteAccelerator: rare (M-series only) but valid on the OS disk.
    # Must be captured here because STEP 6B re-fetches $vm, and STEP 7B should not
    # read from the STEP 6B $vm object (fragile cross-step dependency).
    $_osWriteAccelerator = [bool]$vm.StorageProfile.OsDisk.WriteAcceleratorEnabled
    # Note: Microsoft documents that OS disk caching settings are non-functional on NVMe VMs
    # and will be disabled in a future update. The value is preserved here for completeness
    # and in case the VM is ever converted back to SCSI.
    # Data disk DeleteOption: original setting may be 'Delete' (temporary/scratch disks) or
    # 'Detach' (persistent disks). Add-AzVMDataDisk does not accept -DeleteOption; the value
    # must be set directly on the disk object in the VM config after attachment. Without this,
    # all data disks on the recreated VM would silently revert to the Azure default ('Detach'),
    # which is safer but silently changes the intended lifecycle behaviour for scratch disks.
    # NIC DeleteOption: same issue - see $_nics capture above and STEP 7B NIC loop.
    # Note: $_accelNetSupported was set in pre-flight (including IgnoreSKUCheck fallback)
    # and is intentionally NOT recaptured here from the re-fetched $vm object.
    $_tags          = $vm.Tags
    $_location      = $vm.Location
    $_licenseType   = $vm.LicenseType
    $_availSetId    = if ($vm.AvailabilitySetReference) { $vm.AvailabilitySetReference.Id } else { $null }
    $_ppgId         = if ($vm.ProximityPlacementGroup)  { $vm.ProximityPlacementGroup.Id  } else { $null }
    $_zones         = $vm.Zones
    $_bootDiag      = $vm.DiagnosticsProfile
    $_identity      = $vm.Identity
    # System-assigned managed identity: capture old PrincipalId BEFORE VM deletion.
    # After Remove-AzVM the old principal is gone; the old principal no longer exists in AAD.
    # User-assigned identities keep their PrincipalId after recreation and need no export.
    # The pre-flight check already enumerated role assignments in $_preflightRbacAssignments;
    # we reuse that data here rather than calling Get-AzRoleAssignment a second time.
    $_oldSystemMIPrincipalId = if ($_hasSystemMI) { $vm.Identity.PrincipalId } else { $null }
    $_rbacExportPath          = $null
    $_rbacResultsPath         = $null
    $_rbacExportedAssignments = @()
    $_rbacExportFailed        = $false
    if ($_oldSystemMIPrincipalId -and $RestoreSystemAssignedRBAC) {
        if ($_preflightRbacFetchFailed) {
            # Pre-flight RBAC enumeration failed - export would be incomplete.
            # Mark as failed so STEP 9B and the completion block report this accurately.
            $_rbacExportFailed = $true
            WriteLog "  System-assigned MI: RBAC pre-flight fetch failed  -  export skipped. RBAC restore will not run in STEP 9B." "WARNING"
            WriteLog "    Re-assign RBAC manually after recreation using the new principal ID." "WARNING"
        } else {
            $_rbacTimestamp   = (Get-Date).ToString('yyyyMMdd-HHmmss')
            $_rbacExportPath  = "$VMName-$_rbacTimestamp-rbac-export.json"
            $_rbacResultsPath = "$VMName-$_rbacTimestamp-rbac-restore-results.json"
            # Write the pre-flight assignments to the export file.
            # PS5.1 ConvertTo-Json serializes an empty array as 'null'; write '[]' explicitly.
            try {
                $_rbacExportedAssignments = $_preflightRbacAssignments
                $json = if ($_rbacExportedAssignments.Count -gt 0) { $_rbacExportedAssignments | ConvertTo-Json -Depth 5 } else { '[]' }
                # Use WriteAllText with a no-BOM encoder.
                # Set-Content -Encoding UTF8 writes a BOM in PS5.1; the \ufeff prefix makes
                # ConvertFrom-Json fail when Restore-SystemAssignedRBACAssignments reads this file.
                [System.IO.File]::WriteAllText($_rbacExportPath, $json, [System.Text.UTF8Encoding]::new($false))
                WriteLog "  System-assigned MI: $($_rbacExportedAssignments.Count) assignment(s) saved to '$_rbacExportPath' for STEP 9B restore." "IMPORTANT"
            } catch {
                $_rbacExportFailed = $true
                WriteLog "  System-assigned MI: could not write export file '$_rbacExportPath': $_" "WARNING"
                WriteLog "    RBAC restore will be skipped. Re-assign manually after recreation if needed." "WARNING"
            }
        }
    }
    $_priority      = $vm.Priority
    # Spot/Low VMs: eviction policy (Deallocate or Delete) and max price cap must be preserved.
    # EvictionPolicy defaults to Deallocate and MaxPrice to -1 (no cap) if not captured.
    $_evictionPolicy = $vm.EvictionPolicy
    $_maxPrice       = if ($vm.BillingProfile) { $vm.BillingProfile.MaxPrice } else { $null }
    # Dedicated Host: VM may be pinned to a specific host (Host.Id) or a host group (HostGroup.Id).
    # These are mutually exclusive - a VM can only have one or the other, never both.
    $_hostId         = if ($vm.Host)      { $vm.Host.Id      } else { $null }
    $_hostGroupId    = if ($vm.HostGroup) { $vm.HostGroup.Id } else { $null }
    $_ultraSSD      = ($vm.AdditionalCapabilities -and $vm.AdditionalCapabilities.UltraSSDEnabled    -eq $true)
    # Hibernation (AdditionalCapabilities sibling of UltraSSD - both must be set together on the object).
    $_hibernation   = ($vm.AdditionalCapabilities -and $vm.AdditionalCapabilities.HibernationEnabled -eq $true)
    # Security profile: TrustedLaunch (SecureBoot + vTPM) and encryption at host.
    # TrustedLaunch is now the Azure default for new Gen2 VMs. Without it the recreated VM will
    # either fail to boot (if the OS disk has VM Guest State) or silently lose its security posture.
    # EncryptionAtHost silently disappears without this - a quiet security regression.
    $_securityType     = if ($vm.SecurityProfile) { $vm.SecurityProfile.SecurityType     } else { $null }
    $_secureBoot       = ($vm.SecurityProfile -and $vm.SecurityProfile.UefiSettings -and $vm.SecurityProfile.UefiSettings.SecureBootEnabled -eq $true)
    $_vTpm             = ($vm.SecurityProfile -and $vm.SecurityProfile.UefiSettings -and $vm.SecurityProfile.UefiSettings.VTpmEnabled       -eq $true)
    $_encryptionAtHost = ($vm.SecurityProfile -and $vm.SecurityProfile.EncryptionAtHost  -eq $true)

    # STEP 2a nulled SecurityProfile on the ARM resource (TrustedLaunch -> Standard).
    # The re-fetched VM above therefore shows Standard/null instead of TrustedLaunch.
    # Override with the pre-downgrade values so STEP 7B creates the new VM with
    # TrustedLaunch restored, exactly as documented in .DESCRIPTION.
    if ($script:_needTrustedLaunchRestore) {
        $_securityType     = $_secTypeForCheck       # 'TrustedLaunch'
        $_secureBoot       = $_origSecureBoot
        $_vTpm             = $_origVTpm
        $_encryptionAtHost = $_origEncryptionAtHost
        WriteLog "  Note: security profile overridden with pre-downgrade values (STEP 2a active) - TrustedLaunch will be set on new VM." "WARNING"
    }
    # Capacity Reservation Group: VM consumes a slot from this group. Without restoration the
    # recreated VM is no longer associated and the slot is paid for but unused.
    $_capacityReservId = if ($vm.CapacityReservation -and $vm.CapacityReservation.CapacityReservationGroup) { $vm.CapacityReservation.CapacityReservationGroup.Id } else { $null }
    # UserData: base64-encoded payload read by cloud-init and custom extensions on each boot.
    $_userData         = $vm.UserData
    # Marketplace Plan: required for VMs deployed from paid marketplace images (e.g. SQL Server,
    # RHEL, 3rd-party security tools). Without it New-AzVM fails or the VM starts without its
    # billing plan. Microsoft explicitly warns: losing this before deletion requires a support ticket.
    $_plan             = $vm.Plan
    # VmSizeProperties: custom CPU configuration (reduced vCPU count, SMT/hyperthreading disabled).
    # Used in HPC, SAP HANA, and regulated workloads. Applied at creation time for the target size;
    # if the target size differs from the source the values may need adjustment (warned below).
    $_vmSizeProps      = $vm.HardwareProfile.VmSizeProperties
    # ApplicationProfile: VM Applications from Azure Compute Gallery (distinct from VM Extensions).
    # These are full software packages (agents, tools) deployed and maintained via gallery versioning.
    $_galleryApps      = if ($vm.ApplicationProfile -and $vm.ApplicationProfile.GalleryApplications -and
                             $vm.ApplicationProfile.GalleryApplications.Count -gt 0) {
                             $vm.ApplicationProfile.GalleryApplications
                         } else { @() }
    # ScheduledEventsProfile: configures the graceful termination window for Scheduled Events.
    # enableTerminateNotification gives the VM advance notice (PT5M–PT15M) before eviction/deletion.
    # Without this, Spot VM evictions and platform maintenance events arrive with no warning window.
    $_schedEventsProfile = $vm.ScheduledEventsProfile
    # VMSS Flexible orchestration: VM may be a member of a Flexible-mode scale set.
    # Remove-AzVM detaches it from the set entirely. We re-register at config-build time in STEP 7B.
    # PlatformFaultDomain: fault domain index within the VMSS; must be set at creation time.
    # NOTE: load balancer backend pool membership is NOT automatically restored (Microsoft limitation).
    $_vmssId           = if ($vm.VirtualMachineScaleSet) { $vm.VirtualMachineScaleSet.Id } else { $null }
    $_platformFaultDom = $vm.PlatformFaultDomain   # $null on VMs not in a VMSS
    # ExtendedLocation: Azure Edge Zone (carrier partner edge) deployments.
    # Without this the recreated VM lands in the parent Azure region, not the edge node.
    $_extendedLocation = $vm.ExtendedLocation
    # Capture source image reference for informational logging only.
    # It is NOT applied to New-AzVM: Azure does not allow setting imageReference when attaching
    # an existing OS disk (CreateOption Attach). The portal will show a blank image field on the
    # recreated VM; the original image info is retained on the disk's creationData.imageReference.
    $_imageRef      = $vm.StorageProfile.ImageReference

    WriteLog "  NICs          : $($_nicIds.Count)"
    WriteLog "  OS disk cache : $(if ($_osDiskCaching) { $_osDiskCaching } else { 'not set (platform default)' })"
    if ($IgnoreSKUCheck) {
        WriteLog "  Accel network : unknown (-IgnoreSKUCheck) - disabling on NICs as a precaution" "WARNING"
    } else {
        WriteLog "  Accel network : $(if ($_accelNetSupported) { 'supported by target size' } else { 'NOT supported by target size - will be disabled on NICs' })"
    }
    WriteLog "  Data disks    : $($_dataDisks.Count)"
    WriteLog "  Tags          : $($_tags.Count)"
    WriteLog "  License type  : $(if ($_licenseType) { $_licenseType } else { 'none' })"
    WriteLog "  Avail Set     : $(if ($_availSetId)  { $_availSetId  } else { 'none' })"
    WriteLog "  PPG           : $(if ($_ppgId)        { $_ppgId       } else { 'none' })"
    WriteLog "  Zones         : $(if ($_zones)        { $_zones -join ',' } else { 'none' })"
    WriteLog "  Priority      : $(if ($_priority) { $_priority } else { 'none (Regular)' })"
    if ($_priority -eq 'Spot' -or $_priority -eq 'Low') {
        WriteLog "  Eviction pol  : $(if ($_evictionPolicy) { $_evictionPolicy } else { 'Deallocate (default)' })"
        WriteLog "  Max price     : $(if ($null -eq $_maxPrice) { 'not set (Azure default)' } elseif ($_maxPrice -eq -1) { 'no cap (pay-as-you-go, MaxPrice=-1)' } else { "$_maxPrice/hr" })"
    }
    WriteLog "  Dedicated host: $(if ($_hostId) { Get-ArmName $_hostId } elseif ($_hostGroupId) { 'HostGroup: ' + (Get-ArmName $_hostGroupId) } else { 'none' })"
    WriteLog "  UltraSSD      : $(if ($_ultraSSD)    { 'enabled' } else { 'disabled' })"
    WriteLog "  Hibernation   : $(if ($_hibernation)  { 'enabled' } else { 'disabled' })"
    if ($_securityType) {
        WriteLog "  Security type : $_securityType$(if ($_securityType -eq 'TrustedLaunch') { " (SecureBoot=$_secureBoot, vTPM=$_vTpm)" })"
    } else {
        WriteLog "  Security type : Standard (TrustedLaunch not enabled)"
    }
    WriteLog "  Encrypt@host  : $(if ($_encryptionAtHost) { 'enabled' } else { 'disabled' })"
    WriteLog "  Capacity Rsrv : $(if ($_capacityReservId) { Get-ArmName $_capacityReservId } else { 'none' })"
    WriteLog "  UserData      : $(if ($_userData) { 'present (' + [Convert]::FromBase64String($_userData).Length.ToString() + ' bytes decoded)' } else { 'none' })"
    WriteLog "  Plan          : $(if ($_plan -and $_plan.Publisher) { "$($_plan.Publisher) / $($_plan.Name)" } else { 'none (not a paid marketplace image)' })"
    WriteLog "  VmSizeProps   : $(if ($_vmSizeProps -and ($_vmSizeProps.VCPUsAvailable -or $_vmSizeProps.VCPUsPerCore)) { "vCPUsAvailable=$($_vmSizeProps.VCPUsAvailable), vCPUsPerCore=$($_vmSizeProps.VCPUsPerCore)" } else { 'none (default)' })"
    WriteLog "  Gallery Apps  : $($_galleryApps.Count) VM application(s) from Azure Compute Gallery"
    if ($_schedEventsProfile -and $_schedEventsProfile.TerminateNotificationProfile -and
        $_schedEventsProfile.TerminateNotificationProfile.Enable) {
        WriteLog "  SchedEvents   : terminate notification enabled (window: $($_schedEventsProfile.TerminateNotificationProfile.NotBeforeTimeout))"
    } else {
        WriteLog "  SchedEvents   : terminate notification not enabled"
    }
    if ($_vmssId) {
        WriteLog "  VMSS          : $(Get-ArmName $_vmssId) (fault domain: $(if ($null -ne $_platformFaultDom) { $_platformFaultDom } else { 'auto' }))" "WARNING"
        WriteLog "    NOTE: load balancer backend pool membership is NOT automatically restored after recreation." "WARNING"
        WriteLog "    NOTE: Application Gateway backend pool membership is also NOT automatically restored." "WARNING"
        WriteLog "    Verify the VM appears in the correct backend pool(s) after this script completes." "WARNING"
    } else {
        WriteLog "  VMSS          : none"
    }
    # Load balancer and Application Gateway backend pools are separate ARM resources
    # (Microsoft.Network/loadBalancers/backendAddressPools,
    #  Microsoft.Network/applicationGateways/backendAddressPools).
    # They reference the VM's NIC IP configuration. The NIC itself is preserved through PATH B,
    # but NIC IP configuration backend pool references are NOT automatically re-established
    # after recreation if they were set at the NIC level rather than via VMSS membership.
    # This applies to BOTH standard Load Balancers and Application Gateways.
    # Check if any NIC has LB or AppGW backend pool associations.
    try {
        # Fetch all NIC objects in one batch (parallel on PS7) for backend-pool detection
        # AND for STEP 7B use (AccelNet, Add-AzVMNetworkInterface). Avoids N serial round-trips.
        $_nicObjects = Get-AzNICBatch $_nics
        $_nicBackendWarnings = @()
        foreach ($_nicId in $_nicIds) {
            $_nicName = Get-ArmName $_nicId
            $_nicObj  = $_nicObjects[$_nicId]
            if ($_nicObj) {
                foreach ($_ipCfg in $_nicObj.IpConfigurations) {
                    $lbPools  = @($_ipCfg.LoadBalancerBackendAddressPools       | Where-Object { $_ })
                    $agwPools = @($_ipCfg.ApplicationGatewayBackendAddressPools | Where-Object { $_ })
                    if ($lbPools.Count -gt 0 -or $agwPools.Count -gt 0) {
                        $_nicBackendWarnings += "NIC '$_nicName' IP config '$($_ipCfg.Name)': " +
                            "$(if ($lbPools.Count -gt 0) { "$($lbPools.Count) LB pool(s)" })" +
                            "$(if ($lbPools.Count -gt 0 -and $agwPools.Count -gt 0) { ', ' })" +
                            "$(if ($agwPools.Count -gt 0) { "$($agwPools.Count) AppGW pool(s)" })"
                    }
                }
            }
        }
        if ($_nicBackendWarnings.Count -gt 0) {
            WriteLog "  Backend pools : the following NIC IP configurations have LB/AppGW pool memberships:" "WARNING"
            foreach ($_w in $_nicBackendWarnings) { WriteLog "    $_w" "WARNING" }
            WriteLog "    These are NIC-level associations preserved on the NIC resource itself." "WARNING"
            WriteLog "    They will remain intact after recreation as the NIC is reused unchanged." "WARNING"
            WriteLog "    Verify backend pool memberships in Portal after recreation to confirm." "WARNING"
        } else {
            WriteLog "  Backend pools : no LB or AppGW backend pool associations found on NICs."
        }
    } catch {
        WriteLog "  Backend pools : could not check NIC backend pool memberships: $_" "WARNING"
    }
    WriteLog "  ExtLocation   : $(if ($_extendedLocation -and $_extendedLocation.Name) { "$($_extendedLocation.Name) ($($_extendedLocation.Type))" } else { 'none (standard Azure region)' })"
    if ($_imageRef -and $_imageRef.Publisher) {
        WriteLog "  Source image  : $($_imageRef.Publisher) / $($_imageRef.Offer) / $($_imageRef.Sku)"
    }

    # Extensions: classified and confirmed by the early check before STEP 1.
    # $_extensionList is already populated; STEP 8B handles reinstall after recreation.
    WriteLog "  Extensions    : $($_extensionList.Count) extension(s) (classified pre-flight; reinstall handled in STEP 8B)"

    # Managed identity summary
    if ($_identity) {
        $_miSummary = $_identity.Type
        if ($_hasSystemMI -and $_hasUserMI) {
            $_miSummary = "SystemAssigned + UserAssigned ($($vm.Identity.UserAssignedIdentities.Count) user-assigned)"
        } elseif ($_hasSystemMI) {
            $_miSummary = "SystemAssigned (PrincipalId: $_oldSystemMIPrincipalId)"
        } elseif ($_hasUserMI) {
            $_miSummary = "UserAssigned ($($vm.Identity.UserAssignedIdentities.Count) identity/identities  -  stable across recreation)"
        }
        WriteLog "  Managed MI    : $_miSummary"
        if ($_hasSystemMI) {
            # The system-assigned principal ID changes after Remove-AzVM + New-AzVM.
            # Any Azure RBAC role assignments on the old principal (Storage, Key Vault,
            # Automation, Event Hubs, Log Analytics, etc.) will silently stop working
            # until re-assigned to the new principal ID.
            if ($RestoreSystemAssignedRBAC -and $_rbacExportFailed) {
                WriteLog "  RBAC save     : FAILED  -  see WARNING above. Restore manually after recreation." "WARNING"
            } elseif ($RestoreSystemAssignedRBAC -and $_rbacExportedAssignments.Count -gt 0) {
                WriteLog "  RBAC save     : $($_rbacExportedAssignments.Count) assignment(s) saved  ->  will be restored in STEP 9B." "IMPORTANT"
            } elseif ($RestoreSystemAssignedRBAC) {
                WriteLog "  RBAC save     : 0 direct assignments  -  nothing to restore in STEP 9B." "INFO"
            } else {
                # -RestoreSystemAssignedRBAC not specified: assignments were logged at pre-flight
                if ($_preflightRbacAssignments.Count -gt 0) {
                    WriteLog "  RBAC          : $($_preflightRbacAssignments.Count) assignment(s) detected (logged at pre-flight)  -  NOT auto-restored." "WARNING"
                    WriteLog "    Re-assign manually to new principal after recreation (see pre-flight log for list)." "WARNING"
                } else {
                    WriteLog "  RBAC          : no direct assignments found  -  nothing to re-assign." "INFO"
                }
            }
            if ($_hasUserMI) {
                WriteLog "  User-assigned : RBAC is stable (user-assigned principal IDs survive VM recreation)." "INFO"
            }
        }
    } else {
        WriteLog "  Managed MI    : none"
    }

    # Azure Automanage detection
    # VMs enrolled in an Automanage configuration profile are assigned a
    # Microsoft.Automanage/configurationProfileAssignments resource linked to the VM resource ID.
    # Remove-AzVM deletes the VM resource, which removes this assignment. After recreation the VM
    # is no longer enrolled and Automanage services (Guest Configuration, Update Management,
    # Backup, Monitoring, etc.) silently stop running until the operator manually re-enrolls.
    # Re-enrollment is done via: Azure Portal > Automanage > Enable on VM, or via ARM/CLI.
    try {
        $_autoManageAssignments = @(Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType 'Microsoft.Automanage/configurationProfileAssignments' -ExpandProperties -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq $VMName -or $_.ParentResourcePath -like "*$VMName*" })
        if ($_autoManageAssignments.Count -gt 0) {
            WriteLog "  Automanage    : ENROLLED - configuration profile assignment detected:" "WARNING"
            foreach ($_am in $_autoManageAssignments) {
                $_amProfile = if ($_am.Properties -and $_am.Properties.configurationProfile) { $_am.Properties.configurationProfile } else { '(profile name unavailable)' }
                WriteLog "    Profile: $_amProfile" "WARNING"
            }
            WriteLog "    PATH B recreation removes the Automanage enrollment." "WARNING"
            WriteLog "    After recreation: re-enroll via Azure Portal > Automanage > Enable on VM." "WARNING"
        } else {
            WriteLog "  Automanage    : not enrolled (no configurationProfileAssignment found)."
        }
    } catch {
        WriteLog "  Automanage    : could not check enrollment: $_  -  verify manually after recreation." "WARNING"
    }

    # TrustedLaunch + PATH B: vTPM state loss warning
    # When a TrustedLaunch VM is recreated via PATH B, the vTPM chip is associated with the
    # VM resource, NOT with the OS disk. Remove-AzVM destroys the virtual TPM permanently:
    #   - BitLocker keys protected by vTPM are lost (BitLocker will enter recovery mode on
    #     first boot if BCD has no TPM fallback protector; the original disk is unaffected).
    #   - FIDO2/Windows Hello keys bound to vTPM are lost.
    #   - Attestation certificates and any secrets sealed to the vTPM state are lost.
    # The OS disk data is fully intact and the recreated VM boots normally, but the above
    # security credentials must be re-provisioned after recreation.
    # NOTE: this does NOT abort the script. vTPM state loss is unavoidable with PATH B
    # (Azure has no API to export/import vTPM state). It is a known Azure limitation.
    # The TrustedLaunch security posture (SecureBoot + vTPM chip) IS preserved on the new VM
    # because we restore the SecurityProfile in STEP 7B; only the stored vTPM *contents* are lost.
    if ($_securityType -eq 'TrustedLaunch') {
        WriteLog "WARNING: This VM uses TrustedLaunch." "WARNING"
        WriteLog "  PATH B (VM recreation) permanently destroys the vTPM state:" "WARNING"
        WriteLog "    - BitLocker keys bound to vTPM -> disk may enter BitLocker recovery on first boot." "WARNING"
        WriteLog "      (Only affects keys sealed to vTPM; standard password/recovery key protectors are unaffected.)" "WARNING"
        WriteLog "    - FIDO2 / Windows Hello for Business keys bound to vTPM -> must be re-provisioned." "WARNING"
        WriteLog "    - Attestation certificates / secrets sealed to vTPM state -> lost." "WARNING"
        WriteLog "  The TrustedLaunch security posture (SecureBoot + vTPM chip) IS restored on the new VM." "WARNING"
        WriteLog "  Only the vTPM-stored credentials are lost; the OS disk and all data are unaffected." "WARNING"
        WriteLog "  Action required after recreation: re-provision any vTPM-bound credentials." "WARNING"
        # Note: the deletion confirmation prompt below ("VM will now be DELETED") already covers this
        # as the single point-of-no-return for PATH B. A second prompt here would ask the operator
        # the same question twice within the same step, with only Azure API calls in between.
    }

    # STEP 6B  -  Delete original VM (NICs and disks are NOT deleted)
    # Safety: set DeleteOption = Detach on OS disk, data disks and NICs before removing the VM.
    # Since Azure portal 2022, VMs are created with DeleteOption = Delete by default, which means
    # Remove-AzVM would silently delete all attached resources along with the VM shell.
    WriteLog "--- STEP 6B: Setting DeleteOption = Detach on all disks and NICs ---" "IMPORTANT"
    try {
        $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
        $vm.StorageProfile.OsDisk.DeleteOption        = "Detach"
        foreach ($dd in $vm.StorageProfile.DataDisks) { $dd.DeleteOption = "Detach" }
        foreach ($nic in $vm.NetworkProfile.NetworkInterfaces) { $nic.DeleteOption = "Detach" }
        Invoke-AzWithRetry -Description 'Update-AzVM (set DeleteOption=Detach)' -ScriptBlock { Update-AzVM -ResourceGroupName $ResourceGroupName -VM $vm | Out-Null }

        # Verify DeleteOption=Detach on all resources before proceeding to deletion.
        # Update-AzVM is synchronous, but ARM's read-after-write consistency is eventual:
        # a Get-AzVM immediately after Update may hit a different front-end that hasn't
        # replicated yet. Retry up to 3 times with a short backoff instead of a fixed 30s sleep.
        WriteLog "Verifying DeleteOption was applied..."
        $badItems = @()
        for ($_verifyAttempt = 1; $_verifyAttempt -le 3; $_verifyAttempt++) {
            if ($_verifyAttempt -gt 1) {
                WriteLog "  Retry $_verifyAttempt/3: waiting 10 seconds for ARM replication..."
                Start-Sleep -Seconds 10
            }
            $vmVerify = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
            $badItems = @(Get-VMResourcesWithBadDeleteOption $vmVerify)
            if ($badItems.Count -eq 0) { break }
        }
        if ($badItems.Count -gt 0) {
            WriteLog "ABORTING  -  DeleteOption was NOT set to Detach on the following resources:" "ERROR"
            foreach ($item in $badItems) { WriteLog "  $item" "ERROR" }
            WriteLog "The VM has NOT been deleted. Resolve this manually before re-running." "ERROR"
            Write-TrustedLaunchRestoreNote   # no-op if -AllowTrustedLaunchDowngrade was not used
            Stop-Script
        }
        WriteLog "Verified: DeleteOption = Detach on OS disk, $($vmVerify.StorageProfile.DataDisks.Count) data disk(s) and $($vmVerify.NetworkProfile.NetworkInterfaces.Count) NIC(s)."
    } catch {
        WriteLog "Error setting/verifying DeleteOption: $_" "ERROR"
        WriteLog "Aborting  -  VM has NOT been deleted. No resources were changed." "ERROR"
        Write-TrustedLaunchRestoreNote   # no-op if -AllowTrustedLaunchDowngrade was not used
        Stop-Script
    }

    WriteLog "DeleteOption verified  -  deleting VM shell now (disks and NICs are preserved)..." "IMPORTANT"
    # Single point-of-no-return for PATH B. Mentions vTPM loss when TrustedLaunch applies so
    # the operator sees the most important consequence right before the irreversible action.
    # AskToContinue handles -Force (auto-continues with log) and -DryRun (no prompt) internally.
    $_deletePrompt = if ($_securityType -eq 'TrustedLaunch') {
        "The original VM '$VMName' will now be DELETED and recreated (vTPM state will be permanently lost). Continue?"
    } else {
        "The original VM '$VMName' will now be DELETED and recreated. Continue?"
    }
    AskToContinue $_deletePrompt
    try {
        Invoke-AzWithRetry -Description 'Remove-AzVM' -ScriptBlock { Remove-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Force | Out-Null }
        WriteLog "VM shell deleted. OS disk '$($osDisk.Name)', data disks and NICs are intact."
        # Old VM is gone: Update-AzVM to restore TrustedLaunch is no longer possible.
        # Clear the flag so the finally block does not emit a misleading "run Update-AzVM" note.
        # TrustedLaunch is already embedded in $newVMConfig.SecurityProfile and will be applied
        # by New-AzVM in STEP 7B. If New-AzVM fails, its error handler logs recovery instructions.
        if ($script:_needTrustedLaunchRestore) {
            WriteLog "  TrustedLaunch will be restored via SecurityProfile in the new VM (STEP 7B)." "WARNING"
            $script:_needTrustedLaunchRestore = $false
        }
    } catch {
        WriteLog "Error deleting VM: $_" "ERROR"
        Write-TrustedLaunchRestoreNote   # no-op if -AllowTrustedLaunchDowngrade was not used
        Stop-Script
    }

    # STEP 7B  -  Create new VM
    WriteLog "--- STEP 7B: Creating new VM '$VMName' (size: $VMSize, controller: $NewControllerType) ---" "IMPORTANT"
    try {
        # Base VM config.
        # NOTE: -DiskControllerType cannot be combined with -AvailabilitySetId or
        # -ProximityPlacementGroupId on New-AzVMConfig as they are in different parameter sets.
        # Solution: set DiskControllerType on StorageProfile AFTER Set-AzVMOSDisk,
        # which initialises StorageProfile ($null on a fresh config object).
        WriteLog "  Building VM config..."
        $_ppgParam      = if ($_ppgId)     { @{ ProximityPlacementGroupId = $_ppgId     } } else { @{} }
        $_availSetParam = if ($_availSetId) { @{ AvailabilitySetId        = $_availSetId } } else { @{} }
        $newVMConfig = New-AzVMConfig -VMName $VMName -VMSize $VMSize @_ppgParam @_availSetParam
        WriteLog "  VM config created (size: $VMSize$(if ($_ppgId) { ', PPG: ' + (Get-ArmName $_ppgId) })$(if ($_availSetId) { ', AvailSet: ' + (Get-ArmName $_availSetId) }))."

        WriteLog "  Attaching OS disk: $($osDisk.Name)..."
        # -Windows and -Linux are mutually exclusive switches on Set-AzVMOSDisk.
        # Splatting adds the right one without duplicating the full call.
        $_osDiskSplat = @{ VM = $newVMConfig; ManagedDiskId = $osDisk.Id; CreateOption = "Attach"; Caching = $_osDiskCaching }
        if ($osDisk.OsType -eq "Windows") { $_osDiskSplat["Windows"] = $true } else { $_osDiskSplat["Linux"] = $true }
        $newVMConfig = Set-AzVMOSDisk @_osDiskSplat
        # Restore original OS disk DeleteOption (captured in STEP 5B before STEP 6B forced it to Detach).
        # Set-AzVMOSDisk has no -DeleteOption parameter; must be set directly on the disk object.
        if ($_osDiskDeleteOption) {
            $newVMConfig.StorageProfile.OsDisk.DeleteOption = $_osDiskDeleteOption
            WriteLog "  OS disk caching: $_osDiskCaching  DeleteOption: $_osDiskDeleteOption"
        } else {
            WriteLog "  OS disk caching: $_osDiskCaching"
        }

        # Set DiskControllerType now that StorageProfile has been initialised by Set-AzVMOSDisk
        $newVMConfig.StorageProfile.DiskControllerType = $NewControllerType
        WriteLog "  DiskControllerType set to $NewControllerType."

        # Data disks
        if ($_dataDisks.Count -gt 0) {
            WriteLog "  Attaching $($_dataDisks.Count) data disk(s)..."
            foreach ($dd in $_dataDisks) {
                $newVMConfig = Add-AzVMDataDisk `
                    -VM                   $newVMConfig `
                    -ManagedDiskId        $dd.ManagedDisk.Id `
                    -Lun                  $dd.Lun `
                    -CreateOption         Attach `
                    -Caching              $dd.Caching `
                    -DiskSizeInGB         $dd.DiskSizeGB `
                    -WriteAccelerator:([bool]$dd.WriteAcceleratorEnabled)
                # DeleteOption is not a parameter on Add-AzVMDataDisk; set it directly on
                # the last-added disk object. Preserves the original 'Delete' or 'Detach'
                # intent so scratch/temp data disks behave identically after recreation.
                if ($dd.DeleteOption) {
                    $newVMConfig.StorageProfile.DataDisks[-1].DeleteOption = $dd.DeleteOption
                }
                WriteLog "    LUN $($dd.Lun): $($dd.Name) ($($dd.DiskSizeGB) GB, caching: $($dd.Caching)$(if ($dd.WriteAcceleratorEnabled) { ', WriteAccelerator: ON' })$(if ($dd.DeleteOption) { ', DeleteOption: ' + $dd.DeleteOption }))"
            }
        } else {
            WriteLog "  No data disks to attach."
        }

        # OS disk Write Accelerator (M-series: rare but valid on OS disk too)
        if ($_osWriteAccelerator) {
            $newVMConfig.StorageProfile.OsDisk.WriteAcceleratorEnabled = $true
            WriteLog "  OS disk WriteAccelerator: enabled (M-series)"
        }

        # NICs  -  preserve primary flag
        # Accelerated networking:
        #   Target does not support it  -> disable on any NIC that has it enabled.
        #   Target supports it + -EnableAcceleratedNetworking -> enable on all NICs.
        #   Target supports it, no flag -> leave NIC setting unchanged.
        WriteLog "  Attaching $($_nics.Count) NIC(s)..."
        # NIC objects were pre-fetched in STEP 5B (Get-AzNICBatch) - no extra API calls here.
        # If a NIC was not in the cache (should not happen), fall back to a fresh Get-AzNetworkInterface.
        foreach ($nic in $_nics) {   # use STEP 5B snapshot - $vm is the STEP 6B object (all DeleteOptions=Detach)
            $nicName = Get-ArmName $nic.Id
            # Use cached object if present and non-null (SilentlyContinue may leave null in the cache).
            $nicObj  = if ($_nicObjects -and $_nicObjects.ContainsKey($nic.Id) -and $_nicObjects[$nic.Id]) { $_nicObjects[$nic.Id] } else { Get-AzNetworkInterface -Name $nicName -ResourceGroupName (Get-ArmRG $nic.Id) }
            if (-not $_accelNetSupported) {
                # Target size does not support accel net - disable if currently enabled
                if ($nicObj.EnableAcceleratedNetworking) {
                    WriteLog "    NIC: $nicName - disabling AcceleratedNetworking (not supported by $VMSize)..." "WARNING"
                    $nicObj.EnableAcceleratedNetworking = $false
                    Invoke-AzWithRetry -Description "Set-AzNetworkInterface ($nicName disable AccelNet)" -ScriptBlock { Set-AzNetworkInterface -NetworkInterface $nicObj | Out-Null }
                    WriteLog "    NIC: $nicName - AcceleratedNetworking disabled."
                } else {
                    WriteLog "    NIC: $nicName$(if ($nic.Primary) { ' (primary)' }) - AcceleratedNetworking already disabled."
                }
            } elseif ($EnableAcceleratedNetworking) {
                # Target supports it and user requested it - enable if not already on
                if (-not $nicObj.EnableAcceleratedNetworking) {
                    WriteLog "    NIC: $nicName - enabling AcceleratedNetworking (-EnableAcceleratedNetworking)..." "INFO"
                    $nicObj.EnableAcceleratedNetworking = $true
                    Invoke-AzWithRetry -Description "Set-AzNetworkInterface ($nicName enable AccelNet)" -ScriptBlock { Set-AzNetworkInterface -NetworkInterface $nicObj | Out-Null }
                    WriteLog "    NIC: $nicName - AcceleratedNetworking enabled."
                } else {
                    WriteLog "    NIC: $nicName$(if ($nic.Primary) { ' (primary)' }) - AcceleratedNetworking already enabled."
                }
            } else {
                WriteLog "    NIC: $nicName$(if ($nic.Primary) { ' (primary)' })"
            }
            $newVMConfig = Add-AzVMNetworkInterface -VM $newVMConfig -Id $nic.Id -Primary:($nic.Primary -eq $true)
            # DeleteOption is not a parameter on Add-AzVMNetworkInterface; set it directly.
            # Preserves any 'Delete' intent on NICs that were provisioned as ephemeral/disposable.
            if ($nic.DeleteOption) {
                $newVMConfig.NetworkProfile.NetworkInterfaces[-1].DeleteOption = $nic.DeleteOption
            }
        }

        # Optional properties
        # Availability set and PPG already set via New-AzVMConfig above.
        if ($_zones -and $_zones.Count -gt 0) {
            $newVMConfig.Zones = $_zones
            WriteLog "  Zone(s): $($_zones -join ', ')"
        }
        if ($_licenseType) {
            $newVMConfig.LicenseType = $_licenseType
            WriteLog "  License type: $_licenseType"
        }
        if ($_bootDiag -and $_bootDiag.BootDiagnostics -and $_bootDiag.BootDiagnostics.Enabled) {
            # -StorageAccountUri was removed in newer Az.Compute versions.
            # If a storage URI is set use it; otherwise enable managed boot diagnostics (no URI needed).
            $_bootUri = $_bootDiag.BootDiagnostics.StorageUri
            if ($_bootUri) {
                # Parse the storage account name from the URI (https://<account>.blob.core...).
                $_storageAccountName = $_bootUri -replace 'https?://([^.]+).*','$1'
                # The storage account may live in a different resource group from the VM.
                # Set-AzVMBootDiagnostic requires -ResourceGroupName; using the VM's RG would
                # silently fail (404) and fall back to managed boot diagnostics, losing the
                # original storage account configuration without any error logged.
                # Look up the real resource group via a subscription-wide search.
                $_bootStorageRG     = $null
                $_bootStorageFailed = $false
                try {
                    $_bootStorageAccount = Get-AzStorageAccount -ErrorAction Stop |
                        Where-Object { $_.StorageAccountName -eq $_storageAccountName } |
                        Select-Object -First 1
                    if ($_bootStorageAccount) {
                        $_bootStorageRG = $_bootStorageAccount.ResourceGroupName
                    }
                } catch {
                    $_bootStorageFailed = $true
                    WriteLog "  Boot diagnostics: could not enumerate storage accounts to find '$_storageAccountName': $_" "WARNING"
                    WriteLog "    Falling back to managed boot diagnostics  -  restore original config manually after recreation." "WARNING"
                }
                if ($_bootStorageRG) {
                    WriteLog "  Boot diagnostics: storage account '$_storageAccountName' found in RG '$_bootStorageRG'"
                    $newVMConfig = Set-AzVMBootDiagnostic -VM $newVMConfig -Enable -ResourceGroupName $_bootStorageRG -StorageAccountName $_storageAccountName
                } elseif (-not $_bootStorageFailed) {
                    # Account not found anywhere in this subscription (cross-subscription,
                    # access-denied at list level already caught above, or account deleted).
                    WriteLog "  Boot diagnostics: storage account '$_storageAccountName' not found in this subscription." "WARNING"
                    WriteLog "    Falling back to managed boot diagnostics (Azure-managed storage)." "WARNING"
                    WriteLog "    To restore original config: Set-AzVMBootDiagnostic -ResourceGroupName <RG> -StorageAccountName '$_storageAccountName'" "WARNING"
                    $newVMConfig = Set-AzVMBootDiagnostic -VM $newVMConfig -Enable
                } else {
                    # Exception path: warning already logged above; enable managed as fallback.
                    $newVMConfig = Set-AzVMBootDiagnostic -VM $newVMConfig -Enable
                }
            } else {
                $newVMConfig = Set-AzVMBootDiagnostic -VM $newVMConfig -Enable
                WriteLog "  Boot diagnostics: enabled (managed storage)"
            }
        }
        if ($_ultraSSD -or $_hibernation) {
            # Both UltraSSD and Hibernation live on the same AdditionalCapabilities object.
            # Setting the object with only one property would clear the other, so they are
            # always written together.
            $newVMConfig.AdditionalCapabilities = [Microsoft.Azure.Management.Compute.Models.AdditionalCapabilities]@{
                UltraSSDEnabled    = [bool]$_ultraSSD
                HibernationEnabled = [bool]$_hibernation
            }
            if ($_ultraSSD)    { WriteLog "  UltraSSD: enabled" }
            if ($_hibernation) { WriteLog "  Hibernation: enabled" }
        }

        # Security profile: TrustedLaunch (SecureBoot + vTPM) and/or EncryptionAtHost.
        # TrustedLaunch is now the Azure-recommended default for Gen2 VMs. Without restoring
        # the SecurityProfile, a TrustedLaunch VM will either fail to boot (if VM Guest State
        # was written to the OS disk) or silently lose Secure Boot and vTPM protection.
        # EncryptionAtHost covers the temp disk and disk caches - losing it is a silent
        # security regression with no error at boot.
        if ($_securityType -or $_encryptionAtHost) {
            $newVMConfig.SecurityProfile = [Microsoft.Azure.Management.Compute.Models.SecurityProfile]@{
                SecurityType     = $_securityType     # 'TrustedLaunch' or 'Standard' or $null
                EncryptionAtHost = $_encryptionAtHost # bool
            }
            if ($_securityType -eq 'TrustedLaunch') {
                $newVMConfig.SecurityProfile.UefiSettings = [Microsoft.Azure.Management.Compute.Models.UefiSettings]@{
                    SecureBootEnabled = $_secureBoot
                    VTpmEnabled       = $_vTpm
                }
                WriteLog "  Security type : TrustedLaunch (SecureBoot=$_secureBoot, vTPM=$_vTpm)"
            } elseif ($_securityType) {
                WriteLog "  Security type : $_securityType"
            }
            if ($_encryptionAtHost) { WriteLog "  EncryptionAtHost: enabled" }
        }

        # Capacity Reservation Group: restores the VM's slot association so the
        # reservation continues to be consumed (and billing stays accurate).
        if ($_capacityReservId) {
            $newVMConfig.CapacityReservation = [Microsoft.Azure.Management.Compute.Models.CapacityReservationProfile]@{
                CapacityReservationGroup = [Microsoft.Azure.Management.Compute.Models.SubResource]@{ Id = $_capacityReservId }
            }
            WriteLog "  Capacity reservation: $(Get-ArmName $_capacityReservId)"
        }

        # UserData: base64-encoded payload read by cloud-init and VM extensions on each boot.
        if ($_userData) {
            $newVMConfig.UserData = $_userData
            WriteLog "  UserData: restored"
        }

        # Marketplace Plan: required for VMs originally deployed from paid marketplace images.
        # Without this, New-AzVM may fail with a plan mismatch error, or the VM starts without
        # its billing plan - either way an unrecoverable state if the original VM is already gone.
        if ($_plan -and $_plan.Publisher) {
            $newVMConfig = Set-AzVMPlan -VM $newVMConfig -Publisher $_plan.Publisher -Product $_plan.Product -Name $_plan.Name
            if ($_plan.PromotionCode) { $newVMConfig.Plan.PromotionCode = $_plan.PromotionCode }
            WriteLog "  Marketplace plan: $($_plan.Publisher) / $($_plan.Name)"
        }

        # VmSizeProperties: custom CPU configuration (reduced vCPU count, SMT disabled).
        # Applied for the target size. If the target size differs from the source the specific
        # values may be invalid (e.g. vCPUsAvailable must not exceed the target size's default).
        # New-AzVM will reject invalid values; a warning is logged and recreation continues
        # without the constraint - the operator must apply it manually via Update-AzVM.
        if ($_vmSizeProps -and ($_vmSizeProps.VCPUsAvailable -or $_vmSizeProps.VCPUsPerCore)) {
            try {
                $newVMConfig.HardwareProfile.VmSizeProperties = [Microsoft.Azure.Management.Compute.Models.VMSizeProperties]@{
                    VCPUsAvailable = $_vmSizeProps.VCPUsAvailable
                    VCPUsPerCore   = $_vmSizeProps.VCPUsPerCore
                }
                WriteLog "  VmSizeProperties: vCPUsAvailable=$($_vmSizeProps.VCPUsAvailable), vCPUsPerCore=$($_vmSizeProps.VCPUsPerCore)"
                if ($script:_originalSize -ne $VMSize) {
                    WriteLog "    Note: VM size changed - verify these values are valid for $VMSize before proceeding." "WARNING"
                    WriteLog "    If New-AzVM fails, re-run with -ForcePathA or apply after recreation via Update-AzVM." "WARNING"
                }
            } catch {
                WriteLog "  VmSizeProperties: could not apply ($_)  -  set manually after recreation." "WARNING"
            }
        }

        # VM Gallery Applications: Azure Compute Gallery packages (distinct from VM Extensions).
        # These are full software packages (monitoring agents, security tools, custom software)
        # deployed via gallery versioning and installed by the VMApplicationManager extension.
        if ($_galleryApps.Count -gt 0) {
            WriteLog "  Gallery applications: restoring $($_galleryApps.Count) application(s)..."
            foreach ($_app in $_galleryApps) {
                try {
                    $newVMConfig = Add-AzVmGalleryApplication -VM $newVMConfig `
                        -PackageReferenceId $_app.PackageReferenceId `
                        -Order              $_app.Order `
                        -TreatFailureAsDeploymentFailure:([bool]$_app.TreatFailureAsDeploymentFailure)
                    if ($_app.ConfigurationReference) {
                        # ConfigurationReference must be set directly on the last-added entry
                        $newVMConfig.ApplicationProfile.GalleryApplications[-1].ConfigurationReference = $_app.ConfigurationReference
                    }
                    WriteLog "    Gallery app: $($_app.PackageReferenceId.Split('/')[-3])/$($_app.PackageReferenceId.Split('/')[-1]) (order: $($_app.Order))"
                } catch {
                    WriteLog "    Gallery app '$($_app.PackageReferenceId.Split('/')[-3])': failed to add ($_)  -  add manually after recreation." "WARNING"
                }
            }
        }
        if ($_identity) {
            $newVMConfig.Identity = $_identity
            WriteLog "  Managed identity: $($_identity.Type)"
            # Clarify the operational implications of identity restoration for the operator.
            # The Identity object is passed to New-AzVM, but the effect differs by identity type:
            #   SystemAssigned: Azure creates a BRAND-NEW managed identity with a new PrincipalId.
            #                   The old PrincipalId is gone after Remove-AzVM. Any RBAC role
            #                   assignments (Storage, Key Vault, Automation, Service Bus, etc.)
            #                   on the old principal silently stop working. STEP 9B restores these
            #                   automatically; any failures require manual re-assignment.
            #   UserAssigned:   The user-assigned identity resource itself is NOT deleted by
            #                   Remove-AzVM. Its PrincipalId is stable and survives VM recreation.
            #                   RBAC assignments on user-assigned identities are unaffected.
            # NOTE: "Managed identity restored" in this log does NOT mean "all RBAC is working".
            #       For system-assigned identities, RBAC is only fully restored after STEP 9B.
            if ($_hasSystemMI -and $_hasUserMI) {
                if ($RestoreSystemAssignedRBAC) {
                    WriteLog "    SystemAssigned : new PrincipalId assigned by Azure  -  RBAC will be restored in STEP 9B." "WARNING"
                } else {
                    WriteLog "    SystemAssigned : new PrincipalId assigned by Azure  -  RBAC NOT auto-restored (see pre-flight log)." "WARNING"
                }
                WriteLog "    UserAssigned   : PrincipalId(s) unchanged  -  RBAC on user-assigned identities is unaffected." "INFO"
            } elseif ($_hasSystemMI) {
                if ($RestoreSystemAssignedRBAC) {
                    WriteLog "    SystemAssigned : new PrincipalId assigned by Azure  -  RBAC will be restored in STEP 9B." "WARNING"
                } else {
                    WriteLog "    SystemAssigned : new PrincipalId assigned by Azure  -  RBAC NOT auto-restored (re-assign manually)." "WARNING"
                }
            } elseif ($_hasUserMI) {
                WriteLog "    UserAssigned   : PrincipalId(s) stable across recreation  -  RBAC is unaffected." "INFO"
            }
        }
        if ($_priority) {
            $newVMConfig.Priority = $_priority
            WriteLog "  Priority: $_priority"
            # Eviction policy and max price are only valid for Spot/Low priority VMs.
            if ($_evictionPolicy) {
                $newVMConfig.EvictionPolicy = $_evictionPolicy
                WriteLog "  Eviction policy: $_evictionPolicy"
            }
            if ($null -ne $_maxPrice) {
                $newVMConfig.BillingProfile = [Microsoft.Azure.Management.Compute.Models.BillingProfile]@{ MaxPrice = $_maxPrice }
                if ($_maxPrice -eq -1) {
                    WriteLog "  Max price cap: none (pay-as-you-go, MaxPrice=-1)"
                } else {
                    WriteLog "  Max price cap: `$$_maxPrice/hr"
                }
            } else {
                WriteLog "  Max price cap: not set (Azure default)"
            }
        }
        # Dedicated Host: restore host or host group pinning.
        # These are mutually exclusive - the VM can only have one.
        if ($_hostId) {
            $newVMConfig.Host = [Microsoft.Azure.Management.Compute.Models.SubResource]@{ Id = $_hostId }
            WriteLog "  Dedicated host: $(Get-ArmName $_hostId)"
        } elseif ($_hostGroupId) {
            $newVMConfig.HostGroup = [Microsoft.Azure.Management.Compute.Models.SubResource]@{ Id = $_hostGroupId }
            WriteLog "  Host group: $(Get-ArmName $_hostGroupId)"
        }
        if ($_tags -and $_tags.Count -gt 0) {
            $newVMConfig.Tags = $_tags
            WriteLog "  Tags: $($_tags.Count) tag(s) applied"
        }

        # ScheduledEventsProfile: restores the graceful termination notification window.
        # Spot VM operators typically set this to PT5M–PT15M so workloads can checkpoint
        # before eviction. Silently dropped without this, leaving the VM with no warning window.
        if ($_schedEventsProfile -and $_schedEventsProfile.TerminateNotificationProfile -and
            $_schedEventsProfile.TerminateNotificationProfile.Enable) {
            $newVMConfig.ScheduledEventsProfile = $_schedEventsProfile
            WriteLog "  Scheduled events: terminate notification enabled (window: $($_schedEventsProfile.TerminateNotificationProfile.NotBeforeTimeout))"
        }

        # VMSS Flexible orchestration membership: re-registers the VM with the scale set.
        # Remove-AzVM removes it from the set. Both VirtualMachineScaleSet and PlatformFaultDomain
        # can only be set at creation time, not via Update-AzVM afterwards.
        # WARNING: load balancer backend pool membership is NOT restored automatically.
        if ($_vmssId) {
            $newVMConfig.VirtualMachineScaleSet = [Microsoft.Azure.Management.Compute.Models.SubResource]@{ Id = $_vmssId }
            WriteLog "  VMSS: $(Get-ArmName $_vmssId)"
            if ($null -ne $_platformFaultDom) {
                $newVMConfig.PlatformFaultDomain = $_platformFaultDom
                WriteLog "  Platform fault domain: $_platformFaultDom"
            }
        }

        # ExtendedLocation (Edge Zone): passed directly to New-AzVM.
        # If omitted the VM is created in the parent Azure region, not the edge node.
        $_extLocParam = if ($_extendedLocation -and $_extendedLocation.Name) {
            WriteLog "  Extended location: $($_extendedLocation.Name) ($($_extendedLocation.Type))"
            @{ ExtendedLocation = $_extendedLocation }
        } else { @{} }
        # Source image reference is intentionally NOT set on the new VM config.
        # Set-AzVMSourceImage is mutually exclusive with -CreateOption Attach:
        # attaching an existing OS disk means Azure uses that disk as-is, with no
        # image reference needed or allowed. The image info is logged in STEP 5B only.
        if ($_imageRef -and $_imageRef.Publisher) {
            WriteLog "  Source image (informational): $($_imageRef.Publisher) / $($_imageRef.Offer) / $($_imageRef.Sku)"
        }

        WriteLog "  Submitting New-AzVM request to Azure  -  this typically takes 2-3 minutes..."
        # Note: New-AzVM always starts the VM immediately after creation.
        # There is no -NoWait or deferred-start option; the VM will be running when this returns.
        # Pipe through Tee-Object so we capture all output objects for $newVM extraction below,
        # while also streaming verbose Azure progress lines to the log in real time.
        # ForEach-Object produces no output (it only calls WriteLog), so we do NOT assign
        # the pipeline result; $newVM is populated on the next line from $_newAzVMOutput.
        New-AzVM -ResourceGroupName $ResourceGroupName -Location $_location -VM $newVMConfig @_extLocParam -Verbose 4>&1 | Tee-Object -Variable _newAzVMOutput | ForEach-Object {
                if ($_ -is [System.Management.Automation.VerboseRecord]) {
                    WriteLog "  [Azure] $($_.Message)"
                }
            }
        $newVM = $_newAzVMOutput | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] } | Select-Object -Last 1

        WriteLog "New VM '$VMName' created successfully." "IMPORTANT"
        if ($newVM) {
            WriteLog "  Provisioning state: $($newVM.StatusCode)"
        } else {
            WriteLog "  (Provisioning state unavailable - VM was created but output object was not captured)" "WARNING"
        }

        # TrustedLaunch: the SecurityProfile was included in $newVMConfig (captured in STEP 5B).
        # The new VM is born with a fresh TrustedLaunch chip - no extra Update-AzVM needed.
        if ($_isTrustedLaunchDowngrade) {
            WriteLog "  TrustedLaunch restored on new VM (SecurityType=TrustedLaunch from STEP 5B config)." "IMPORTANT"
            Write-VTPMDataLossWarning
            $script:_needTrustedLaunchRestore = $false
        }

        # Verify the VM has actually reached running state after creation.
        # New-AzVM returns as soon as provisioning succeeds, but the guest OS may still be
        # starting. This check confirms the power state from the control plane perspective.
        try {
            $vmPost     = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status -ErrorAction Stop
            $postPower  = ($vmPost.Statuses | Where-Object { $_.Code -like 'PowerState*' } | Select-Object -First 1).Code
            WriteLog "  Post-creation power state: $postPower"
            if ($postPower -ne "PowerState/running") {
                WriteLog "  VM is not yet running ($postPower)  -  start it manually if it does not come up on its own." "WARNING"
            }
        } catch {
            WriteLog "  Could not verify post-creation power state: $_  -  check the VM manually." "WARNING"
        }

        if ($_vmssId) {
            WriteLog "  VMSS membership restored: $(Get-ArmName $_vmssId)" "INFO"
            WriteLog "  IMPORTANT: Load balancer backend pool membership is NOT automatically restored." "WARNING"
            WriteLog "    Verify the VM appears in the correct backend pool before returning it to service." "WARNING"
        }

        # Azure does not allow setting or changing imageReference on an existing VM -
        # any PATCH to storageProfile.imageReference returns "PropertyChangeNotAllowed".
        # The source image info is preserved on the OS disk resource itself
        # (Get-AzDisk | Select -ExpandProperty CreationData) and was logged in STEP 5B.
        if ($_imageRef -and $_imageRef.Publisher) {
            WriteLog "  Source image info is retained on the OS disk (creationData.imageReference)." "INFO"
            WriteLog "  Azure does not allow restoring imageReference on an existing VM - portal will show blank." "INFO"
        }

    } catch {
        WriteLog "Error creating new VM: $_" "ERROR"
        WriteLog "============================================================" "ERROR"
        WriteLog "IMPORTANT: The VM shell has been deleted, but all resources are intact." "ERROR"
        WriteLog "  Original OS disk : $($osDisk.Name) (RG: $diskRg)" "ERROR"
        WriteLog "  Snapshot (backup): $snapshotName  (RG: $ResourceGroupName)" "ERROR"
        WriteLog "  NICs             : $($_nicIds -join ', ')" "ERROR"
        WriteLog "Re-run this script, or recreate the VM manually:" "ERROR"
        WriteLog "  New-AzVMConfig ... | Set-AzVMOSDisk -ManagedDiskId '$($osDisk.Id)' -CreateOption Attach" "ERROR"
        # TrustedLaunch note: if -AllowTrustedLaunchDowngrade was used, SecurityProfile=TrustedLaunch
        # was already embedded in $newVMConfig before New-AzVM was called. The VM no longer exists
        # so Update-AzVM is moot; _needTrustedLaunchRestore was already cleared after Remove-AzVM.
        # When re-running this script or recreating manually, include SecurityProfile=TrustedLaunch
        # in the VM config - the new VM will boot with a fresh TrustedLaunch posture.
        if ($_isTrustedLaunchDowngrade) {
            WriteLog "  TrustedLaunch note: SecurityProfile=TrustedLaunch was in the failed $newVMConfig." "WARNING"
            WriteLog "    Re-running this script will include it automatically." "WARNING"
            WriteLog "    If recreating manually: add SecurityProfile=TrustedLaunch to New-AzVMConfig." "WARNING"
        }
        WriteLog "============================================================" "ERROR"
        Stop-Script
    }

    # STEP 8B  -  Reinstall VM extensions
    # Extensions are bound to the VM resource and not preserved through recreation.
    # Two user-visible reinstall outcomes:
    #   AUTO   - reinstalled automatically. Some extensions have internal special handling
    #            (KeyVault: RBAC warning; MMA/OMS: workspace key lookup; SqlIaasAgent: survive-or-create)
    #            but the operator sees them succeed just like any other AUTO extension.
    #   MANUAL - protected settings required with no API recovery path; operator must reinstall.
    if ($_extensionList.Count -gt 0 -and -not $SkipExtensionReinstall) {
        WriteLog "--- STEP 8B: Reinstalling $($_extensionList.Count) VM extension(s) ---" "IMPORTANT"
        $_reinstalled = @()
        $_manualList  = @()
        $_failedList  = @()

        # One-time check: discover which optional parameters the installed Az.Compute version
        # of Set-AzVMExtension actually accepts. -AutoUpgradeMinorVersion and
        # -EnableAutomaticUpgrade vary across Az.Compute versions; splatting an unsupported
        # parameter name causes a "parameter cannot be found" error for every extension.
        $_setExtCmdParams = (Get-Command Set-AzVMExtension -ErrorAction SilentlyContinue).Parameters
        $_extSupportsAutoUpgrade   = ($null -ne $_setExtCmdParams -and $_setExtCmdParams.ContainsKey('AutoUpgradeMinorVersion'))
        $_extSupportsEnableAutoUpg = ($null -ne $_setExtCmdParams -and $_setExtCmdParams.ContainsKey('EnableAutomaticUpgrade'))
        WriteLog "  Set-AzVMExtension params available: AutoUpgradeMinorVersion=$_extSupportsAutoUpgrade, EnableAutomaticUpgrade=$_extSupportsEnableAutoUpg"

        foreach ($_ext in $_extensionList) {

            # ── -SkipExtensions: operator-specified first (overrides ALL other classification) ─
            # An extension explicitly listed by the operator is always skipped, even if its type
            # is in $_manualExtTypes. The operator has deliberately opted out; treating it as
            # MANUAL instead would log misleading ACTION REQUIRED output and contradict the DryRun
            # summary which shows it as SKIP. Must come before the MANUAL and azure-managed checks.
            if ($SkipExtensions -and $_ext.Name -in $SkipExtensions) {
                WriteLog "  SKIP (-SkipExtensions): '$($_ext.Name)' ($($_ext.ExtensionType))  -  skipped by operator request." "INFO"
                continue
            }

            # ── Azure-managed extensions: skip, they re-deploy via their own service plane ──
            if ($_ext.ExtensionType -in $_azureManagedExtTypes) {
                WriteLog "  SKIP (Azure-managed): '$($_ext.Name)' ($($_ext.ExtensionType))  -  will re-appear automatically." "INFO"
                continue
            }

            # ── Definitive MANUAL check ──────────────────────────────────────────────────────
            if ($_ext.ExtensionType -in $_manualExtTypes) {
                $_reason = Get-ExtensionManualReason -ExtensionType $_ext.ExtensionType
                WriteLog "  MANUAL: '$($_ext.Name)' ($($_ext.ExtensionType))  -  $_reason" "WARNING"
                $_manualList += $_ext
                continue
            }

            # ── Build base params (shared by all AUTO extensions) ────────────────────────────
            # TypeHandlerVersion can be null on extensions installed without an explicit version.
            # Splitting null produces an empty array; joining produces an empty string which
            # Set-AzVMExtension rejects with a parameter validation error. Default to '1.0'.
            if (-not $_ext.TypeHandlerVersion) {
                WriteLog "  '$($_ext.Name)' ($($_ext.ExtensionType)): TypeHandlerVersion is null - defaulting to '1.0'." "WARNING"
                $_ver = '1.0'
            } else {
                $_ver = ($_ext.TypeHandlerVersion -split '\.')[0..1] -join '.'
            }
            $_extParams = @{
                ResourceGroupName  = $ResourceGroupName
                VMName             = $VMName
                Name               = $_ext.Name
                Publisher          = $_ext.Publisher
                ExtensionType      = $_ext.ExtensionType
                TypeHandlerVersion = $_ver
                Location           = $_location
            }
            # Guard optional parameters against Az.Compute version differences.
            # -AutoUpgradeMinorVersion was the original parameter name; newer versions of
            # Az.Compute renamed it to -EnableAutomaticUpgrade. The wrong name causes a
            # "parameter cannot be found" error when splatting. Availability was checked
            # once before the loop (see $_extSupportsAutoUpgrade / $_extSupportsEnableAutoUpg).
            if ($null -ne $_ext.AutoUpgradeMinorVersion -and $_extSupportsAutoUpgrade) {
                $_extParams['AutoUpgradeMinorVersion'] = $_ext.AutoUpgradeMinorVersion
            }
            if ($null -ne $_ext.EnableAutomaticUpgrade -and $_extSupportsEnableAutoUpg) {
                $_extParams['EnableAutomaticUpgrade'] = $_ext.EnableAutomaticUpgrade
            }
            if ($_ext.Settings -and $_ext.Settings.Count -gt 0) { $_extParams['Settings'] = $_ext.Settings }

            # ── Special handling ─────────────────────────────────────────────────────────────

            # KeyVault extension  ──────────────────────────────────────────────────────────────
            # Authenticates to Key Vault via managed identity; no protected settings needed.
            # User-assigned MI: identity is independent of the VM lifecycle, RBAC is preserved.
            # System-assigned MI: the new VM has a DIFFERENT principal ID after recreation,
            #   so any Key Vault RBAC assignments or access policies referencing the old
            #   principal will be broken until updated by the operator.
            if ($_ext.ExtensionType -in @('KeyVaultForWindows','KeyVaultForLinux')) {
                if (-not $_hasSystemMI -and -not $_hasUserMI) {
                    WriteLog "  MANUAL: '$($_ext.Name)' (KeyVault)  -  no managed identity on VM. Configure MI then reinstall." "WARNING"
                    $_manualList += $_ext
                    continue
                }
                if ($_hasUserMI) {
                    WriteLog "  '$($_ext.Name)' (KeyVault): user-assigned MI found  -  Key Vault RBAC is preserved." "INFO"
                } else {
                    # System-assigned only: new VM = new principal ID.
                    # STEP 9B runs AFTER STEP 8B; RBAC may not be in place yet when the extension
                    # installs. The extension will start working once RBAC is correct.
                    if ($RestoreSystemAssignedRBAC) {
                        WriteLog "  '$($_ext.Name)' (KeyVault): system-assigned MI only." "WARNING"
                        WriteLog "    RBAC restore is enabled (-RestoreSystemAssignedRBAC)." "WARNING"
                        WriteLog "    STEP 9B (after this step) will restore Key Vault RBAC to the new principal." "WARNING"
                        WriteLog "    The extension installs now and should work once STEP 9B completes." "WARNING"
                    } else {
                        WriteLog "  '$($_ext.Name)' (KeyVault): system-assigned MI only  -  ACTION REQUIRED:" "WARNING"
                        WriteLog "    The recreated VM has a NEW system-assigned principal ID." "WARNING"
                        WriteLog "    Key Vault RBAC role assignments or access policies referencing the old principal" "WARNING"
                        WriteLog "    will be broken until you update them to the new principal ID." "WARNING"
                        WriteLog "    After this script completes, run:" "WARNING"
                        WriteLog "      (Get-AzVM -ResourceGroupName '$ResourceGroupName' -Name '$VMName').Identity.PrincipalId" "WARNING"
                        WriteLog "    Then update your Key Vault RBAC / access policy with the new principal ID." "WARNING"
                        WriteLog "    Alternatively, re-run with -RestoreSystemAssignedRBAC to auto-restore RBAC." "WARNING"
                        WriteLog "    The extension installs now and will work once RBAC is fixed." "WARNING"
                    }
                }
                # Extension itself needs no protected settings when using MI
            }

            # SqlIaasAgent  ───────────────────────────────────────────────────────────────────
            # The SQL IaaS Agent extension has no protected settings. It is registered via
            # New-AzSqlVM (which creates a separate Microsoft.SqlVirtualMachine resource),
            # not Set-AzVMExtension.
            # Remove-AzVM deletes ONLY the VM shell - the SqlVirtualMachines ARM resource
            # is a SEPARATE resource type that survives and auto-relinks once the VM is
            # recreated with the same name and resource group. In the rare case it was
            # deleted externally, we re-create it with PAYG as a safe default.
            # Azure auto-registers SQL 2016+ via CEIP anyway, but doing it here immediately
            # ensures billing accuracy (PAYG vs AHUB vs DR).
            if ($_ext.ExtensionType -eq 'SqlIaasAgent') {
                WriteLog "  '$($_ext.Name)' (SQL IaaS Agent): checking SQL VM resource..."
                try {
                    $null = Get-Command New-AzSqlVM -ErrorAction Stop
                } catch {
                    WriteLog "  '$($_ext.Name)' (SQL IaaS Agent): Az.SqlVirtualMachine module not available  -  falling back to MANUAL." "WARNING"
                    WriteLog "    Install with: Install-Module Az.SqlVirtualMachine" "WARNING"
                    $_manualList += $_ext
                    continue
                }
                try {
                    # The Microsoft.SqlVirtualMachine/SqlVirtualMachines resource is a separate ARM
                    # resource from the VM shell. Remove-AzVM does NOT delete it, so it persists
                    # through PATH B and is automatically re-linked once the VM is recreated with
                    # the same name and resource ID. If it exists, nothing to do.
                    $_sqlVm = Get-AzSqlVM -Name $VMName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
                    if ($_sqlVm) {
                        WriteLog "  '$($_ext.Name)' (SQL IaaS Agent): SQL VM resource survived recreation and is already re-linked (license: $($_sqlVm.LicenseType))." "INFO"
                        $_reinstalled += $_ext
                    } else {
                        # Resource was deleted (e.g. if the VM previously had DeleteOption=Delete on
                        # the SQL VM resource, or was removed manually). Re-register with PAYG default.
                        WriteLog "  '$($_ext.Name)' (SQL IaaS Agent): SQL VM resource not found  -  registering via New-AzSqlVM (license: PAYG)." "WARNING"
                        WriteLog "    If the original license was AHUB or DR, update it via: Update-AzSqlVM -LicenseType <type>" "WARNING"
                        New-AzSqlVM -Name $VMName -ResourceGroupName $ResourceGroupName -Location $_location -LicenseType 'PAYG' -ErrorAction Stop | Out-Null
                        WriteLog "  '$($_ext.Name)' (SQL IaaS Agent): SQL VM resource created (license: PAYG)." "INFO"
                        WriteLog "    Azure will auto-install the extension binaries on the VM within minutes." "INFO"
                        $_reinstalled += $_ext
                    }
                } catch {
                    WriteLog "  '$($_ext.Name)' (SQL IaaS Agent): failed: $_  -  register manually." "WARNING"
                    $_failedList += $_ext
                }
                continue   # skip the generic Set-AzVMExtension install below
            }

            # MicrosoftMonitoringAgent / OmsAgentForLinux (Legacy MMA/OMS)  ───────────────────
            # WorkspaceId is in public settings; workspaceKey is a protected setting.
            # We retrieve the key directly from the Log Analytics workspace using the Az API,
            # provided we can locate the workspace by its CustomerId (= workspaceId GUID).
            if ($_ext.ExtensionType -in @('MicrosoftMonitoringAgent','OmsAgentForLinux')) {
                $_wsId = if ($_ext.Settings) { $_ext.Settings['workspaceId'] } else { $null }
                if (-not $_wsId) {
                    WriteLog "  '$($_ext.Name)' (MMA/OMS): no workspaceId in public settings  -  falling back to MANUAL." "WARNING"
                    $_manualList += $_ext
                    continue
                }
                WriteLog "  '$($_ext.Name)' (MMA/OMS): looking up workspace key for workspace '$_wsId'..."
                try {
                    $null = Get-Command Get-AzOperationalInsightsWorkspace -ErrorAction Stop
                } catch {
                    WriteLog "  '$($_ext.Name)' (MMA/OMS): Az.OperationalInsights module not available  -  falling back to MANUAL." "WARNING"
                    WriteLog "    Install with: Install-Module Az.OperationalInsights" "WARNING"
                    $_manualList += $_ext
                    continue
                }
                try {
                    $_ws = Get-AzOperationalInsightsWorkspace -ErrorAction Stop |
                           Where-Object { $_.CustomerId.ToString() -eq $_wsId } | Select-Object -First 1
                    if (-not $_ws) {
                        WriteLog "  '$($_ext.Name)' (MMA/OMS): workspace '$_wsId' not found in this subscription  -  falling back to MANUAL." "WARNING"
                        $_manualList += $_ext
                        continue
                    }
                    $_wsKey = (Get-AzOperationalInsightsWorkspaceSharedKey -ResourceGroupName $_ws.ResourceGroupName -Name $_ws.Name -ErrorAction Stop).PrimarySharedKey
                    $_extParams['ProtectedSettings'] = @{ workspaceKey = $_wsKey }
                    WriteLog "  '$($_ext.Name)' (MMA/OMS): workspace key retrieved from '$($_ws.Name)' (RG: $($_ws.ResourceGroupName))." "INFO"
                } catch {
                    WriteLog "  '$($_ext.Name)' (MMA/OMS): failed to retrieve workspace key: $_  -  falling back to MANUAL." "WARNING"
                    $_manualList += $_ext
                    continue
                }
            }

            # AzureMonitorWindowsAgent / AzureMonitorLinuxAgent (new AMA)  ─────────────────────
            # Uses managed identity; no protected settings needed.
            # Data Collection Rule (DCR) associations are separate ARM resources referencing the
            # VM resource ID. Since the VM resource ID is the same after recreation (same name,
            # same RG), DCR associations survive and data collection resumes automatically.
            if ($_ext.ExtensionType -in @('AzureMonitorWindowsAgent','AzureMonitorLinuxAgent')) {
                WriteLog "  '$($_ext.Name)' (AMA): uses managed identity. DCR associations are preserved (reference VM resource ID)." "INFO"
            }

            # AADSSHLoginForLinux / AADLoginForWindows  ─────────────────────────────────────────
            # No protected settings. RBAC roles (e.g. Virtual Machine Administrator Login)
            # are assigned on the VM resource ID, which is identical after recreation with the
            # same VM name and resource group. No RBAC update needed - login works immediately.
            if ($_ext.ExtensionType -in @('AADSSHLoginForLinux','AADLoginForWindows')) {
                WriteLog "  '$($_ext.Name)' (AAD login): no protected settings. AAD login RBAC (VM resource ID) is preserved." "INFO"
            }

            # ── Install ──────────────────────────────────────────────────────────────────────
            WriteLog "  Installing '$($_ext.Name)' ($($_ext.Publisher)/$($_ext.ExtensionType) v$($_ver))..."
            try {
                Set-AzVMExtension @_extParams | Out-Null
                WriteLog "  OK: '$($_ext.Name)' reinstalled." "INFO"
                $_reinstalled += $_ext
            } catch {
                WriteLog "  FAILED: '$($_ext.Name)': $_  -  reinstall manually." "WARNING"
                $_failedList += $_ext
            }
        }

        # ── Summary ──────────────────────────────────────────────────────────────────────────
        if ($_reinstalled.Count -gt 0) { WriteLog "  Auto-reinstalled : $($_reinstalled.Count) extension(s)" "INFO" }
        if ($_manualList.Count -gt 0) {
            WriteLog "  Manual required  : $($_manualList.Count) extension(s)  -  reinstall via Portal or deployment pipeline:" "WARNING"
            $_manualList | ForEach-Object { WriteLog "    - $($_.Name) ($($_.ExtensionType))" "WARNING" }
        }
        if ($_failedList.Count -gt 0) {
            WriteLog "  Failed           : $($_failedList.Count) extension(s)  -  reinstall manually:" "WARNING"
            $_failedList | ForEach-Object { WriteLog "    - $($_.Name) ($($_.ExtensionType))" "WARNING" }
        }

        # Azure-managed extensions note: these re-deploy via their own service plane.
        # No manual action needed; they will re-appear automatically after recreation.
        $_hasAzureManaged = @($_extensionList | Where-Object { $_.ExtensionType -in $_azureManagedExtTypes })
        if ($_hasAzureManaged.Count -gt 0) {
            $_hasBackup = @($_hasAzureManaged | Where-Object { $_.ExtensionType -in @('VMSnapshot','VMSnapshotLinux') })
            if ($_hasBackup.Count -gt 0) {
                WriteLog "  Azure Backup (VMSnapshot): backup protection preserved - same resource ID after recreation." "INFO"
            }
            $_otherManaged = @($_hasAzureManaged | Where-Object { $_.ExtensionType -notin @('VMSnapshot','VMSnapshotLinux') })
            if ($_otherManaged.Count -gt 0) {
                WriteLog "  Azure-managed extensions ($($_otherManaged.Count)): will re-appear automatically via their service plane:" "INFO"
                $_otherManaged | ForEach-Object { WriteLog "    - $($_.Name) ($($_.ExtensionType))" "INFO" }
            }
        }

        # Extension post-validation: verify provisioning state of all auto-reinstalled extensions.
        # Set-AzVMExtension is asynchronous under the hood: it submits the request and waits for
        # the agent to acknowledge, but the final provisioning state is written by the VM guest agent
        # after Set-AzVMExtension returns. A brief pause then a fresh Get-AzVMExtension call gives
        # a more accurate picture than the install-time status alone.
        # Non-fatal: failures are logged as ACTION REQUIRED but do not abort the script.
        if ($_reinstalled.Count -gt 0) {
            WriteLog "  Verifying extension provisioning states (post-install check)..."
            Start-Sleep -Seconds 15   # allow guest agent time to report final state
            try {
                $_postExtensions = @(Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $VMName -ErrorAction Stop)
                $_extNotSucceeded = @($_postExtensions | Where-Object {
                    $_.ProvisioningState -ne 'Succeeded' -and
                    # Skip extensions that are auto-managed by Azure service planes and may
                    # still be provisioning or not yet re-deployed at this point
                    $_.ExtensionType -notin $_azureManagedExtTypes -and
                    # Skip extensions the operator explicitly excluded from reinstall (-SkipExtensions).
                    # These were not installed by STEP 8B; they may be pushed by an external system
                    # (e.g. Azure Policy) and could show as Updating or Creating at this point.
                    -not ($SkipExtensions -and $_.Name -in $SkipExtensions) -and
                    # MMA/OMS workspace-key extensions can take longer than the 15s wait to fully
                    # provision; exclude both to avoid a spurious ACTION REQUIRED on Linux/Windows.
                    $_.ExtensionType -notin @('MicrosoftMonitoringAgent','OmsAgentForLinux') -and
                    # KeyVault extensions authenticate via managed identity. When a system-assigned MI
                    # is present, RBAC is only restored in STEP 9B (which runs AFTER this post-check).
                    # Excluding them here prevents a false "ACTION REQUIRED" before RBAC is in place.
                    # Their status should be verified manually after STEP 9B completes.
                    $_.ExtensionType -notin @('KeyVaultForWindows','KeyVaultForLinux')
                })
                if ($_extNotSucceeded.Count -eq 0) {
                    WriteLog "  Extension post-validation: all $($_postExtensions.Count) extension(s) provisioning state = Succeeded." "INFO"
                } else {
                    WriteLog "  Extension post-validation: $($_extNotSucceeded.Count) extension(s) NOT in Succeeded state:" "WARNING"
                    foreach ($_ev in $_extNotSucceeded) {
                        WriteLog "    ACTION REQUIRED: '$($_ev.Name)' ($($_ev.ExtensionType)) -> ProvisioningState = '$($_ev.ProvisioningState)'" "WARNING"
                    }
                    WriteLog "  Check the VM extension blade in the Azure Portal for details." "WARNING"
                }
            } catch {
                WriteLog "  Extension post-validation: could not retrieve extension status: $_  -  verify manually." "WARNING"
            }
        }

    } elseif ($SkipExtensionReinstall -and $_extensionList.Count -gt 0) {
        WriteLog "STEP 8B: Extension reinstall skipped (-SkipExtensionReinstall). Reinstall $($_extensionList.Count) extension(s) manually." "WARNING"
    } else {
        WriteLog "STEP 8B: No extensions to reinstall."
    }

    # STEP 9B  -  Restore system-assigned managed identity RBAC assignments
    # Only runs when -RestoreSystemAssignedRBAC was specified AND the export file is present.
    # Without the flag: assignments were logged at pre-flight; operator confirmed to proceed
    # without auto-restore. Just log the reminder here.
    if ($_oldSystemMIPrincipalId -and $RestoreSystemAssignedRBAC `
        -and $_rbacExportPath -and (Test-Path $_rbacExportPath)) {
        WriteLog "--- STEP 9B: Restoring system-assigned managed identity RBAC assignments ---" "IMPORTANT"
        try {
            # Read the new PrincipalId from the recreated VM.
            # ARM needs a moment to propagate the new identity; retry once if null.
            $_newVMForRbac   = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction Stop
            $_newPrincipalId = if ($_newVMForRbac.Identity) { $_newVMForRbac.Identity.PrincipalId } else { $null }
            if (-not $_newPrincipalId) {
                WriteLog "  New system-assigned PrincipalId not yet available  -  waiting 20s for ARM propagation..." "WARNING"
                Start-Sleep -Seconds 20
                $_newVMForRbac   = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction SilentlyContinue
                $_newPrincipalId = if ($_newVMForRbac.Identity) { $_newVMForRbac.Identity.PrincipalId } else { $null }
            }
            if (-not $_newPrincipalId) {
                WriteLog "  Could not read new system-assigned PrincipalId  -  RBAC restore skipped." "WARNING"
                WriteLog "    Restore manually once the VM is running:" "WARNING"
                WriteLog "      New principal: (Get-AzVM -RG '$ResourceGroupName' -Name '$VMName').Identity.PrincipalId" "WARNING"
                WriteLog "      Export file  : '$_rbacExportPath'" "WARNING"
            } else {
                WriteLog "  Old PrincipalId : $_oldSystemMIPrincipalId"
                WriteLog "  New PrincipalId : $_newPrincipalId"
                $_rbacResult = Restore-SystemAssignedRBACAssignments `
                    -NewPrincipalId $_newPrincipalId `
                    -InputPath      $_rbacExportPath `
                    -ResultsPath    $_rbacResultsPath
                $_nRestored  = @($_rbacResult.Restored).Count
                $_nExisted   = @($_rbacResult.AlreadyExisted).Count
                $_nFailed    = @($_rbacResult.Failed).Count
                $_severity   = if ($_nFailed -gt 0) { "WARNING" } else { "IMPORTANT" }
                WriteLog "  Result: $_nRestored restored, $_nExisted already existed, $_nFailed failed." $_severity
                if ($_nFailed -gt 0) {
                    WriteLog "  ACTION REQUIRED: $_nFailed assignment(s) could not be restored  -  check '$_rbacResultsPath'." "WARNING"
                }
            }
        } catch {
            WriteLog "  RBAC restore step encountered an error: $_" "WARNING"
            WriteLog "    Restore manually from '$_rbacExportPath' using Restore-SystemAssignedRBACAssignments." "WARNING"
        }
    } elseif ($_oldSystemMIPrincipalId -and $RestoreSystemAssignedRBAC -and $_rbacExportFailed) {
        WriteLog "STEP 9B: RBAC export failed in STEP 5B  -  restore skipped." "WARNING"
        WriteLog "  Re-assign manually after the VM is running." "WARNING"
        WriteLog "  Old PrincipalId : $_oldSystemMIPrincipalId" "WARNING"
        WriteLog "  New PrincipalId : run: (Get-AzVM -ResourceGroupName '$ResourceGroupName' -Name '$VMName').Identity.PrincipalId" "WARNING"
    } elseif ($_oldSystemMIPrincipalId -and -not $RestoreSystemAssignedRBAC) {
        WriteLog "STEP 9B: RBAC auto-restore not requested (-RestoreSystemAssignedRBAC not specified)." "WARNING"
        if ($_preflightRbacAssignments.Count -gt 0) {
            WriteLog "  $($_preflightRbacAssignments.Count) assignment(s) were detected at pre-flight and must be re-assigned manually." "WARNING"
            WriteLog "  Old PrincipalId : $_oldSystemMIPrincipalId" "WARNING"
            WriteLog "  New PrincipalId : run: (Get-AzVM -ResourceGroupName '$ResourceGroupName' -Name '$VMName').Identity.PrincipalId" "WARNING"
        } else {
            WriteLog "  No direct assignments found at pre-flight  -  nothing to re-assign." "INFO"
        }
    } elseif (-not $_oldSystemMIPrincipalId) {
        WriteLog "STEP 9B: No system-assigned managed identity on this VM  -  RBAC restore not applicable."
    }

    # STEP 10B  -  Cleanup snapshot (unless -KeepSnapshot)
    if (-not $KeepSnapshot) {
        WriteLog "--- STEP 10B: Removing snapshot (use -KeepSnapshot to retain) ---" "IMPORTANT"

        try {
            Invoke-AzWithRetry -Description 'Remove-AzSnapshot' -ScriptBlock { Remove-AzSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $snapshotName -Force | Out-Null }
            WriteLog "Snapshot '$snapshotName' removed."
        } catch {
            WriteLog "Non-fatal: could not remove snapshot '$snapshotName': $_" "WARNING"
            WriteLog "Remove manually when no longer needed." "WARNING"
        }
    } else {
        WriteLog "Snapshot retained: $snapshotName (ResourceGroup: $ResourceGroupName)" "IMPORTANT"
        WriteLog "Use as rollback point  -  delete manually when no longer needed." "WARNING"
    }

    WriteLog "The original OS disk '$($osDisk.Name)' has been reattached to the new VM." "INFO"
}

##############################################################################################################
# COMPLETION
##############################################################################################################

} catch {
    # Two expected termination paths share this single catch:
    #   1. AzVMFatalError  - thrown by Stop-Script or AskToContinue abort.
    #      Message was already written to the log; just exit.
    #   2. Any other unhandled exception  - log it, then exit.
    # NOTE: catch [AzVMFatalError] does NOT work in PS5.1 for script-defined
    # classes (typed catch filters are only resolved for .NET / Add-Type types).
    # We therefore use a single catch {} with an in-body type check.
    if ($_.Exception -isnot [AzVMFatalError]) {
        WriteLog "Unhandled error: $_" "ERROR"
    }
    exit 1
} finally {
    # Always restore breaking change warnings regardless of how the script exits
    if ($_bcwWasEnabled) { Update-AzConfig -DisplayBreakingChangeWarning $true | Out-Null }
    # If the script exited after STEP 2a (TrustedLaunch downgrade) but before the re-enable
    # completed (PATH A: STEP 4Aa; PATH B: STEP 7B), emit the restore instructions via
    # WriteLog so they are captured in the log file.
    # Write-TrustedLaunchRestoreNote is a no-op when _needTrustedLaunchRestore is $false.
    Write-TrustedLaunchRestoreNote
}

WriteLog "=======================================================" "IMPORTANT"
if ($script:_needTrustedLaunchRestore) {
    WriteLog " Conversion complete  (with warnings - TrustedLaunch NOT restored)" "IMPORTANT"
    WriteLog " See ACTION REQUIRED above to re-enable TrustedLaunch manually." "IMPORTANT"
} else {
    WriteLog " Conversion complete" "IMPORTANT"
}
WriteLog "=======================================================" "IMPORTANT"
$_elapsed = (Get-Date) - $script:_starttime
WriteLog "Duration            : $([int]$_elapsed.TotalMinutes) min $($_elapsed.Seconds) sec"
WriteLog "Original size       : $script:_originalSize"
WriteLog "New size            : $VMSize"
WriteLog "Original controller : $script:_originalController"
WriteLog "New controller      : $NewControllerType"
WriteLog "Source disk arch    : $_sourceDiskArch"
WriteLog "Target disk arch    : $_targetDiskArch"
WriteLog "Execution path      : $(if ($_useRecreationPath) { 'PATH B (Recreation)' } else { 'PATH A (Resize)' })"
if ($_secTypeForCheck) {
    if ($_isTrustedLaunchDowngrade) {
        if ($script:_needTrustedLaunchRestore) {
            # STEP 4Aa failed: TrustedLaunch was downgraded but NOT re-enabled.
            # _needTrustedLaunchRestore is still $true; finally block already emitted ACTION REQUIRED.
            WriteLog "Security type       : Standard  *** TrustedLaunch NOT re-enabled - see ACTION REQUIRED above ***" "ERROR"
        } else {
            WriteLog "Security type       : TrustedLaunch (temporarily downgraded for conversion, then re-enabled)" "IMPORTANT"
        }
    } else {
        WriteLog "Security type       : $_secTypeForCheck"
    }
} else {
    WriteLog "Security type       : Standard"
}
if ($WriteLogfile) { WriteLog "Log file            : $script:_logfile" }
WriteLog ""
if ($_useRecreationPath) {
    WriteLog "ROLLBACK options:" "IMPORTANT"
    WriteLog "  Option 1  -  Re-run this script to go back to original size/controller:" "IMPORTANT"
    WriteLog "    .\AzureVM-NVME-and-localdisk-Conversion.ps1 -ResourceGroupName '$ResourceGroupName' -VMName '$VMName' ``" "IMPORTANT"
    WriteLog "    -NewControllerType $script:_originalController -VMSize '$script:_originalSize' -StartVM" "IMPORTANT"
    if ($_isTrustedLaunchDowngrade) {
        WriteLog "    Note: -AllowTrustedLaunchDowngrade is NOT needed for rollback  -  the TrustedLaunch restriction only applies to SCSI->NVMe conversion." "IMPORTANT"
    }
    $_snapNote = if ($KeepSnapshot) { "(retained: '$snapshotName')" } else { '(only available if -KeepSnapshot was specified)' }
    WriteLog "  Option 2  -  Restore from snapshot ${_snapNote}:" "IMPORTANT"
    if ($KeepSnapshot) {
        WriteLog "    Create a new managed disk from snapshot '$snapshotName', then recreate the VM." "IMPORTANT"
    } else {
        WriteLog "    Snapshot was deleted after successful recreation (use -KeepSnapshot to retain it next time)." "IMPORTANT"
    }
    if ($_extensionList.Count -gt 0) { WriteLog "  Extensions: $($_extensionList.Count) found. Check STEP 8B log above for reinstall status." "IMPORTANT" }
    if ($_oldSystemMIPrincipalId) {
        if ($RestoreSystemAssignedRBAC -and $_rbacResultsPath -and (Test-Path $_rbacResultsPath)) {
            try {
                $_rbacSummary = Get-Content -Path $_rbacResultsPath -Raw -ErrorAction Stop | ConvertFrom-Json
                $_nFailed = @($_rbacSummary.Failed).Count
            } catch { $_nFailed = -1 }
            if ($_nFailed -gt 0) {
                WriteLog "  MI RBAC           : restore PARTIAL  -  $_nFailed failure(s)  -  review '$_rbacResultsPath'" "WARNING"
            } elseif ($_nFailed -eq 0) {
                WriteLog "  MI RBAC           : restored successfully  -  see '$_rbacResultsPath'" "IMPORTANT"
            } else {
                WriteLog "  MI RBAC           : results file unreadable  -  check '$_rbacResultsPath' manually" "WARNING"
            }
        } elseif ($RestoreSystemAssignedRBAC -and $_rbacExportedAssignments.Count -eq 0) {
            WriteLog "  MI RBAC           : no direct assignments found  -  nothing to restore" "INFO"
        } elseif ($RestoreSystemAssignedRBAC -and $_rbacExportFailed) {
            WriteLog "  MI RBAC           : export FAILED  -  re-assign manually (old principal: $_oldSystemMIPrincipalId)" "WARNING"
        } elseif ($RestoreSystemAssignedRBAC) {
            # Fallback: RestoreRBAC was requested, export did not fail, but restore results file is absent.
            # Most likely cause: STEP 9B could not read the new principal ID (VM identity not yet visible)
            # and skipped the restore step. Check the STEP 9B log output above for details.
            WriteLog "  MI RBAC           : restore results unavailable  -  verify STEP 9B log output above and re-assign manually if needed" "WARNING"
            WriteLog "    Old principal: $_oldSystemMIPrincipalId" "WARNING"
            WriteLog "    New principal: run: (Get-AzVM -ResourceGroupName '$ResourceGroupName' -Name '$VMName').Identity.PrincipalId" "WARNING"
        } elseif (-not $RestoreSystemAssignedRBAC -and $_preflightRbacAssignments.Count -gt 0) {
            WriteLog "  MI RBAC           : NOT auto-restored  -  $($_preflightRbacAssignments.Count) assignment(s) must be re-assigned manually" "WARNING"
            WriteLog "    Old principal: $_oldSystemMIPrincipalId" "WARNING"
            WriteLog "    New principal: run: (Get-AzVM -ResourceGroupName '$ResourceGroupName' -Name '$VMName').Identity.PrincipalId" "WARNING"
        } elseif (-not $RestoreSystemAssignedRBAC) {
            WriteLog "  MI RBAC           : no direct assignments found at pre-flight  -  nothing to re-assign" "INFO"
        }
    }
} else {
    WriteLog "ROLLBACK command:" "IMPORTANT"
    if ($_isTrustedLaunchDowngrade) {
        WriteLog "  Note: rollback targets $script:_originalController — the TrustedLaunch restriction only applies to SCSI->NVMe. -AllowTrustedLaunchDowngrade is not needed for rollback." "IMPORTANT"
    }
    WriteLog "  .\AzureVM-NVME-and-localdisk-Conversion.ps1 ``" "IMPORTANT"
    WriteLog "    -ResourceGroupName '$ResourceGroupName' ``" "IMPORTANT"
    WriteLog "    -VMName '$VMName' ``" "IMPORTANT"
    WriteLog "    -NewControllerType $script:_originalController ``" "IMPORTANT"
    WriteLog "    -VMSize '$script:_originalSize' ``" "IMPORTANT"
    WriteLog "    -StartVM" "IMPORTANT"
}

# Reminder about NVMe temp disk initialization for dependent startup tasks.
# Shown whenever the conversion target is nvme-temp AND the source was not already
# nvme-temp (i.e. the task was freshly installed this run, on either PATH A or PATH B).
# Suppressed when -NVMEDiskInitScriptSkip was specified.
if ($_needNvmeTempDiskTask) {
    WriteLog "" 
    WriteLog "=======================================================" "IMPORTANT"
    WriteLog " IMPORTANT: NVMe temp disk (D:\) initialization" "IMPORTANT"
    WriteLog "=======================================================" "IMPORTANT"
    WriteLog "The new VM size uses an NVMe-based temp disk (D:\) that is presented" "IMPORTANT"
    WriteLog "RAW and unformatted on every boot. The scheduled task 'AzureNVMeTempDiskInit'" "IMPORTANT"
    WriteLog "has been installed to initialize and format it automatically at startup." "IMPORTANT"
    WriteLog "" 
    WriteLog "If any OTHER startup tasks depend on D:\ (e.g. SQL Server tempdb):" "IMPORTANT"
    WriteLog "  Add the Wait-ForDrive snippet at the TOP of those tasks so they wait" "IMPORTANT"
    WriteLog "  until D:\ is ready before proceeding. Without this, they may fail" "IMPORTANT"
    WriteLog "  on the first boot after each host reallocation." "IMPORTANT"
    WriteLog "" 
    WriteLog "  Snippet location on the VM:" "IMPORTANT"
    WriteLog "    $NVMEDiskInitScriptLocation\Wait-ForDrive-D.ps1.snippet.txt" "IMPORTANT"
    WriteLog "" 
    WriteLog "  Snippet content (also saved to the file above):" "IMPORTANT"
    @(
        '    $maxWait = 120   # seconds to wait for D:\ before giving up',
        '    $elapsed = 0',
        '    while (-not (Test-Path "D:\") -and $elapsed -lt $maxWait)',
        '        { Start-Sleep -Seconds 5; $elapsed += 5 }',
        '    if (-not (Test-Path "D:\"))',
        '        { Write-Error "D:\ not ready"; exit 1 }'
    ) | ForEach-Object { WriteLog "    $_" "IMPORTANT" }
    WriteLog "=======================================================" "IMPORTANT"
}

# Linux NVMe conversion advisory: udev rules and disk symlink change
# After SCSI->NVMe conversion, the waagent SCSI udev rules that created /dev/disk/azure/scsi1/lunX
# symlinks are inactive. The azure-vm-utils package provides the NVMe replacement udev rules
# that create /dev/disk/azure/data/by-lun/X symlinks.
# Shown whenever this run converted FROM SCSI (i.e. not a pure resize of an already-NVMe VM).
if ($_os -eq "Linux" -and $NewControllerType -eq "NVMe" -and $script:_originalController -ne "NVMe") {
    WriteLog ""
    WriteLog "=======================================================" "IMPORTANT"
    WriteLog " IMPORTANT: Linux NVMe - disk symlinks and udev rules" "IMPORTANT"
    WriteLog "=======================================================" "IMPORTANT"
    WriteLog "After SCSI -> NVMe conversion, the waagent SCSI udev rules that created" "IMPORTANT"
    WriteLog "/dev/disk/azure/scsi1/lunX symlinks are NO LONGER ACTIVE on this VM." "IMPORTANT"
    WriteLog "This is true regardless of whether azure-vm-utils is installed: the SCSI udev" "IMPORTANT"
    WriteLog "rules simply do not fire for NVMe disks. Any scripts, fstab entries, or tools" "IMPORTANT"
    WriteLog "referencing /dev/disk/azure/scsi1/ paths will fail on first boot." "IMPORTANT"
    WriteLog ""
    WriteLog "  1. Verify azure-vm-utils is installed (check STEP 1 output above)." "IMPORTANT"
    WriteLog "     It provides /dev/disk/azure/data/by-lun/X as the NVMe replacement" "IMPORTANT"
    WriteLog "     for /dev/disk/azure/scsi1/lunX." "IMPORTANT"
    WriteLog "     Pre-installed on marketplace images: Ubuntu 22.04/24.04/25.04, Azure Linux 2.0," "IMPORTANT"
    WriteLog "       Fedora 42, and Kinvolk/Flatcar 4152.2.3+." "IMPORTANT"
    WriteLog "     Must be installed on: RHEL/Rocky, SLES, Debian, older Ubuntu." "IMPORTANT"
    WriteLog "       Ubuntu/Debian : sudo apt-get install azure-vm-utils" "IMPORTANT"
    WriteLog "       RHEL/Rocky    : sudo dnf install azure-vm-utils" "IMPORTANT"
    WriteLog "       SLES/OpenSUSE : sudo zypper install azure-vm-utils" "IMPORTANT"
    WriteLog "     (If -FixOperatingSystemSettings was specified, STEP 1 already attempted this.)" "IMPORTANT"
    WriteLog ""
    WriteLog "  2. Update any references to /dev/disk/azure/scsi1/ paths in:" "IMPORTANT"
    WriteLog "       /etc/fstab (prefer UUID= or /dev/disk/azure/data/by-lun/X)" "IMPORTANT"
    WriteLog "       systemd .mount units" "IMPORTANT"
    WriteLog "       Application configs and startup scripts" "IMPORTANT"
    WriteLog ""
    # v7+ NVMe multi-controller advisory.
    # On v7+ VM sizes, Azure automatically distributes disks across two NVMe controllers:
    # cached disks (OS + data with caching enabled) go to the cached controller (nvme0),
    # uncached data disks go to the uncached controller (nvme1).
    # Assignment is based on per-disk caching policy: if caching is changed, the disk
    # silently moves to a different controller on the next boot. Raw /dev/nvme0nX or
    # /dev/nvme1nX paths in fstab or scripts will point to the wrong disk without warning.
    # UUID= and /dev/disk/azure/data/by-lun/X paths are stable regardless of controller.
    $_targetVersion = if ($VMSize -match '_v(\d+)') { [int]$Matches[1] } else { 0 }
    if ($_targetVersion -ge 7) {
        WriteLog "  Note: $VMSize is a v$_targetVersion VM (multi-controller NVMe)." "IMPORTANT"
        WriteLog "    On v7+ sizes, Azure distributes disks across two NVMe controllers:" "IMPORTANT"
        WriteLog "      Cached controller  (nvme0): OS disk + data disks with caching enabled." "IMPORTANT"
        WriteLog "      Uncached controller (nvme1): data disks with caching disabled." "IMPORTANT"
        WriteLog "    Assignment is automatic based on per-disk caching policy. If caching is" "IMPORTANT"
        WriteLog "    changed on a disk, it silently moves to the other controller on next boot." "IMPORTANT"
        WriteLog "    Raw /dev/nvme0nX or /dev/nvme1nX paths in fstab or scripts will silently" "IMPORTANT"
        WriteLog "    point to the wrong disk after any caching policy change." "IMPORTANT"
        WriteLog "    Use UUID= in fstab or /dev/disk/azure/data/by-lun/X paths exclusively." "IMPORTANT"
        WriteLog "" 
        WriteLog "    Important: if you need to change a disk caching policy after NVMe conversion," "IMPORTANT"
        WriteLog "    always stop the VM first, apply the change, then start it again. Changing caching" "IMPORTANT"
        WriteLog "    while the VM is running on NVMe can cause the disk to silently reassign to a" "IMPORTANT"
        WriteLog "    different controller, resulting in path changes or remapping issues." "IMPORTANT"
        WriteLog ""
    }
    WriteLog "=======================================================" "IMPORTANT"
}
