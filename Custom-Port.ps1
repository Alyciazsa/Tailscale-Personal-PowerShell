function Ensure-Admin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-Process -Id $PID).Path
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        $psi.Verb = "runas"
        try { [Diagnostics.Process]::Start($psi) | Out-Null } catch { Write-Error "Elevation failed."; }
        exit
    }
}
Ensure-Admin

Import-Module ScheduledTasks -ErrorAction SilentlyContinue

$taskName = "TailscaleCustomPort"
$tailscaleServiceName = "Tailscale"
$tailscaledPath = "C:\Program Files\Tailscale\tailscaled.exe"

$portInput = Read-Host "Enter port (0-65535) or press Enter to restore default Tailscale service"

if ([string]::IsNullOrWhiteSpace($portInput)) {
    try {
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            try { Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue } catch {}
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "Removed scheduled task '$taskName'."
        }
    } catch {}
    & sc.exe config $tailscaleServiceName start= auto | Out-Null
    & sc.exe start  $tailscaleServiceName | Out-Null
    Write-Host "✅ Tailscale service is set to Automatic and started."
    return
}

if (-not ($portInput -as [int])) { Write-Error "Invalid input. Port must be 0..65535."; exit 1 }
$port = [int]$portInput
if ($port -lt 0 -or $port -gt 65535) { Write-Error "Invalid port: $port. Must be 0..65535."; exit 1 }

if (-not (Test-Path -LiteralPath $tailscaledPath)) { Write-Error "tailscaled.exe not found."; exit 1 }

$portArg = "--port=$port"
Write-Host "Configuring Tailscale to use custom port: $port"

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    try { Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue } catch {}
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed old scheduled task '$taskName'."
}

$action1 = New-ScheduledTaskAction -Execute "sc.exe" -Argument "stop $tailscaleServiceName"
$action2 = New-ScheduledTaskAction -Execute "sc.exe" -Argument "config $tailscaleServiceName start= disabled"
$action3 = New-ScheduledTaskAction -Execute $tailscaledPath -Argument $portArg

$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0)

$settings.DisallowStartIfOnBatteries = $false
$settings.StopIfGoingOnBatteries = $false

$task = New-ScheduledTask -Action $action1, $action2, $action3 -Trigger $trigger -Principal $principal -Settings $settings
if (-not $task) { Write-Error "Failed to build scheduled task object."; exit 1 }

Register-ScheduledTask -TaskName $taskName -InputObject $task | Out-Null
Write-Host "✅ Scheduled task '$taskName' created (runs at startup, system account, highest privileges)."

try { 
    Start-ScheduledTask -TaskName $taskName
    Write-Host "✅ Scheduled task '$taskName' started immediately. Tailscale is now running with custom port $port."
} catch {
    Write-Warning "⚠ Task was created but could not be started immediately: $($_.Exception.Message)"
}
