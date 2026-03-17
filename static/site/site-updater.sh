#!/bin/bash

# ==========================================
# Terminal Color Codes
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ==========================================
# Configuration Variables
# ==========================================
# Dynamically resolve the repository root based on the script's location
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_SRC="$REPO_DIR/"
DEST_DIR="/library/www/html/home"

printf "\n${CYAN}Starting site deployment and synchronization...${NC}\n"

# Ensure source directory exists before attempting to sync
if [ ! -d "$SITE_SRC" ]; then
    printf "${RED}Fatal Error: Source directory not found at $SITE_SRC.${NC}"
    exit 1
fi

# Ensure destination directory exists, create if it does not
if [ ! -d "$DEST_DIR" ]; then
    printf "Destination directory $DEST_DIR does not exist. Creating it now...\n"
    mkdir -p "$DEST_DIR"
fi

# ==========================================
# Audit Phase: Detect Destination Drift
# ==========================================
printf "Auditing $DEST_DIR for local modifications or orphaned files...\n"

# Perform a dry-run rsync (-n) to detect differences.
# Detects & delete files that are different at the destination not origin.
LOCAL_MODS=$(rsync -ani --delete "$SITE_SRC/" "$DEST_DIR/" | grep -E '^>fc|^\*deleting')

if [ -n "$LOCAL_MODS" ]; then
    printf "\n${YELLOW}WARNING: Destination drift detected.${NC}\n"
    printf "The following files in the live directory will be OVERWRITTEN or DELETED to match the clean repository state:\n"
    
    # Format the rsync output for readability
    echo "$LOCAL_MODS" | awk '{print "  - " $2}'
    echo ""
    
    read -p "Acknowledge and proceed with deployment? (y/N): " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        printf "${RED}Deployment aborted by user. The live site remains unchanged.${NC}\n"
        exit 1
    fi
else
    printf "No conflicts detected. Destination is clean or ready for new files.\n"
fi

# ==========================================
# Synchronization Phase
# ==========================================
printf "Synchronizing landing site data from local repository...\n"

# Execute the actual sync. The --delete flag ensures orphaned files are removed.
rsync -a --delete "$SITE_SRC/" "$DEST_DIR/"

printf "${GREEN}Deployment completed successfully.\n"
printf "The landing page has been mirrored from the local repository.${NC}\n"
