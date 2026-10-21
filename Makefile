# Verification and release helpers. Nothing here writes outside the repository
# except the patch target, which reads the Omarchy checkout.
.PHONY: check test lint patch

check:            ## run every suite that can run on this machine
	bash tests/check.sh

test: check

lint:             ## syntax checks only (fast)
	node --check files/MenuModel.js
	@command -v qmllint >/dev/null 2>&1 && qmllint -I files files/Menu.qml || echo "qmllint not installed"

patch:            ## regenerate the pack's patch from this edition (needs the pack beside this repo)
	@echo "The patch belongs to the pack repository: cd ../omarchy-launcher-v2 && make patch"
