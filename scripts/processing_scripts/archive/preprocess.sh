#!/bin/bash

# Preprocessing Wrapper Script
# Simple dispatcher to run daily or monthly preprocessing
# Usage: pre-processing.sh [daily|monthly]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:-daily}"

case "$MODE" in
    daily)
        echo "Starting daily preprocessing..."
        bash "$SCRIPT_DIR/daily_preprocess.sh" "$SCRIPT_DIR/daily_config.txt"
        ;;
    monthly)
        echo "Starting monthly preprocessing..."
        bash "$SCRIPT_DIR/monthly_preprocess.sh" "$SCRIPT_DIR/monthly_config.txt"
        ;;
    *)
        echo "Usage: $0 [daily|monthly]"
        echo ""
        echo "Examples:"
        echo "  $0 daily    # Process daily data"
        echo "  $0 monthly  # Process monthly data"
        exit 1
        ;;
esac

echo "Done!"
