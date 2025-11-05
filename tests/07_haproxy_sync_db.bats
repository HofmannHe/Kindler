#!/usr/bin/env bats

setup() {
  ROOT_DIR="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/.." && pwd)"
  CFG="$ROOT_DIR/compose/infrastructure/haproxy.cfg"
}

@test "haproxy_sync uses SQLite clusters as source-of-truth when available" {
  # Require haproxy container and webui backend (SQLite) running, otherwise skip
  run bash -lc 'docker ps --format "{{.Names}}" | grep -q "^haproxy-gw$"'
  if [ $status -ne 0 ]; then
    skip "haproxy-gw not running"
  fi
  run bash -lc 'docker ps --format "{{.Names}}" | grep -q "^kindler-webui-backend$"'
  if [ $status -ne 0 ]; then
    skip "kindler-webui-backend not running"
  fi

  # Ensure there is at least one business cluster in DB (non-devops); otherwise skip
  run bash -lc "docker exec kindler-webui-backend sqlite3 /data/kindler-webui/kindler.db \"select count(*) from clusters where name!='devops';\""
  [ $status -eq 0 ]
  count="${output:-0}"
  if [ "$count" -eq 0 ]; then
    skip "no business clusters in DB"
  fi

  # Run sync (DB-driven) and check ACL entries exist for DB clusters
  run bash -lc "cd '$ROOT_DIR' && NO_RELOAD=1 ./scripts/haproxy_sync.sh --prune"
  [ $status -eq 0 ]

  # Verify haproxy.cfg contains host_ ACLs for each DB cluster
  run bash -lc "docker exec kindler-webui-backend sqlite3 /data/kindler-webui/kindler.db \"select name from clusters where name!='devops' order by name;\""
  [ $status -eq 0 ]
  while IFS= read -r env; do
    [ -n "$env" ] || continue
    run bash -lc "grep -q \"acl host_${env} \" '$CFG'"
    [ $status -eq 0 ]
  done <<< "$output"
}

