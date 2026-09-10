import { describe, it, expect } from "vitest";
import { generateTickerArtwork, escapeXml } from "@/lib/tickerArtwork";

describe("generateTickerArtwork", () => {
  it("is a valid, well-formed SVG document", () => {
    const svg = generateTickerArtwork("DOG", 1);
    expect(svg).toContain("<svg");
    expect(svg).toContain("</svg>");
    expect(svg).toContain("xmlns=\"http://www.w3.org/2000/svg\"");
  });

  it("prominently displays the canonical ticker with a $ prefix", () => {
    const svg = generateTickerArtwork("DOG", 1);
    expect(svg).toContain("$DOG");
  });

  it("includes CLOG branding", () => {
    const svg = generateTickerArtwork("DOG", 1);
    expect(svg).toContain("CLOG");
  });

  it("includes the token id", () => {
    const svg = generateTickerArtwork("DOG", 42);
    expect(svg).toContain("Ticker #42");
  });

  it("the exact same ticker and tokenId always produce byte-identical artwork", () => {
    const first = generateTickerArtwork("PEPE", 7);
    const second = generateTickerArtwork("PEPE", 7);
    expect(first).toBe(second);
  });

  it("two different tickers (same tokenId) produce visually different artwork", () => {
    const dog = generateTickerArtwork("DOG", 1);
    const pepe = generateTickerArtwork("PEPE", 1);
    expect(dog).not.toBe(pepe);
  });

  it("the same ticker with two different tokenIds produces different artwork", () => {
    // Tickers are unique per protocol rules, but this proves the generator's
    // determinism genuinely depends on both inputs together, not ticker alone.
    const first = generateTickerArtwork("DOG", 1);
    const second = generateTickerArtwork("DOG", 2);
    expect(first).not.toBe(second);
  });

  it("produces visibly distinct artwork across a representative set of tickers (not all collapsing to one look)", () => {
    const tickers = ["DOG", "PEPE", "CAT", "FROG", "BEAR", "FISH", "BIRD", "WOLF"];
    const outputs = tickers.map((t, i) => generateTickerArtwork(t, i + 1));
    const uniqueGradients = new Set(outputs.map((svg) => svg.match(/stop-color="(#[0-9A-Fa-f]{6})"/)?.[1]));
    expect(uniqueGradients.size).toBeGreaterThan(1);
  });
});

describe("escapeXml", () => {
  it("escapes all five XML special characters", () => {
    expect(escapeXml("&")).toBe("&amp;");
    expect(escapeXml("<")).toBe("&lt;");
    expect(escapeXml(">")).toBe("&gt;");
    expect(escapeXml("\"")).toBe("&quot;");
    expect(escapeXml("'")).toBe("&apos;");
  });

  it("neutralizes a markup injection attempt so no new element is introduced", () => {
    const malicious = "</text><script>alert(1)</script><text>";
    const escaped = escapeXml(malicious);
    expect(escaped).not.toContain("<script>");
    expect(escaped).not.toContain("</text>");
    expect(escaped).toContain("&lt;script&gt;");
  });

  it("a ticker-shaped injection attempt never breaks out of the generated SVG's text content", () => {
    // Tickers can currently only ever be A-Z on chain (TickerRegistry's
    // _normalize reverts on anything else), so this is defense in depth for
    // a path that isn't actually reachable today - proven anyway, since the
    // generator itself has no way to know that invariant holds forever.
    const svg = generateTickerArtwork("</text><image href=x onerror=alert(1)>", 1);
    expect(svg).not.toContain("<image href=x onerror=alert(1)>");
    expect(svg).toContain("&lt;/text&gt;&lt;image");
  });
});
