import type { HTMLAttributes } from "react";
import clsx from "clsx";

interface PanelProps extends HTMLAttributes<HTMLDivElement> {
  raised?: boolean;
}

export function Panel({ raised, className, children, ...props }: PanelProps) {
  return (
    <div
      className={clsx(
        "rounded border",
        raised ? "bg-surface-raised border-border-strong" : "bg-surface border-border",
        className
      )}
      {...props}
    >
      {children}
    </div>
  );
}
