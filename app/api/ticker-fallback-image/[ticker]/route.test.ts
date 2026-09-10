import { describe, it, expect } from "vitest";
import { NextRequest } from "next/server";
import { GET } from "@/app/api/ticker-fallback-image/[ticker]/route";

describe("app/api/ticker-fallback-image/[ticker] route", () => {
  it("returns an SVG with the correct content type", async () => {
    const res = await GET(new NextRequest("http://localhost/api/ticker-fallback-image/CAT"), {
      params: { ticker: "CAT" },
    });
    expect(res.headers.get("Content-Type")).toBe("image/svg+xml");
    const body = await res.text();
    expect(body).toContain("<svg");
    expect(body).toContain(">C<"); // the ticker's first letter
  });

  it("is deterministic - the same ticker always gets the same color", async () => {
    const res1 = await GET(new NextRequest("http://localhost/api/ticker-fallback-image/DOG"), {
      params: { ticker: "DOG" },
    });
    const res2 = await GET(new NextRequest("http://localhost/api/ticker-fallback-image/DOG"), {
      params: { ticker: "DOG" },
    });
    expect(await res1.text()).toBe(await res2.text());
  });

  it("different tickers can get different colors (not all collapsed to one)", async () => {
    const bodies = await Promise.all(
      ["CAT", "DOG", "FISH", "BIRD", "FROG", "BEAR"].map(async (t) => {
        const res = await GET(new NextRequest(`http://localhost/api/ticker-fallback-image/${t}`), {
          params: { ticker: t },
        });
        return res.text();
      })
    );
    const uniqueColors = new Set(bodies.map((b) => b.match(/fill="(#[0-9A-Fa-f]{6})"/)?.[1]));
    expect(uniqueColors.size).toBeGreaterThan(1);
  });
});
