#!/usr/bin/env bash
set -euo pipefail

ROLLOUT_TIMEOUT_MINUTES="${ROLLOUT_TIMEOUT_MINUTES:-5}"
STAGGER_DELAY_SECONDS="${STAGGER_DELAY_SECONDS:-30}"

tmp_files=()

cleanup() {
  if ((${#tmp_files[@]} > 0)); then
    rm -f "${tmp_files[@]}" || true
  fi
}

trap cleanup EXIT

echo "Checking if any pods need trust anchor refresh..."

trust_anchor="$(kubectl get configmap linkerd-identity-trust-roots -n linkerd -o jsonpath='{.data.ca-bundle\.crt}' || true)"
if [[ -z "$trust_anchor" ]]; then
  echo "ERROR: Could not read ca-bundle.crt from configmap linkerd-identity-trust-roots in namespace linkerd (not found or empty)"
  exit 1
fi

current_hash="$(printf '%s' "$trust_anchor" | sha256sum | awk '{print $1}')"
echo "Current trust anchor hash: $current_hash"

check_and_restart_workload() {
  local kind="$1" ns="$2" name="$3" pods_file="$4" rs_file="$5"
  local output needs_restart=false

  case "$kind" in
    Deployment)
      output=$(jq -s -r \
        --arg name "$name" \
        --arg hash "$current_hash" \
        '
        .
        | .[0].items as $pods
        | .[1].items as $replicasets
        | ( $replicasets
          | map(select(any(.metadata.ownerReferences[]?; .kind=="Deployment" and .name==$name)))
          | map(.metadata.name)
          | map({key: ., value: true}) | from_entries
        ) as $rs_set
        | $pods
        | select(any(.metadata.ownerReferences[]?; .kind=="ReplicaSet" and (.name | in($rs_set))))
        | (.metadata.annotations["linkerd.io/trust-root-sha256"] // "") as $pod_hash
        | if   $pod_hash == ""    then "WARN Pod \(.metadata.name) has no trust-root-sha256 annotation — skipping"
          elif $pod_hash != $hash then "STALE Pod \(.metadata.name) hash \($pod_hash) != \($hash)"
          else empty
          end
        ' "$pods_file" "$rs_file")
      ;;
    DaemonSet|StatefulSet)
      output="$(jq -r \
        --arg kind "$kind" \
        --arg name "$name" \
        --arg hash "$current_hash" \
        '
          .items[]
          | select(any(.metadata.ownerReferences[]?; .kind==$kind and .name==$name))
          | (.metadata.annotations["linkerd.io/trust-root-sha256"] // "") as $pod_hash
          | if   $pod_hash == ""    then "WARN Pod \(.metadata.name) has no trust-root-sha256 annotation — skipping"
            elif $pod_hash != $hash then "STALE Pod \(.metadata.name) hash \($pod_hash) != \($hash)"
            else empty
            end
        ' "$pods_file"
      )"
      ;;
    *)
      echo "WARNING: unsupported kind '$kind' — skipping $name" >&2
      return
      ;;
  esac

  [[ -n "$output" ]] && echo "$output"

  if grep -q '^STALE' <<< "$output"; then
    needs_restart=true
  fi

  if [[ "$needs_restart" != true ]]; then
    echo "Skipping $kind/$name (no pods with stale trust anchor)"
    return
  fi

  echo "Restarting $kind/$name"
  kubectl rollout restart "${kind,,}" "$name" -n "$ns"
  kubectl rollout status "${kind,,}" "$name" -n "$ns" --timeout="${ROLLOUT_TIMEOUT_MINUTES}m" || true
}

current_ns=""
pods_file=""
rs_file=""

echo "Checking the cluster for stale trust anchors"
while read -r kind ns name; do
  if [[ "$ns" != "$current_ns" ]]; then
    if [[ -n "$current_ns" ]]; then
      echo "Waiting ${STAGGER_DELAY_SECONDS}s before next namespace..."
      sleep "${STAGGER_DELAY_SECONDS}"
    fi
    current_ns="$ns"
    echo "> Namespace: $ns"
    pods_file="$(mktemp)"
    rs_file="$(mktemp)"
    tmp_files+=("$pods_file" "$rs_file")
    kubectl get pod -n "$ns" -o json >"$pods_file"
    kubectl get rs -n "$ns" -o json >"$rs_file"
  fi

  check_and_restart_workload "$kind" "$ns" "$name" "$pods_file" "$rs_file"
done < <(
  # This gets a list of all workloads in the cluster in the format of:
  # [kind] [namespace] [name]
  # The result is sorted so that workloads of linkerd is at the top
  # so that linkerd workloads are restarted prior the rest of the workloads.
  kubectl get ns,deploy,statefulset,daemonset -A -o json |
    jq -r '
      # Build a lookup of namespace -> linkerd inject annotation value
      ( .items
        | map(select(.kind == "Namespace"))
        | map({key: .metadata.name, value: (.metadata.annotations["linkerd.io/inject"] // "")})
        | from_entries
      ) as $ns_inject

      | [ .items[]
          | select(.kind != "Namespace")
          | (.spec.template.metadata.annotations["linkerd.io/inject"] // "") as $inject

          # Include workload if explicitly enabled, or if namespace is enabled and not explicitly disabled
          | select(
              $inject == "enabled"
              or ($inject != "disabled" and ($ns_inject[.metadata.namespace] // "") == "enabled")
            )
          | {kind, ns: .metadata.namespace, name: .metadata.name}
        ]

      # Sort with linkerd namespace first (in jq false < true), then by ns/kind/name
      | sort_by([(.ns != "linkerd"), .ns, .kind, .name])
      | .[]
      | "\(.kind) \(.ns) \(.name)"
    '
)

echo "Trust anchor refresh complete"
