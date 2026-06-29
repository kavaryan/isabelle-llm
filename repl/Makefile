IMAGE ?= isabelle-mcp:local
AUTOCORRODE_URL ?= https://github.com/awslabs/AutoCorrode.git
DOCKER_CONTEXT ?= .docker-context
SHELL := /bin/bash

.PHONY: docker docker-image build clean clean-docker-context

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

clean: clean-docker-context
	-docker image rm "$(IMAGE)"
	
clean-docker-context:
	rm -rf "$(DOCKER_CONTEXT)"
