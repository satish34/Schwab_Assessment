ifeq ($(OS),Windows_NT)
SHELL := C:/Program Files/Git/bin/bash.exe
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

export PROJECT_ID BILLING_ACCOUNT_ID ADMIN_CIDR GCLOUD_CONFIGURATION DOMAIN_NAME
export PRIMARY_REGION SECONDARY_REGION MAVEN_IMAGE GCLOUD_IMAGE

.PHONY: help preflight fmt test local-up local-verify bootstrap global clusters
.PHONY: build deploy-apps wait-negs lb verify seed-traffic verify-bigquery
.PHONY: test-failover capture-evidence plan-check destroy orphan-check

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
	  'lb                 apply infra/30-lb after the NEG gate' \
	  'verify             verify clusters, backends, and public API' \
	  'seed-traffic       generate controlled application traffic' \
	  'verify-bigquery    run checked-in BigQuery queries' \
	  'test-failover      run and restore the cell-failover experiment' \
	  'capture-evidence   save non-secret gate evidence' \
	  'plan-check         run final Terraform drift checks' \
	  'destroy            execute the mandatory ordered teardown' \
	  'orphan-check       report remaining billable resources'

preflight:
	@bash ./scripts/preflight.sh

define pending_target
	@printf '%s\n' '$(1) is not implemented yet; see docs/GATE_CHECKLIST.md' >&2
	@exit 2
endef

fmt:
	$(call pending_target,fmt)

test:
	$(call pending_target,test)

local-up:
	$(call pending_target,local-up)

local-verify:
	$(call pending_target,local-verify)

bootstrap:
	@bash ./scripts/terraform-stack.sh infra/00-bootstrap apply

global:
	@bash ./scripts/terraform-stack.sh infra/10-global apply

clusters:
	@bash ./scripts/terraform-stack.sh infra/20-cluster apply

build:
	$(call pending_target,build)

deploy-apps:
	$(call pending_target,deploy-apps)

wait-negs:
	$(call pending_target,wait-negs)

lb:
	$(call pending_target,lb)

verify:
	$(call pending_target,verify)

seed-traffic:
	$(call pending_target,seed-traffic)

verify-bigquery:
	$(call pending_target,verify-bigquery)

test-failover:
	$(call pending_target,test-failover)

capture-evidence:
	$(call pending_target,capture-evidence)

plan-check:
	$(call pending_target,plan-check)

destroy:
	$(call pending_target,destroy)

orphan-check:
	$(call pending_target,orphan-check)
