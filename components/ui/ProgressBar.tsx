export function ProgressBar({ pct, tone = "cyan" }: { pct: number; tone?: "cyan" | "gold" }) {
  const clamped = Math.max(0, Math.min(100, pct));
  return (
    <div className="h-1.5 w-full rounded-full bg-border overflow-hidden">
      <div
        className={`h-full rounded-full ${tone === "cyan" ? "bg-cyan" : "bg-gold"}`}
        style={{ width: `${clamped}%` }}
      />
    </div>
  );
}
