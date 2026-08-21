# Atajos. Todo esto se puede hacer a mano; el Makefile solo evita recordarlo.
SHELL := /bin/sh
ISO   ?= ubuntu-24.04.4-live-server-amd64.iso
OUT   ?= ubuntu-autoinstall.iso

.POSIX:
.PHONY: help test lint build iso clean

help: ## Muestra esta ayuda
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  %-10s %s\n", $$1, $$2}'

test: ## Ejecuta la suite de pruebas
	@sh tests/run.sh

lint: ## shellcheck y sintaxis en varios shells
	@shellcheck -s sh -S warning setup.sh build-usb.sh tests/run.sh
	@for f in setup.sh build-usb.sh tests/run.sh; do \
	  for s in sh dash bash; do \
	    command -v $$s >/dev/null || continue; \
	    $$s -n $$f || exit 1; \
	  done; \
	done
	@echo "lint ok"

build: ## Genera cloud-init/user-data y meta-data
	@./build-usb.sh

iso: ## Reempaqueta la ISO. Uso: make iso ISO=ubuntu.iso [OUT=salida.iso]
	@./build-usb.sh --iso=$(ISO) --iso-out=$(OUT)

clean: ## Borra los artefactos generados
	@rm -f cloud-init/user-data cloud-init/meta-data
	@echo "limpio"
