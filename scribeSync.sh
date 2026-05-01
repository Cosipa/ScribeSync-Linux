#!/usr/bin/env bash
set -euo pipefail

clear

# Load config if it exists
if [[ -f "./config.ini" ]]; then
    set -a
    source "./config.ini"
    set +a
else
    log_status "error" "Config file ./config.ini not found, exiting script"
    exit 1
fi

# Validate required config
if [[ -z "${AssetsFolder:-}" ]]; then
    log_status "error" "AssetsFolder not set in config.ini"
    exit 1
fi

# Shell colors for the script
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No color
readonly BOLD='\033[1m'

# Function to clear the current line
clear_line() {
    printf "\r\033[K"
}

# Logging functions (info, success, warning and error)
log_status() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%H:%M:%S')
    
    case $level in
        "info")
            printf "${BLUE}[INFO]${NC} ${timestamp} - %s\n" "$message"
            ;;
        "success")
            printf "${GREEN}[SUCCESS]${NC} ${timestamp} - %s\n" "$message"
            ;;
        "waitended")
            clear_line
            printf "${GREEN}[✓]${NC} %s\n" "$message"
            ;;
        "warning")
            printf "${YELLOW}[WARNING]${NC} ${timestamp} - %s\n" "$message"
            ;;
        "error")
            printf "${RED}[ERROR]${NC} ${timestamp} - %s\n" "$message"
            ;;
    esac
}

# Section header function
section_header() {
    local title="$1"
    printf "\n${BOLD}%s${NC}\n" "$title"
    printf '%s\n' "$title" | tr ' ' '-'
    printf "\n"
}

# Function to show an animated waiting indicator
frame_index=0
frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
show_waiting() {
    local message=$1
    printf "\r${BLUE}[%s]${NC} %s" "${frames:frame_index:1}" "$message"
    frame_index=$(( (frame_index + 1) % 10 ))
}

# Function to compute MD5 hash (fast change detection)
get_file_hash() {
    md5sum "$1" | awk '{ print $1 }'
}

#=====--- Start of the actual script ---=====#

section_header "Kindle Scribe Sync"

# Scribe connected?
if lsusb | grep -i "kindle scribe" > /dev/null; then
    log_status "info" "Kindle Scribe is currently plugged-in"
else
    connected=false
    while [[ "$connected" == false ]]; do
        show_waiting "Waiting for Kindle Scribe connection..."
        sleep 0.1
        if lsusb | grep -iq "scribe"; then
            connected=true
        fi
    done
    log_status "waitended" "Kindle Scribe connected"
fi

# Read or initialize notebook labels JSON file
touch ./notebook_labels.json > /dev/null
if [ -f "./notebook_labels.json" ]; then
    jsonContent=$(<"./notebook_labels.json")
else
    jsonContent='{}'
    log_status "warning" "No existing notebook labels found, creating new labels file"
fi

# Create folder structure
mkdir /mnt/MTP > /dev/null 2>&1;
mkdir -p ./sync_data/{notebooks,epub,pdf}

# Mount the Scribe
if [ ! -d "/mnt/MTP/Internal Storage/.notebooks" ]; then
    sleep 3
    jmtpfs /mnt/MTP &
    sleep 1
    log_status "success" "Scribe Internal Storage mounted successfully"
else
    log_status "success" "Scribe Internal Storage already mounted"
fi

# Process JSON data
declare -A notebookLabels
while IFS="=" read -r key value; do
    [[ -z "$key" ]] && continue
    key=$(echo "$key" | tr -d ' "')
    value=$(echo "$value" | sed 's/^"//' | sed 's/"$//')
    notebookLabels["$key"]="$value"
done < <(jq -r 'to_entries | .[] | "\(.key)=\(.value)"' <<< "$jsonContent")

# Sanitize entries
for key in "${!notebookLabels[@]}"; do
    sanitizedValue=$(echo "${notebookLabels[$key]}" | tr -d "'")
    notebookLabels["$key"]="$sanitizedValue"
done

# Phase 1: Detect changes and copy notebooks (while Scribe is mounted)
section_header "Notebook Detection & Copy Phase"
declare -a changedNotebooks
declare -A notebookLabelMap

for folder in "/mnt/MTP/Internal Storage/.notebooks"/*/; do
    folderName=$(basename "$folder")
    guidPattern='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    # Ignore folders that are not written notebooks (clipboard, thumbnails, etc)
    if [[ $folderName =~ $guidPattern ]]; then
        # Check if the folders contain the notebook file (nbk)
        if [ -f "$folder/nbk" ]; then

            # Give existing label, if not use default inherited label
            if [ -n "${notebookLabels[$folderName]}" ]; then
                label="${notebookLabels[$folderName]}"
            else
                label="Scribe Notebook for $folderName"
                notebookLabels["$folderName"]="$label"
                log_status "warning" "No label found for $folderName, using default"
            fi

            # Store label for later use during conversion
            notebookLabelMap["$folderName"]="$label"

            # Create the exported folder on PC
            exportedfolder="./sync_data/notebooks/$folderName"
            mkdir -p "$exportedfolder"

            # If a local copy of the notebook exists check its MD5 hash
            localfilehash=""
            if [ -f "$exportedfolder/nbk" ]; then
                localfilehash=$(get_file_hash "$exportedfolder/nbk")
            fi

            # If the hashes match, skip this notebook, else copy it
            remotefilehash=$(get_file_hash "$folder/nbk")
            if [ "$remotefilehash" == "$localfilehash" ]; then
                log_status "info" "No changes detected for: $label"
            else
                log_status "info" "Changes detected in: $label"
                cp "$folder/nbk" "$exportedfolder"
                changedNotebooks+=("$folderName")
            fi
        fi
    fi
done

# Phase 2: Unmount the device (before starting conversions)
section_header "Device Unmount"
if fusermount -u /mnt/MTP 2>/dev/null; then
    clear_line
    log_status "success" "Device unmounted successfully"
else
    log_status "warning" "Device may already be unmounted or busy"
    sleep 5
    fusermount -u /mnt/MTP 2>/dev/null || true
fi

# Phase 3: Convert notebooks (Scribe is now unmounted, can run in parallel)
section_header "Notebook Conversion Phase"
declare -a conversionPids

if [ ${#changedNotebooks[@]} -eq 0 ]; then
    log_status "info" "No notebooks to convert"
else
    for folderName in "${changedNotebooks[@]}"; do
        label="${notebookLabelMap[$folderName]}"
        exportedfolder="./sync_data/notebooks/$folderName"
        exportedEpubPath="./sync_data/epub/$folderName.epub"
        exportedPdfPath="./sync_data/pdf/$folderName.pdf"
        
        { calibre-debug --run-plugin "KFX Input" "$exportedfolder" "$exportedEpubPath" > /dev/null 2>&1 &&
          ebook-convert "$exportedEpubPath" "$exportedPdfPath" > /dev/null 2>&1
        } &
        conversionPids+=($!)
    done
    
    # Wait for all conversions and display progress
    completedCount=0
    for pid in "${conversionPids[@]}"; do
        while kill -0 "$pid" 2>/dev/null; do
            show_waiting "Converting notebooks ($completedCount/${#changedNotebooks[@]})"
            sleep 0.1
        done
        wait "$pid"
        ((completedCount++)) || true
        clear_line
        log_status "success" "Converted ${notebookLabelMap[${changedNotebooks[$((completedCount-1))]}]}"
    done
fi

# Save updated JSON
jsonObject=$(jq -n '{
  '"$(for key in "${!notebookLabels[@]}"; do
      printf "%s: \"%s\", " "\"$key\"" "${notebookLabels[$key]}"
    done | sed 's/, $//')"'
}')

# Store the json on file
echo "$jsonObject" | jq '.' > ./notebook_labels.json

# Process PDF files
section_header "Notebook registry information"
shopt -s nullglob
PDFs=("./sync_data/pdf"/*.pdf)

if [ ${#PDFs[@]} -eq 0 ]; then
    log_status "warning" "No PDF files found in the source folder: ./sync_data/pdf"
    exit 1
fi

log_status "info" "Found ${#PDFs[@]} notebooks in the Scribe"

# Phase 4: Create symlinks to notebooks in home directory
section_header "Creating Notebook Symlinks"
mkdir -p "$HOME/Notebooks"

for exportedPdfPath in "${PDFs[@]}"; do
    pdfFileName=$(basename "$exportedPdfPath")
    notebookId="${pdfFileName%.pdf}"
    ln -sf "$(cd "$AssetsFolder" && pwd)/$pdfFileName" "$HOME/Notebooks/${notebookLabelMap[$notebookId]}.pdf"
    log_status "success" "Created symlink: ${notebookLabelMap[$notebookId]}.pdf"
done
