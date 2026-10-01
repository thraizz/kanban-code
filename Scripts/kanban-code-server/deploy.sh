#!/bin/bash
# Builds kanban-code-server on a Linux host and runs it there as a systemd service.
#
#   Scripts/kanban-code-server/deploy.sh [user@host]      (default root@51.159.202.175)
#
# The host needs a Swift 6.2 toolchain in /opt/swift (swift.org tarball for the
# distribution) plus zlib1g-dev. The committed tree (HEAD) is unpacked into
# ~/Projects/kanban-server on the host, built there in release mode with a static
# Swift runtime, installed as /usr/local/bin/kanban-code-server and restarted,
# with the `kanban export` helper next to it in /usr/local/bin/kanban-code-export.
# The CLI from the same tree is built there too (node + pnpm on the host) and
# installed into ~/.kanban-code/cli, which the host's `kanban` wrapper runs.
set -euo pipefail

HOST="${1:-root@51.159.202.175}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REMOTE_DIR="Projects/kanban-server"

git -C "$ROOT" archive --format=tar HEAD | ssh "$HOST" \
  "mkdir -p $REMOTE_DIR && cd $REMOTE_DIR && find . -mindepth 1 -maxdepth 1 ! -name .build -exec rm -rf {} + && tar x"

ssh "$HOST" bash -s <<REMOTE
set -euo pipefail
export PATH=/opt/swift/usr/bin:\$PATH
cd $REMOTE_DIR
swift build -c release --product kanban-code-server --static-swift-stdlib
swift build -c release --product kanban-code-export --static-swift-stdlib
install -m 0755 .build/release/kanban-code-server /usr/local/bin/kanban-code-server
install -m 0755 .build/release/kanban-code-export /usr/local/bin/kanban-code-export
install -m 0644 Scripts/kanban-code-server/kanban-code-server.service /etc/systemd/system/kanban-code-server.service
systemctl daemon-reload
systemctl enable kanban-code-server >/dev/null
systemctl restart kanban-code-server
for i in \$(seq 1 30); do curl -fsS -o /dev/null http://127.0.0.1:7780/v1/health && break; sleep 1; done
systemctl --no-pager --lines=5 status kanban-code-server
curl -fsS http://127.0.0.1:7780/v1/health
echo

cd cli
pnpm install --frozen-lockfile
pnpm build
rm -rf ~/.kanban-code/cli.new
mkdir -p ~/.kanban-code/cli.new
cp -a dist package.json node_modules docs ~/.kanban-code/cli.new/
rm -rf ~/.kanban-code/cli.old
if [ -d ~/.kanban-code/cli ]; then mv ~/.kanban-code/cli ~/.kanban-code/cli.old; fi
mv ~/.kanban-code/cli.new ~/.kanban-code/cli
rm -rf ~/.kanban-code/cli.old
/usr/bin/node ~/.kanban-code/cli/dist/kanban.js --version
REMOTE
