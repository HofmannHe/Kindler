#!/usr/bin/env bats

@test "haproxy cfg anchors and frontends exist" {
  run test -f compose/infrastructure/haproxy.cfg
  [ $status -eq 0 ]
  run grep -q "BEGIN DYNAMIC ACL" compose/infrastructure/haproxy.cfg
  [ $status -eq 0 ]
  run grep -q "BEGIN DYNAMIC BACKENDS" compose/infrastructure/haproxy.cfg
  [ $status -eq 0 ]
  run grep -q "frontend fe_http" compose/infrastructure/haproxy.cfg
  [ $status -eq 0 ]
  run grep -q "frontend fe_https" compose/infrastructure/haproxy.cfg
  [ $status -eq 0 ]
}
