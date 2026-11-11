#!/bin/bash
# Builds kanban-code-server on a Linux host and runs it there as a systemd service.
#
#   Scripts/kanban-code-server/deploy.sh [user@host]      (default root@51.159.202.175)
#
# The host needs a Swift 6.2 toolchain in /opt/swift (swift.org tarball for the
# distribution) or on its PATH, plus zlib (zlib1g-dev on Debian). The target user
# may be root or a normal user; a normal user needs passwordless sudo (`sudo -n`)
# for the install and systemctl steps, and the service then runs as that user
# with its HOME. The committed tree (HEAD) is unpacked into
# ~/Projects/kanban-server on the host, built there in release mode with a static
# Swift runtime, installed as /usr/local/bin/kanban-code-server and restarted,
# with the `kanban export` helper next to it in /usr/local/bin/kanban-code-export.
# The CLI from the same tree is built there too (node + pnpm on the host) and
# installed into ~/.kanban-code/cli, which the host's `kanban` wrapper runs.
set -euo pipefail

HOST="${1:-root@51.159.202.175}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REMOTE_DIR="Projects/kanban-server"

# Stamp of the installed CLI: the Mac app keeps a CLI stamped this way until
# its own bundle was built after this deploy (BoxdMachineSupervisor.shouldInstallCli).
CLI_STAMP="deploy:$(date +%s):$(git -C "$ROOT" rev-parse --short HEAD)"

TARBALL="/tmp/kanban-code-src-$$.tar"
git -C "$ROOT" archive --format=tar HEAD | ssh "$HOST" "cat > $TARBALL"

# One deploy at a time: two at once race on the source tree, the SwiftPM
# build folder and the CLI copy, and starve the host of memory.
ssh "$HOST" flock /tmp/kanban-code-deploy.lock bash -s <<REMOTE
set -euo pipefail
export PATH=/opt/swift/usr/bin:\$PATH
SUDO=""
if [ "\$(id -u)" -ne 0 ]; then SUDO="sudo -n"; fi
RUN_USER=\$(id -un)
mkdir -p $REMOTE_DIR
cd $REMOTE_DIR
find . -mindepth 1 -maxdepth 1 ! -name .build -exec rm -rf {} +
tar xf $TARBALL
rm -f $TARBALL
swift build -c release -j 4 --product kanban-code-server --static-swift-stdlib
swift build -c release -j 4 --product kanban-code-export --static-swift-stdlib
\$SUDO install -m 0755 .build/release/kanban-code-server /usr/local/bin/kanban-code-server
\$SUDO install -m 0755 .build/release/kanban-code-export /usr/local/bin/kanban-code-export
# The unit is written for root; run it as the deploying user, with their HOME.
sed -e "s|^User=root|User=\$RUN_USER|" -e "s|/root|\$HOME|g" Scripts/kanban-code-server/kanban-code-server.service \\
  | \$SUDO tee /etc/systemd/system/kanban-code-server.service >/dev/null
\$SUDO systemctl daemon-reload
\$SUDO systemctl enable kanban-code-server >/dev/null
# Everything is built and installed before this point, so the API is down
# only for the restart itself.
RESTART_AT=\$(date +%s.%N)
\$SUDO systemctl restart kanban-code-server
for i in \$(seq 1 600); do curl -fsS -m 1 -o /dev/null http://127.0.0.1:7780/v1/health && break; sleep 0.1; done
awk -v a=\$RESTART_AT -v b=\$(date +%s.%N) 'BEGIN { printf "remote API back %.2f s after the restart\\n", b - a }'
systemctl --no-pager --lines=5 status kanban-code-server
curl -fsS http://127.0.0.1:7780/v1/health
echo

cd cli
pnpm install --frozen-lockfile
pnpm build
NEW=\$(mktemp -d ~/.kanban-code/cli.new.XXXXXX)
cp -a dist package.json node_modules docs "\$NEW"/
printf '%s' '$CLI_STAMP' > "\$NEW"/VERSION
chmod 755 "\$NEW"
rm -rf ~/.kanban-code/cli.old
if [ -d ~/.kanban-code/cli ]; then mv ~/.kanban-code/cli ~/.kanban-code/cli.old; fi
mv "\$NEW" ~/.kanban-code/cli
rm -rf ~/.kanban-code/cli.old ~/.kanban-code/cli.new
/usr/bin/node ~/.kanban-code/cli/dist/kanban.js --version
mkdir -p ~/.local/bin
printf '#!/bin/sh\nexec /usr/bin/node %s/.kanban-code/cli/dist/kv.js "\$@"\n' "\$HOME" > ~/.local/bin/kv
chmod 755 ~/.local/bin/kv
REMOTE
