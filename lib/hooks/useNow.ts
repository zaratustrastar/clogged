"use client";

import { useEffect, useState } from "react";

/** Returns the current timestamp (ms), updating every `intervalMs`. Used to
 * drive countdown displays without each consumer running its own interval. */
export function useNow(intervalMs = 1000) {
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), intervalMs);
    return () => clearInterval(id);
  }, [intervalMs]);

  return now;
}
