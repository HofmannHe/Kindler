#!/usr/bin/env bats

@test "directories exist" {
  run test -d "manifests" -a -d "compose" -a -d "scripts" -a -d "config"
  [ $status -eq 0 ]
}

@test "docs present" {
  run test -f "docs/TESTING_GUIDE.md" -a -f "docs/ARCHITECTURE.md"
  [ $status -eq 0 ]
}
