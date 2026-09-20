import { describe, it, expect } from "vitest";
import { shouldResetImageFailure } from "@/components/machine/tokenAvatarLogic";

describe("shouldResetImageFailure", () => {
  it("returns true when a broken image's imageUrl changes to a new, different one - the exact bug this exists to fix", () => {
    // A stale failure from the PREVIOUS imageUrl must not silently persist
    // onto a new one - useTokenDiscovery's own polling refetch can hand
    // TokenAvatar a fixed imageUrl for the same token without ever
    // remounting the component.
    expect(shouldResetImageFailure("/uploads/broken.png", "/uploads/fixed.png")).toBe(true);
  });

  it("returns false when imageUrl is unchanged - a re-render for some unrelated reason must not wipe out a failure that's still accurate", () => {
    expect(shouldResetImageFailure("/uploads/same.png", "/uploads/same.png")).toBe(false);
  });

  it("returns true when imageUrl changes from null to a real URL", () => {
    expect(shouldResetImageFailure(null, "/uploads/new.png")).toBe(true);
  });

  it("returns true when imageUrl changes from a real URL to null (e.g. the profile's image was cleared)", () => {
    expect(shouldResetImageFailure("/uploads/old.png", null)).toBe(true);
  });

  it("treats null and undefined as the same 'no image' value - no false reset between them", () => {
    expect(shouldResetImageFailure(null, undefined)).toBe(false);
    expect(shouldResetImageFailure(undefined, null)).toBe(false);
  });

  it("returns false when both are null (or both undefined) - never an image, nothing changed", () => {
    expect(shouldResetImageFailure(null, null)).toBe(false);
    expect(shouldResetImageFailure(undefined, undefined)).toBe(false);
  });

  it("returns true for a change between two different real URLs, not just to/from null", () => {
    expect(shouldResetImageFailure("/uploads/a.png", "/uploads/b.png")).toBe(true);
  });
});
