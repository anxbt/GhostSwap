import { useState, useEffect, useRef } from "react";

const POLL_INTERVAL_MS = 30_000;
const TIMEOUT_MS = 5_000;

/**
 * Polls the CoFHE coprocessor health endpoint and reports status.
 *
 * @param {{ healthCheck?: () => Promise<boolean> } | null} client - CoFHE client with healthCheck method
 * @returns {{ status: "checking" | "healthy" | "degraded" | "offline", lastChecked: number | null, message: string }}
 */
export function useCoFheHealth(client) {
  const [state, setState] = useState({
    status: "checking",
    lastChecked: null,
    message: "Checking CoFHE coprocessor status...",
  });
  const intervalRef = useRef(null);

  useEffect(() => {
    if (!client) {
      setState({ status: "offline", lastChecked: Date.now(), message: "CoFHE client not initialized." });
      return;
    }

    let cancelled = false;

    async function check() {
      try {
        const timeoutPromise = new Promise((_, reject) =>
          setTimeout(() => reject(new Error("timeout")), TIMEOUT_MS)
        );

        let isHealthy;
        if (typeof client.healthCheck === "function") {
          isHealthy = await Promise.race([client.healthCheck(), timeoutPromise]);
        } else {
          // If no healthCheck method, assume healthy if client exists
          isHealthy = true;
        }

        if (!cancelled) {
          setState({
            status: isHealthy ? "healthy" : "degraded",
            lastChecked: Date.now(),
            message: isHealthy ? "CoFHE coprocessor online" : "CoFHE coprocessor degraded",
          });
        }
      } catch {
        if (!cancelled) {
          setState({
            status: "offline",
            lastChecked: Date.now(),
            message: "CoFHE coprocessor unreachable",
          });
        }
      }
    }

    check();
    intervalRef.current = setInterval(check, POLL_INTERVAL_MS);

    return () => {
      cancelled = true;
      if (intervalRef.current) {
        clearInterval(intervalRef.current);
      }
    };
  }, [client]);

  return state;
}