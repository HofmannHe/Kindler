#!/usr/bin/env bats

@test "dev create uses kind (dry-run)" {
  run bash -lc 'DRY_RUN=1 scripts/cluster.sh create dev'
  [ $status -eq 0 ]
  [[ "$output" == *"kind create cluster"* ]]
}

@test "uat create uses kind (dry-run)" {
  run bash -lc 'DRY_RUN=1 scripts/cluster.sh create uat'
  [ $status -eq 0 ]
  [[ "$output" == *"kind create cluster"* ]]
}

@test "prod create uses kind (dry-run)" {
  run bash -lc 'DRY_RUN=1 scripts/cluster.sh create prod'
  [ $status -eq 0 ]
  [[ "$output" == *"kind create cluster"* ]]
}

@test "usage without args" {
  run scripts/cluster.sh
  [ $status -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
}
