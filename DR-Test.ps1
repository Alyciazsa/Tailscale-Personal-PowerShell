# --- Build DERP code -> name map ---
$DerpMap = @{}
try {
    $derp = irm https://controlplane.tailscale.com/derpmap/default
    if ($derp -and $derp.Regions) {
        $derp.Regions.PSObject.Properties | ForEach-Object {
            $DerpMap[$_.Value.RegionCode] = $_.Value.RegionName
        }
    }
} catch { }

# --- Helper: IPv4 to Int ---
function Convert-IPv4ToInt {
    param([string]$IPv4)
    $bytes = [IPAddress]::Parse($IPv4).GetAddressBytes(); [Array]::Reverse($bytes)
    [BitConverter]::ToUInt32($bytes, 0)
}

# --- Fetch Status ---
$statusJson = tailscale status --json | ConvertFrom-Json
$allPeers = $statusJson.Peer.PSObject.Properties.Value | Where-Object { $_.Online -eq $true -and -not $_.Self }

$results = $allPeers | ForEach-Object -Parallel {
    $p = $_
    $ip = ($p.TailscaleIPs | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1)
    
    # Path Detection from JSON Status (Most Accurate)
    $isDirect = if ($p.CurAddr -and $p.CurAddr -notmatch "derp") { $true } else { $false }
    $isPeerRelay = if ($p.PeerAPIURL -match "relay" -or $p.Relay -match "peer") { $true } else { $false }
    
    # Final check: Tailscale Ping to confirm current active path
    $tp = tailscale ping -c 1 $ip 2>&1 | Out-String
    if ($tp -match "peer-relay") { $isPeerRelay = $true; $isDirect = $false }
    elseif ($tp -match "direct") { $isDirect = $true; $isPeerRelay = $false }

    # Endpoint Labeling
    $endpoint = "Unknown"
    if ($isDirect) {
        if ($tp -match 'direct\s+([0-9.]+:\d+)') { $endpoint = $Matches[1] }
        else { $endpoint = $p.CurAddr }
    } elseif ($isPeerRelay) {
        if ($tp -match 'peer-relay\s+([0-9.]+:\d+)') { $endpoint = "Relay via " + $Matches[1] }
        else { $endpoint = "i3-8100 Relay" }
    } else {
        if ($tp -match 'DERP\(([^)]+)\)') {
            $code = $Matches[1]; $map = $using:DerpMap
            $endpoint = if ($map.ContainsKey($code)) { $map[$code] } else { $code.ToUpper() }
        }
    }

    # ICMP Latency
    $lat = "-"; $pong = ping -n 1 -w 500 $ip 2>&1 | Out-String
    if ($pong -match 'time[=<]?\s*(\d+)\s*ms') { $lat = ("{0}ms" -f $Matches[1]) }

    [pscustomobject]@{
        Name = (($p.DNSName -split '\.')[0]); IP = $ip; Latency = $lat
        Direct = $isDirect; PeerRelay = $isPeerRelay; Endpoint = $endpoint
    }
}

# --- Output ---
Write-Host "`nTailscale Network Status (v2.2)`n" -ForegroundColor White
$results | ForEach-Object {
    if ($_.Direct) { $color = "Green"; $tag = "Direct " }
    elseif ($_.PeerRelay) { $color = "Cyan"; $tag = "P-Relay" }
    else { $color = "Red"; $tag = "Relay  " }

    $line = "{0,-15} [{1,-12}] - {2} {{{3,5}}} [{4}]" -f $_.Name, $_.IP, $tag, $_.Latency, $_.Endpoint
    Write-Host $line -ForegroundColor $color
}
