ifeq ($(OS),Windows_NT)
SHELL := C:/Program Files/Git/bin/bash.exe
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
PRIMARY_REGION ?= us-central1
SECONDARY_REGION ?= us-east4
MAVEN_IMAGE ?= maven:3.9.11-eclipse-temurin-21
GCLOUD_IMAGE ?= gcr.io/google.com/cloudsdktool/google-cloud-cli:525.0.0-slim
IMAGE_TAG ?= $(shell git rev-parse --verify HEAD^{commit} 2>/dev/null)

export PROJECT_ID BILLING_ACCOUNT_ID ADMIN_CIDR GCLOUD_CONFIGURATION DOMAIN_NAME
export PRIMARY_REGION SECONDARY_REGION MAVEN_IMAGE GCLOUD_IMAGE

.PHONY: help preflight fmt test local-up local-verify bootstrap global clusters
.PHONY: build deploy-apps wait-negs lb-plan lb verify seed-traffic verify-bigquery verify-grafana
.PHONY: verify-error-reporting test-failover capture-evidence plan-check secret-scan destroy orphan-check

help:
	@printf '%s\n' \
	  'preflight          verify local tools, account, project, and billing' \
	  'fmt                format all source and configuration' \
	  'test               run Java, .NET, contract, and schema tests' \
	  'local-up           build and start the local two-service stack' \
	  'local-verify       verify API propagation, traces, and JSON logs' \
	  'bootstrap          apply infra/00-bootstrap' \
	  'global             apply infra/10-global' \
	  'clusters           apply infra/20-cluster' \
	  'build              test, build, and publish immutable images' \
	  'deploy-apps        deploy both regional Kubernetes overlays' \
	  'wait-negs          wait for six standalone zonal NEGs' \
	  'lb-plan            preview the global edge change after the NEG gate' \
	  'lb                 apply infra/30-lb after the NEG gate' \
	  'verify             verify clusters, backends, and public API' \
	  'seed-traffic       generate controlled application traffic' \
	  'verify-bigquery    run checked-in BigQuery queries' \
	  'verify-grafana     verify source data and all four live Grafana panels' \
	  'verify-error-reporting verify grouped App A and App B exceptions' \
	  'test-failover      run and restore the cell-failover experiment' \
	  'capture-evidence   save non-secret gate evidence' \
	  'plan-check         run final Terraform drift checks' \
	  'secret-scan        scan Git history and the worktree for secrets' \
	  'destroy            execute the mandatory ordered teardown' \
	  'orphan-check       report remaining billable resources'

preflight:
	@bash ./scripts/preflight.sh

define pending_target
	@printf '%s\n' '$(1) is not implemented yet; see docs/GATE_CHECKLIST.md' >&2
	@exit 2
endef

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

local-up:
	@bash ./scripts/local-up.sh

local-verify:
	@bash ./scripts/local-verify.sh

bootstrap:
	@bash ./scripts/terraform-stack.sh infra/00-bootstrap apply

global:
	@bash ./scripts/terraform-stack.sh infra/10-global apply

clusters:
	@bash ./scripts/terraform-stack.sh infra/20-cluster apply

build:
	@bash ./scripts/build-images.sh

deploy-apps:
	@bash ./scripts/deploy-apps.sh "$(IMAGE_TAG)"

wait-negs:
	@bash ./scripts/wait-negs.sh "$(IMAGE_TAG)"

lb-plan:
	@bash ./scripts/terraform-stack.sh infra/30-lb plan

lb:
	@bash ./scripts/terraform-stack.sh infra/30-lb apply

verify:
	@bash ./scripts/verify-workloads.sh "$(IMAGE_TAG)"
	@bash ./scripts/wait-negs.sh "$(IMAGE_TAG)"
	@bash ./scripts/verify-lb.sh

seed-traffic:
	@bash ./scripts/generate-traffic.sh "$(IMAGE_TAG)"

verify-bigquery:
	@bash ./scripts/verify-bigquery.sh "$(IMAGE_TAG)"

verify-grafana:
	@bash ./scripts/verify-grafana.sh

verify-error-reporting:
	@bash ./scripts/verify-error-reporting.sh

test-failover:
	@bash ./scripts/test-failover.sh "$(IMAGE_TAG)"

capture-evidence:
	@bash ./scripts/capture-evidence.sh "$(IMAGE_TAG)"

plan-check:
	@bash ./scripts/plan-check.sh

secret-scan:
	@bash ./scripts/secret-scan.sh

destroy:
	@DESTROY_CONFIRMATION="$(DESTROY_CONFIRMATION)" bash ./scripts/destroy.sh

orphan-check:
	@bash ./scripts/orphan-check.sh
