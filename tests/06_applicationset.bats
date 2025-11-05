#!/usr/bin/env bats

@test "sync_applicationset excludes devops and includes all business envs" {
  run bash -lc './scripts/sync_applicationset.sh'
  [ $status -eq 0 ]
  # devops must not be present in generated ApplicationSet
  run bash -lc "grep -q \"name: 'whoami-devops'\" manifests/argocd/whoami-applicationset.yaml && echo found || echo notfound"
  [ "$output" = "notfound" ]
  # 动态校验：CSV 中的业务集群（排除 devops）均应出现
  run bash -lc 'awk -F, "NR>1 && \$1!=\"devops\" && \$0 !~ /^[[:space:]]*#/ && NF>0 {print \$1}" config/environments.csv | while read -r env; do grep -q "^\\s*- env: ${env}$" manifests/argocd/whoami-applicationset.yaml || exit 1; done'
  [ $status -eq 0 ]
}

