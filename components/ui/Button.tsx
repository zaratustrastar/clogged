import { forwardRef } from "react";
import type { ButtonHTMLAttributes } from "react";
import clsx from "clsx";

type Variant = "primary" | "secondary" | "ghost" | "gold" | "danger";
type Size = "sm" | "md" | "lg";

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: Variant;
  size?: Size;
  fullWidth?: boolean;
}

const variantClasses: Record<Variant, string> = {
  primary: "bg-cyan text-bg hover:bg-cyan/90 disabled:bg-cyan/30",
  secondary:
    "bg-transparent text-ink border border-border-strong hover:border-cyan/60 hover:text-cyan disabled:opacity-40",
  ghost: "bg-transparent text-ink-dim hover:text-ink disabled:opacity-40",
  gold: "bg-gold text-bg hover:bg-gold/90 disabled:bg-gold/30",
  danger: "bg-danger text-bg hover:bg-danger/90 disabled:bg-danger/30",
};

const sizeClasses: Record<Size, string> = {
  sm: "text-sm px-3 py-1.5 rounded-sm",
  md: "text-sm px-4 py-2.5 rounded",
  lg: "text-base px-6 py-3.5 rounded-md",
};

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  { variant = "primary", size = "md", fullWidth, className, disabled, children, ...props },
  ref
) {
  return (
    <button
      ref={ref}
      disabled={disabled}
      className={clsx(
        "inline-flex items-center justify-center gap-2 font-medium font-body transition-colors duration-150 disabled:cursor-not-allowed",
        variantClasses[variant],
        sizeClasses[size],
        fullWidth && "w-full",
        className
      )}
      {...props}
    >
      {children}
    </button>
  );
});
