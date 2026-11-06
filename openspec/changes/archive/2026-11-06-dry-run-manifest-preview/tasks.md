# Tasks: dry-run-manifest-preview

## 1. Implementation

- [x] 1.1 `common.sh`: `dry_run_render_manifests` (helm gate, kubeVersion parse, markers, warn-on-failure)
- [x] 1.2 `install.sh` + `update.sh`: call it at the end of the dry-run blocks

## 2. Tests

- [x] 2.1 `tests/stubs/helm`: `template` case with `HC_STUB_TEMPLATE_FAIL=1` knob
- [x] 2.2 `test-common.sh`: no-helm note, stub render (markers + mock log args incl. `-f /extra` and `--kube-version 1.25.0`), failing render warns
- [x] 2.3 `test-install.sh` + `test-update.sh`: dry-run asserts (note without helm, markers + mock template call with stubs)

## 3. Verification & close-out

- [x] 3.1 Full suite green (v3 + v4 chart runs)
- [x] 3.2 `openspec validate --all`; change archived; committed
