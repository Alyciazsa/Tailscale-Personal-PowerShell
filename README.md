# Tailscale Personal PowerShell
Check all client in Tailscale Network for Direct and Relay Connection.
```
irm https://raw.githubusercontent.com/Alyciazsa/Tailscale-Personal-PowerShell/refs/heads/main/TS-PShell.ps1 | iex
```
Example Output

Tailscale Status Scanner
---------------------------------------------------------------

Name1      [x.x.x.x] - Direct           {    0 ms}   [      Local Machine      ]
Name2      [x.x.x.x] - Peer-Direct      {   32 ms}   [      x.x.x.x:xxxxx      ]    [   100%] [10/10]
Name3      [x.x.x.x] - Direct           {    1 ms}   [      x.x.x.x:xxxxx      ]    [   100%] [10/10]
Name4      [x.x.x.x] - Relay            {   60 ms}   [      x.x.x.x:xxxxx      ]    [   100%] [10/10]
 
---------------------------------------------------------------

<br><br>
