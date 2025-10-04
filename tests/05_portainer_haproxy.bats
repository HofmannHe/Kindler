#!/usr/bin/env bats

setup() {
  run docker compose -f compose/haproxy/docker-compose.yml up -d
  run bash -lc './scripts/portainer.sh up'
  # wait a moment for TLS endpoint
  run bash -lc 'for i in {1..20}; do curl -skI https://127.0.0.1:23343 >/dev/null && break; sleep 1; done; true'
}

teardown() {
  # keep haproxy up for manual debugging; comment the line below to auto-stop
  # docker compose -f compose/haproxy/docker-compose.yml down -v || true
  :
}

@test "Portainer HTTP redirects to HTTPS (23380->23343)" {
  run bash -lc "curl -sI http://127.0.0.1:23380 | head -n1"
  [[ "$status" -eq 0 ]]
  [[ "$output" =~ "301" ]]
}

@test "Portainer HTTPS responds (23343)" {
  run bash -lc "curl -skI https://127.0.0.1:23343 | head -n1"
  [[ "$status" -eq 0 ]]
  [[ "$output" =~ "200" || "$output" =~ "302" ]]
}
