#!/usr/bin/env bats

load_config() { source config/clusters.env; }

@test "providers default as expected" {
  run bash -lc 'source config/clusters.env && echo "$PROVIDER_DEV $PROVIDER_UAT $PROVIDER_PROD"'
  [ $status -eq 0 ]
  [ "$output" = "kind kind kind" ]
}

@test "ports default as expected" {
  run bash -lc 'source config/clusters.env && echo "$DEV_HTTP $DEV_HTTPS $UAT_HTTP $UAT_HTTPS $PROD_HTTP $PROD_HTTPS"'
  [ $status -eq 0 ]
  [ "$output" = "18090 18443 28080 28443 38080 38443" ]
}
