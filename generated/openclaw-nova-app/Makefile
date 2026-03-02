.PHONY: build-docker build-enclave run-local
.RECIPEPREFIX := >

build-docker:
> docker build -t openclaw-nova-app:latest .

build-enclave:
> enclaver build

run-local:
> docker run --rm -p 18789:18789 -e OPENCLAW_GATEWAY_TOKEN=dev-token openclaw-nova-app:latest
