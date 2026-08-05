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
| No downstream patches yet | — | — | — |

When upstream accepts a change, the downstream removes its duplicate patch
during the next synchronization and uses the upstream implementation.
