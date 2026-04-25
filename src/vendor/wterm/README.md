# wterm vendor

Pre-built tarballs of [GetsEclectic/wterm](https://github.com/GetsEclectic/wterm), a fork of [vercel-labs/wterm](https://github.com/vercel-labs/wterm). The fork is one commit deep — `MAX_SCROLLBACK_LINES` raised from 1,000 to 10,000 in `src/scrollback.zig`, needed because apiary's tmux panes routinely have scrollbacks past the upstream cap.

Vendored rather than published to npm because it's a single-consumer fork of a single constant; a published package would imply ongoing maintenance that doesn't match the actual scope.

To rebuild: clone the fork, `pnpm install && pnpm --filter './packages/@wterm/*' pack`, drop the resulting `wterm-{core,dom}-<version>.tgz` files here, and bump the version refs in `src/package.json`.
