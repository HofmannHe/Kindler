#!/usr/bin/env bats

ROOT_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"

lookup_provider() {
  local env="$1"
  awk -F',' -v env="$env" '
    $0 ~ /^[[:space:]]*#/ { next }
    NF < 2 { next }
    {
      gsub(/[[:space:]]/, "", $1)
      gsub(/[[:space:]]/, "", $2)
      if ($1 == env) {
        print $2
        exit
      }
    }
  ' "$ROOT_DIR/config/environments.csv"
}

assert_provider_dry_run() {
  local env="$1"
  local provider
  provider="$(lookup_provider "$env")"
  [ -n "$provider" ] || provider="k3d"
  run bash -lc "cd '$ROOT_DIR' && DRY_RUN=1 scripts/cluster.sh create $env"
  [ $status -eq 0 ]
  if [ "$provider" = "kind" ]; then
    [[ "$output" == *"kind create cluster"* ]]
  else
    [[ "$output" == *"k3d cluster create"* ]]
  fi
}

@test "dev create respects provider (dry-run)" {
  assert_provider_dry_run "dev"
}

@test "uat create respects provider (dry-run)" {
  assert_provider_dry_run "uat"
}

@test "prod create respects provider (dry-run)" {
  assert_provider_dry_run "prod"
}

@test "usage without args" {
  run scripts/cluster.sh
  [ $status -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
}
