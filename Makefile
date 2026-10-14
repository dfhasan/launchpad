# Local shortcuts. CI uses the same scripts.
STACKS := bootstrap live/platform live/environments observability/datadog

.PHONY: check fmt validate test envs gitops kind-up kind-down

check: fmt validate test envs gitops ## everything CI runs offline

fmt:
	terraform fmt -check -recursive

validate:
	@for d in $(STACKS); do terraform -chdir=$$d init -backend=false -input=false >/dev/null && terraform -chdir=$$d validate || exit 1; done

test:
	terraform -chdir=live/environments test

envs:
	python3 scripts/envctl.py validate

gitops:
	@for o in gitops/apps/*/overlays/*; do kubectl kustomize $$o | kubeconform -strict -summary -ignore-missing-schemas || exit 1; done

kind-up:
	scripts/kind-up.sh

kind-down:
	scripts/kind-down.sh
