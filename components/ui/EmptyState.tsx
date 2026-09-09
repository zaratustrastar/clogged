import type { ReactNode } from "react";

export function EmptyState({
  title,
  description,
  action,
}: {
  title: string;
  description: string;
  action?: ReactNode;
}) {
  return (
    <div className="flex flex-col items-center justify-center gap-3 rounded border border-dashed border-border py-16 text-center">
      <p className="font-display text-base text-ink">{title}</p>
      <p className="max-w-sm text-sm text-ink-dim">{description}</p>
      {action}
    </div>
  );
}
