import { spawnSync } from "node:child_process";
import { dirname, extname, join } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * `kanban vault ...` is `kv ...`: the arguments go to the kv entry point that
 * ships next to this CLI, unchanged, with this terminal's stdio. Its exit code
 * is returned as is, so a denial still exits 77.
 */
export function runVaultAlias(args: string[]): number {
  const self = fileURLToPath(import.meta.url);
  const kv = join(dirname(self), `kv${extname(self)}`);
  const child = spawnSync(process.execPath, [...process.execArgv, kv, ...args], { stdio: "inherit" });
  if (child.error) {
    process.stderr.write(`kanban vault: could not start kv: ${child.error.message}\n`);
    return 1;
  }
  if (child.signal) return 128 + (signalNumber(child.signal) ?? 1);
  return child.status ?? 1;
}

function signalNumber(signal: NodeJS.Signals): number | undefined {
  return (
    { SIGHUP: 1, SIGINT: 2, SIGQUIT: 3, SIGKILL: 9, SIGTERM: 15 } as Partial<Record<NodeJS.Signals, number>>
  )[signal];
}
