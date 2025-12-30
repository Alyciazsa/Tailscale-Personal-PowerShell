# --- 1. Pre-fetch DERP Map ---
$DerpLookup = @{}
try {
    $derp = irm https://controlplane.tailscale.com/derpmap/default
    if ($derp -and $derp.Regions) { 
        $derp.Regions.PSObject.Properties | ForEach-Object { $DerpLookup[$_.Value.RegionCode] = $_.Value.RegionName } 
    }
} catch { }

# --- 2. Identify Online Peers & Self ---
$selfIP = (tailscale ip -4).Trim()
$onlinePeers = tailscale status | Where-Object { $_ -notmatch "offline" -and $_ -match "100\." } | ForEach-Object {
    $p = $_ -split '\s+'
    [pscustomobject]@{ Name = $p[1]; IP = $p[0] }
}

# --- Helper Function to Center Text ---
function Get-CenteredText {
    param([string]$text, [int]$width)
    if ($text -eq $null) { $text = "-" }
    if ($text.Length -ge $width) { return $text.Substring(0, $width) }
    $pad = ($width - $text.Length) / 2
    return (" " * [math]::Floor($pad)) + $text + (" " * [math]::Ceiling($pad))
}

# --- 3. Setup Shared Memory ---
$SyncHash = [hashtable]::Synchronized(@{})
foreach ($peer in $onlinePeers) {
    # Pre-pad "Idle" with spaces to match "Direct     " and "Peer-Relay" width (11 chars)
    $SyncHash[$peer.IP] = @{ Latencies = @(); Done = $false; Last = 0; Tag = "Idle       "; Path = "-"; Color = "Gray" }
}

# --- 4. Launch Background Threads ---
$RunspacePool = [runspacefactory]::CreateRunspacePool(1, 100)
$RunspacePool.Open()
$Jobs = foreach ($peer in $onlinePeers) {
    $PowerShell = [powershell]::Create().AddScript({
        param($IP, $Sync, $Map, $Self)
        if ($IP -eq $Self) {
            $data = $Sync[$IP]
            $data.Tag = "Direct     "; $data.Color = "Green"; $data.Path = "Local Machine"
            $data.Last = 0; $data.Latencies = @(0,0,0,0,0,0,0,0,0,0); $data.Done = $true
            $Sync[$IP] = $data
            return
        }

        for ($i=1; $i -le 10; $i++) {
            $data = $Sync[$IP]
            try {
                # Force-run tailscale ping
                $p = tailscale ping --c 1 --timeout 1s $IP 2>&1 | Out-String
                $match = [regex]::Match($p, "in (\d+)ms")
                
                # Check Status
                $ts = tailscale status | Select-String $IP | Out-String
                if ($ts -match 'peer-relay\s+([0-9.]+:[0-9]+)') {
                    $data.Tag = "Peer-Relay "; $data.Color = "Cyan"; $data.Path = $Matches[1]
                } elseif ($ts -match 'direct\s+([0-9.]+:\d+)') {
                    $data.Tag = "Direct     "; $data.Color = "Green"; $data.Path = $Matches[1]
                } elseif ($ts -match 'relay\s+"([^"]+)"') {
                    $data.Tag = "Relay      "; $data.Color = "Red"
                    $code = $Matches[1]; $data.Path = if ($Map.ContainsKey($code)) { $Map[$code] } else { "DERP $code" }
                }

                if ($match.Success) { 
                    $val = [int]$match.Groups[1].Value
                    $data.Latencies += $val; $data.Last = $val
                } else { 
                    $data.Latencies += -1 
                    $data.Last = -1; $data.Color = "Red" 
                }
            } catch {
                $data.Latencies += -1
                $data.Last = -1; $data.Color = "Red"
            }

            $Sync[$IP] = $data
            Start-Sleep -Milliseconds 600
        }
        $final = $Sync[$IP]; $final.Done = $true; $Sync[$IP] = $final
    }).AddArgument($peer.IP).AddArgument($SyncHash).AddArgument($DerpLookup).AddArgument($selfIP)
    $PowerShell.RunspacePool = $RunspacePool
    @{ PS = $PowerShell; Handle = $PowerShell.BeginInvoke() }
}

# --- 5. Main UI Loop ---
Clear-Host
Write-Host "Tailscale Parallel Monitor (v5.2)" -ForegroundColor White
Write-Host "---------------------------------------------------------------" -ForegroundColor Gray
$ScanLine = "Scanning... (Tailscale Protocol)"
Write-Host $ScanLine -ForegroundColor Yellow

while ($true) {
    $runningCount = 0
    foreach ($peer in $onlinePeers) {
        $data = $SyncHash[$peer.IP]
        if (-not $data.Done) { $allDone = $false; $runningCount++ }

        $count = $data.Latencies.Count
        if ($data.Done) {
            $valid = $data.Latencies | Where-Object { $_ -ge 0 }
            $latVal = if ($valid) { "{0:N0} ms" -f ($valid | Measure-Object -Average).Average } else { "Timeout" }
            $prog = "[10/10]"
        } else {
            $last = if ($data.Last -eq -1) { "Timeout" } else { "$($data.Last) ms" }
            $latVal = $last
            $displayCount = if ($count -eq 0) { 1 } else { $count }
            $prog = "[$($displayCount)/10]"
        }

        # Format everything with fixed widths
        $centeredPath = Get-CenteredText -text $data.Path -width 25
        $idx = [array]::IndexOf($onlinePeers, $peer)
        [Console]::SetCursorPosition(0, $idx + 3)
        
        # Fixed alignment: Name(15), IP(12), Tag(11)
        $line = "{0,-15} [{1,-12}] - {2,-11} {{{3,8}}} [{4}] {5}" -f $peer.Name, $peer.IP, $data.Tag.Trim(), $latVal, $centeredPath, $prog
        Write-Host ($line.PadRight([Console]::WindowWidth - 1)) -ForegroundColor $data.Color
    }
    if ($runningCount -eq 0) { break }
    Start-Sleep -Milliseconds 200
}

# --- 6. Final Cleanup ---
[Console]::SetCursorPosition(0, 2)
Write-Host ("Done!".PadRight($ScanLine.Length + 5)) -ForegroundColor Green
[Console]::SetCursorPosition(0, $onlinePeers.Count + 3)
Write-Host "---------------------------------------------------------------" -ForegroundColor Gray
$RunspacePool.Close()
