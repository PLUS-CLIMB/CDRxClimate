#!/bin/bash
# Benchmark: One-pass vs Two-pass GDAL processing

CONFIG="config_simple.txt"
INPUT_DIR="../../test/test_data"
OUT_DIR_1P="../../test/outputs/gdal_onepass"
OUT_DIR_2P="../../test/outputs/gdal_twopass"

echo "=========================================="
echo "GDAL Processing Benchmark: 1-Pass vs 2-Pass"
echo "=========================================="
echo ""

# Test ONE-PASS
echo "Running ONE-PASS (combined clip+resample)..."
rm -rf "$OUT_DIR_1P"
START=$(date +%s%N)
./daily_gdal_onepass.sh "$CONFIG" "$INPUT_DIR" "$OUT_DIR_1P" > /tmp/onepass.log 2>&1
END=$(date +%s%N)
TIME_1P=$(( (END - START) / 1000000 ))  # Convert to ms
SIZE_1P=$(du -sh "$OUT_DIR_1P" 2>/dev/null | cut -f1)
MEM_1P=$(grep -i "memory" /tmp/onepass.log | tail -1 || echo "N/A")

echo "✓ One-pass completed in ${TIME_1P}ms"
echo "  Output size: $SIZE_1P"
echo ""

# Test TWO-PASS
echo "Running TWO-PASS (clip then resample)..."
rm -rf "$OUT_DIR_2P"
START=$(date +%s%N)
./daily_gdal_twopass.sh "$CONFIG" "$INPUT_DIR" "$OUT_DIR_2P" > /tmp/twopass.log 2>&1
END=$(date +%s%N)
TIME_2P=$(( (END - START) / 1000000 ))  # Convert to ms
SIZE_2P=$(du -sh "$OUT_DIR_2P" 2>/dev/null | cut -f1)
MEM_2P=$(grep -i "memory" /tmp/twopass.log | tail -1 || echo "N/A")

echo "✓ Two-pass completed in ${TIME_2P}ms"
echo "  Output size: $SIZE_2P"
echo ""

# Compare
echo "=========================================="
echo "RESULTS COMPARISON"
echo "=========================================="
DIFF=$((TIME_1P - TIME_2P))
DIFF_PCT=$((DIFF * 100 / TIME_1P))

echo "Time:       One-pass: ${TIME_1P}ms | Two-pass: ${TIME_2P}ms"
if [[ $DIFF -gt 0 ]]; then
    echo "            Two-pass is ${DIFF}ms FASTER ($(abs $DIFF_PCT)% better)"
else
    echo "            One-pass is $((0 - DIFF))ms FASTER ($((0 - DIFF_PCT))% better)"
fi
echo ""
echo "Output:     One-pass: $SIZE_1P | Two-pass: $SIZE_2P"
echo ""
echo "Full logs: /tmp/onepass.log | /tmp/twopass.log"
