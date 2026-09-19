import { describe, it, expect } from "vitest";
import { generateTickerArtworkV1, generateTickerArtworkV2, escapeXml } from "@/lib/tickerArtwork";

describe("generateTickerArtworkV1", () => {
  it("is a valid, well-formed SVG document", () => {
    const svg = generateTickerArtworkV1("DOG", 1);
    expect(svg).toContain("<svg");
    expect(svg).toContain("</svg>");
    expect(svg).toContain("xmlns=\"http://www.w3.org/2000/svg\"");
  });

  it("prominently displays the canonical ticker with a $ prefix", () => {
    const svg = generateTickerArtworkV1("DOG", 1);
    expect(svg).toContain("$DOG");
  });

  it("includes CLOG branding", () => {
    const svg = generateTickerArtworkV1("DOG", 1);
    expect(svg).toContain("CLOG");
  });

  it("includes the token id", () => {
    const svg = generateTickerArtworkV1("DOG", 42);
    expect(svg).toContain("Ticker #42");
  });

  it("the exact same ticker and tokenId always produce byte-identical artwork", () => {
    const first = generateTickerArtworkV1("PEPE", 7);
    const second = generateTickerArtworkV1("PEPE", 7);
    expect(first).toBe(second);
  });

  it("two different tickers (same tokenId) produce visually different artwork", () => {
    const dog = generateTickerArtworkV1("DOG", 1);
    const pepe = generateTickerArtworkV1("PEPE", 1);
    expect(dog).not.toBe(pepe);
  });

  it("the same ticker with two different tokenIds produces different artwork", () => {
    // Tickers are unique per protocol rules, but this proves the generator's
    // determinism genuinely depends on both inputs together, not ticker alone.
    const first = generateTickerArtworkV1("DOG", 1);
    const second = generateTickerArtworkV1("DOG", 2);
    expect(first).not.toBe(second);
  });

  it("produces visibly distinct artwork across a representative set of tickers (not all collapsing to one look)", () => {
    const tickers = ["DOG", "PEPE", "CAT", "FROG", "BEAR", "FISH", "BIRD", "WOLF"];
    const outputs = tickers.map((t, i) => generateTickerArtworkV1(t, i + 1));
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
    const svg = generateTickerArtworkV1("</text><image href=x onerror=alert(1)>", 1);
    expect(svg).not.toContain("<image href=x onerror=alert(1)>");
    expect(svg).toContain("&lt;/text&gt;&lt;image");
  });
});

describe("generateTickerArtworkV2", () => {
  // Real, measured safe-area bounds (see lib/tickerArtwork.ts's own docs on
  // how these were scanned directly against the base image's real pixel
  // content) - mirrored here so these tests assert against the same real
  // numbers the generator itself uses, not independently-guessed values
  // that could drift from the implementation without either side noticing.
  const MAIN_TICKER_SAFE_WIDTH = 660;
  const MAIN_TICKER_BASELINE_Y = 420;
  const TOKEN_ID_PLAQUE_SAFE_WIDTH = 620;
  const TOKEN_ID_PLAQUE_BASELINE_Y = 726;
  // The plaque's own real measured vertical span (metal divider to bottom
  // border) - the main ticker's own text element must never fall inside
  // this range, and the token-id element must always fall inside it.
  const PLAQUE_TOP_Y = 655;
  const PLAQUE_BOTTOM_Y = 780;

  function extractTextElement(svg: string, textContentPattern: string): { y: number; textLength: number } | null {
    const re = new RegExp(`<text[^>]*\\by="([\\d.]+)"[^>]*textLength="([\\d.]+)"[^>]*>${textContentPattern}`);
    const match = svg.match(re);
    if (!match) return null;
    return { y: Number(match[1]), textLength: Number(match[2]) };
  }

  it("is a valid, well-formed SVG document, self-contained with an embedded base image and no external references", () => {
    const svg = generateTickerArtworkV2("DOG", 1);
    expect(svg).toContain("<svg");
    expect(svg).toContain("</svg>");
    expect(svg).toContain('xmlns="http://www.w3.org/2000/svg"');
    // The base artwork is embedded as a data URI, never an external URL -
    // the whole point of the marketplace-safety requirement this satisfies.
    expect(svg).toContain('href="data:image/jpeg;base64,');
    expect(svg).not.toMatch(/href="https?:\/\//);
    expect(svg).not.toMatch(/href="\/(?!\S*base64)/); // no root-relative nested image reference either
  });

  it("never references an external font (@import/@font-face/<link>) - only system font-family fallback stacks", () => {
    const svg = generateTickerArtworkV2("DOG", 1);
    expect(svg).not.toContain("@import");
    expect(svg).not.toContain("@font-face");
    expect(svg).not.toContain("<link");
    expect(svg).not.toMatch(/fonts\.googleapis\.com|fonts\.gstatic\.com/);
  });

  it("prominently displays the canonical ticker with a $ prefix", () => {
    const svg = generateTickerArtworkV2("DOG", 1);
    expect(svg).toContain("$DOG");
  });

  it("includes the token id in the TICKER #<id> form", () => {
    const svg = generateTickerArtworkV2("DOG", 42);
    expect(svg).toContain("TICKER #42");
  });

  describe("distinct coordinate regions - $TICKER in the central glass area, TICKER #<id> only in the lower plaque", () => {
    it("the main $TICKER text element sits at the glass area's own baseline, well above the plaque's real top edge", () => {
      const svg = generateTickerArtworkV2("DOG", 1);
      const el = extractTextElement(svg, "\\$DOG");
      expect(el, "main ticker text element must be found").not.toBeNull();
      expect(el!.y).toBe(MAIN_TICKER_BASELINE_Y);
      expect(el!.y).toBeLessThan(PLAQUE_TOP_Y);
    });

    it("the TICKER #<id> text element sits at the plaque's own baseline, within the plaque's real measured vertical span", () => {
      const svg = generateTickerArtworkV2("DOG", 1);
      const el = extractTextElement(svg, "TICKER #1");
      expect(el, "token-id text element must be found").not.toBeNull();
      expect(el!.y).toBe(TOKEN_ID_PLAQUE_BASELINE_Y);
      expect(el!.y).toBeGreaterThan(PLAQUE_TOP_Y);
      expect(el!.y).toBeLessThan(PLAQUE_BOTTOM_Y);
    });

    it("$TICKER never appears with a plaque-range y-coordinate, and TICKER #<id> never appears with the glass-area y-coordinate - the two zones never swap", () => {
      const svg = generateTickerArtworkV2("DOG", 1);
      const tickerEl = extractTextElement(svg, "\\$DOG")!;
      const tokenEl = extractTextElement(svg, "TICKER #1")!;
      expect(tickerEl.y).not.toBe(tokenEl.y);
      expect(tokenEl.y).not.toBe(MAIN_TICKER_BASELINE_Y);
      expect(tickerEl.y).not.toBe(TOKEN_ID_PLAQUE_BASELINE_Y);
    });

    it("the main ticker is visually dominant: its font-size is always strictly larger than the token-id line's fixed, small font-size", () => {
      const svg = generateTickerArtworkV2("DOGE", 1);
      const tickerFontSize = Number(svg.match(/font-size="([\d.]+)"[^>]*font-weight="900"/)?.[1]);
      const tokenFontSize = Number(svg.match(/font-size="([\d.]+)"[^>]*font-weight="700"/)?.[1]);
      expect(tickerFontSize).toBeGreaterThan(0);
      expect(tokenFontSize).toBeGreaterThan(0);
      expect(tickerFontSize).toBeGreaterThan(tokenFontSize * 2);
    });
  });

  it("a 2-character ticker (the shortest valid length) fits within the main glass area's safe text width", () => {
    const svg = generateTickerArtworkV2("AB", 1);
    const el = extractTextElement(svg, "\\$AB");
    expect(el, "must produce a matched, clamped text element").not.toBeNull();
    expect(el!.textLength).toBeGreaterThan(0);
    expect(el!.textLength).toBeLessThanOrEqual(MAIN_TICKER_SAFE_WIDTH);
  });

  it("a 10-character ticker (the longest valid length) fits, without wrapping or cropping, within the main glass area's safe text width", () => {
    const longTicker = "ABCDEFGHIJ";
    const svg = generateTickerArtworkV2(longTicker, 1);
    expect(svg).toContain(`$${longTicker}`);
    // No wrapping: exactly one <text> element carries the ticker, never split
    // across a <tspan> or multiple elements.
    expect(svg.match(/\$ABCDEFGHIJ/g)?.length).toBe(1);
    const el = extractTextElement(svg, "\\$ABCDEFGHIJ");
    expect(el, "must produce a matched, clamped text element").not.toBeNull();
    expect(el!.textLength).toBeGreaterThan(0);
    expect(el!.textLength).toBeLessThanOrEqual(MAIN_TICKER_SAFE_WIDTH); // never exceeds the glass area's own safe width - no cropping
  });

  it("every valid ticker length (2 through 10) produces a textLength within the main glass area's safe width, never wrapped", () => {
    for (let len = 2; len <= 10; len++) {
      const ticker = "X".repeat(len);
      const svg = generateTickerArtworkV2(ticker, 1);
      const el = extractTextElement(svg, `\\$${ticker}`);
      expect(el, `ticker length ${len} should produce a matched, clamped text element`).not.toBeNull();
      expect(el!.textLength).toBeLessThanOrEqual(MAIN_TICKER_SAFE_WIDTH);
      expect(svg).not.toContain("<tspan"); // never wraps onto a second line
    }
  });

  it("the token-id plaque text stays within its own safe width even for a large tokenId", () => {
    const svg = generateTickerArtworkV2("DOG", 999999);
    const el = extractTextElement(svg, "TICKER #999999");
    expect(el, "must produce a matched, clamped text element").not.toBeNull();
    expect(el!.textLength).toBeLessThanOrEqual(TOKEN_ID_PLAQUE_SAFE_WIDTH);
  });

  it("the exact same ticker and tokenId always produce byte-identical artwork (no randomness, no current timestamp)", () => {
    const first = generateTickerArtworkV2("PEPE", 7);
    const second = generateTickerArtworkV2("PEPE", 7);
    expect(first).toBe(second);
  });

  it("different tickers produce different dynamic labels but preserve the exact same base design (identical embedded image, identical structural SVG around the label)", () => {
    const dog = generateTickerArtworkV2("DOG", 1);
    const pepe = generateTickerArtworkV2("PEPE", 1);
    expect(dog).not.toBe(pepe);
    // Same embedded base image data URI in both - the whole point of V2 is
    // one shared canonical base, not a per-token generated background like V1.
    const dogImage = dog.match(/href="(data:image\/jpeg;base64,[^"]+)"/)?.[1];
    const pepeImage = pepe.match(/href="(data:image\/jpeg;base64,[^"]+)"/)?.[1];
    expect(dogImage).toBeDefined();
    expect(dogImage).toBe(pepeImage);
  });

  it("different tokenIds (same ticker) produce different dynamic labels but the identical embedded base image", () => {
    const first = generateTickerArtworkV2("DOG", 1);
    const second = generateTickerArtworkV2("DOG", 2);
    expect(first).not.toBe(second);
    expect(first).toContain("TICKER #1");
    expect(second).toContain("TICKER #2");
    const firstImage = first.match(/href="(data:image\/jpeg;base64,[^"]+)"/)?.[1];
    const secondImage = second.match(/href="(data:image\/jpeg;base64,[^"]+)"/)?.[1];
    expect(firstImage).toBe(secondImage);
  });

  it("a ticker-shaped injection attempt never breaks out of the generated SVG's text content", () => {
    const svg = generateTickerArtworkV2("</text><image href=x onerror=alert(1)>", 1);
    expect(svg).not.toContain("<image href=x onerror=alert(1)>");
    expect(svg).toContain("&lt;/text&gt;&lt;image");
  });
});
