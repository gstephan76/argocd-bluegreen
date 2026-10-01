#!/usr/bin/env bash
set -Eeuo pipefail

MESH_CONTROL_PLANE_NAMESPACE="${MESH_CONTROL_PLANE_NAMESPACE:-istio-system}"
ISTIO_NAME="${ISTIO_NAME:-default}"
ISTIOCNI_NAMESPACE="${ISTIOCNI_NAMESPACE:-istio-cni}"
ISTIOCNI_NAME="${ISTIOCNI_NAME:-default}"
MIN_OSSM_VERSION="${MIN_OSSM_VERSION:-3.4.0}"

die(){ echo "ERROR: $*" >&2; exit 1; }
pass(){ echo "[PASS] $*"; }

for c in oc awk sort jq; do
  command -v "$c" >/dev/null 2>&1 || die "$c not found"
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-canary-mesh.sh
source "${SCRIPT_DIR}/lib-canary-mesh.sh"
mesh_install_wrappers

oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"

for crd in \
  istios.sailoperator.io \
  istiocnis.sailoperator.io \
  gateways.networking.istio.io \
  virtualservices.networking.istio.io
do
  oc get crd "$crd" >/dev/null 2>&1 || die "Missing CRD: $crd"
done
pass "Sail and Istio networking CRDs are present"

ossm_version="$(
  oc get csv -A \
    -o custom-columns='NAME:.metadata.name,PHASE:.status.phase' \
    --no-headers 2>/dev/null |
  awk '
    $2 == "Succeeded" && $1 ~ /^servicemeshoperator3[.]v[0-9]+[.][0-9]+[.][0-9]+/ {
      v=$1
      sub(/^servicemeshoperator3[.]v/, "", v)
      sub(/[^0-9.].*$/, "", v)
      print v
    }
  ' |
  sort -V |
  tail -1
)"
[[ -n "$ossm_version" ]] || die "No Succeeded OpenShift Service Mesh 3 operator CSV was found"
printf '%s\n%s\n' "$MIN_OSSM_VERSION" "$ossm_version" | sort -V -C || \
  die "OpenShift Service Mesh ${ossm_version} is older than required ${MIN_OSSM_VERSION}"
pass "OpenShift Service Mesh ${ossm_version} satisfies >= ${MIN_OSSM_VERSION}"

oc get istios.sailoperator.io "$ISTIO_NAME" \
  -n "$MESH_CONTROL_PLANE_NAMESPACE" >/dev/null 2>&1 || \
  die "Istio/${ISTIO_NAME} not found in ${MESH_CONTROL_PLANE_NAMESPACE}"

control_plane_namespace="$(
  oc get istios.sailoperator.io "$ISTIO_NAME" \
    -n "$MESH_CONTROL_PLANE_NAMESPACE" \
    -o jsonpath='{.spec.namespace}'
)"
[[ "$control_plane_namespace" == "$MESH_CONTROL_PLANE_NAMESPACE" ]] || \
  die "Istio/${ISTIO_NAME} spec.namespace=${control_plane_namespace:-empty}; expected ${MESH_CONTROL_PLANE_NAMESPACE}"

oc wait \
  --for=condition=Ready \
  "istios.sailoperator.io/${ISTIO_NAME}" \
  -n "$MESH_CONTROL_PLANE_NAMESPACE" \
  --timeout=10s >/dev/null
pass "Istio/${ISTIO_NAME} is Ready in ${MESH_CONTROL_PLANE_NAMESPACE}"

oc get istios.sailoperator.io "$ISTIO_NAME" \
  -n "$MESH_CONTROL_PLANE_NAMESPACE" \
  -o json |
jq -e '
  any(
    .spec.values.meshConfig.discoverySelectors[]?;
    .matchLabels["istio-discovery"] == "enabled"
  )
' >/dev/null || \
  die "Istio/${ISTIO_NAME} does not select namespaces labeled istio-discovery=enabled"
pass "Istio discovery selector accepts istio-discovery=enabled"

oc get istiocnis.sailoperator.io "$ISTIOCNI_NAME" \
  -n "$ISTIOCNI_NAMESPACE" >/dev/null 2>&1 || \
  die "IstioCNI/${ISTIOCNI_NAME} not found in ${ISTIOCNI_NAMESPACE}"

oc wait \
  --for=condition=Ready \
  "istiocnis.sailoperator.io/${ISTIOCNI_NAME}" \
  -n "$ISTIOCNI_NAMESPACE" \
  --timeout=10s >/dev/null
pass "IstioCNI/${ISTIOCNI_NAME} is Ready in ${ISTIOCNI_NAMESPACE}"

echo
echo "OSSM 3.4+ prerequisite check passed."
echo "Control plane: ${MESH_CONTROL_PLANE_NAMESPACE}/Istio/${ISTIO_NAME}"
