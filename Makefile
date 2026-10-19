# verify uses its own data dir so a live backend init in terraform/.terraform does not interfere.
TF := TF_DATA_DIR=.terraform-verify terraform -chdir=terraform

.PHONY: verify
verify:
	bash scripts/check-paths.sh
	bash scripts/check-backend.sh
	bash scripts/test-bootstrap-state-bucket.sh
	bash scripts/test-bootstrap-namespace.sh
	bash scripts/test-refresh-gh-secrets.sh
	bash scripts/test-set-google-oauth.sh
	@for f in deploy/aws/*.sh scripts/*.sh; do bash -n "$$f" || exit 1; done; echo "bash -n: OK"
	@if command -v shellcheck >/dev/null 2>&1; then shellcheck -x scripts/*.sh; else echo "shellcheck not installed: skipped"; fi
	$(TF) fmt -check -recursive
	$(TF) init -backend=false -input=false
	$(TF) validate
	$(TF) test
	tflint --init
	tflint --chdir=terraform
