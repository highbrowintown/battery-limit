.PHONY: test lint

test:
	bash tests/test.sh

lint:
	shellcheck bin/battery-limit install.sh tests/test.sh
