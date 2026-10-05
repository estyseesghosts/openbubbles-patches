# Community integration

Branch: `integration/community-test`, based on validated
`integration/local-fixes` (`274c736ce`). See `INTEGRATION.md` for F1 + F4 and
baseline validation. The local-fixes branch is frozen with RustPush `f9f2fdc`.

Community PRs are imported from the existing frozen `review/pr-*` refs, in this
order; each APK and available Flutter test suite must pass before the next PR:

| Addition | Reviewed app PR head | Integration commit | APK | Flutter tests |
|---|---|---|---|---|
| #244, persistence observability | `d2ed6670c` | `06905117f` | passed, 65.2 s | 7/7 passed |
| #274, incremental CloudKit saves | `2dffbb48f` | `69a8e6da7` + `0e261da5f` | passed after repair, 65.2 s | 7/7 passed |
| #226, incoming delivery integrity | `742296e3b` | `688d20c26` | passed, 167.9 s | 16/16 passed |
| #255, TLK share verification | `a1c1cf287` | `b05fe37b3` | passed after retry, 50.4 s | 16/16 passed |

#244 and #274 merged without conflicts (`message.dart` auto-merged, retaining
#244's logging and #274's save guards). #231 is deliberately excluded; no F2/F3 fix is
added. No APK installation or account/device action is authorized/performed.

#274's first build failed at `message.dart:1140`: its `void` → `bool` return-type
change omitted the existing SMS/missing-chat early-return value. The community
integration repairs that one line to `return false`, preserving the skip
behavior and the PR's "not applied" return contract. This repair is not on the
local-fixes branch. The original failed build/analyzer logs are preserved.

#226 merged without conflicts: `message.dart`, `main.dart`, and
`rustpush_service.dart` auto-merged, retaining F1's hook and #274's guards/repair.
Its four upstream test files are included. Host tests use a local uncommitted
`lib/libobjectbox.dylib` copy from the read-only #226 verification checkout;
that checkout itself is not modified.

#255's RustPush dependency is `540f6351c2b34241032462f2c23dbeed55e8bedf`, one
commit above the baseline. It was merged with F4 without Rust source conflicts
on RustPush branch `integration/community-tlk`, producing
`ef214f9b132c7eab34a235533f1c0be4e064024d`. Both the original F4 `f9f2fdc` and
PR #255 dependency `540f635` are ancestors of that commit; only the PR's TLK
change differs from F4. Nested submodule pins remain unchanged.

The app merge had one expected gitlink conflict (`f9f2fdc` versus `540f635`),
resolved by staging the combined `ef214f9b1` pointer, which Git itself identified
as the possible merge resolution. F4 was not replaced or dropped.
Final combined RustPush validation: lock-ordering **7/7 passed** (17.9 seconds,
including compilation); `cargo check --lib` **passed** (7.1 seconds).

The #255 APK required a retry. The first attempt (`pr255-apk`) cannot be trusted:
its background shell returned `Shell.NotFoundError` and the Python result wrapper
vanished, leaving Flutter PID 20565 orphaned. That owned process group was stopped
before any retry, and no exit code or APK validation was taken from it; the
incomplete `pr255-apk.log` is retained as evidence only, and
`pr255-harness-interruption.txt` records the interruption. Only the retry counts:

`pr255-retry-apk` exited **0** in **50.4 seconds**, built from app commit
`b05fe37b3` with RustPush `ef214f9b1`, and is preserved as
`build/integration-apks/pr255-retry.apk` (637,453,011 bytes, SHA-256
`10ec32496060ab81c7d933955da59409270f2187481f6aed725330e41e8f4289`, recomputed
and matched after the copy). `aapt` badging confirms package
`com.bluebubbles.messaging.alpha`, `application-debuggable`, and `arm64-v8a`;
the APK carries `lib/arm64-v8a/libflutter.so` together with `lib/x86/` and
`lib/x86_64/`, matching the other debug APKs in this stack.

All APKs use the same Flutter 3.24.0 alpha debug `android-arm64` build command
as the local stack. Preserved APKs are under ignored `build/integration-apks/`;
command logs, SHA-256, timing, `aapt` badging, and artifact JSON are under the
evidence directory named in `INTEGRATION.md`. Builds are not device validation:
authentication remains blocked by the pre-existing RustPush 2FA issue.
