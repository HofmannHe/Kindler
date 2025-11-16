#!/usr/bin/env bash
# HAProxy config modification unit tests (no container dependency)

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/tests/lib.sh"

echo "=========================================="
echo "HAProxy Config Unit Tests"
echo "=========================================="

tmp_cfg="$(mktemp /tmp/haproxy_cfg.XXXXXX.cfg)"
cp "$ROOT_DIR/compose/infrastructure/haproxy.cfg" "$tmp_cfg"
# Ensure dynamic sections start empty to get deterministic counts
sed -i '/# BEGIN DYNAMIC ACL/,/# END DYNAMIC ACL/{//!d}' "$tmp_cfg"
sed -i '/# BEGIN DYNAMIC USE_BACKEND/,/# END DYNAMIC USE_BACKEND/{//!d}' "$tmp_cfg"
sed -i '/# BEGIN DYNAMIC BACKENDS/,/# END DYNAMIC BACKENDS/{//!d}' "$tmp_cfg"

# Test mode: no reload, no docker validation, no network connect
export HAPROXY_CFG="$tmp_cfg"
export NO_RELOAD=1
export SKIP_VALIDATE=1
export SKIP_NETWORK_CONNECT=1

# 1) Add route for dev (idempotent)
"$ROOT_DIR/scripts/haproxy_route.sh" add dev --node-port 30080 >/tmp/unit_add1.log 2>&1 || true
"$ROOT_DIR/scripts/haproxy_route.sh" add dev --node-port 30080 >/tmp/unit_add2.log 2>&1 || true

acl_count=$(grep -cE "^[[:space:]]*acl[[:space:]]+host_dev[[:space:]]+hdr_reg\(host\)" "$tmp_cfg" || true)
ub_count=$(grep -cE "^[[:space:]]*use_backend[[:space:]]+be_dev[[:space:]]+if[[:space:]]+host_dev" "$tmp_cfg" || true)
be_count=$(grep -cE "^[[:space:]]*backend[[:space:]]+be_dev\b" "$tmp_cfg" || true)

assert_equals "2" "${acl_count:-0}" "dev ACL appears once per frontend after idempotent add"
assert_equals "2" "${ub_count:-0}" "dev use_backend appears once per frontend after idempotent add"
assert_equals "1" "${be_count:-0}" "dev backend appears exactly once after idempotent add"

# 2) Remove route for dev
"$ROOT_DIR/scripts/haproxy_route.sh" remove dev >/tmp/unit_rm.log 2>&1 || true

assert_equals "0" "$(grep -c "acl host_dev" "$tmp_cfg" || true)" "dev ACL removed"
assert_equals "0" "$(grep -c "use_backend be_dev if host_dev" "$tmp_cfg" || true)" "dev use_backend removed"
assert_equals "0" "$(grep -c "backend be_dev" "$tmp_cfg" || true)" "dev backend removed"

# 3) Prune dangling use_backend entries
# Prepare: add valid 'dev' then inject a ghost entry
"$ROOT_DIR/scripts/haproxy_route.sh" add dev --node-port 30080 >/tmp/unit_add3.log 2>&1 || true
sed -i "/# BEGIN DYNAMIC USE_BACKEND/a \\
  use_backend be_ghost if host_ghost" "$tmp_cfg"

# Sanity: both present now
assert_equals "2" "$(grep -c "use_backend be_dev if host_dev" "$tmp_cfg" || true)" "dev use_backend present pre-prune (both frontends)"
assert_equals "2" "$(grep -c "use_backend be_ghost if host_ghost" "$tmp_cfg" || true)" "ghost use_backend present pre-prune (both frontends)"

# Run prune (CSV will be used for allow-set)
NO_RELOAD=1 "$ROOT_DIR/scripts/haproxy_sync.sh" --prune >/tmp/unit_prune.log 2>&1 || true

# Expect dev remains, ghost removed
assert_equals "2" "$(grep -c "use_backend be_dev if host_dev" "$tmp_cfg" || true)" "dev use_backend remains after prune (both frontends)"
assert_equals "0" "$(grep -c "use_backend be_ghost if host_ghost" "$tmp_cfg" || true)" "ghost use_backend pruned"

# 4) Ensure haproxy_sync propagates haproxy_route failures (simulated)
echo ""
echo "[CASE 4] haproxy_sync fails when haproxy_route add fails (simulated)"

# Reset dynamic sections to empty for deterministic behaviour
sed -i '/# BEGIN DYNAMIC ACL/,/# END DYNAMIC ACL/{//!d}' "$tmp_cfg"
sed -i '/# BEGIN DYNAMIC USE_BACKEND/,/# END DYNAMIC USE_BACKEND/{//!d}' "$tmp_cfg"
sed -i '/# BEGIN DYNAMIC BACKENDS/,/# END DYNAMIC BACKENDS/{//!d}' "$tmp_cfg"

export HAPROXY_CFG="$tmp_cfg"
export NO_RELOAD=1
export SKIP_VALIDATE=1
export SKIP_NETWORK_CONNECT=1
export FORCE_HAPROXY_ROUTE_FAIL=1

# Stub kubectl to always report success (避免依赖真实集群)
stub_bin_dir="$(mktemp -d /tmp/haproxy_kubectl_stub.XXXXXX)"
cat >"$stub_bin_dir/kubectl" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$stub_bin_dir/kubectl"
OLD_PATH="$PATH"
PATH="$stub_bin_dir:$PATH"

sync_rc=0
if "$ROOT_DIR/scripts/haproxy_sync.sh" >/tmp/unit_sync_fail.log 2>&1; then
  sync_rc=0
else
  sync_rc=$?
fi

cond=0
if [ "$sync_rc" -ne 0 ]; then
  cond=1
fi
assert_equals "1" "$cond" "haproxy_sync.sh returns non-zero when haproxy_route add fails (simulated)"

# Ensure no dynamic ACLs for dev were written when failures are propagated
acl_after=$(grep -c "acl host_dev" "$tmp_cfg" || true)
assert_equals "0" "${acl_after:-0}" "no dynamic ACLs for dev written when haproxy_route add is forced to fail"

unset FORCE_HAPROXY_ROUTE_FAIL
PATH="$OLD_PATH"
rm -rf "$stub_bin_dir"

print_summary

# cleanup
rm -f "$tmp_cfg" /tmp/unit_add1.log /tmp/unit_add2.log /tmp/unit_rm.log /tmp/unit_add3.log /tmp/unit_prune.log /tmp/unit_sync_fail.log
