# Tailscale Personal PowerShell
Check all client in Tailscale Network for Direct and Relay Connection.
```
irm https://raw.githubusercontent.com/Alyciazsa/Tailscale-Personal-PowerShell/refs/heads/main/DR-Test.ps1 | iex
```
Example Output

- tsname [100.69.0.19] - Direct {1ms} [x.x.x.x:41641]
- tsname2 [100.69.0.22] - Relay {86ms} [DERP Singapore]

<br><br>

Tailscale Custom Port - Persist across reboot
```
irm https://raw.githubusercontent.com/Alyciazsa/Tailscale-Personal-PowerShell/refs/heads/main/Custom-Port.ps1 | iex
```
- Input port 0-65535 that you want. and press Enter. it will Stop and Disabled Tailscale service and start custom port with Task Scheduler.So it will run scross reboot.
- Not input and just press enter to restore default window tailscale.
