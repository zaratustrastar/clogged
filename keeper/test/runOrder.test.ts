import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import path from "node:path";

describe("keeper runOnce action ordering", () => {
  it("qualifies matured tokens before closing the current due round", () => {
    const source = readFileSync(
      path.join(process.cwd(), "src/index.ts"),
      "utf8"
    );

    const qualify = source.indexOf(
      '{ name: "qualifyMaturedTokens"'
    );

    const close = source.indexOf(
      '{ name: "closeDueRounds"'
    );

    expect(qualify).toBeGreaterThanOrEqual(0);
    expect(close).toBeGreaterThanOrEqual(0);
    expect(qualify).toBeLessThan(close);
  });
});
