.PHONY: generate example

generate:
	./scripts/install_openclaw_nova_app.sh

example:
	./scripts/install_openclaw_nova_app.sh --output-dir ./generated/openclaw-nova-app --cpu-count 2 --memory-mb 12288 --gateway-port 18789
