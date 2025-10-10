#!/usr/bin/env bats

@test "sync_applicationset excludes devops and includes CSV envs" {
  run bash -lc './scripts/sync_applicationset.sh'
  [ $status -eq 0 ]
  # devops must not be present in generated ApplicationSet
  run bash -lc "grep -q \"name: 'whoami-devops'\" manifests/argocd/whoami-applicationset.yaml && echo found || echo notfound"
  [ "$output" = "notfound" ]
  # sample CSV envs should appear (as list elements)
  run bash -lc "grep -q '^\s*- env: dev$' manifests/argocd/whoami-applicationset.yaml"
  [ $status -eq 0 ]
  run bash -lc "grep -q '^\s*- env: uat$' manifests/argocd/whoami-applicationset.yaml"
  [ $status -eq 0 ]
  run bash -lc "grep -q '^\s*- env: prod$' manifests/argocd/whoami-applicationset.yaml"
  [ $status -eq 0 ]
}
