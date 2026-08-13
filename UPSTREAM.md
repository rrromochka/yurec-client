# Upstream relationship

This repository is a friendly downstream of
[`kirbex/yurec-client`](https://github.com/kirbex/yurec-client), maintained
with permission of the original author.

## Branches

- `main` is a clean mirror of `upstream/main` and does not accept downstream
  changes.
- `cambodgia` is the product and release branch for Cambodgia build of
  YurecClient.
- `contrib/*` branches contain small upstream-neutral changes created from the
  current clean `main`.

The downstream does not open unsolicited pull requests against upstream. The
original author may cherry-pick a commit or branch, or ask for a pull request.

## Support boundary

Cambodgia maintainers support the downstream build. Issues caused by this
build should be reported in
[`rrromochka/yurec-client`](https://github.com/rrromochka/yurec-client/issues),
not to the original author unless the problem is independently reproduced in
an unmodified upstream build.

## Patch lifecycle

Allowed statuses are `draft`, `tested`, `upstream-candidate`, `offered`,
`accepted`, `rejected`, and `superseded`.

| Change | Branch | Status | Upstream result |
| --- | --- | --- | --- |
| Profile-driven sing-box route selector | `contrib/route-selector` | `tested` | `not offered` |
| TUN recovery after macOS sleep | `contrib/sleep-wake-recovery` | `tested` | `not offered` |
| Session lifecycle generation guard | `contrib/session-lifecycle` | `tested` | `not offered` |

The route-selector patch is upstream-neutral: it reads standard sing-box
`selector` outbounds, stores a choice per profile and selector tag, and applies
that choice only to a temporary runtime config. Its isolated Swift tests and a
Debug build pass. Manual downstream acceptance covers FI/US/KZ/RU-to-FI route
switching and revocation of both inactive and actively selected routes without
a manual TUN restart. This does not imply that the patch has been offered
upstream.

The sleep/wake patch is also upstream-neutral. It stops only the session owned
by the app before sleep, waits for a stable physical network after wake and
restores the same profile and mode once. Its isolated tests and Debug build
pass; manual downstream acceptance on 2026-08-13 confirmed recovery without a
TUN toggle and a successful live subscription update afterwards.

The session-lifecycle patch is upstream-neutral as well. It assigns a
generation-based token to every sing-box session and ignores delayed
termination callbacks that no longer own the active session. Its isolated
tests cover replacement sessions, PID reuse and duplicate callbacks; a Debug
build passes. Manual downstream acceptance on 2026-08-13 confirmed that a
delayed callback no longer disconnects the replacement session after an active
route is revoked and the subscription falls back to Finland.

When upstream accepts a change, the downstream removes its duplicate patch
during the next synchronization and uses the upstream implementation.
