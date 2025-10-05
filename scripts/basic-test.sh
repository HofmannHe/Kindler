#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

fail=0
note() { printf "[NOTE] %s\n" "$*"; }
ok() { printf "[ OK ] %s\n" "$*"; }
err() { printf "[FAIL] %s\n" "$*"; fail=1; }

test -d manifests && ok "manifests dir exists" || err "missing manifests dir"
test -f compose/infrastructure/haproxy.cfg && ok "haproxy.cfg exists" || err "missing haproxy.cfg"
grep -q "dev.local" compose/infrastructure/haproxy.cfg && ok "haproxy routes dev.local" || err "haproxy missing dev.local"

DRY_RUN=1 out=$(scripts/cluster.sh create dev 2>&1 || true)
echo "$out" | grep -q "kind create cluster" && ok "dev uses kind (dry-run)" || err "dev not using kind"

DRY_RUN=1 out=$(scripts/cluster.sh create uat 2>&1 || true)
echo "$out" | grep -q "kind create cluster" && ok "uat uses kind (dry-run)" || err "uat not using kind"

exit $fail
