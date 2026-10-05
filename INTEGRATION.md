# Local-fixes integration

Date: 2026-10-04. Branch: `integration/local-fixes`.

## Included

- Frozen `upstream/rustpush` app baseline: `eed1b6332efbb17adbf5ebfa2263ad770169f75e`.
- F1 notification restoration count-baseline fix, debug-only replay hook and its
  setup/settings entry points, copied verbatim from the original checkout.
  Existing `test/notification_count_baseline_test.dart` included as characterization
  tests (a modeled listener, not an end-to-end ObjectBox test).
- F4 app submodule pointer update to RustPush
  `f9f2fdc22568144a1870a38925ad52f49dc625e8`: keystore/identity lock-order fix
  and seven bounded regression tests.
- No F3 production patch exists; none included. No community PRs or #231 included.

F1 and F4 applied without source conflicts. The handoff omitted the two existing
F1 UI entry-point changes; those were included so the hook remains reachable.

## Dependency pins

| Submodule | Commit |
|---|---|
| `rustpush/apple-private-apis` | `e1c2b0b26bc0d1e9ef04191b8d31c079ee625586` |
| `rustpush/apple-private-apis/clearadi` | `663f33f9d71b0df5436d04611755142df6db6a35` |
| `rustpush/open-absinthe` | `1f8dc73a311e7b4d94a868972a6816c8a2c14e44` |
| `telephony_plus` | `5210e940dd92ae371f8c74eaeb552d0704034244` |
| `telephony_plus/android-smsmms` | `36f34f482dd5546c929f448d746c3124875a4faa` |

## Validation

- `cargo test --test lock_ordering --no-default-features -- --test-threads=1`:
  **7/7 passed** (117 seconds including compilation; tests themselves 1.11 seconds).
- `cargo check --lib`: **passed** (100.5 seconds; existing compiler warnings).
- F1 Flutter characterization tests: **7/7 passed** (41 seconds).
- Targeted Dart analysis: **no errors or new diagnostics**. Both integrated and
  isolated `eed1b6332` baseline code report the same 9 warnings and 9 infos
  (exit 2 from existing warnings); both new hook files have no diagnostics.
- Alpha debug ARM64 APK: **built successfully** (788.9 seconds including startup
  lock wait; Gradle 775.9 seconds). Command:
  `/tmp/flutter_3.24.0/flutter/bin/flutter build apk --no-pub --flavor alpha --debug --target-platform android-arm64`.
  Preserved locally at `build/integration-apks/local-fixes.apk` (577,768,808 bytes).
  SHA-256: `4de9d193d4a5e14b135b1394520a3954c4aebdc013133c5570f63242df5d4b36`.
  `aapt dump badging` confirms `com.bluebubbles.messaging.alpha`, version
  `1.15.0`/`20002227`, debuggable, min SDK 24/target SDK 36, and `arm64-v8a` support.
  Bundled native dependencies also advertise other ABIs; this is not an
  ARM64-only/split APK despite the requested Flutter target.

Host commands are limited to 300 seconds by a Python process-group timeout
wrapper because neither `timeout` nor `gtimeout` is installed. Android builds use
Flutter 3.24.0, Java 21, stable Rust, and NDK 26.1.10909125 as in the handoff.

Local build material only: `rustpush/certs/fairplay` symlinks to the original
checkout's **`certs/fairplay`** directory (`certs/fairpush` does not exist).
APFS copy-on-write build-cache copies avoid duplicating tens of GiB of artifacts.
Cargo lockfile updates, cert material, ObjectBox binaries, and generated platform
configuration are not part of the commits.

`cargo test --lib` remains blocked by baseline missing `certs/proxy/*.pem`.
Pattern/characterization tests do not prove authenticated device behavior;
authentication is blocked by the pre-existing RustPush 2FA issue. No APK installed,
account action, F2 patch, or #231 integration performed.

Logs and command/result JSON are under:
`/private/var/folders/dg/dztwhk5n6rb9xr8jt3t0nkf00000gp/T/opencode/openbubbles-integration-evidence/`.
