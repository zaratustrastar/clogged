import { describe, it, expect } from "vitest";
import { encodeEventTopics, encodeAbiParameters, type Log } from "viem";
import { parseLaunchedTokenIdFromReceipt } from "@/lib/hooks/useProtocolActions";
import { tickerRegistryAbi } from "@/lib/web3/abis/tickerRegistry";

const REGISTRY_ADDRESS = "0x111111111111111111111111111111111111111a";
const SENDER = "0x222222222222222222222222222222222222222b";
const MARKET = "0x333333333333333333333333333333333333333c";
const TOKEN = "0x444444444444444444444444444444444444444d";

/** Builds a real, correctly-encoded Launched event log using viem's own
 * ABI encoding (not hand-crafted hex) - a genuine round-trip: encode with
 * the real ABI here, decode with the real ABI inside the function under
 * test. */
function makeLaunchedLog(tokenId: number, ticker: string, overrideAddress?: string): Log {
  const topics = encodeEventTopics({
    abi: tickerRegistryAbi,
    eventName: "Launched",
    args: { sender: SENDER as `0x${string}`, tokenId: BigInt(tokenId) },
  });
  const data = encodeAbiParameters(
    [{ type: "string" }, { type: "address" }, { type: "address" }],
    [ticker, MARKET as `0x${string}`, TOKEN as `0x${string}`]
  );
  return {
    address: (overrideAddress ?? REGISTRY_ADDRESS) as `0x${string}`,
    data,
    topics,
  } as unknown as Log;
}

describe("parseLaunchedTokenIdFromReceipt", () => {
  it("extracts the real, authoritative tokenId from a genuine Launched event", () => {
    const logs = [makeLaunchedLog(1, "HOOD")];
    expect(parseLaunchedTokenIdFromReceipt(logs, REGISTRY_ADDRESS)).toBe(1);
  });

  it("is case-insensitive when matching the registry address (real addresses are checksummed inconsistently across sources)", () => {
    const logs = [makeLaunchedLog(1, "HOOD")];
    expect(parseLaunchedTokenIdFromReceipt(logs, REGISTRY_ADDRESS.toUpperCase())).toBe(1);
  });

  it("ignores logs from a different contract address entirely", () => {
    const logs = [makeLaunchedLog(1, "HOOD", "0x999999999999999999999999999999999999999f")];
    expect(parseLaunchedTokenIdFromReceipt(logs, REGISTRY_ADDRESS)).toBeNull();
  });

  it("ignores logs that aren't decodable against this ABI at all, without throwing", () => {
    const garbageLog = {
      address: REGISTRY_ADDRESS,
      data: "0xdeadbeef",
      topics: ["0x0000000000000000000000000000000000000000000000000000000000000001"],
    } as unknown as Log;
    expect(() => parseLaunchedTokenIdFromReceipt([garbageLog], REGISTRY_ADDRESS)).not.toThrow();
    expect(parseLaunchedTokenIdFromReceipt([garbageLog], REGISTRY_ADDRESS)).toBeNull();
  });

  it("finds the real Launched event even when other, unrelated logs are present in the same receipt", () => {
    const unrelated = {
      address: REGISTRY_ADDRESS,
      data: "0x",
      topics: ["0x" + "0".repeat(64)],
    } as unknown as Log;
    const logs = [unrelated, makeLaunchedLog(42, "PEPE")];
    expect(parseLaunchedTokenIdFromReceipt(logs, REGISTRY_ADDRESS)).toBe(42);
  });

  it("returns null (not a fabricated id) when the receipt has no logs at all", () => {
    expect(parseLaunchedTokenIdFromReceipt([], REGISTRY_ADDRESS)).toBeNull();
  });

  it("correctly extracts tokenId 0 - the first-ever launched token - which is falsy and must not be confused with 'not found'", () => {
    const logs = [makeLaunchedLog(0, "GENESIS")];
    const result = parseLaunchedTokenIdFromReceipt(logs, REGISTRY_ADDRESS);
    expect(result).toBe(0);
    expect(result).not.toBeNull();
  });
});
