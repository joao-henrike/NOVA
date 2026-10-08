SHELL := /usr/bin/env bash
ROOT_DIR := $(shell pwd)
TOOLS_BIN := $(ROOT_DIR)/.tools/bin
VENV_BIN := $(ROOT_DIR)/.venv/bin
TERRAFORM := $(TOOLS_BIN)/terraform
PYTHON := $(VENV_BIN)/python
AWS_REGION ?= us-east-1

.DEFAULT_GOAL := start

.PHONY: start setup doctor validate fmt tflint deploy up down logs restart test migrate smoke tf-init tf-validate tf-plan

# Default entry point after cloning the repository.
# It prepares the local environment, validates it, and starts the application.
start: setup doctor validate up

setup:
	bash scripts/bootstrap-local.sh

doctor:
	bash scripts/doctor.sh

validate: fmt
	$(PYTHON) -m compileall -q apps/backend/app apps/backend/tests

fmt:
	$(TERRAFORM) fmt -check -recursive

tflint:
	$(TOOLS_BIN)/tflint --init --config .tflint.hcl
	$(TOOLS_BIN)/tflint --config .tflint.hcl --format compact
	$(TOOLS_BIN)/tflint --config .tflint.hcl --format compact --chdir bootstrap

tf-validate:
	bash scripts/terraform-validate.sh

tf-init:
	@test -n "$$TF_STATE_BUCKET" || (echo "Set TF_STATE_BUCKET first"; exit 1)
	$(TERRAFORM) init --backend-config="bucket=$TF_STATE_BUCKET" --backend-config="region=$(AWS_REGION)" --reconfigure --input=false

tf-plan:
	$(TERRAFORM) plan -refresh=true -lock=true -input=false -no-color

deploy: setup doctor validate
	bash scripts/deploy.sh

up:
	docker compose up -d --build

down:
	docker compose down

restart:
	docker compose down
	docker compose up -d --build

logs:
	docker compose logs -f --tail=200

migrate:
	docker compose up -d postgres
	bash scripts/wait-for-postgres.sh
	cd apps/backend && \
		DATABASE_URL=postgresql+psycopg://cloudstart_admin:local-development-only@127.0.0.1:5432/cloudstart \
		DB_HOST=127.0.0.1 DB_PORT=5432 DB_NAME=cloudstart DB_USER=cloudstart_admin DB_PASSWORD=local-development-only \
		$(PYTHON) -m alembic upgrade head

test:
	docker compose up -d postgres
	bash scripts/wait-for-postgres.sh
	cd apps/backend && \
		DATABASE_URL=postgresql+psycopg://cloudstart_admin:local-development-only@127.0.0.1:5432/cloudstart \
		DB_HOST=127.0.0.1 DB_PORT=5432 DB_NAME=cloudstart DB_USER=cloudstart_admin DB_PASSWORD=local-development-only \
		AUTH_JWT_SECRET_KEY=local-test-signing-secret-with-more-than-32-characters \
		AUTH_COOKIE_SECURE=false \
		$(PYTHON) -m alembic upgrade head && \
		$(PYTHON) -m pytest -q

smoke:
	curl --fail --silent --show-error http://127.0.0.1:8080/ >/dev/null
	curl --fail --silent --show-error http://127.0.0.1:8080/health >/dev/null
	curl --fail --silent --show-error http://127.0.0.1:8080/api/health >/dev/null
	curl --fail --silent --show-error http://127.0.0.1:8080/api/info >/dev/null
	curl --fail --silent --show-error http://127.0.0.1:8080/api/health/db >/dev/null
	@status=$(curl --silent --output /tmp/nova-items.json --write-out "%{http_code}" http://127.0.0.1:8080/api/items); \
	test "$$status" = "401"
	@echo "Local smoke tests passed."
