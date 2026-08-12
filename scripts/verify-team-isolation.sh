#!/usr/bin/env bash
set -Eeuo pipefail
set +x

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
export PATH="$repo_root/.tools/gke-auth/bin:$PATH"
bash "$repo_root/scripts/ensure-gke-auth-plugin.sh"

expected_project="schwab-assessment-gke"
expected_configuration="schwab-assessment"
expected_account="satish.cse7@gmail.com"
runtime_dir="$repo_root/.tmp"
work_dir=""

fail() {
  printf 'verify-team-isolation: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local exit_code=$?
  if [[ -n "$work_dir" && -d "$work_dir" ]]; then
    case "$work_dir" in
      "$runtime_dir"/verify-team-isolation.*) rm -rf -- "$work_dir" ;;
    esac
  fi
  trap - EXIT INT TERM
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${GCLOUD_CONFIGURATION:?GCLOUD_CONFIGURATION is required}"
[[ "$PROJECT_ID" == "$expected_project" ]] || fail "expected project $expected_project"
[[ "$GCLOUD_CONFIGURATION" == "$expected_configuration" ]] \
  || fail "expected gcloud configuration $expected_configuration"
for command_name in gcloud git jq kubectl timeout; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required"
done
for override_name in \
  CLOUDSDK_AUTH_ACCESS_TOKEN CLOUDSDK_AUTH_ACCESS_TOKEN_FILE \
  CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT \
  GOOGLE_APPLICATION_CREDENTIALS GOOGLE_OAUTH_ACCESS_TOKEN; do
  [[ -z "${!override_name:-}" ]] || fail "$override_name must be unset"
done
active_account="$(gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value account 2>/dev/null)"
configured_project="$(gcloud --configuration="$GCLOUD_CONFIGURATION" config get-value project 2>/dev/null)"
[[ "$active_account" == "$expected_account" ]] \
  || fail "expected account $expected_account, found ${active_account:-<none>}"
[[ "$configured_project" == "$PROJECT_ID" ]] \
  || fail "expected project $PROJECT_ID, found ${configured_project:-<none>}"

export CLOUDSDK_ACTIVE_CONFIG_NAME="$GCLOUD_CONFIGURATION"
export CLOUDSDK_CORE_ACCOUNT="$expected_account"
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"
mkdir -p "$runtime_dir"
work_dir="$(mktemp -d "$runtime_dir/verify-team-isolation.XXXXXX")"
git check-ignore --quiet -- "$work_dir" || fail "the temporary isolation directory is not ignored"

cli_path() {
  case "$(uname -s)" in
    MINGW* | MSYS*) cygpath -w "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

prepare_kubeconfig() {
  local path="$1" identity="$2" context cluster region source_context
  local cli
  cli="$(cli_path "$path")"
  printf '%s\n' 'apiVersion: v1' 'kind: Config' 'preferences: {}' \
    'clusters: []' 'contexts: []' 'users: []' >"$path"
  chmod 600 "$path" 2>/dev/null || true
  for spec in \
    'gke-risk-usc1|gke-risk-usc1|us-central1' \
    'gke-risk-use4|gke-risk-use4|us-east4'; do
    IFS='|' read -r context cluster region <<<"$spec"
    if [[ -n "$identity" ]]; then
      CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT="$identity" KUBECONFIG="$cli" \
        timeout --foreground --signal=INT 2m \
        gcloud --configuration="$GCLOUD_CONFIGURATION" \
          --account="$expected_account" --project="$PROJECT_ID" \
          --impersonate-service-account="$identity" \
          container clusters get-credentials "$cluster" --region="$region" >/dev/null
    else
      KUBECONFIG="$cli" timeout --foreground --signal=INT 2m \
        gcloud --configuration="$GCLOUD_CONFIGURATION" \
          --account="$expected_account" --project="$PROJECT_ID" \
          container clusters get-credentials "$cluster" --region="$region" >/dev/null
    fi
    source_context="$(KUBECONFIG="$cli" kubectl config current-context | tr -d '\r')"
    if [[ "$source_context" != "$context" ]]; then
      KUBECONFIG="$cli" kubectl config rename-context "$source_context" "$context" >/dev/null
    fi
  done

  [[ "$(KUBECONFIG="$cli" kubectl config get-contexts -o name | tr -d '\r' | sort)" \
      == $'gke-risk-usc1\ngke-risk-use4' ]] \
    || fail "isolated kubeconfig has an unexpected context inventory"
}

kube() {
  local path="$1" identity="$2"
  shift 2
  local cli
  cli="$(cli_path "$path")"
  if [[ -n "$identity" ]]; then
    CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT="$identity" KUBECONFIG="$cli" \
      kubectl "$@"
  else
    KUBECONFIG="$cli" kubectl "$@"
  fi
}

expect_can_i() {
  local path="$1" identity="$2" context="$3" expected="$4"
  local verb="$5" resource="$6" namespace="$7" actual command_status
  set +e
  actual="$(kube "$path" "$identity" --context="$context" --namespace="$namespace" \
    --request-timeout=20s auth can-i "$verb" "$resource" | tr -d '\r')"
  command_status=$?
  set -e
  actual="${actual%%[[:space:]]*}"
  [[ "$actual" == "yes" && "$command_status" == "0" \
    || "$actual" == "no" && "$command_status" == "1" ]] \
    || fail "$context $identity could not evaluate '$verb $resource' in $namespace"
  [[ "$actual" == "$expected" ]] \
    || fail "$context $identity expected '$expected' for '$verb $resource' in $namespace, received '$actual'"
}

operator_kubeconfig="$work_dir/operator.kubeconfig"
app_a_kubeconfig="$work_dir/app-a.kubeconfig"
app_b_kubeconfig="$work_dir/app-b.kubeconfig"
app_a_deployer="currency-app-a-deployer@$PROJECT_ID.iam.gserviceaccount.com"
app_b_deployer="currency-app-b-deployer@$PROJECT_ID.iam.gserviceaccount.com"
prepare_kubeconfig "$operator_kubeconfig" ""
prepare_kubeconfig "$app_a_kubeconfig" "$app_a_deployer"
prepare_kubeconfig "$app_b_kubeconfig" "$app_b_deployer"

for context in gke-risk-usc1 gke-risk-use4; do
  namespaces_json="$(kube "$operator_kubeconfig" "" --context="$context" \
    --request-timeout=20s get namespaces currency-app-a currency-app-b currency-observability -o json)"
  jq -e '
    ([.items[].metadata.name] | sort) == ["currency-app-a", "currency-app-b", "currency-observability"] and
    all(.items[];
      .metadata.labels["pod-security.kubernetes.io/enforce"] == "restricted" and
      .metadata.labels["pod-security.kubernetes.io/audit"] == "restricted" and
      .metadata.labels["pod-security.kubernetes.io/warn"] == "restricted")
  ' <<<"$namespaces_json" >/dev/null || fail "$context namespace Pod Security labels changed"

  legacy_namespace="$(kube "$operator_kubeconfig" "" --context="$context" \
    --request-timeout=20s get namespace risk-system --ignore-not-found -o name)" \
    || fail "$context could not prove that the legacy risk-system namespace is absent"
  [[ -z "$legacy_namespace" ]] \
    || fail "$context still contains the legacy risk-system namespace"

  for namespace in currency-app-a currency-app-b; do
    quota_json="$(kube "$operator_kubeconfig" "" --context="$context" --namespace="$namespace" \
      --request-timeout=20s get resourcequota application-capacity -o json)"
    jq -e --arg namespace "$namespace" '
      .spec.hard == (if $namespace == "currency-app-a" then {
        "configmaps":"8",
        "count/deployments.apps":"6",
        "count/horizontalpodautoscalers.autoscaling":"6",
        "limits.cpu":"6",
        "limits.memory":"16Gi",
        "pods":"12",
        "requests.cpu":"3",
        "requests.memory":"12Gi",
        "services":"4"
      } else {
        "configmaps":"8",
        "count/deployments.apps":"3",
        "count/horizontalpodautoscalers.autoscaling":"3",
        "limits.cpu":"6",
        "limits.memory":"12Gi",
        "pods":"10",
        "requests.cpu":"3",
        "requests.memory":"8Gi",
        "services":"4"
      } end)
    ' \
      <<<"$quota_json" >/dev/null || fail "$context/$namespace quota contract changed"
    secrets_json="$(kube "$operator_kubeconfig" "" --context="$context" --namespace="$namespace" \
      --request-timeout=20s get secrets -o json)"
    jq -e '(.items | length) == 0' <<<"$secrets_json" >/dev/null \
      || fail "$context/$namespace contains a stored Kubernetes Secret"
    roles_json="$(kube "$operator_kubeconfig" "" --context="$context" --namespace="$namespace" \
      --request-timeout=20s get roles -o json)"
    rolebindings_json="$(kube "$operator_kubeconfig" "" --context="$context" --namespace="$namespace" \
      --request-timeout=20s get rolebindings -o json)"
    jq -e '([.items[].metadata.name] | sort) == ["application-deployer"]' \
      <<<"$roles_json" >/dev/null \
      || fail "$context/$namespace must not grant a production developer Role"
    jq -e '([.items[].metadata.name] | sort) == ["application-deployer"]' \
      <<<"$rolebindings_json" >/dev/null \
      || fail "$context/$namespace must not grant a production developer RoleBinding"
    role_json="$(kube "$operator_kubeconfig" "" --context="$context" --namespace="$namespace" \
      --request-timeout=20s get role application-deployer -o json)"
    jq -e '
      any(.rules[]; (.apiGroups | index("apps")) != null and
        (.resources | index("deployments")) != null and (.verbs | index("patch")) != null) and
      all(.rules[]; ((.resources | index("secrets")) == null) and
        ((.resources | index("services")) == null) and
        ((.resources | index("serviceaccounts")) == null) and
        ((.resources | index("pods/exec")) == null))
    ' <<<"$role_json" >/dev/null || fail "$context/$namespace deployer Role is overbroad or incomplete"
  done

  observability_quota="$(kube "$operator_kubeconfig" "" --context="$context" \
    --namespace=currency-observability --request-timeout=20s \
    get resourcequota evidence-capacity -o json)"
  jq -e '.spec.hard == {
    "configmaps":"4",
    "count/jobs.batch":"1",
    "limits.cpu":"500m",
    "limits.ephemeral-storage":"640Mi",
    "limits.memory":"768Mi",
    "persistentvolumeclaims":"0",
    "pods":"1",
    "requests.cpu":"250m",
    "requests.ephemeral-storage":"256Mi",
    "requests.memory":"512Mi",
    "secrets":"0",
    "services":"0"
  }' <<<"$observability_quota" >/dev/null \
    || fail "$context/currency-observability quota contract changed"
  observability_roles="$(kube "$operator_kubeconfig" "" --context="$context" \
    --namespace=currency-observability --request-timeout=20s get roles -o json)"
  observability_bindings="$(kube "$operator_kubeconfig" "" --context="$context" \
    --namespace=currency-observability --request-timeout=20s get rolebindings -o json)"
  jq -e '(.items | length) == 0' <<<"$observability_roles" >/dev/null \
    || fail "$context/currency-observability must not grant a namespaced Role"
  jq -e '(.items | length) == 0' <<<"$observability_bindings" >/dev/null \
    || fail "$context/currency-observability must not grant a namespaced RoleBinding"

  app_a_binding="$(kube "$operator_kubeconfig" "" --context="$context" --namespace=currency-app-a \
    --request-timeout=20s get rolebinding application-deployer -o json)"
  app_b_binding="$(kube "$operator_kubeconfig" "" --context="$context" --namespace=currency-app-b \
    --request-timeout=20s get rolebinding application-deployer -o json)"
  jq -e --arg subject "$app_a_deployer" \
    '.roleRef.name == "application-deployer" and .subjects == [{"apiGroup":"rbac.authorization.k8s.io","kind":"User","name":$subject}]' \
    <<<"$app_a_binding" >/dev/null || fail "$context App A deployer binding changed"
  jq -e --arg subject "$app_b_deployer" \
    '.roleRef.name == "application-deployer" and .subjects == [{"apiGroup":"rbac.authorization.k8s.io","kind":"User","name":$subject}]' \
    <<<"$app_b_binding" >/dev/null || fail "$context App B deployer binding changed"

  app_a_sa="$(kube "$operator_kubeconfig" "" --context="$context" --namespace=currency-app-a \
    --request-timeout=20s get serviceaccount app-a-gateway -o json)"
  app_b_sa="$(kube "$operator_kubeconfig" "" --context="$context" --namespace=currency-app-b \
    --request-timeout=20s get serviceaccount app-b-engine -o json)"
  grafana_sa="$(kube "$operator_kubeconfig" "" --context="$context" --namespace=currency-observability \
    --request-timeout=20s get serviceaccount currency-grafana -o json)"
  jq -e --arg caller "currency-app-a-caller@$PROJECT_ID.iam.gserviceaccount.com" \
    '.automountServiceAccountToken == false and .metadata.annotations["iam.gke.io/gcp-service-account"] == $caller' \
    <<<"$app_a_sa" >/dev/null || fail "$context App A KSA identity changed"
  jq -e --arg telemetry "currency-app-b-telemetry@$PROJECT_ID.iam.gserviceaccount.com" \
    '.automountServiceAccountToken == false and .metadata.annotations["iam.gke.io/gcp-service-account"] == $telemetry' \
    <<<"$app_b_sa" >/dev/null || fail "$context App B telemetry identity changed"
  jq -e --arg reader "grafana-reader@$PROJECT_ID.iam.gserviceaccount.com" \
    '.automountServiceAccountToken == false and .metadata.annotations["iam.gke.io/gcp-service-account"] == $reader' \
    <<<"$grafana_sa" >/dev/null || fail "$context Grafana evidence identity changed"

  observability_inventory="$(kube "$operator_kubeconfig" "" --context="$context" \
    --namespace=currency-observability --request-timeout=20s get all -o json)"
  jq -e '([.items[]?] | length) == 0' <<<"$observability_inventory" >/dev/null \
    || fail "$context must have no standing observability workloads or Services"
  observability_secrets="$(kube "$operator_kubeconfig" "" --context="$context" \
    --namespace=currency-observability --request-timeout=20s get secrets -o json)"
  jq -e '([.items[]?] | length) == 0' <<<"$observability_secrets" >/dev/null \
    || fail "$context observability namespace contains a stored Secret"
  observability_policies="$(kube "$operator_kubeconfig" "" --context="$context" \
    --namespace=currency-observability --request-timeout=20s get networkpolicies -o json)"
  jq -e '([.items[].metadata.name] | sort) == ["default-deny-ingress"] and
    .items[0].spec.podSelector == {} and .items[0].spec.policyTypes == ["Ingress"] and
    ((.items[0].spec.ingress // []) == []) and ((.items[0].spec.egress // []) == [])' \
    <<<"$observability_policies" >/dev/null || fail "$context observability ingress isolation changed"

  app_a_policies="$(kube "$operator_kubeconfig" "" --context="$context" --namespace=currency-app-a \
    --request-timeout=20s get networkpolicies -o json)"
  app_b_policies="$(kube "$operator_kubeconfig" "" --context="$context" --namespace=currency-app-b \
    --request-timeout=20s get networkpolicies -o json)"
  jq -e '
    ([.items[] | select(.metadata.name == "default-deny-ingress")] | first) as $deny |
    ([.items[] | select(.metadata.name == "allow-app-a-from-global-load-balancer")] | first) as $allow |
    ([.items[].metadata.name] | sort) ==
      ["allow-app-a-from-global-load-balancer", "default-deny-ingress"] and
    ($deny.spec.podSelector == {}) and
    ($deny.spec.policyTypes == ["Ingress"]) and
    (($deny.spec.ingress // []) == []) and
    (($deny.spec.egress // []) == []) and
    ($allow.spec.podSelector == {"matchLabels":{"app":"app-a-gateway"}}) and
    ($allow.spec.policyTypes == ["Ingress"]) and
    (($allow.spec.ingress | length) == 1) and
    (($allow.spec.egress // []) == []) and
    (($allow.spec.ingress[0].ports // []) == [{"port":8080,"protocol":"TCP"}]) and
    (($allow.spec.ingress[0].from | length) == 2) and
    ([ $allow.spec.ingress[0].from[] | keys[] ] | unique == ["ipBlock"]) and
    all($allow.spec.ingress[0].from[]; (.ipBlock | keys) == ["cidr"]) and
    ([ $allow.spec.ingress[0].from[].ipBlock.cidr ] | sort ==
      ["130.211.0.0/22", "35.191.0.0/16"])
  ' \
    <<<"$app_a_policies" >/dev/null || fail "$context App A NetworkPolicy inventory changed"
  jq -e '
    ([.items[] | select(.metadata.name == "default-deny-ingress")] | first) as $deny |
    ([.items[] | select(.metadata.name == "allow-app-b-from-app-a")] | first) as $allow |
    ([.items[].metadata.name] | sort) ==
      ["allow-app-b-from-app-a", "default-deny-ingress"] and
    ($deny.spec.podSelector == {}) and
    ($deny.spec.policyTypes == ["Ingress"]) and
    (($deny.spec.ingress // []) == []) and
    (($deny.spec.egress // []) == []) and
    ($allow.spec.podSelector == {"matchLabels":{"app":"app-b-engine"}}) and
    ($allow.spec.policyTypes == ["Ingress"]) and
    (($allow.spec.ingress | length) == 1) and
    (($allow.spec.egress // []) == []) and
    (($allow.spec.ingress[0].ports // []) == [{"port":8080,"protocol":"TCP"}]) and
    (($allow.spec.ingress[0].from // []) == [{
      "namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"currency-app-a"}},
      "podSelector":{"matchLabels":{"app":"app-a-gateway"}}
    }])
  ' \
    <<<"$app_b_policies" >/dev/null || fail "$context App B cross-namespace policy changed"

  for lane in app-a app-b; do
    if [[ "$lane" == app-a ]]; then
      path="$app_a_kubeconfig"; identity="$app_a_deployer"
      own=currency-app-a; other=currency-app-b; platform=currency-observability
    else
      path="$app_b_kubeconfig"; identity="$app_b_deployer"
      own=currency-app-b; other=currency-app-a; platform=currency-observability
    fi
    for resource in deployments.apps horizontalpodautoscalers.autoscaling poddisruptionbudgets.policy; do
      for verb in get list watch create update patch delete; do
        expect_can_i "$path" "$identity" "$context" yes "$verb" "$resource" "$own"
      done
    done
    expect_can_i "$path" "$identity" "$context" yes get pods/log "$own"
    for resource in configmaps services serviceaccounts networkpolicies.networking.k8s.io \
      roles.rbac.authorization.k8s.io rolebindings.rbac.authorization.k8s.io resourcequotas; do
      for verb in get list watch create update patch delete; do
        expect_can_i "$path" "$identity" "$context" no "$verb" "$resource" "$own"
      done
    done
    for verb in get list watch create update patch delete; do
      expect_can_i "$path" "$identity" "$context" no "$verb" secrets "$own"
      expect_can_i "$path" "$identity" "$context" no "$verb" secrets "$other"
      expect_can_i "$path" "$identity" "$context" no "$verb" secrets "$platform"
    done
    for verb in create update patch delete; do
      expect_can_i "$path" "$identity" "$context" no "$verb" pods "$own"
    done
    expect_can_i "$path" "$identity" "$context" no create pods/exec "$own"
    expect_can_i "$path" "$identity" "$context" no create pods/attach "$own"
    expect_can_i "$path" "$identity" "$context" no create pods/portforward "$own"
    expect_can_i "$path" "$identity" "$context" no create pods/exec "$other"
    expect_can_i "$path" "$identity" "$context" no create pods/attach "$other"
    expect_can_i "$path" "$identity" "$context" no create pods/portforward "$other"
    expect_can_i "$path" "$identity" "$context" no create pods/exec "$platform"
    expect_can_i "$path" "$identity" "$context" no create pods/attach "$platform"
    expect_can_i "$path" "$identity" "$context" no create pods/portforward "$platform"
    for resource in deployments.apps horizontalpodautoscalers.autoscaling \
      poddisruptionbudgets.policy pods pods/log configmaps services serviceaccounts \
      networkpolicies.networking.k8s.io roles.rbac.authorization.k8s.io \
      rolebindings.rbac.authorization.k8s.io resourcequotas; do
      for verb in get list watch create update patch delete; do
        expect_can_i "$path" "$identity" "$context" no "$verb" "$resource" "$other"
        expect_can_i "$path" "$identity" "$context" no "$verb" "$resource" "$platform"
      done
    done
  done

  printf '%s: PASS namespaces, PSA, quotas, policies, KSA/GSA mappings, deployer RoleBindings, no Dev RBAC, and own-vs-other RBAC.\n' \
    "$context"
done

[[ "$app_a_deployer" != "$app_b_deployer" ]] \
  || fail "team identities are not distinct"
printf 'Team isolation: PASS (no production Dev RBAC; distinct short-lived deployers; no cross-namespace access, Secrets, exec, attach, or port-forward).\n'
