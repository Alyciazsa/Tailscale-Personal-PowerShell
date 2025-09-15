# --- Build DERP code -> name map from Tailscale derpmap (best-effort) ---
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

# --- helper: IPv4 -> UInt32 for numeric sort ---
function Convert-IPv4ToInt {
  param([Parameter(Mandatory)][string]$IPv4)
  $bytes = [System.Net.IPAddress]::Parse($IPv4).GetAddressBytes()
  [Array]::Reverse($bytes) # little-endian for BitConverter
  [BitConverter]::ToUInt32($bytes, 0)
}

# --- collect online peers w/ IPv4, attach IPv4 + index for stable ordering ---
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

# Sort numerically by IPv4 (x.x.x.1 -> x.x.x.254)
$sorted = $allPeers | Sort-Object { Convert-IPv4ToInt $_.IPv4 }
for ($i=0; $i -lt $sorted.Count; $i++) { $sorted[$i] | Add-Member NoteProperty Index $i -Force }

# --- run in parallel, gather results, then print all at once ---
$results = $sorted | ForEach-Object -Parallel {
  $p    = $_
  $name = if ($p.Name) { $p.Name } elseif ($p.DNSName) { ($p.DNSName -split '\.')[0] } else { $p.HostName }
  $ip   = $p.IPv4

  # Try to establish direct path (success if any of 10 tries is direct)
  tailscale ping --until-direct -c 10 $ip *> $null
  $isDirect = $?

  # Run one ping to extract the path actually used (for endpoint/DERP)
  $tp = tailscale ping -c 1 $ip 2>&1 | Out-String

  # Latency via ICMP (just for the {ms} display)
  $lat = "-"
  try {
    $pong = ping -n 1 $ip 2>&1 | Out-String
    if     ($pong -match 'time[=<]?\s*(\d+)\s*ms')   { $lat = ("{0}ms" -f $Matches[1]) }
    elseif ($pong -match 'Average\s*=\s*(\d+)\s*ms') { $lat = ("{0}ms" -f $Matches[1]) }
  } catch {}

  # Endpoint:
  # - If Direct: extract WANIP:PORT from tailscale ping output; fallback to status Endpoints
  # - If Relay : extract DERP(code) from ping or map p.Relay code -> RegionName
  $endpoint = "-"

  if ($isDirect) {
    if     ($tp -match '(?i)direct\s+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:\d+)') { $endpoint = $Matches[1] }
    elseif ($tp -match '(?i)via\s+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:\d+)')    { $endpoint = $Matches[1] }
    elseif ($p.Endpoints -and $p.Endpoints.Count -gt 0) {
      # Prefer public endpoint if present
      $public = $p.Endpoints | Where-Object { $_ -notmatch '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)' } | Select-Object -First 1
      $endpoint = if ($public) { $public } else { $p.Endpoints[0] }
    }
  } else {
    if ($tp -match 'DERP\(([^)]+)\)') {
      $code = $Matches[1]
      $map  = $using:DerpMap
      $endpoint = if ($map.ContainsKey($code)) { "DERP $($map[$code])" } else { "DERP $($code.ToUpper())" }
    } elseif ($p.Relay) {
      $map  = $using:DerpMap
      $endpoint = if ($map.ContainsKey($p.Relay)) { "DERP $($map[$p.Relay])" } else { "DERP $($p.Relay.ToUpper())" }
    } else {
      $endpoint = "DERP"
    }
  }

  [pscustomobject]@{
    Index    = $p.Index
    Name     = $name
    IP       = $ip
    Latency  = $lat
    Direct   = $isDirect
    Endpoint = $endpoint
  }
} -ThrottleLimit 16

$results | Sort-Object Index | ForEach-Object {
  $state = if ($_.Direct) { "Direct" } else { "Relay" }
  $line  = "{0} [{1}] - {2} {{{3}}} [{4}]" -f $_.Name, $_.IP, $state, $_.Latency, $_.Endpoint
  if ($_.Direct) { Write-Host $line -ForegroundColor Green } else { Write-Host $line -ForegroundColor Red }
}
