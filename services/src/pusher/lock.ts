import {openSync, readFileSync, rmSync, writeFileSync} from "node:fs";

/// A single-instance lock.
///
/// Two pushers share a key and race nonces, and the symptom is intermittent "nonce too low"
/// failures that look like an RPC problem rather than a second process. This makes the second one
/// say so and exit.

export interface LockResult {
  acquired: boolean;
  /// The pid recorded in an existing lock, when there is one worth naming.
  heldBy: number | null;
}

/// True when a process with this pid is running.
///
/// Signal 0 performs the permission and existence checks without delivering anything. The distinction
/// that matters is ESRCH — no such process — from EPERM, which means it exists and belongs to
/// somebody else.
function isRunning(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}

export function acquireLock(path: string, pid: number): LockResult {
  try {
    // `wx` fails if the file exists, which is the whole point: the check and the create are one
    // operation, so two pushers starting together cannot both succeed.
    const handle = openSync(path, "wx");
    writeFileSync(handle, String(pid));
    return {acquired: true, heldBy: null};
  } catch {
    // Something is there. Whether it matters depends on whether that process still exists.
  }

  let holder: number | null = null;
  try {
    const contents = readFileSync(path, "utf8").trim();
    holder = /^\d+$/.test(contents) ? Number(contents) : null;
  } catch {
    holder = null;
  }

  // A lock left behind by a process that is gone — killed, or crashed before its exit handler ran —
  // must not keep the service down forever. Taking it over is safe precisely because the check is
  // about a live pid rather than about the file's age.
  if (holder === null || !isRunning(holder)) {
    try {
      rmSync(path, {force: true});
      const handle = openSync(path, "wx");
      writeFileSync(handle, String(pid));
      return {acquired: true, heldBy: null};
    } catch {
      return {acquired: false, heldBy: holder};
    }
  }

  return {acquired: false, heldBy: holder};
}
