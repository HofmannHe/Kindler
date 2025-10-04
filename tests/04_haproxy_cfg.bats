#!/usr/bin/env bats

@test "haproxy cfg anchors and frontends exist" {
  run test -f compose/haproxy/haproxy.cfg
  [ $status -eq 0 ]
  run grep -q "BEGIN DYNAMIC ACL" compose/haproxy/haproxy.cfg
  [ $status -eq 0 ]
  run grep -q "BEGIN DYNAMIC BACKENDS" compose/haproxy/haproxy.cfg
  [ $status -eq 0 ]
  run grep -q "fe_portainer_https" compose/haproxy/haproxy.cfg
  [ $status -eq 0 ]
}
