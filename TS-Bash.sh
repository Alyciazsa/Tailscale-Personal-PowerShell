#!/bin/bash

# --- Configuration & Colors ---
C_GRAY="\033[90m"
C_GREEN="\033[92m"
C_YELLOW="\033[93m"
C_RED="\033[91m"
C_CYAN="\033[96m"
C_WHITE="\033[97m"
C_RESET="\033[0m"

# Temporary directory for "shared memory"
SHM_DIR="/dev/shm/ts_scanner_$$"
mkdir -p "$SHM_DIR"

# Cleanup on exit
cleanup() {
    rm -rf "$SHM_DIR"
    tput cnorm # Show cursor
    echo -e "${C_RESET}"
}
trap cleanup EXIT

# Hide cursor
tput civis

# --- 1. Pre-fetch DERP Map ---
declare -A DERP_MAP
DERP_JSON=$(curl -s https://controlplane.tailscale.com/derpmap/default)
# Basic parsing of DERP JSON using grep/sed (avoids requiring 'jq')
while read -r code name; do
    DERP_MAP["$code"]="$name"
done < <(echo "$DERP_JSON" | grep -Po '"RegionCode":"\K[^"]*| "RegionName":"\K[^"]*' | sed 'N;s/\n/ /')

# --- 2. Identify Peers & Self ---
SELF_IP=$(tailscale ip -4 | tr -d '[:space:]')
mapfile -t PEER_LINES < <(tailscale status | grep "100\." | grep -v "offline")

# --- 3. UI Helpers ---
move_cursor() { echo -ne "\033[$(($1 + 1));$(($2 + 1))H"; }

center_text() {
    local text="$1"
    local width="$2"
    if [[ -z "$text" || "$text" == "-" ]]; then text="-"; fi
    if ((${#text} >= width)); then echo "${text:0:width}"; return; fi
    local pad=$(((width - ${#text}) / 2))
    printf "%${pad}s%s%$(($width - ${#text} - pad))s" "" "$text" ""
}

# --- 4. Worker Function (Run in Background) ---
worker() {
    local ip="$1"
    local name="$2"
    local data_file="$SHM_DIR/$ip"

    # Initial state
    local tag="Idle" color="Gray" path="-" last=0 count=0 ok_count=0 lats=""
    
    if [[ "$ip" == "$SELF_IP" ]]; then
        echo "Direct|Green|Local Machine|0|10|10|100%|Done" > "$data_file"
        return
    fi

    for i in {1..10}; do
        ping_out=$(tailscale ping --c 1 --timeout 1s "$ip" 2>&1)
        status_line=$(tailscale status | grep "$ip")
        
        # Parse Latency
        if [[ $ping_out =~ in\ ([0-9]+)ms ]]; then
            last="${BASH_REMATCH[1]}"
            ((ok_count++))
        else
            last="-1"
            color="Red"
        fi
        ((count++))

        # Path Logic
        if [[ $ping_out =~ via\ ([0-9.]+:[0-9]+) ]]; then
            tag="Direct"; color="Green"; path="${BASH_REMATCH[1]}"
        elif [[ $ping_out =~ via\ DERP\(([a-z0-9]+)\) ]]; then
            tag="Relay"; color="Red"; 
            code="${BASH_REMATCH[1]}"
            path="DERP: ${DERP_MAP[$code]:-$code}"
        elif [[ $(echo "$status_line" | tr '[:upper:]' '[:lower:]') =~ direct\ ([0-9.]+:[0-9]+) ]]; then
            tag="Direct"; color="Green"; path="${BASH_REMATCH[1]}"
        fi

        # Percentage
        perc=$(awk "BEGIN {printf \"%.0f\", ($ok_count/$count)*100}")
        
        # Update shared file
        echo "$tag|$color|$path|$last|$count|$ok_count|$perc%|Running" > "$data_file"
        sleep 0.6
    done
    
    # Final state
    sed -i 's/Running/Done/' "$data_file"
}

# --- 5. Main Execution ---
clear
echo -e "${C_WHITE}Tailscale Status Scanner${C_RESET}"
echo -e "${C_GRAY}---------------------------------------------------------------${C_RESET}"
echo -e "${C_YELLOW}Scanning...${C_RESET}"

# Launch Workers
for line in "${PEER_LINES[@]}"; do
    parts=($line)
    worker "${parts[0]}" "${parts[1]}" &
done

# UI Loop
while true; do
    running=0
    term_width=$(tput cols)
    
    for i in "${!PEER_LINES[@]}"; do
        parts=(${PEER_LINES[$i]})
        ip="${parts[0]}"
        name="${parts[1]}"
        data_file="$SHM_DIR/$ip"

        if [[ -f "$data_file" ]]; then
            IFS='|' read -r tag color path last count ok_count perc status < "$data_file"
            
            [[ "$status" == "Running" ]] && ((running++))
            
            # Format Latency display
            if [[ "$status" == "Done" ]]; then
                lat_display="$last ms"
                [[ "$last" == "-1" ]] && lat_display="Timeout"
                prog="[10/10]"
            else
                lat_display="$last ms"
                [[ "$last" == "-1" ]] && lat_display="Timeout"
                prog="[$count/10]"
            fi

            color_var="C_${color^^}"
            c_code="${!color_var}"
            
            centered_path=$(center_text "$path" 25)
            move_cursor $((i + 3)) 0
            
            if [[ "$path" == "Local Machine" ]]; then
                line=$(printf "%-15s [%-12s] - %-11s {%8s} [%s]" "$name" "$ip" "$tag" "$lat_display" "$centered_path")
            else
                line=$(printf "%-15s [%-12s] - %-11s {%8s} [%s] [%7s] %s" "$name" "$ip" "$tag" "$lat_display" "$centered_path" "$perc" "$prog")
            fi
            
            # Print line and clear to end of terminal line
            echo -ne "${c_code}${line:0:$((term_width-1))}${C_RESET}\033[K"
        fi
    done

    # Check if background jobs are finished
    if [[ $running -eq 0 && $(ls "$SHM_DIR" | wc -l) -eq ${#PEER_LINES[@]} ]]; then
        # Double check "Running" status in files
        if ! grep -q "Running" "$SHM_DIR"/* 2>/dev/null; then break; fi
    fi
    sleep 0.2
done

# Finalize
move_cursor 2 0
echo -e "${C_GREEN}Done!        ${C_RESET}"
move_cursor $((${#PEER_LINES[@]} + 3)) 0
echo -e "${C_GRAY}---------------------------------------------------------------${C_RESET}"