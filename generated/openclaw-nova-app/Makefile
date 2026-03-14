.PHONY: build-docker build-enclave prepare-local-data run-local
.RECIPEPREFIX := >

build-docker:
> docker build -t openclaw-manager-app:latest .

build-enclave:
> ./build_release_image.sh

prepare-local-data:
> mkdir -p ./openclaw-data

run-local: prepare-local-data
> docker run --rm -p 8000:8000 -v "$(CURDIR)/openclaw-data:/mnt/openclaw" openclaw-manager-app:latest
