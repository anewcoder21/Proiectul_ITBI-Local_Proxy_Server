#!/bin/bash
TMPFS_DIR="/mnt/tmpfs"
URL="$1"
if [[ -z "$URL" ]]; then
    echo "Error: No URL provided"
    exit 1
fi
if [[ ! "$URL" =~ ^https?:// ]]; then
    echo "Error: Invalid URL"
    exit 1
fi
FILENAME=$(echo -n "$URL" | sha256sum | awk '{print $1}').html
FILEPATH="$TMPFS_DIR/$FILENAME"
if [[ -f "$FILEPATH" ]]; then
    echo "File exists in tmpfs. Opening locally..."
    
else
    echo "File not found in tmpfs. Downloading..."
    wget -q -O "$FILEPATH" "$URL"
fi
xdg-open $FILEPATH

echo $FILEPATH
