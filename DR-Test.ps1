# --- 1. Pre-fetch DERP Map ---
$DerpLookup = @{}
try {
    $derp = irm https://controlplane.tailscale.com/derpmap/default
    if ($derp -and $derp.Regions) { 
        $derp.Regions.PSObject.Properties | ForEach-Object { $DerpLookup[$_.Value.RegionCode] = $_.Value.RegionName } 
    }
} catch { }

# --- 2. Identify Online Peers ---
$onlinePeers = tailscale status | Where-Object { $_ -notmatch "offline" -and $_ -match "100\." } | ForEach-Object {
    $p = $_ -split '\s+'
    [pscustomobject]@{ Name = $p[1]; IP = $p[0] }
}

# --- 3. Setup Shared Memory (The Secret to Real-time) ---
$SyncHash = [hashtable]::Synchronized(@{})
foreach ($peer in $onlinePeers) {
    $SyncHash[$peer.IP] = @{ Latencies = @(); Done = $false; Last = 0; Tag = "Idle"; Path = "-"; Color = "Gray" }
}

# --- 4. Launch Background Threads ---
$RunspacePool = [runspacefactory]::CreateRunspacePool(1, 100)
$RunspacePool.Open()
$Jobs = foreach ($peer in $onlinePeers) {
    $PowerShell = [powershell]::Create().AddScript({
        param($IP, $Sync, $Map)
        for ($i=1; $i -le 10; $i++) {
            # Perform Ping
            $p = ping -n 1 -w 400 $IP
            $match = [regex]::Match($p, "time[=<](\d+)ms")
            
            # Update Shared Memory
            $data = $Sync[$IP]
            if ($match.Success) { 
                $val = [int]$match.Groups[1].Value
                $data.Latencies += $val
                $data.Last = $val
            } else { 
                $data.Last = -1 # Timeout
            }

            # Update Path Status every few pings
            $ts = tailscale status | Select-String $IP | Out-String
            if ($ts -match 'peer-relay\s+([0-9.]+:[0-9]+)') {
                $data.Tag = "Peer-Relay"; $data.Color = "Cyan"; $data.Path = $Matches[1]
            } elseif ($ts -match 'direct\s+([0-9.]+:\d+)') {
                $data.Tag = "Direct     "; $data.Color = "Green"; $data.Path = $Matches[1]
            } elseif ($ts -match 'relay\s+"([^"]+)"') {
                $data.Tag = "Relay      "; $data.Color = "Red"
                $code = $Matches[1]; $data.Path = if ($Map.ContainsKey($code)) { $Map[$code] } else { "DERP $code" }
            }

            $Sync[$IP] = $data
            Start-Sleep -Milliseconds 800 # Delay so you can see it count
        }
        $final = $Sync[$IP]; $final.Done = $true; $Sync[$IP] = $final
    }).AddArgument($peer.IP).AddArgument($SyncHash).AddArgument($DerpLookup)
    $PowerShell.RunspacePool = $RunspacePool
    @{ PS = $PowerShell; Handle = $PowerShell.BeginInvoke() }
}

# --- 5. Main UI Loop (Reads from Shared Memory) ---
Clear-Host
Write-Host "Tailscale Parallel Monitor (v4.4)" -ForegroundColor White
Write-Host "---------------------------------------------------------------" -ForegroundColor Gray
$HeaderPos = [Console]::CursorTop
Write-Host "Scanning...                   " -ForegroundColor Yellow

$allDone = $false
while (-not $allDone) {
    $allDone = $true
    foreach ($peer in $onlinePeers) {
        $data = $SyncHash[$peer.IP]
        if (-not $data.Done) { $allDone = $false }

        $count = $data.Latencies.Count
        $lastVal = if ($data.Last -eq -1) { "Timeout" } else { "$($data.Last) ms" }

        # Formatting logic
        $latDisplay = ""
        if ($data.Done) {
            $valid = $data.Latencies | Where-Object { $_ -ne -1 }
            if ($valid) { 
                $avg = ($valid | Measure-Object -Average).Average
                $latDisplay = "{0:N0} ms" -f $avg
            } else { $latDisplay = "Timeout" }
        } else {
            $latDisplay = "[$($count + 1)/10] $lastVal"
        }

        # Write to screen
        $idx = [array]::IndexOf($onlinePeers, $peer)
        [Console]::SetCursorPosition(0, $idx + 3)
        $line = "{0,-15} [{1,-12}] - {2} {{{3,11}}} [{4}]" -f $peer.Name, $peer.IP, $data.Tag, $latDisplay, $data.Path
        Write-Host ($line.PadRight([Console]::WindowWidth - 1)) -ForegroundColor $data.Color
    }
    Start-Sleep -Milliseconds 150
}

# --- 6. Cleanup ---
[Console]::SetCursorPosition(0, 2)
Write-Host "Done!                         " -ForegroundColor Green
[Console]::SetCursorPosition(0, $onlinePeers.Count + 3)
Write-Host "---------------------------------------------------------------" -ForegroundColor Gray
$RunspacePool.Close()
