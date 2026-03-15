.PHONY: build-docker build-enclave prepare-local-data run-local

build-docker:
	docker build -t openclaw-manager-app:latest .

build-enclave:
	./build_release_image.sh

prepare-local-data:
	mkdir -p ./openclaw-data

run-local: prepare-local-data
	docker run --rm -p 8000:8000 -e HTTP_PROXY="$${HTTP_PROXY:-$${http_proxy:-}}" -e HTTPS_PROXY="$${HTTPS_PROXY:-$${https_proxy:-}}" -e NO_PROXY="$${NO_PROXY:-$${no_proxy:-}}" -e ALL_PROXY="$${ALL_PROXY:-$${all_proxy:-}}" -e http_proxy="$${http_proxy:-$${HTTP_PROXY:-}}" -e https_proxy="$${https_proxy:-$${HTTPS_PROXY:-}}" -e no_proxy="$${no_proxy:-$${NO_PROXY:-}}" -e all_proxy="$${all_proxy:-$${ALL_PROXY:-}}" -v "$(CURDIR)/openclaw-data:/mnt/openclaw" openclaw-manager-app:latest
