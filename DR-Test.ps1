# --- Build DERP code -> name map from Tailscale derpmap ---
$DerpMap = @{}
try {
    $derp = irm https://controlplane.tailscale.com/derpmap/default
    if ($derp -and $derp.Regions) {
        $derp.Regions.PSObject.Properties | ForEach-Object {
            $code = $_.Value.RegionCode
            $name = $_.Value.RegionName
            if ($code -and $name) { $DerpMap[$code] = $name }
        }
    }
} catch { }

# --- Helper: IPv4 -> UInt32 for numeric sort ---
function Convert-IPv4ToInt {
    param([Parameter(Mandatory)][string]$IPv4)
    $bytes = [System.Net.IPAddress]::Parse($IPv4).GetAddressBytes()
    [Array]::Reverse($bytes)
    [BitConverter]::ToUInt32($bytes, 0)
}

# --- Collect online peers ---
$allPeers = (tailscale status --json | ConvertFrom-Json).Peer.PSObject.Properties.Value |
    Where-Object {
        $_.Online -eq $true -and -not $_.Self -and $_.TailscaleIPs -and
        ($_.TailscaleIPs | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' })
    } |
    ForEach-Object {
        $ip4 = ($_.TailscaleIPs | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1)
        $_ | Add-Member -NotePropertyName IPv4 -NotePropertyValue $ip4 -Force
        $_
    }

$sorted = $allPeers | Sort-Object { Convert-IPv4ToInt $_.IPv4 }
for ($i=0; $i -lt $sorted.Count; $i++) { $sorted[$i] | Add-Member NoteProperty Index $i -Force }

# --- Run in parallel ---
$results = $sorted | ForEach-Object -Parallel {
    $p    = $_
    $name = if ($p.Name) { $p.Name } elseif ($p.DNSName) { ($p.DNSName -split '\.')[0] } else { $p.HostName }
    $ip   = $p.IPv4

    # Execute tailscale ping
    $tp = tailscale ping -c 2 $ip 2>&1 | Out-String

    # Improved Path Detection Logic
    $isDirect = $false
    $isPeerRelay = $false
    $endpoint = "Unknown"

    if ($tp -match 'via\s+([0-9.]+:\d+)') {
        $isDirect = $true
        $endpoint = $Matches[1]
    } elseif ($tp -match 'peer-relay\s+([0-9.]+:\d*)') {
        $isPeerRelay = $true
        $endpoint = "Peer-Relay (" + $Matches[1] + ")"
    } elseif ($tp -match 'DERP\(([^)]+)\)') {
        $code = $Matches[1]
        $map  = $using:DerpMap
        $endpoint = if ($map.ContainsKey($code)) { $map[$code] } else { $code.ToUpper() }
    }

    # Latency via ICMP
    $lat = "-"
    try {
        $pong = ping -n 1 -w 500 $ip 2>&1 | Out-String
        if ($pong -match 'time[=<]?\s*(\d+)\s*ms') { $lat = ("{0}ms" -f $Matches[1]) }
    } catch {}

    [pscustomobject]@{
        Index     = $p.Index
        Name      = $name
        IP        = $ip
        Latency   = $lat
        Direct    = $isDirect
        PeerRelay = $isPeerRelay
        Endpoint  = $endpoint
    }
} -ThrottleLimit 16

# --- Print Results ---
Write-Host "`nTailscale Network Status (P-Relay Aware)`n"
$results | Sort-Object Index | ForEach-Object {
    if ($_.Direct) {
        $state = "Direct "
        $color = "Green"
    } elseif ($_.PeerRelay) {
        $state = "P-Relay"
        $color = "Cyan"
    } else {
        $state = "Relay  "
        $color = "Red"
    }
    
    $line = "{0,-15} [{1,-12}] - {2} {{{3,5}}} [{4}]" -f $_.Name, $_.IP, $state, $_.Latency, $_.Endpoint
    Write-Host $line -ForegroundColor $color
}
Write-Host "`n"
