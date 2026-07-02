IMAGE ?= isabelle-mcp:local
AUTOCORRODE_URL ?= https://github.com/awslabs/AutoCorrode.git
DOCKER_CONTEXT ?= .docker-context
ISABELLE_HEAPS_DIR ?= $(HOME)/tmp/.heaps
HEAP_SESSIONS ?= HOL HOL-Lattice
SHELL := /bin/bash

.PHONY: docker docker-image build heaps clean clean-docker-context clean-heaps-dir

docker: docker-image

docker-image:
	@set -euo pipefail; \
	rm -rf "$(DOCKER_CONTEXT)"; \
	mkdir -p "$(DOCKER_CONTEXT)/tmp"; \
	cp Dockerfile docker-entrypoint.sh "$(DOCKER_CONTEXT)/"; \
	git clone "$(AUTOCORRODE_URL)" "$(DOCKER_CONTEXT)/tmp/AutoCorrode"; \
	cp "$(DOCKER_CONTEXT)/tmp/AutoCorrode/iq/iq_bridge.py" "$(DOCKER_CONTEXT)/iq-http-bridge.py"; \
	docker build --pull -t "$(IMAGE)" "$(DOCKER_CONTEXT)"; \
	rm -rf "$(DOCKER_CONTEXT)"

build: docker-image

heaps:
	@set -euo pipefail; \
	mkdir -p "$(ISABELLE_HEAPS_DIR)"; \
	chmod 0777 "$(ISABELLE_HEAPS_DIR)"; \
	docker run --rm \
	  --entrypoint /bin/bash \
	  -v "$(ISABELLE_HEAPS_DIR):/home/isabelle/.isabelle/heaps" \
	  "$(IMAGE)" \
	  -lc 'umask 000; /home/isabelle/Isabelle2025-2/bin/isabelle build -b -f -o record_theories=true $(HEAP_SESSIONS)'

clean: clean-docker-context
	-docker image rm "$(IMAGE)"

clean-heaps-dir:
	rm -rf "$(ISABELLE_HEAPS_DIR)"
	
clean-docker-context:
	rm -rf "$(DOCKER_CONTEXT)"
