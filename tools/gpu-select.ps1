<#
.SYNOPSIS
  Force Civ VI (and the whole desktop) onto the discrete NVIDIA GPU on this
  headless box by disabling the Intel iGPU — or restore it.

.DESCRIPTION
  On this machine Civ VI's DoGraphicsDeviceSelection stubbornly picks the Intel
  iGPU even when the NVIDIA RTX drives the only (dummy-plug) display. That leaves
  the render adapter (Intel) and the display (NVIDIA) on different cards, and the
  game dies with DXGI_ERROR_NOT_FOUND ("Unable to get the primary display's DXGI
  output"). Civ ignores the Windows per-app GPU preference and has no adapter knob
  in GraphicsOptions.txt, so the reliable cure is to remove the iGPU from the
  running set: with only the NVIDIA present, Civ must select it, and it already
  owns the display -> render + display on one card -> it works.

  Safe: the Intel iGPU is already driving nothing here (the display is on the
  NVIDIA dummy plug), so disabling it does not black out the screen. Reversible:
  run with 'intel' to turn it back on. Adapters are matched by PCI vendor ID
  (Intel = VEN_8086, NVIDIA = VEN_10DE), not a hard-coded instance path.

.PARAMETER Mode
  nvidia  Disable the Intel iGPU  -> Civ is forced onto the NVIDIA RTX.
  intel   Re-enable the Intel iGPU -> restore the default (both GPUs present).
  status  Show current adapter states and change nothing (no admin needed).

.EXAMPLE
  .\gpu-select.ps1 nvidia
  .\gpu-select.ps1 status
  .\gpu-select.ps1 intel
#>
[CmdletBinding()]
param(
    [ValidateSet('nvidia', 'intel', 'status')]
    [string]$Mode = 'status'
)

$ErrorActionPreference = 'Stop'

function Get-Adapters {
    $all = Get-PnpDevice -Class Display -PresentOnly -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Intel  = $all | Where-Object { $_.InstanceId -like 'PCI\VEN_8086*' }
        Nvidia = $all | Where-Object { $_.InstanceId -like 'PCI\VEN_10DE*' }
    }
}

function Show-Status {
    $a = Get-Adapters
    Write-Host ''
    Write-Host 'Display adapters:' -ForegroundColor Cyan
    foreach ($d in @($a.Nvidia) + @($a.Intel)) {
        if ($null -ne $d) {
            Write-Host ("  {0,-8} {1}" -f $d.Status, $d.FriendlyName)
        }
    }
    if (-not $a.Intel)  { Write-Host '  (no Intel iGPU present)' }
    if (-not $a.Nvidia) { Write-Host '  (no NVIDIA GPU present!)' -ForegroundColor Red }
    Write-Host ''
}

# --- Self-elevation: state changes need admin; status is read-only ---
$isAdmin = (New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($Mode -ne 'status' -and -not $isAdmin) {
    Write-Host 'Elevation required — relaunching as administrator (approve the UAC prompt)...' -ForegroundColor Yellow
    $hostExe = (Get-Process -Id $PID).Path
    Start-Process -FilePath $hostExe -Verb RunAs -ArgumentList @(
        '-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"", $Mode
    )
    return
}

$adapters = Get-Adapters
if (-not $adapters.Nvidia) {
    Write-Host 'No NVIDIA GPU detected — refusing to touch the Intel adapter (you would lose all display).' -ForegroundColor Red
    Show-Status
    return
}

switch ($Mode) {
    'status' {
        Show-Status
    }
    'nvidia' {
        if (-not $adapters.Intel) {
            Write-Host 'Intel iGPU already absent/disabled — nothing to do. Civ should already use the NVIDIA.' -ForegroundColor Green
        }
        else {
            foreach ($d in $adapters.Intel) {
                Write-Host "Disabling: $($d.FriendlyName) ..." -ForegroundColor Yellow
                Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false
            }
            Write-Host 'Intel iGPU disabled. Civ VI is now forced onto the NVIDIA RTX.' -ForegroundColor Green
        }
        Show-Status
        Write-Host 'Next: relaunch the game (dotnet run) and check Renderer.log shows Selected GPU = NVIDIA.' -ForegroundColor Cyan
    }
    'intel' {
        if (-not $adapters.Intel) {
            # Disabled devices are not "present" via -PresentOnly filtering in
            # some states; re-query without the vendor filter to catch it.
            $intelAny = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
                Where-Object { $_.InstanceId -like 'PCI\VEN_8086*' }
            if (-not $intelAny) {
                Write-Host 'No Intel iGPU found to enable.' -ForegroundColor Yellow
                Show-Status; return
            }
            $adapters.Intel = $intelAny
        }
        foreach ($d in $adapters.Intel) {
            Write-Host "Enabling: $($d.FriendlyName) ..." -ForegroundColor Yellow
            Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false
        }
        Write-Host 'Intel iGPU re-enabled (default restored).' -ForegroundColor Green
        Show-Status
    }
}
