/**
 * Paired devices of the remote control server, kept in
 * `~/.kanban-code/remote/devices.json`. The Mac app reads and writes the same
 * file (docs/remote-control.md), so the format here is the wire format:
 *
 *   {"devices":[{"id","name","scope","tokenHash","createdAt","lastSeenAt"}]}
 *
 * Only the SHA-256 of a token is stored. Unknown keys, on the file and on each
 * device, are kept as they are.
 */

import { createHash, randomBytes, randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { hostname } from "node:os";
import { dirname, join } from "node:path";
import { kanbanHome } from "./paths.js";

export type RemoteScope = "full" | "agent" | "peer" | "terminal";

export const REMOTE_SCOPES: readonly RemoteScope[] = ["full", "agent", "peer", "terminal"];
export const REMOTE_DEFAULT_PORT = 7780;

export interface PairedDevice {
  id: string;
  name: string;
  scope: RemoteScope;
  tokenHash: string;
  createdAt: string;
  lastSeenAt: string | null;
  [key: string]: unknown;
}

interface DevicesFile {
  devices: PairedDevice[];
  [key: string]: unknown;
}

export function remoteDevicesPath(): string {
  return join(kanbanHome(), "remote", "devices.json");
}

const BASE62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const TOKEN_LENGTH = 40;

/** `kc_` plus 40 base62 characters, drawn without modulo bias. */
export function generateRemoteToken(): string {
  let out = "";
  while (out.length < TOKEN_LENGTH) {
    for (const byte of randomBytes(64)) {
      // 248 = 62 * 4: bytes at or above it would favour the first characters.
      if (byte >= 248) continue;
      out += BASE62[byte % 62];
      if (out.length === TOKEN_LENGTH) break;
    }
  }
  return `kc_${out}`;
}

export function hashRemoteToken(token: string): string {
  return createHash("sha256").update(token, "utf8").digest("hex");
}

export function readDevicesFile(path = remoteDevicesPath()): DevicesFile {
  if (!existsSync(path)) return { devices: [] };
  const raw = readFileSync(path, "utf8");
  if (raw.trim() === "") return { devices: [] };
  const parsed = JSON.parse(raw) as DevicesFile;
  if (!parsed || typeof parsed !== "object" || !Array.isArray(parsed.devices)) {
    throw new Error(`${path} is not a devices file: expected {"devices": [...]}`);
  }
  return parsed;
}

/** Writes through a temp file and a rename, so the server never reads half a file. */
export function writeDevicesFile(file: DevicesFile, path = remoteDevicesPath()): void {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const tmp = `${path}.${process.pid}.${Date.now()}.tmp`;
  writeFileSync(tmp, JSON.stringify(file, null, 2) + "\n", { mode: 0o600 });
  chmodSync(tmp, 0o600);
  renameSync(tmp, path);
}

export function listDevices(path = remoteDevicesPath()): PairedDevice[] {
  return readDevicesFile(path).devices;
}

export function addDevice(
  name: string,
  scope: RemoteScope,
  path = remoteDevicesPath(),
  now = new Date()
): { device: PairedDevice; token: string } {
  const trimmed = name.trim();
  if (!trimmed) throw new Error("A device needs a name.");
  if (!REMOTE_SCOPES.includes(scope)) {
    throw new Error(`Unknown scope '${scope}'. Use full or agent.`);
  }
  const file = readDevicesFile(path);
  const token = generateRemoteToken();
  const device: PairedDevice = {
    id: randomUUID().toLowerCase(),
    name: trimmed,
    scope,
    tokenHash: hashRemoteToken(token),
    createdAt: now.toISOString(),
    lastSeenAt: null,
  };
  file.devices.push(device);
  writeDevicesFile(file, path);
  return { device, token };
}

/** Removes a device by id, or by name when exactly one device has that name. */
export function revokeDevice(idOrName: string, path = remoteDevicesPath()): PairedDevice {
  const file = readDevicesFile(path);
  let index = file.devices.findIndex((d) => d.id === idOrName);
  if (index < 0) {
    const wanted = idOrName.trim().toLowerCase();
    const byName = file.devices
      .map((d, i) => ({ d, i }))
      .filter(({ d }) => typeof d.name === "string" && d.name.toLowerCase() === wanted);
    if (byName.length > 1) {
      const ids = byName.map(({ d }) => d.id).join(", ");
      throw new Error(`${byName.length} devices are named '${idOrName}'. Revoke one by id: ${ids}`);
    }
    index = byName[0]?.i ?? -1;
  }
  if (index < 0) throw new Error(`No paired device '${idOrName}'. See kanban remote devices.`);
  const [removed] = file.devices.splice(index, 1);
  writeDevicesFile(file, path);
  return removed;
}

// ── Pairing link ─────────────────────────────────────────────────────

const WILDCARDS = new Set(["0.0.0.0", "::"]);

/**
 * The address and port the Mac's remote control answers other machines on:
 * the first address of `remoteControl.bindAddresses` in settings.json that is
 * not a wildcard (an IPv4 one first) and its `remoteControl.port`, as the app's
 * own pairing link uses them. Undefined parts when nothing is configured.
 */
export function configuredRemoteAddress(
  read: () => string = () => readFileSync(join(kanbanHome(), "settings.json"), "utf8")
): { host?: string; port?: number } {
  let remote: { bindAddresses?: unknown; port?: unknown } | undefined;
  try {
    remote = (JSON.parse(read()) as { remoteControl?: typeof remote }).remoteControl;
  } catch {
    return {};
  }
  const addresses = (Array.isArray(remote?.bindAddresses) ? remote.bindAddresses : [])
    .filter((a): a is string => typeof a === "string")
    .map((a) => a.trim().replace(/^\[(.*)\]$/, "$1").replace(/%.*$/, ""))
    .filter((a) => a && !WILDCARDS.has(a));
  const ip = addresses.find((a) => !a.includes(":")) ?? addresses[0];
  const port = typeof remote?.port === "number" && remote.port > 0 ? remote.port : undefined;
  return { host: ip === undefined ? undefined : ip.includes(":") ? `[${ip}]` : ip, port };
}

export function defaultServerUrl(address = configuredRemoteAddress()): string {
  return `http://${address.host ?? "127.0.0.1"}:${address.port ?? REMOTE_DEFAULT_PORT}`;
}

/** The Mac's name as the app shows it (System Settings > General > Sharing), else the host name. */
export function macHostName(): string {
  if (process.platform === "darwin") {
    try {
      const name = execFileSync("scutil", ["--get", "ComputerName"], {
        encoding: "utf8",
        timeout: 2000,
        stdio: ["ignore", "pipe", "ignore"],
      }).trim();
      if (name) return name;
    } catch {
      // Fall back to the host name.
    }
  }
  return hostname().replace(/\.local$/, "");
}

export function pairingLink(url: string, token: string, name = macHostName()): string {
  const e = encodeURIComponent;
  return `kanbancode://pair?url=${e(url)}&token=${e(token)}&name=${e(name)}`;
}
