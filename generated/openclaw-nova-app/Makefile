.PHONY: build-docker build-enclave prepare-local-data run-local
.RECIPEPREFIX := >

build-docker:
> docker build -t openclaw-nova-app:latest .

build-enclave:
> enclaver build

prepare-local-data:
> mkdir -p ./openclaw-data

run-local: prepare-local-data
> docker run --rm -p 18789:18789 -e OPENCLAW_GATEWAY_TOKEN=dev-token -v "$(CURDIR)/openclaw-data:/mnt/openclaw" openclaw-nova-app:latest
