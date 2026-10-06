#!/usr/bin/env node
import { runKv, VaultCliError } from "./vault.js";

// Pipes are asynchronous in Node: exit only once stdout and stderr are flushed,
// or a long `kv ls --json | ...` ends cut at 64 KiB.
const exit = (code: number) =>
  process.stdout.write("", () => process.stderr.write("", () => process.exit(code)));

runKv(process.argv.slice(2)).then(
  (code) => exit(code),
  (error) => {
    if (error instanceof VaultCliError) {
      process.stderr.write(error.message + "\n");
      exit(error.code);
      return;
    }
    process.stderr.write(`kv: ${(error as Error)?.stack ?? error}\n`);
    exit(1);
  }
);
