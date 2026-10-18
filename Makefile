TF := terraform -chdir=terraform
TFB := terraform -chdir=terraform/bootstrap

.PHONY: verify
verify:
	bash scripts/check-paths.sh
	bash scripts/check-backend.sh
	@for f in deploy/aws/*.sh scripts/*.sh; do bash -n "$$f" || exit 1; done; echo "bash -n: OK"
	@if command -v shellcheck >/dev/null 2>&1; then shellcheck -x scripts/*.sh; else echo "shellcheck not installed: skipped"; fi
	$(TF) fmt -check -recursive
	$(TF) init -backend=false -input=false
	$(TF) validate
	$(TF) test
	tflint --init
	tflint --chdir=terraform
	$(TFB) init -backend=false -input=false
	$(TFB) validate
	$(TFB) test
	tflint --init --chdir=terraform/bootstrap
	tflint --chdir=terraform/bootstrap
