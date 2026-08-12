ifeq ($(OS),Windows_NT)
SHELL := bash
WINGET_LINKS := $(LOCALAPPDATA)\Microsoft\WinGet\Links
export PATH := $(WINGET_LINKS);$(PATH)
else
SHELL := /bin/bash
endif
.SHELLFLAGS := -eu -o pipefail -c

-include .env

PROJECT_ID ?= schwab-assessment-gke
BILLING_ACCOUNT_ID ?=
ADMIN_CIDR ?=
GCLOUD_CONFIGURATION ?= schwab-assessment
DOMAIN_NAME ?=
ENABLE_CLOUD_ARMOR ?= 0
ENABLE_BINARY_AUTHORIZATION ?= 0
ALLOW_CENTRAL_CLUSTER_REPLACEMENT ?= 0
PRIMARY_REGION ?= us-central1
SECONDARY_REGION ?= us-east4
MAVEN_IMAGE ?= maven:3.9.11-eclipse-temurin-21
GCLOUD_IMAGE ?= gcr.io/google.com/cloudsdktool/google-cloud-cli:525.0.0-slim
IMAGE_TAG ?= $(shell git rev-parse --verify HEAD^{commit} 2>/dev/null)
APP_A_IMAGE_TAG ?= $(IMAGE_TAG)
APP_B_IMAGE_TAG ?= $(IMAGE_TAG)
GRAFANA_IMAGE_TAG ?=

export PROJECT_ID BILLING_ACCOUNT_ID ADMIN_CIDR GCLOUD_CONFIGURATION DOMAIN_NAME
export ENABLE_CLOUD_ARMOR ENABLE_BINARY_AUTHORIZATION
export ALLOW_CENTRAL_CLUSTER_REPLACEMENT
export PRIMARY_REGION SECONDARY_REGION MAVEN_IMAGE GCLOUD_IMAGE
export IMAGE_TAG APP_A_IMAGE_TAG APP_B_IMAGE_TAG GRAFANA_IMAGE_TAG

.PHONY: help preflight fmt test local-up local-verify bootstrap-plan bootstrap global-plan global clusters-plan clusters
.PHONY: build build-app-a build-app-b build-grafana deploy-apps deploy-app-a deploy-app-b wait-negs lb-plan lb verify verify-armor test-armor seed-traffic verify-bigquery verify-grafana verify-cloud-observability verify-platform-observability
.PHONY: gke-grafana gke-grafana-status cleanup-gke-grafana
.PHONY: verify-error-reporting verify-binauthz test-binauthz-denial test-failover
.PHONY: capture-evidence capture-observability-manifest capture-observability-cloud capture-observability-platform
.PHONY: capture-observability-grafana-start capture-observability-grafana-verify capture-observability-grafana-cleanup
.PHONY: plan-check secret-scan destroy orphan-check

help:
	@printf '%s\n' \
	  'preflight          verify local tools, account, project, and billing' \
	  'fmt                format all source and configuration' \
	  'test               run Java, .NET, contract, and schema tests' \
	  'local-up           build and start the local two-service stack' \
	  'local-verify       verify API propagation, traces, and JSON logs' \
	  'bootstrap-plan     save and display the exact 00-bootstrap plan for review' \
	  'bootstrap          apply the reviewed 00-bootstrap plan' \
	  'global-plan        save and display the exact 10-global plan for review' \
	  'global             apply the reviewed 10-global plan' \
	  'clusters-plan      preview the guarded 20-cluster change' \
	  'clusters           apply the guarded 20-cluster change' \
	  'build              test, build, and publish both release images' \
	  'build-app-a        test, build, and publish only the App A image' \
	  'build-app-b        test, build, and publish only the App B image' \
	  'build-grafana      build and publish the baked-plugin evidence image (explicit full SHA)' \
	  'deploy-apps        deploy both regional Kubernetes overlays' \
	  'deploy-app-a       deploy only App A to both regional cells' \
	  'deploy-app-b       deploy only App B to both regional cells' \
	  'wait-negs          wait for six standalone zonal NEGs' \
	  'lb-plan            save and display the exact 30-lb plan for review' \
	  'lb                 apply the reviewed 30-lb plan after the NEG gate' \
	  'verify             verify clusters, backends, and public API' \
	  'verify-armor       verify the opt-in attached Cloud Armor policy' \
	  'test-armor         generate bounded opt-in WAF/rate-limit evidence' \
	  'seed-traffic       generate controlled application traffic' \
	  'verify-bigquery    run checked-in BigQuery queries' \
	  'verify-grafana     verify source data and all four live Grafana panels' \
	  'verify-cloud-observability prove direct cross-service traces and App A profiles' \
	  'verify-platform-observability prove bounded platform logs and node/HPA/LB metrics' \
	  'gke-grafana        start private one-hour Grafana evidence Job and loopback tunnel' \
	  'gke-grafana-status inspect the private Grafana evidence session' \
	  'cleanup-gke-grafana remove the ephemeral Grafana Job, ConfigMaps, and tunnel' \
	  'verify-error-reporting verify grouped App A and App B exceptions' \
	  'verify-binauthz     verify the opt-in Binary Authorization contract' \
	  'test-binauthz-denial prove opt-in Docker Hub denial without persisting a Pod' \
	  'test-failover      run and restore the cell-failover experiment' \
	  'capture-evidence   save non-secret gate evidence' \
	  'capture-observability-* save phased Trace, Profiler, platform, and private Grafana proof' \
	  'plan-check         run final Terraform drift checks' \
	  'secret-scan        scan Git history and the worktree for secrets' \
	  'destroy            execute the mandatory ordered teardown' \
	  'orphan-check       report remaining billable resources'

preflight:
	@bash ./scripts/preflight.sh

fmt:
	@MSYS_NO_PATHCONV=1 docker run --rm \
	  --volume "$(CURDIR)/apps/app-a-java:/workspace" \
	  --volume schwab-assessment-maven-cache:/root/.m2 \
	  --workdir /workspace \
	  "$(MAVEN_IMAGE)" \
	  mvn --batch-mode --no-transfer-progress spotless:apply spotless:check
	@cd apps/app-b-dotnet && dotnet format AppB.sln --verbosity minimal
	@terraform fmt -recursive infra
	@find scripts -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
	@git diff --check

test:
	@MSYS_NO_PATHCONV=1 docker run --rm \
	  --volume "$(CURDIR)/apps/app-a-java:/workspace" \
	  --volume schwab-assessment-maven-cache:/root/.m2 \
	  --workdir /workspace \
	  "$(MAVEN_IMAGE)" \
	  mvn --batch-mode --no-transfer-progress spotless:check verify
	@cd apps/app-b-dotnet && dotnet restore AppB.sln --nologo
	@cd apps/app-b-dotnet && dotnet format AppB.sln --verify-no-changes --no-restore --verbosity minimal
	@cd apps/app-b-dotnet && dotnet test AppB.sln --configuration Release --no-restore --nologo
	@kubectl kustomize k8s/overlays/us-central1 >/dev/null
	@kubectl kustomize k8s/overlays/us-east4 >/dev/null
	@bash ./scripts/verify-kustomize-contracts.sh
	@bash ./scripts/platform-cutover-contract.sh
	@bash ./scripts/verify-cloud-observability.sh --static
	@bash ./scripts/gke-grafana-evidence.sh static
	@bash ./scripts/terraform-saved-plan-contract.sh --self-test

local-up:
	@bash ./scripts/local-up.sh

local-verify:
	@bash ./scripts/local-verify.sh

bootstrap-plan:
	@bash ./scripts/terraform-stack.sh infra/00-bootstrap plan

bootstrap:
	@bash ./scripts/terraform-stack.sh infra/00-bootstrap apply

global-plan:
	@bash ./scripts/terraform-stack.sh infra/10-global plan

global:
	@bash ./scripts/terraform-stack.sh infra/10-global apply

clusters-plan:
	@bash ./scripts/terraform-stack.sh infra/20-cluster plan

clusters:
	@bash ./scripts/terraform-stack.sh infra/20-cluster apply

build:
	@bash ./scripts/build-images.sh

build-app-a:
	@bash ./scripts/build-app-a.sh "$(APP_A_IMAGE_TAG)"

build-app-b:
	@bash ./scripts/build-app-b.sh "$(APP_B_IMAGE_TAG)"

build-grafana:
	@bash ./scripts/build-grafana.sh "$(GRAFANA_IMAGE_TAG)"

deploy-apps:
	@bash ./scripts/deploy-apps.sh "$(APP_A_IMAGE_TAG)" "$(APP_B_IMAGE_TAG)"

deploy-app-a:
	@bash ./scripts/deploy-app-a.sh "$(APP_A_IMAGE_TAG)" "$(APP_B_IMAGE_TAG)"

deploy-app-b:
	@bash ./scripts/deploy-app-b.sh "$(APP_B_IMAGE_TAG)" "$(APP_A_IMAGE_TAG)"

wait-negs:
	@bash ./scripts/wait-negs.sh "$(APP_A_IMAGE_TAG)" "$(APP_B_IMAGE_TAG)"

lb-plan:
	@bash ./scripts/terraform-stack.sh infra/30-lb plan

lb:
	@bash ./scripts/terraform-stack.sh infra/30-lb apply

verify:
	@bash ./scripts/verify-deployment-gates.sh "$(APP_A_IMAGE_TAG)" "$(APP_B_IMAGE_TAG)"

verify-armor:
	@bash ./scripts/test-cloud-armor.sh verify

test-armor:
	@bash ./scripts/test-cloud-armor.sh exercise

seed-traffic:
	@bash ./scripts/verify-workloads.sh "$(APP_A_IMAGE_TAG)" "$(APP_B_IMAGE_TAG)"
	@bash ./scripts/generate-traffic.sh "$(APP_A_IMAGE_TAG)" "$(APP_B_IMAGE_TAG)"

verify-bigquery:
	@bash ./scripts/verify-bigquery.sh "$(APP_A_IMAGE_TAG)" "$(APP_B_IMAGE_TAG)"

verify-grafana:
	@bash ./scripts/verify-grafana.sh

verify-cloud-observability:
	@bash ./scripts/verify-cloud-observability.sh "$(APP_A_IMAGE_TAG)" "$(APP_B_IMAGE_TAG)"

verify-platform-observability:
	@bash ./scripts/verify-platform-observability.sh

gke-grafana:
	@bash ./scripts/gke-grafana-evidence.sh start "$(GRAFANA_IMAGE_TAG)"

gke-grafana-status:
	@bash ./scripts/gke-grafana-evidence.sh status "$(GRAFANA_IMAGE_TAG)"

cleanup-gke-grafana:
	@bash ./scripts/gke-grafana-evidence.sh cleanup "$(GRAFANA_IMAGE_TAG)"

verify-error-reporting:
	@bash ./scripts/verify-error-reporting.sh

verify-binauthz:
	@bash ./scripts/verify-binary-authorization.sh

test-binauthz-denial:
	@bash ./scripts/test-binary-authorization-denial.sh

test-failover:
	@bash ./scripts/test-failover.sh "$(APP_A_IMAGE_TAG)" "$(APP_B_IMAGE_TAG)"

capture-evidence:
	@bash ./scripts/capture-evidence.sh "$(APP_A_IMAGE_TAG)" "$(APP_B_IMAGE_TAG)"

capture-observability-manifest:
	@bash ./scripts/capture-observability-evidence.sh manifest "$(APP_A_IMAGE_TAG)" "$(APP_B_IMAGE_TAG)"

capture-observability-cloud:
	@bash ./scripts/capture-observability-evidence.sh cloud "$(APP_A_IMAGE_TAG)" "$(APP_B_IMAGE_TAG)"

capture-observability-platform:
	@bash ./scripts/capture-observability-evidence.sh platform

capture-observability-grafana-start:
	@bash ./scripts/capture-observability-evidence.sh grafana start "$(GRAFANA_IMAGE_TAG)"

capture-observability-grafana-verify:
	@bash ./scripts/capture-observability-evidence.sh grafana verify "$(GRAFANA_IMAGE_TAG)"

capture-observability-grafana-cleanup:
	@bash ./scripts/capture-observability-evidence.sh grafana cleanup "$(GRAFANA_IMAGE_TAG)"

plan-check:
	@bash ./scripts/plan-check.sh

secret-scan:
	@bash ./scripts/secret-scan.sh

destroy:
	@DESTROY_CONFIRMATION="$(DESTROY_CONFIRMATION)" bash ./scripts/destroy.sh

orphan-check:
	@bash ./scripts/orphan-check.sh
