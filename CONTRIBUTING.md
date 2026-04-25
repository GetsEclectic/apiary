# Contributing

Bug reports, fixes, and small features are all welcome. For anything larger than a one-file change, please open an issue first to sanity-check the direction.

## Running the tests

There are two test layers, both wired into CI ([`.github/workflows/test.yml`](.github/workflows/test.yml)).

### Container smoke test (Linux)

Builds the repo into an Ubuntu 24.04 image, runs `install.sh` inside it as a non-root user, brings up the systemd user units, and exercises the mTLS surface end-to-end.

```bash
./test/container/test.sh
```

Requires Docker. The image build uses the repo root as build context, so the test always runs against your working tree.

### Browser e2e (developer machine)

[`test/e2e.sh`](test/e2e.sh) drives the wterm-on-ttyd stack through real headless browsers. It expects parallel `*-e2e` systemd user units listening on `:3543` / `:3544` (the production stack stays untouched on `:3443` / `:3441`). It is currently scaffolded against the maintainer's laptop setup; if you want to extend a scenario in `test/scenarios/`, the per-scenario shell scripts are the unit of work and should be runnable individually.

### macOS

The macOS install path is exercised by the `macos` job in CI on `macos-14` runners. There is no local-machine driver script — if you need to verify a macOS change locally, mirror the steps from the workflow.

## Pull requests

- One logical change per PR.
- CI must be green. Both jobs run on every push and PR.
- Keep commit messages in the existing terse, lowercase, area-prefixed style (e.g. `tmux-api: strip trailing newline from /scrollback payload`).
- Don't bump version strings or tag releases in PRs. Tagging is done from `master` after merge.

## Reporting security issues

Do not open a public issue. Use the [private security advisory](https://github.com/GetsEclectic/apiary/security/advisories/new) flow instead. See [SECURITY.md](SECURITY.md) for the trust model.
