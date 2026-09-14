/**
 * Structured JSON-lines logging - one JSON object per line on stdout
 * (info/warn) or stderr (error), which systemd/journald captures natively
 * and which any downstream log aggregator can parse without a custom
 * grammar. Deliberately no external logging library: a v1 keeper this size
 * doesn't need one, and one fewer dependency is one fewer thing to audit.
 */

export type LogLevel = "info" | "warn" | "error";

export interface LogFields {
  [key: string]: string | number | boolean | undefined;
}

function emit(level: LogLevel, action: string, message: string, fields?: LogFields): void {
  const record = {
    ts: new Date().toISOString(),
    level,
    action,
    message,
    ...fields,
  };
  const line = JSON.stringify(record);
  if (level === "error") console.error(line);
  else console.log(line);
}

export const logger = {
  info: (action: string, message: string, fields?: LogFields) => emit("info", action, message, fields),
  warn: (action: string, message: string, fields?: LogFields) => emit("warn", action, message, fields),
  error: (action: string, message: string, fields?: LogFields) => emit("error", action, message, fields),
};
