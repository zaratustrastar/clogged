import { describe, it, expect } from "vitest";
import { isStillResolvingTokenExistence } from "@/lib/hooks/useTokenData";

describe("isStillResolvingTokenExistence - transient 404 fix", () => {
  it("THE ORIGINAL BUG: a ticker missing from a stale discovery snapshot, right after a fresh launch, is treated as still-resolving (not confirmed-missing) while discovery is fetching", () => {
    // This is exactly the moment right after a successful reveal: the
    // just-launched ticker is genuinely not yet in the cached snapshot,
    // but a fresh discovery fetch (triggered by reveal()'s own
    // invalidation) is already in flight.
    expect(
      isStillResolvingTokenExistence({
        foundInSnapshot: false,
        discoveryIsLoading: false,
        discoveryIsFetching: true,
      })
    ).toBe(true);
  });

  it("is still-resolving on discovery's very first load too (isLoading), not only on a background refetch", () => {
    expect(
      isStillResolvingTokenExistence({
        foundInSnapshot: false,
        discoveryIsLoading: true,
        discoveryIsFetching: false,
      })
    ).toBe(true);
  });

  it("only concludes not-found once discovery has genuinely settled (not loading, not fetching) and the ticker is still missing", () => {
    expect(
      isStillResolvingTokenExistence({
        foundInSnapshot: false,
        discoveryIsLoading: false,
        discoveryIsFetching: false,
      })
    ).toBe(false);
  });

  it("never reports still-resolving once the ticker is actually found, regardless of discovery's own fetch state", () => {
    expect(
      isStillResolvingTokenExistence({
        foundInSnapshot: true,
        discoveryIsLoading: false,
        discoveryIsFetching: true,
      })
    ).toBe(false);
    expect(
      isStillResolvingTokenExistence({
        foundInSnapshot: true,
        discoveryIsLoading: false,
        discoveryIsFetching: false,
      })
    ).toBe(false);
  });
});
