#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$ROOT_DIR/compose/infrastructure/haproxy.cfg"

echo "=========================================="
echo "HAProxy Devops Routing Regression Test"
echo "=========================================="

fail=0; total=0

chk() {
  local ok=1 msg="$1"; shift
  if eval "$*"; then
    echo "  ✓ $msg"; total=$((total+1))
  else
    echo "  ✗ $msg"; fail=$((fail+1)); total=$((total+1))
  fi
}

# 1) 不应存在 devops 泛匹配 ACL
chk "no generic devops ACL" \
  "! rg -n 'acl\\s+host_devops' -S \"$CFG\" >/dev/null 2>&1"

# 2) 不应存在 use_backend be_devops
chk "no use_backend be_devops" \
  "! rg -n 'use_backend\\s+be_devops' -S \"$CFG\" >/dev/null 2>&1"

# 3) 明确的管理路由存在
chk "has explicit portainer route" \
  "rg -n 'use_backend\\s+be_portainer\\s+if\\s+host_portainer' -S \"$CFG\" >/dev/null 2>&1"
chk "has explicit kindler route" \
  "rg -n 'use_backend\\s+be_kindler\\s+if\\s+host_kindler' -S \"$CFG\" >/dev/null 2>&1"
chk "has explicit argocd route" \
  "rg -n 'use_backend\\s+be_argocd\\s+if\\s+host_argocd' -S \"$CFG\" >/dev/null 2>&1"

echo ""
echo "Total: $total"
echo "Failed: $fail"
if [ $fail -eq 0 ]; then
  echo "Status: ✓ ALL PASS"; exit 0
else
  echo "Status: ✗ FAILED"; exit 1
fi

