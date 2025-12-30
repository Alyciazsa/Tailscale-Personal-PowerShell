# --- Build DERP Map ---
$DerpMap = @{}
try {
    $derp = irm https://controlplane.tailscale.com/derpmap/default
    if ($derp -and $derp.Regions) {
        $derp.Regions.PSObject.Properties | ForEach-Object { $DerpMap[$_.Value.RegionCode] = $_.Value.RegionName }
    }
} catch { }

# --- Fetch Online Peers ---
$statusJson = tailscale status --json | ConvertFrom-Json
$allPeers = $statusJson.Peer.PSObject.Properties.Value | Where-Object { $_.Online -eq $true -and -not $_.Self }

Write-Host "`nNegotiating Paths (Waiting for Tailscale)..." -ForegroundColor Gray

$results = $allPeers | ForEach-Object -Parallel {
    $p = $_
    $ip = ($p.TailscaleIPs | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1)
    
    # Increase timeout and force 2 pings to ensure path negotiation finishes
    $tp = tailscale ping -c 2 -timeout 3s $ip 2>&1 | Out-String

    # Path Detection Logic - Explicit Regex
    $isDirect = $false; $isPeerRelay = $false; $endpoint = "Relay"

    if ($tp -match 'peer-relay\s+([0-9.]+:[0-9]+)') {
        $isPeerRelay = $true
        $endpoint = $Matches[1]
    } elseif ($tp -match 'direct\s+([0-9.]+:\d+)') {
        $isDirect = $true
        $endpoint = $Matches[1]
    } elseif ($tp -match 'via\s+DERP\(([^)]+)\)') {
        $code = $Matches[1]; $map = $using:DerpMap
        $endpoint = if ($map.ContainsKey($code)) { $map[$code] } else { $code.ToUpper() }
    } elseif ($tp -match 'via\s+([0-9.]+:\d+)') {
        $isDirect = $true
        $endpoint = $Matches[1]
    }

    # ICMP Latency
    $lat = "-"; $pong = ping -n 1 -w 500 $ip 2>&1 | Out-String
    if ($pong -match 'time[=<]?\s*(\d+)\s*ms') { $lat = ("{0}ms" -f $Matches[1]) }

    [pscustomobject]@{
        Name = (($p.DNSName -split '\.')[0]); IP = $ip; Latency = $lat
        Direct = $isDirect; PeerRelay = $isPeerRelay; Endpoint = $endpoint
    }
} -ThrottleLimit 8 # Lower throttle ensures more CPU time per ping

# --- Final Clear and Print ---
Clear-Host
Write-Host "Tailscale Network Status (v2.5) - $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor White
Write-Host "---------------------------------------------------------------" -ForegroundColor Gray

$results | Sort-Object Name | ForEach-Object {
    if ($_.PeerRelay) { 
        $color = "Cyan";  $tag = "-Peer-Relay" 
    } elseif ($_.Direct) { 
        $color = "Green"; $tag = "Direct     " 
    } else { 
        $color = "Red";   $tag = "Relay      " 
    }

    $line = "{0,-15} [{1,-12}] - {2} {{{3,5}}} [{4}]" -f $_.Name, $_.IP, $tag, $_.Latency, $_.Endpoint
    Write-Host $line -ForegroundColor $color
}
Write-Host "---------------------------------------------------------------" -ForegroundColor Gray
