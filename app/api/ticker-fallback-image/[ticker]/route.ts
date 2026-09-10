import { NextRequest, NextResponse } from "next/server";
import { colorForTicker } from "@/lib/tickerColor";

export async function GET(request: NextRequest, { params }: { params: { ticker: string } }) {
  const ticker = params.ticker.toUpperCase().slice(0, 10);
  const color = colorForTicker(ticker);
  const initial = ticker.slice(0, 1) || "?";

  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="500" height="500" viewBox="0 0 500 500">
  <rect width="500" height="500" fill="${color}"/>
  <text x="250" y="290" font-family="ui-sans-serif, system-ui, sans-serif" font-size="220" font-weight="700" fill="#070A11" text-anchor="middle">${initial}</text>
</svg>`;

  return new NextResponse(svg, {
    headers: {
      "Content-Type": "image/svg+xml",
      "Cache-Control": "public, max-age=86400",
    },
  });
}
