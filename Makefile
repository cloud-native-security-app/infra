.PHONY: verify
verify:
	bash scripts/check-paths.sh
	@for f in deploy/aws/*.sh scripts/*.sh; do bash -n "$$f" || exit 1; done; echo "bash -n: OK"
	@if command -v shellcheck >/dev/null 2>&1; then shellcheck -x deploy/aws/*.sh scripts/*.sh; else echo "shellcheck not installed: skipped"; fi
