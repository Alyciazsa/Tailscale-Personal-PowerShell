import sys
import subprocess
import threading
import time
import re
import json
import urllib.request
import math
import shutil

# --- Configuration & ANSI Colors ---
COLORS = {
    "Gray": "\033[90m",
    "Green": "\033[92m",
    "Yellow": "\033[93m",
    "Red": "\033[91m",
    "Cyan": "\033[96m",
    "White": "\033[97m",
    "Reset": "\033[0m"
}

def move_cursor(row, col):
    sys.stdout.write(f"\033[{row+1};{col+1}H")

def write_colored(text, color_name, end="\n"):
    code = COLORS.get(color_name, COLORS["Reset"])
    sys.stdout.write(f"{code}{text}{COLORS['Reset']}{end}")
    sys.stdout.flush()

def get_centered_text(text, width):
    if not text or text == "-":
        text = "-"
    if len(text) >= width:
        return text[:width]
    pad = (width - len(text)) / 2
    left = " " * math.floor(pad)
    right = " " * math.ceil(pad)
    return f"{left}{text}{right}"

def run_command(cmd):
    try:
        result = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        return result.stdout.strip()
    except Exception:
        return ""

# --- 1. Pre-fetch DERP Map ---
derp_lookup = {}
try:
    with urllib.request.urlopen("https://controlplane.tailscale.com/derpmap/default") as url:
        data = json.loads(url.read().decode())
        if 'Regions' in data:
            for rid, rdata in data['Regions'].items():
                derp_lookup[rdata['RegionCode']] = rdata['RegionName']
except Exception:
    pass

# --- 2. Identify Online Peers & Self ---
self_ip = run_command("tailscale ip -4").strip()
status_output = run_command("tailscale status")
online_peers = []

for line in status_output.split('\n'):
    if "offline" not in line and "100." in line:
        parts = line.split()
        if len(parts) >= 2:
            online_peers.append({"Name": parts[1], "IP": parts[0]})

# --- 3. Setup Shared Memory ---
sync_hash = {}
for peer in online_peers:
    sync_hash[peer['IP']] = {
        "Latencies": [],
        "Done": False,
        "Last": 0,
        "Tag": "Idle",
        "Path": "-",
        "Color": "Gray"
    }

# --- 4. Worker Function (Thread Logic) ---
def worker(peer_ip):
    data = sync_hash[peer_ip]
    
    if peer_ip == self_ip:
        data.update({"Tag": "Direct", "Color": "Green", "Path": "Local Machine", 
                     "Last": 0, "Latencies": [0]*10, "Done": True})
        return

    for i in range(10):
        try:
            # 1. Run Ping & Capture Output
            ping_out = run_command(f"tailscale ping --c 1 --timeout 1s {peer_ip}")
            
            # 2. Get Status for this specific IP
            ts_status = run_command("tailscale status")
            peer_line = next((line for line in ts_status.split('\n') if peer_ip in line), "")

            # 3. PATH LOGIC (Ping Output First, Status Second)
            via_direct = re.search(r"via ([0-9.]+:\d+)", ping_out)
            via_derp = re.search(r"via DERP\((\w+)\)", ping_out)
            
            if via_direct:
                data["Tag"], data["Color"], data["Path"] = "Direct", "Green", via_direct.group(1)
            elif via_derp:
                code = via_derp.group(1)
                data["Tag"], data["Color"], data["Path"] = "Relay", "Red", f"DERP: {derp_lookup.get(code, code)}"
            else:
                # Fallback: Parse the 'tailscale status' line
                lower_line = peer_line.lower()
                if "direct" in lower_line:
                    data["Tag"], data["Color"] = "Direct", "Green"
                    addr_match = re.search(r"direct\s+([0-9.]+:\d+)", lower_line)
                    if addr_match: data["Path"] = addr_match.group(1)
                elif "relay" in lower_line or "derp" in lower_line:
                    data["Tag"], data["Color"] = "Relay", "Red"
                elif "active" in lower_line:
                    data["Tag"], data["Color"] = "Direct", "Green" # Usually direct if active on LAN

            # 4. LATENCY LOGIC
            match = re.search(r"in (\d+)ms", ping_out)
            if match:
                val = int(match.group(1))
                data["Latencies"].append(val)
                data["Last"] = val
            else:
                data["Latencies"].append(-1)
                data["Last"] = -1
                data["Color"] = "Red"

        except Exception:
            data["Latencies"].append(-1)
            data["Last"] = -1
            data["Color"] = "Red"
        
        time.sleep(0.6)

    data["Done"] = True

# Launch Threads
for peer in online_peers:
    t = threading.Thread(target=worker, args=(peer['IP'],))
    t.daemon = True
    t.start()

# --- 5. Main UI Loop ---
sys.stdout.write("\033[2J") 
move_cursor(0, 0)
write_colored("Tailscale Status Scanner", "White")
write_colored("-" * 63, "Gray")
scan_line = "Scanning..."
write_colored(scan_line, "Yellow")

for _ in online_peers: print("")

try:
    while True:
        running_count = 0
        term_width = shutil.get_terminal_size((80, 20)).columns

        for idx, peer in enumerate(online_peers):
            data = sync_hash[peer['IP']]
            if not data["Done"]: running_count += 1
            
            lats = data["Latencies"]
            ok_count = len([x for x in lats if x >= 0])
            perc_value = (ok_count / len(lats) * 100) if lats else 0.0
            perc_formatted = f"{int(perc_value)}%" if perc_value.is_integer() else f"{perc_value:.2f}%"
            
            lat_val = "Timeout"
            if data["Done"]:
                valid = [x for x in lats if x >= 0]
                lat_val = f"{int(sum(valid)/len(valid))} ms" if valid else "Timeout"
                prog = "[10/10]"
            else:
                lat_val = "Timeout" if data["Last"] == -1 else f"{data['Last']} ms"
                prog = f"[{max(1, len(lats))}/10]"

            centered_path = get_centered_text(data["Path"], 25)
            move_cursor(idx + 3, 0)

            if data["Path"] == "Local Machine":
                line = f"{peer['Name']:<15} [{peer['IP']:<12}] - {data['Tag']:<11} {{{lat_val:>8}}} [{centered_path}]"
            else:
                line = f"{peer['Name']:<15} [{peer['IP']:<12}] - {data['Tag']:<11} {{{lat_val:>8}}} [{centered_path}] [{perc_formatted:>7}] {prog}"

            sys.stdout.write(f"{COLORS.get(data['Color'], COLORS['Reset'])}{line.ljust(term_width-1)}{COLORS['Reset']}")
            sys.stdout.flush()

        if running_count == 0: break
        time.sleep(0.2)
except KeyboardInterrupt:
    pass

move_cursor(2, 0)
write_colored("Done!".ljust(len(scan_line) + 5), "Green")
move_cursor(len(online_peers) + 3, 0)
write_colored("-" * 63, "Gray")
print("")