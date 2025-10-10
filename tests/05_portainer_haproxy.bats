#!/usr/bin/env bats

setup() {
  run docker compose -f compose/infrastructure/docker-compose.yml up -d
  run bash -lc './scripts/portainer.sh up'
  # wait a moment for TLS endpoint
  run bash -lc 'for i in {1..20}; do curl -skI https://127.0.0.1:443 >/dev/null && break; sleep 1; done; true'
}

teardown() {
  # keep haproxy up for manual debugging; comment the line below to auto-stop
  # docker compose -f compose/haproxy/docker-compose.yml down -v || true
  :
}

@test "Portainer HTTP redirects to HTTPS (80->443)" {
  run bash -lc "curl -sI -H 'Host: portainer.devops.192.168.51.30.sslip.io' http://127.0.0.1 | head -n1"
  [[ "$status" -eq 0 ]]
  [[ "$output" =~ "301" ]]
}

@test "Portainer HTTPS responds (443)" {
  run bash -lc "curl -skI -H 'Host: portainer.devops.192.168.51.30.sslip.io' https://127.0.0.1 | head -n1"
  [[ "$status" -eq 0 ]]
  [[ "$output" =~ "200" || "$output" =~ "302" ]]
}
