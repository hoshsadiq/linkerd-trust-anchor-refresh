#!/usr/bin/env bash
set -euo pipefail

ROLLOUT_TIMEOUT_MINUTES="${ROLLOUT_TIMEOUT_MINUTES:-5}"
STAGGER_DELAY_SECONDS="${STAGGER_DELAY_SECONDS:-30}"

tmp_files=()

cleanup() {
  if ((${#tmp_files[@]} > 0)); then
    rm -f "${tmp_files[@]}" 2>/dev/null || true
  fi
}

trap cleanup EXIT

date_to_epoch() {
  if date --version >/dev/null 2>&1; then
    date -d "$1" +%s
    return
  fi

  date -j -f "%b %e %H:%M:%S %Y %Z" "$1" "+%s"
}

echo "Checking if any pods need trust anchor refresh..."

cert_data="$(kubectl get secret linkerd-identity-issuer -n linkerd -o jsonpath='{.data.tls\.crt}')"
cert_not_before="$(base64 -d <<< "$cert_data" | openssl x509 -noout -startdate | cut -d= -f2)"
cert_epoch="$(date_to_epoch "$cert_not_before")"

echo "Certificate issued at: $cert_not_before (epoch: $cert_epoch)"

echo "=== Restarting Linkerd control plane ==="
while read -r deploy; do
  [[ -z "$deploy" ]] && continue
  echo "Restarting linkerd deployment: $deploy"
  kubectl rollout restart deployment "$deploy" -n linkerd
  kubectl rollout status deployment "$deploy" -n linkerd --timeout="${ROLLOUT_TIMEOUT_MINUTES}m" || true
done < <(kubectl get deploy -n linkerd -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

echo "=== Restarting data plane ==="

current_ns=""
pods_file=""
rs_file=""

while read -r kind ns name; do
  if [[ "$ns" != "$current_ns" ]]; then
    if [[ -n "$current_ns" ]]; then
      echo "Waiting ${STAGGER_DELAY_SECONDS}s before next namespace..."
      sleep "${STAGGER_DELAY_SECONDS}"
    fi
    current_ns="$ns"
    echo "--- Namespace: $ns ---"
    pods_file="$(mktemp)"
    rs_file="$(mktemp)"
    tmp_files+=("$pods_file" "$rs_file")
    kubectl get pod -n "$ns" -o json >"$pods_file"
    kubectl get rs -n "$ns" -o json >"$rs_file"
  fi

  has_old_pods="false"
  case "$kind" in
    Deployment)
      has_old_pods=$(
        jq -s -r \
          --arg deploy_name "$name" \
          --argjson cert_epoch "$cert_epoch" \
          '
            {pods: .[0].items, replicasets: .[1].items} as $all
            | ($all.replicasets
                | map(select(any(.metadata.ownerReferences[]?; .kind=="Deployment" and .name==$deploy_name)))
                | map(.metadata.name)
              ) as $rs_names
            | [$all.pods[]
                | select(any(.metadata.ownerReferences[]?; .kind=="ReplicaSet" and (.metadata.ownerReferences[]?.name as $on | $rs_names | index($on))))
                | select(.status.startTime? != null and (.status.startTime | fromdateiso8601) < $cert_epoch)
              ] | length > 0
          ' "$pods_file" "$rs_file"
      )
      ;;
    DaemonSet|StatefulSet)
      has_old_pods=$(
        jq -r \
          --arg kind "$kind" \
          --arg name "$name" \
          --argjson cert_epoch "$cert_epoch" \
          '
            [.items[]
              | select(any(.metadata.ownerReferences[]?; .kind==$kind and .name==$name))
              | select(.status.startTime? != null and (.status.startTime | fromdateiso8601) < $cert_epoch)
            ] | length > 0
          ' "$pods_file"
      )
      ;;
  esac

  if [[ "$has_old_pods" != "true" ]]; then
    echo "Skipping $kind/$name (no pods with stale trust anchor)"
    continue
  fi

  echo "Restarting $kind/$name"
  kubectl rollout restart "${kind,,}" "$name" -n "$ns"
  kubectl rollout status "${kind,,}" "$name" -n "$ns" --timeout="${ROLLOUT_TIMEOUT_MINUTES}m" || true
done < <(
  kubectl get ns,deploy,statefulset,daemonset -A -o json |
    jq -r '
      ( .items
        | map(select(.kind=="Namespace"))
        | map({key: .metadata.name, value: (.metadata.annotations["linkerd.io/inject"] // "")})
        | from_entries
      ) as $ns_inject
      |
      .items[]
      | select(.kind != "Namespace")
      | select(
          .spec.template.metadata.annotations["linkerd.io/inject"] == "enabled"
          or (
            (.spec.template.metadata.annotations["linkerd.io/inject"] // "") != "disabled"
            and ($ns_inject[.metadata.namespace] // "") == "enabled"
          )
        )
      | "\(.kind) \(.metadata.namespace) \(.metadata.name)"
    ' |
    sort -u
)

echo "=== Trust anchor refresh complete ==="
