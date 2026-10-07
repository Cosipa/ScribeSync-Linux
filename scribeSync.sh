#!/usr/bin/env bash
set -euo pipefail

update_symlinks_only=false
for argument in "$@"; do
    case "$argument" in
        --update-symlinks)
            update_symlinks_only=true
            ;;
        -h|--help)
            printf 'Usage: %s [--update-symlinks]\n' "$0"
            printf '  --update-symlinks  Update links from local PDFs and labels without a connected device.\n'
            exit 0
            ;;
        *)
            printf 'ERROR: Unknown argument: %s\n' "$argument" >&2
            exit 1
            ;;
    esac
done

clear

# Load config if it exists
if [[ -f "./config.ini" ]]; then
    set -a
    source "./config.ini"
    set +a
else
    printf 'ERROR: Config file ./config.ini not found, exiting script\n' >&2
    exit 1
fi

# Validate required config
if [[ -z "${AssetsFolder:-}" ]]; then
    printf 'ERROR: AssetsFolder not set in config.ini\n' >&2
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

# Read labels for both a full sync and an offline symlink update.
load_notebook_labels() {
    local jsonContent key value sanitizedValue
    if [ -s "./notebook_labels.json" ]; then
        jsonContent=$(<"./notebook_labels.json")
    else
        jsonContent='{}'
        log_status "warning" "No existing notebook labels found, using default labels"
    fi

    # Validate JSON before reading through process substitution.
    jq empty <<< "$jsonContent"
    while IFS="=" read -r key value; do
        [[ -z "$key" ]] && continue
        key=$(echo "$key" | tr -d ' "')
        value=$(echo "$value" | sed 's/^"//' | sed 's/"$//')
        sanitizedValue=$(echo "$value" | tr -d "'")
        notebookLabels["$key"]="$sanitizedValue"
    done < <(jq -r 'to_entries | .[] | "\(.key)=\(.value)"' <<< "$jsonContent")
}

update_notebook_symlinks() {
    local exportedPdfPath pdfFileName notebookId label assets_path
    local -a PDFs
    section_header "Notebook registry information"
    shopt -s nullglob
    PDFs=("./sync_data/pdf"/*.pdf)

    if [ ${#PDFs[@]} -eq 0 ]; then
        log_status "warning" "No PDF files found in the source folder: ./sync_data/pdf"
        return 1
    fi

    log_status "info" "Found ${#PDFs[@]} local notebooks"
    assets_path=$(cd "$AssetsFolder" && pwd)
    section_header "Creating Notebook Symlinks"
    mkdir -p "$HOME/Notebooks"

    for exportedPdfPath in "${PDFs[@]}"; do
        pdfFileName=$(basename "$exportedPdfPath")
        notebookId="${pdfFileName%.pdf}"
        label="${notebookLabels[$notebookId]:-Scribe Notebook for $notebookId}"
        ln -sf "$assets_path/$pdfFileName" "$HOME/Notebooks/$label.pdf"
        log_status "success" "Created symlink: $label.pdf"
    done
}

# Keep our FUSE mount private so cleanup cannot unmount another MTP client.
mount_dir=""
mount_point=""
mount_pid=""
fusermount_cmd=""
pending_copy=""

unmount_scribe() {
    [[ -z "$mount_point" ]] && return 0
    if [[ -z "$mount_pid" ]] && ! mountpoint -q "$mount_point"; then
        return 0
    fi
    if mountpoint -q "$mount_point"; then
        if ! "$fusermount_cmd" -u "$mount_point"; then
            log_status "warning" "Could not unmount $mount_point; it may be busy"
            return 1
        fi
    elif [[ -n "$mount_pid" ]]; then
        # Stop the foreground go-mtpfs process if startup failed or timed out.
        kill "$mount_pid" 2>/dev/null || true
    fi
    if [[ -n "$mount_pid" ]]; then
        wait "$mount_pid" 2>/dev/null || true
        mount_pid=""
    fi
    # Startup may have completed just before cancellation.
    if mountpoint -q "$mount_point"; then
        "$fusermount_cmd" -u "$mount_point" || return 1
    fi
    log_status "success" "Device mount released"
}

cleanup() {
    local status=$?
    if [[ -n "$pending_copy" ]]; then
        rm -f -- "$pending_copy" || true
    fi
    unmount_scribe || return "$status"
    if [[ -n "$mount_dir" ]]; then
        rm -f -- "$mount_dir/go-mtpfs.log"
        rmdir -- "$mount_point" "$mount_dir" 2>/dev/null || true
    fi
    return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

#=====--- Start of the actual script ---=====#

section_header "Kindle Scribe Sync"

if ! command -v jq > /dev/null; then
    log_status "error" "Required command not found: jq"
    exit 1
fi

declare -A notebookLabels
load_notebook_labels

if [[ "$update_symlinks_only" == true ]]; then
    update_notebook_symlinks
    exit 0
fi

for dependency in go-mtpfs mountpoint lsusb md5sum calibre-debug ebook-convert; do
    if ! command -v "$dependency" > /dev/null; then
        log_status "error" "Required command not found: $dependency"
        exit 1
    fi
done

if command -v fusermount3 > /dev/null; then
    fusermount_cmd=fusermount3
elif command -v fusermount > /dev/null; then
    fusermount_cmd=fusermount
else
    log_status "error" "Required command not found: fusermount3 or fusermount"
    exit 1
fi

while ! lsusb | grep -iq 'scribe'; do
    show_waiting "Waiting for Kindle Scribe connection..."
    sleep 0.1
done
clear_line
log_status "info" "Kindle Scribe connected"

mkdir -p ./sync_data/{notebooks,epub,pdf}

mount_dir=$(mktemp -d "${TMPDIR:-/tmp}/scribesync.XXXXXX")
mount_point="$mount_dir/device"
mkdir "$mount_point"
# go-mtpfs stays in the foreground. Disable Android-only MTP extensions for Kindle.
# v1.0.0's classic reader drops os.File references while keeping raw FDs; GC can
# close them mid-read. Disable GC only for this short-lived mount process.
GOGC=off go-mtpfs -android=false -dev "${MtpDeviceFilter:-(?i)scribe}" "$mount_point" \
    > "$mount_dir/go-mtpfs.log" 2>&1 &
mount_pid=$!

# Wait for a real FUSE mount, not just for the mount directory to exist.
for ((attempt=0; attempt<300; attempt++)); do
    if mountpoint -q "$mount_point"; then
        break
    fi
    if ! kill -0 "$mount_pid" 2>/dev/null; then
        log_status "error" "go-mtpfs failed. Close other MTP clients and check USB permissions."
        cat "$mount_dir/go-mtpfs.log" >&2
        exit 1
    fi
    sleep 0.1
done
if ! mountpoint -q "$mount_point"; then
    log_status "error" "Timed out waiting for go-mtpfs to mount the Scribe"
    cat "$mount_dir/go-mtpfs.log" >&2
    exit 1
fi
log_status "success" "Scribe mounted successfully"

# Discover the notebook storage rather than assuming its display name.
shopt -s nullglob
notebooks_path=""
for storage_path in "$mount_point"/*/; do
    if [[ -d "$storage_path/.notebooks" ]]; then
        notebooks_path="$storage_path/.notebooks"
        break
    fi
done

if [[ -z "$notebooks_path" ]]; then
    log_status "error" "No .notebooks directory found on the Scribe"
    exit 1
fi

# Phase 1: Detect changes and copy notebooks (while Scribe is mounted)
section_header "Notebook Detection & Copy Phase"
declare -a changedNotebooks=()
declare -A notebookLabelMap=()

# Check directory access before globbing so read errors are not treated as no changes.
ls -- "$notebooks_path" > /dev/null
for folder in "$notebooks_path"/*/; do
    folder="${folder%/}"
    folderName="${folder##*/}"
    # Newer firmware appends this marker; keep backup/label IDs as bare UUIDs.
    folderName="${folderName%!!PDOC!!notebook}"
    guidPattern='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    # Ignore folders that are not written notebooks (clipboard, thumbnails, etc)
    if [[ $folderName =~ $guidPattern ]]; then
        # Check if the folders contain the notebook file (nbk)
        if [[ -f "$folder/nbk" ]]; then

            # Give existing label, if not use default inherited label
            if [ -n "${notebookLabels[$folderName]:-}" ]; then
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
            # MTP has no remote checksum API. Download once, hash locally, then
            # atomically replace the backup only after a successful transfer.
            pending_copy=$(mktemp "$exportedfolder/.nbk.XXXXXX")
            if ! cp -- "$folder/nbk" "$pending_copy"; then
                log_status "error" "Notebook transfer failed: $folderName"
                cat "$mount_dir/go-mtpfs.log" >&2
                exit 1
            fi
            remotefilehash=$(get_file_hash "$pending_copy")
            if [ "$remotefilehash" == "$localfilehash" ]; then
                log_status "info" "No changes detected for: $label"
                rm -f -- "$pending_copy"
                # Retry exports after an interrupted sync or failed conversion.
                if [[ ! -f "./sync_data/epub/$folderName.epub" ||
                      ! -f "./sync_data/pdf/$folderName.pdf" ||
                      "$exportedfolder/nbk" -nt "./sync_data/epub/$folderName.epub" ||
                      "$exportedfolder/nbk" -nt "./sync_data/pdf/$folderName.pdf" ]]; then
                    log_status "info" "Local exports need conversion: $label"
                    changedNotebooks+=("$folderName")
                fi
            else
                log_status "info" "Changes detected in: $label"
                mv -- "$pending_copy" "$exportedfolder/nbk"
                changedNotebooks+=("$folderName")
            fi
            pending_copy=""
        fi
    fi
done

# Phase 2: Release our mount before starting conversions.
section_header "Device Unmount"
unmount_scribe

# Phase 3: Convert local notebook copies in parallel.
section_header "Notebook Conversion Phase"
declare -a conversionPids=()

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

# Phase 4: Create symlinks to notebooks in home directory
update_notebook_symlinks
