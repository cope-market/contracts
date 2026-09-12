import {existsSync, mkdtempSync, readFileSync, writeFileSync} from "node:fs";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {describe, expect, it} from "vitest";
import {acquireLock} from "../src/pusher/lock.js";

function lockPath(): string {
  return join(mkdtempSync(join(tmpdir(), "cope-lock-")), "pusher.lock");
}

describe("the single-instance lock", () => {
  it("is taken when nothing holds it", () => {
    const path = lockPath();
    expect(acquireLock(path, process.pid)).toEqual({acquired: true, heldBy: null});
    expect(readFileSync(path, "utf8")).toBe(String(process.pid));
  });

  /// The failure this prevents: two pushers sharing a key produce intermittent "nonce too low"
  /// errors that look like an RPC problem rather than a second process.
  it("is refused while a live process holds it", () => {
    const path = lockPath();
    acquireLock(path, process.pid);

    const second = acquireLock(path, process.pid + 1);
    expect(second.acquired).toBe(false);
    expect(second.heldBy).toBe(process.pid);
  });

  /// A lock left behind by a process that was killed must not keep the service down forever. The
  /// check is whether that pid is alive, not how old the file is — a time-based check would either
  /// block a fresh start or steal a lock from a slow one.
  it("is taken over when its holder is gone", () => {
    const path = lockPath();
    // A pid that cannot be running: this process would have had to fork four billion times.
    writeFileSync(path, "4000000000");

    expect(acquireLock(path, process.pid).acquired).toBe(true);
    expect(readFileSync(path, "utf8")).toBe(String(process.pid));
  });

  /// The bug this was written after. The first version emptied the lock on exit instead of removing
  /// it, so the file still existed and the next start was refused by a process that had already
  /// exited. A clean shutdown became an outage.
  it("is taken over when the file is empty", () => {
    const path = lockPath();
    writeFileSync(path, "");

    expect(acquireLock(path, process.pid).acquired).toBe(true);
  });

  it("is taken over when the file holds something that is not a pid", () => {
    const path = lockPath();
    writeFileSync(path, "held by someone");

    expect(acquireLock(path, process.pid).acquired).toBe(true);
  });

  it("leaves the file in place for the holder to remove", () => {
    const path = lockPath();
    acquireLock(path, process.pid);
    expect(existsSync(path)).toBe(true);
  });
});
