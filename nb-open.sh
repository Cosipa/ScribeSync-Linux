#!/usr/bin/env bash
set -euo pipefail

# Load config if it exists
if [[ -f "./config.ini" ]]; then
    set -a
    source "./config.ini"
    set +a
else
    echo "Config file ./config.ini not found"
    exit 1
fi

# Read notebook_labels.json
if [ -f "./notebook_labels.json" ]; then
    jsonContent=$(<"./notebook_labels.json")
else
    echo "No notebook_labels.json found"
    exit 1
fi

# Parse JSON to associative array
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

# Trap SIGINT to exit cleanly
trap 'echo ""; exit 0' INT

# Get list of labels
labels=()
for key in "${!notebookLabels[@]}"; do
    labels+=("${notebookLabels[$key]}")
done

# Loop to allow multiple selections
while true; do
    # Use sk to select
    selected_label=$(printf '%s\n' "${labels[@]}" | sk --prompt="Select notebook: ")

    if [ -z "$selected_label" ]; then
        echo "No selection made, exiting"
        exit 0
    fi

    # Find UUID for selected label
    selected_uuid=""
    for key in "${!notebookLabels[@]}"; do
        if [ "${notebookLabels[$key]}" == "$selected_label" ]; then
            selected_uuid="$key"
            break
        fi
    done

    if [ -z "$selected_uuid" ]; then
        echo "UUID not found for label"
        continue
    fi

    # PDF path
    pdf_path="./sync_data/pdf/${selected_uuid}.pdf"

    if [ ! -f "$pdf_path" ]; then
        echo "PDF file not found: $pdf_path"
        continue
    fi

    # Open with xdg-open in background
    xdg-open "$pdf_path" &

    echo "Opened $selected_label"
done