import { useState, useEffect, useRef } from "react";

// Approximate block times for delay calculations
const BLOCK_TIME_SECONDS = 12;
// Fallback delays (~6h / ~24h) used only if the on-chain values are not supplied.
// The hook exposes CANCEL_DELAY_BLOCKS()/FALLBACK_DELAY_BLOCKS() and they are owner-settable
// (shortened for live demos), so GhostSwap reads them from chain and passes them in via `swap`.
const DEFAULT_CANCEL_DELAY_BLOCKS = 1800;
const DEFAULT_FALLBACK_DELAY_BLOCKS = 7200;

/**
 * Manages the decrypt polling lifecycle with staged timeout logic.
 *
 * @param {{ swapId: number|null, createdAtBlock: number|null, currentBlock: number|null, state: number|null, cancelDelayBlocks?: number, fallbackDelayBlocks?: number } | null} swap
 * @returns {{ status: string, elapsedBlocks: number, message: string, canCancel: boolean, canAutoRelease: boolean }}
 */
export function useDecryptPoller(swap) {
  const [pollerState, setPollerState] = useState({
    status: "idle",
    elapsedBlocks: 0,
    message: "",
    canCancel: false,
    canAutoRelease: false,
  });

  useEffect(() => {
    if (!swap || !swap.createdAtBlock || !swap.currentBlock) {
      setPollerState({ status: "idle", elapsedBlocks: 0, message: "", canCancel: false, canAutoRelease: false });
      return;
    }

    const { createdAtBlock, currentBlock, state } = swap;

    // If already emergency-resolved or revealed, no polling needed
    if (state === 5) { // EmergencyResolved
      setPollerState({
        status: "emergency_resolved",
        elapsedBlocks: currentBlock - createdAtBlock,
        message: "Swap was emergency-resolved.",
        canCancel: false,
        canAutoRelease: false,
      });
      return;
    }

    if (state === 4) { // RevealedToAuthorized
      setPollerState({
        status: "revealed",
        elapsedBlocks: currentBlock - createdAtBlock,
        message: "Trade revealed.",
        canCancel: false,
        canAutoRelease: false,
      });
      return;
    }

    const cancelDelayBlocks = Number(swap.cancelDelayBlocks ?? DEFAULT_CANCEL_DELAY_BLOCKS);
    const fallbackDelayBlocks = Number(swap.fallbackDelayBlocks ?? DEFAULT_FALLBACK_DELAY_BLOCKS);

    const elapsedBlocks = currentBlock - createdAtBlock;
    const elapsedSeconds = elapsedBlocks * BLOCK_TIME_SECONDS;
    const cancelReadyBlock = createdAtBlock + cancelDelayBlocks;
    const autoReleaseReadyBlock = createdAtBlock + fallbackDelayBlocks;

    let status, message, canCancel, canAutoRelease;

    if (currentBlock >= autoReleaseReadyBlock) {
      // 24h+ elapsed: auto-release available
      status = "auto_release_available";
      message = "Auto-release available. You can claim your funds.";
      canCancel = true;
      canAutoRelease = true;
    } else if (currentBlock >= cancelReadyBlock) {
      // 6h-24h elapsed: cancellable
      status = "stuck_cancellable";
      message = "CoFHE taking longer than expected. You can cancel this swap.";
      canCancel = true;
      canAutoRelease = false;
    } else if (elapsedSeconds >= 120) {
      // 2min-6h: coprocessor delayed
      status = "coprocessor_delayed";
      message = "CoFHE coprocessor is taking longer than expected. Your funds are safe.";
      canCancel = false;
      canAutoRelease = false;
    } else {
      // 0-2min: waiting normally
      status = "waiting";
      message = "Verifying encrypted fill...";
      canCancel = false;
      canAutoRelease = false;
    }

    setPollerState({ status, elapsedBlocks, message, canCancel, canAutoRelease });
  }, [
    swap?.swapId,
    swap?.createdAtBlock,
    swap?.currentBlock,
    swap?.state,
    swap?.cancelDelayBlocks,
    swap?.fallbackDelayBlocks,
  ]);

  return pollerState;
}