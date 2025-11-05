#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=========================================="
echo "  Full Regression Test (Scripted Only)"
echo "=========================================="
echo "Start: $(date)"

# 1. Clean (timeout: 120s)
echo "[1/4] Cleaning environment..."
if ! timeout 120 bash "$ROOT_DIR/scripts/clean.sh" --all; then
	echo "✗ Clean failed or timeout"
	exit 1
fi

# 2. Bootstrap (timeout: 600s = 10min)
echo "[2/4] Running bootstrap..."
if ! timeout 600 bash "$ROOT_DIR/scripts/bootstrap.sh"; then
	echo "✗ Bootstrap failed or timeout"
	exit 1
fi

# 3. Create business clusters (timeout: 180s each)
echo "[3/4] Creating business clusters..."
clusters=$(awk -F, 'NR>1 && $1!="devops" && $0 !~ /^[[:space:]]*#/ && NF>0 {print $1}' "$ROOT_DIR/config/environments.csv")
for cluster in $clusters; do
	echo "  Creating $cluster..."
	if ! timeout 180 bash "$ROOT_DIR/scripts/create_env.sh" -n "$cluster"; then
		echo "  ✗ $cluster creation failed or timeout"
		exit 1
	fi
done

# 4. Run tests (timeout: 120s)
echo "[4/4] Running test suite..."
if ! timeout 120 bash "$ROOT_DIR/tests/run_tests.sh" all; then
	echo "✗ Tests failed or timeout"
	exit 1
fi

echo ""
echo "=========================================="
echo "  Regression Test Complete"
echo "=========================================="
echo "End: $(date)"
echo "Status: ✓ ALL PASS"

