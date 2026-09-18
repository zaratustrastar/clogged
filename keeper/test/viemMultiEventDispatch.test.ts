import { describe, it, expect } from "vitest";
import { encodeEventTopics, encodeAbiParameters, parseEventLogs, getAbiItem, type Log, type AbiEvent } from "viem";
import { RoundLedger } from "../src/roundLedger.js";
import { TokenWatchlist } from "../src/tokenWatchlist.js";
import { roundManagerAbi } from "../src/abis/roundManager.js";
import { bondingCurveClogAbi } from "../src/abis/bondingCurveClog.js";

const ROUND_MANAGER = "0x101010101010101010101010101010101010100d" as `0x${string}`;
const MARKET = "0x202020202020202020202020202020202020200a" as `0x${string}`;
const BUYER = "0x30303030303030303030303030303030303030af" as `0x${string}`; // all-lowercase, 40 hex chars - EIP-55 exempts these from checksum validation

/** Builds a real, raw (unparsed) log the way an actual eth_getLogs response
 * would shape one - real topics for indexed args AND real ABI-encoded
 * `data` for non-indexed args (both via viem's own encoding utilities, not
 * strings we invented), plus the standard log envelope fields. This is
 * genuinely exercising viem's own event-decoding pipeline (parseEventLogs),
 * not asserting anything about our own mocks' behavior. */
function makeRawLog(params: { address: `0x${string}`; abi: readonly unknown[]; eventName: string; args: Record<string, unknown>; blockNumber: bigint; logIndex: number }): Log {
  const topics = encodeEventTopics({ abi: params.abi, eventName: params.eventName, args: params.args } as never);
  const abiEvent = getAbiItem({ abi: params.abi, name: params.eventName } as never) as AbiEvent;
  const nonIndexedInputs = abiEvent.inputs.filter((input) => !("indexed" in input && input.indexed));
  const data =
    nonIndexedInputs.length > 0
      ? encodeAbiParameters(
          nonIndexedInputs,
          nonIndexedInputs.map((input) => params.args[input.name as string])
        )
      : "0x";
  return {
    address: params.address,
    topics,
    data,
    blockNumber: params.blockNumber,
    blockHash: `0x${"11".repeat(32)}` as `0x${string}`,
    transactionHash: `0x${"22".repeat(32)}` as `0x${string}`,
    transactionIndex: 0,
    logIndex: params.logIndex,
    removed: false,
  } as unknown as Log;
}

describe("REQUIREMENT: real viem multi-event decoding dispatches correctly by eventName (not just our own mock assumptions)", () => {
  it("RoundLedger: RoundClosed, RandomnessRequested, and RoundSettled, decoded together by real viem parseEventLogs, land in the correct internal maps", async () => {
    const rawLogs = [
      makeRawLog({ address: ROUND_MANAGER, abi: roundManagerAbi, eventName: "RoundClosed", args: { roundId: 7n, closeTime: 1000n, candidateCount: 3n, drawSkipped: false }, blockNumber: 100n, logIndex: 0 }),
      makeRawLog({ address: ROUND_MANAGER, abi: roundManagerAbi, eventName: "RandomnessRequested", args: { roundId: 7n, requestId: 55n }, blockNumber: 101n, logIndex: 0 }),
      makeRawLog({ address: ROUND_MANAGER, abi: roundManagerAbi, eventName: "RoundClosed", args: { roundId: 8n, closeTime: 1100n, candidateCount: 5n, drawSkipped: false }, blockNumber: 102n, logIndex: 0 }),
    ];

    // Real viem decoding - the exact function getContractEvents/getLogs
    // uses internally when given multiple events with no eventName
    // filter (confirmed directly against viem's own source). This is
    // what actually assigns each returned object its own `.eventName`
    // field, not an assumption our own mocks encode.
    const decoded = parseEventLogs({ abi: roundManagerAbi, logs: rawLogs });
    expect(decoded).toHaveLength(3);
    expect(decoded.map((l) => l.eventName)).toEqual(["RoundClosed", "RandomnessRequested", "RoundClosed"]);

    const fakeClient = {
      getBlockNumber: async () => 200n,
      getContractEvents: async () => decoded,
    } as unknown as Parameters<typeof RoundLedger.build>[0];

    const ledger = await RoundLedger.build(fakeClient, ROUND_MANAGER, 0n, 1_000_000n);

    // Round 7: closed then requested - needs relay, not retry.
    expect(ledger.needsRandomnessRetry()).toEqual([8n]);
    expect(ledger.needsRelayCheck()).toEqual([{ roundId: 7n, requestId: 55n }]);
  });

  it("RoundLedger: a real RoundSettled (decoded via real viem parseEventLogs) removes the round from every outstanding map, exactly as the hand-built mocks assert elsewhere", async () => {
    const rawLogs = [
      makeRawLog({ address: ROUND_MANAGER, abi: roundManagerAbi, eventName: "RoundClosed", args: { roundId: 7n, closeTime: 1000n, candidateCount: 3n, drawSkipped: false }, blockNumber: 100n, logIndex: 0 }),
      makeRawLog({ address: ROUND_MANAGER, abi: roundManagerAbi, eventName: "RandomnessRequested", args: { roundId: 7n, requestId: 55n }, blockNumber: 101n, logIndex: 0 }),
      makeRawLog({ address: ROUND_MANAGER, abi: roundManagerAbi, eventName: "RoundSettled", args: { roundId: 7n, winnerTokenId: 3n, randomWord: 999n }, blockNumber: 103n, logIndex: 0 }),
    ];
    const decoded = parseEventLogs({ abi: roundManagerAbi, logs: rawLogs });

    const fakeClient = {
      getBlockNumber: async () => 200n,
      getContractEvents: async () => decoded,
    } as unknown as Parameters<typeof RoundLedger.build>[0];

    const ledger = await RoundLedger.build(fakeClient, ROUND_MANAGER, 0n, 1_000_000n);

    expect(ledger.needsRandomnessRetry()).toEqual([]);
    expect(ledger.needsRelayCheck()).toEqual([]);
    expect(ledger.outstandingCount).toBe(0);
  });

  it("TokenWatchlist: real viem-decoded Bought AND Sold logs (from the multi-event ABI) resolve to the correct tokenId via the emitting market address only - never from event args, and an unrelated emitting contract's identically-shaped log is ignored", async () => {
    const UNRELATED_CONTRACT = "0x9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e" as `0x${string}`;
    const rawLogs = [
      makeRawLog({
        address: MARKET,
        abi: bondingCurveClogAbi,
        eventName: "Bought",
        args: { buyer: BUYER, grossEthIn: 1n, buyTax: 0n, curveEthIn: 1n, curveTokensOut: 1n, clogEthIn: 0n, clogTokensOut: 0n, clogExtracted: 0n, clogRetained: 0n },
        blockNumber: 300n,
        logIndex: 0,
      }),
      makeRawLog({
        address: MARKET,
        abi: bondingCurveClogAbi,
        eventName: "Sold",
        args: { seller: BUYER, tokensIn: 1n, grossEthOut: 1n, sellTax: 0n, netEthOut: 1n, wasCapped: false },
        blockNumber: 301n,
        logIndex: 0,
      }),
      // A log from a contract this watchlist has never heard of, but with
      // a real, correctly-encoded Bought event (same topic0, so it WOULD
      // be returned by an address-less eth_getLogs filter, exactly as
      // this design expects) - the local marketToTokenId lookup below
      // must silently ignore it, not error or misattribute it to a known
      // token.
      makeRawLog({
        address: UNRELATED_CONTRACT,
        abi: bondingCurveClogAbi,
        eventName: "Bought",
        args: { buyer: BUYER, grossEthIn: 1n, buyTax: 0n, curveEthIn: 1n, curveTokensOut: 1n, clogEthIn: 0n, clogTokensOut: 0n, clogExtracted: 0n, clogRetained: 0n },
        blockNumber: 302n,
        logIndex: 0,
      }),
    ];
    const decoded = parseEventLogs({ abi: bondingCurveClogAbi, logs: rawLogs });
    expect(decoded).toHaveLength(3);
    expect(decoded.map((l) => l.eventName)).toEqual(["Bought", "Sold", "Bought"]);
    // Confirms tokenId is never even present in the decoded args to infer
    // from in the first place - only buyer/seller/amounts, exactly as
    // documented in tokenWatchlist.ts's own reliability note.
    expect((decoded[0].args as Record<string, unknown>).tokenId).toBeUndefined();
    expect((decoded[1].args as Record<string, unknown>).tokenId).toBeUndefined();

    const fakeClient = {
      getBlockNumber: async () => 400n,
      getLogs: async () => decoded,
      readContract: async () => 12345n,
    } as unknown as Parameters<typeof TokenWatchlist.withKnownTokens>[0];

    const watchlist = TokenWatchlist.withKnownTokens(
      fakeClient,
      "0xe0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0" as `0x${string}`,
      [{ tokenId: 9n, market: MARKET }],
      1_000_000n
    );

    const traded = await watchlist.scanForTradeActivity();
    // Only tokenId 9 (MARKET's own token) - the unrelated contract's log
    // never resolves to anything, silently, exactly as designed.
    expect(traded).toEqual([9n]);
  });
});
