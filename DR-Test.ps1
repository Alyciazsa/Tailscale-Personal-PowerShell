$peers = (tailscale status --json | ConvertFrom-Json).Peer.PSObject.Properties.Value |
  Where-Object { $_.Online -eq $true -and -not $_.Self -and $_.TailscaleIPs -and $_.TailscaleIPs.Count -gt 0 }

$peers | ForEach-Object -Parallel {
  $p    = $_
  $name = if ($p.Name) { $p.Name } elseif ($p.DNSName) { ($p.DNSName -split '\.')[0] } else { $p.HostName }
  $ip   = $p.TailscaleIPs[0]

  # Try up to 10 attempts; exits success if any attempt becomes direct
  tailscale ping --until-direct -c 10 $ip *> $null
  $isDirect = $?

  # Get a latency sample via ICMP; if it fails, show "-"
  $lat = "-"
  try {
    $pong = ping -n 1 $ip 2>&1 | Out-String
    if ($pong -match 'time[=<]?\s*(\d+)\s*ms') { $lat = ("{0}ms" -f $Matches[1]) }
    elseif ($pong -match 'Average\s*=\s*(\d+)\s*ms') { $lat = ("{0}ms" -f $Matches[1]) }
  } catch {}

  if ($isDirect) {
    Write-Host "$name [$ip] {$lat} - Direct" -ForegroundColor Green
  } else {
    Write-Host "$name [$ip] {$lat} - Relay"  -ForegroundColor Red
  }
} -ThrottleLimit 16
