#!/usr/bin/env bash

set -euo pipefail

version="$1"

patch "charts/linkerd-trust-anchor-refresh/Chart.yaml" <<< $(
  command diff -U0 -w -b --ignore-blank-lines \
    <(yq '.' charts/linkerd-trust-anchor-refresh/Chart.yaml) \
    <(
      version="$version" yq eval "
        .version = strenv(version) |
        .appVersion =  strenv(version)
      " charts/linkerd-trust-anchor-refresh/Chart.yaml
    )
  )

patch "charts/linkerd-trust-anchor-refresh/values.yaml" <<< $(
  command diff -U0 -w -b --ignore-blank-lines \
    <(yq '.' charts/linkerd-trust-anchor-refresh/values.yaml) \
    <(version="$version" yq eval ".image.tag = strenv(version)" charts/linkerd-trust-anchor-refresh/values.yaml)
  )
