import {describe, expect, it} from "vitest";
import {loadConfig, runsOnce} from "../src/config.js";
import {withGasFloor} from "../src/chain.js";

const KEY = `0x${"11".repeat(32)}`;
const VAULT = "0x2c720283A8Bbb5CC5b13C0C4Bcf2300826286c47";

const base = {PRIVATE_KEY: KEY, SYNTHETIC_VAULT_ADDRESS: VAULT};

describe("configuration", () => {
  /// Sending is opt-in. A keeper that spent money the first time somebody ran it to see what it did
  /// would be a bad way to learn what it does.
  it("is a dry run unless --send is passed", () => {
    expect(loadConfig(base, []).dryRun).toBe(true);
    expect(loadConfig(base, ["--send"]).dryRun).toBe(false);
  });

  it("reads the vault address in checksummed form", () => {
    expect(loadConfig(base, []).vault).toBe(VAULT);
  });

  it("accepts a lower-case address and checksums it", () => {
    const config = loadConfig({...base, SYNTHETIC_VAULT_ADDRESS: VAULT.toLowerCase()}, []);
    expect(config.vault).toBe(VAULT);
  });

  it("refuses a key that is not 32 bytes of hex", () => {
    expect(() => loadConfig({...base, PRIVATE_KEY: "nope"}, [])).toThrow(/32-byte hex/);
    expect(() => loadConfig({...base, PRIVATE_KEY: "0x1234"}, [])).toThrow(/32-byte hex/);
  });

  /// Failing at startup rather than at the first transaction. The alternative is discovering the
  /// vault address is missing halfway through a sweep.
  it("refuses to start without a vault address", () => {
    expect(() => loadConfig({PRIVATE_KEY: KEY}, [])).toThrow(/SYNTHETIC_VAULT_ADDRESS/);
  });

  it("refuses to start without a key", () => {
    expect(() => loadConfig({SYNTHETIC_VAULT_ADDRESS: VAULT}, [])).toThrow(/PRIVATE_KEY/);
  });

  it("refuses a nonsensical interval", () => {
    expect(() => loadConfig({...base, KEEPER_INTERVAL_SECONDS: "0"}, [])).toThrow(/positive/);
    expect(() => loadConfig({...base, KEEPER_INTERVAL_SECONDS: "soon"}, [])).toThrow(/positive/);
  });

  it("defaults to Arc testnet and a one-minute sweep", () => {
    const config = loadConfig(base, []);
    expect(config.chainId).toBe(5042002);
    expect(config.intervalSeconds).toBe(60);
    expect(config.minMaxFeePerGasWei).toBe(20_000_000_000n);
  });

  it("recognises --once", () => {
    expect(runsOnce(["--once"])).toBe(true);
    expect(runsOnce(["--send"])).toBe(false);
  });
});

describe("the gas floor", () => {
  const FLOOR = 20_000_000_000n;

  /// Arc rejects a transaction priced below 20 gwei outright. It is not slow; it is refused.
  it("raises a suggestion below the floor", () => {
    const priced = withGasFloor({maxFeePerGas: 1_000_000_000n}, FLOOR);
    expect(priced.maxFeePerGas).toBe(FLOOR);
  });

  it("leaves a suggestion above the floor alone", () => {
    const priced = withGasFloor({maxFeePerGas: 50_000_000_000n}, FLOOR);
    expect(priced.maxFeePerGas).toBe(50_000_000_000n);
  });

  it("uses the floor when the node suggests nothing", () => {
    expect(withGasFloor({}, FLOOR).maxFeePerGas).toBe(FLOOR);
  });

  /// A priority fee above the max fee makes a transaction the chain rejects for a second reason,
  /// which would look like the floor not working.
  it("never lets the priority fee exceed the max fee", () => {
    const priced = withGasFloor(
      {maxFeePerGas: 1_000_000_000n, maxPriorityFeePerGas: 99_000_000_000n},
      FLOOR,
    );
    expect(priced.maxPriorityFeePerGas).toBeLessThanOrEqual(priced.maxFeePerGas);
  });

  it("keeps a sensible priority fee as suggested", () => {
    const priced = withGasFloor(
      {maxFeePerGas: 30_000_000_000n, maxPriorityFeePerGas: 1_000_000_000n},
      FLOOR,
    );
    expect(priced.maxPriorityFeePerGas).toBe(1_000_000_000n);
  });
});

describe("restricting the sweep to one position", () => {
  /// The threshold is a global parameter, so lowering it to test a liquidation puts every other
  /// position in scope at the same time. This is how a test — or an operator — acts on exactly one.
  it("takes a token id", () => {
    expect(loadConfig(base, ["--token", "6"]).onlyToken).toBe(6n);
  });

  it("considers every position when not given one", () => {
    expect(loadConfig(base, []).onlyToken).toBeNull();
  });

  it("refuses a token id that is not a number", () => {
    expect(() => loadConfig(base, ["--token", "six"])).toThrow(/decimal token id/);
    expect(() => loadConfig(base, ["--token"])).toThrow(/decimal token id/);
  });
});
