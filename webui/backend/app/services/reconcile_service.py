"""Debounced reconciler integration for WebUI backend

This service schedules a debounced execution of scripts/reconcile.sh on the host
after batch operations (e.g., multiple create/delete) to converge Git branches,
ArgoCD ApplicationSet, and HAProxy routes in a single pass.

Non-blocking, idempotent, and safe to call multiple times in quick succession.
"""

import asyncio
import logging
import os
from typing import Optional

logger = logging.getLogger(__name__)


class DebouncedReconciler:
    """Schedules reconcile.sh with debounce to coalesce frequent updates"""

    def __init__(self):
        # Debounce interval in seconds. Reconcile runs when no new triggers arrive within this window.
        self.debounce_seconds = int(os.getenv("RECONCILE_DEBOUNCE_SECONDS", "5"))
        # Optional flag to disable auto reconcile (set to "0" to disable)
        self.auto_enabled = os.getenv("AUTO_RECONCILE", "1") != "0"
        # Internal state
        self._pending: Optional[asyncio.Task] = None
        self._lock = asyncio.Lock()
        self._last_reason: Optional[str] = None

    async def _run_reconcile(self):
        """Execute reconcile.sh on host via nsenter (non-blocking)"""
        # Build host execution command (same approach as ClusterService)
        project_root = "/home/cloud/github/hofmannhe/kindler"
        cmd = [
            "nsenter",
            "-t",
            "1",
            "-m",
            "-u",
            "-i",
            "-n",
            "su",
            "-",
            "cloud",
            "-c",
            f"cd {project_root} && ./scripts/reconcile.sh",
        ]

        logger.info("[Reconciler] Executing scripts/reconcile.sh on host (debounced)")
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
            )
            # Stream output to logs (line by line)
            while True:
                line = await proc.stdout.readline()
                if not line:
                    break
                logger.info("[reconcile] %s", line.decode("utf-8", errors="replace").rstrip())
            rc = await proc.wait()
            if rc != 0:
                logger.error("[Reconciler] reconcile.sh exited with code %s", rc)
            else:
                logger.info("[Reconciler] reconcile.sh completed successfully")
        except Exception as e:
            logger.error("[Reconciler] Failed to execute reconcile.sh: %s", e)

    async def _debounced_worker(self, reason: Optional[str]):
        # Small delay to gather further triggers
        await asyncio.sleep(self.debounce_seconds)
        await self._run_reconcile()
        # Clear pending after completion
        async with self._lock:
            self._pending = None
            self._last_reason = None

    async def schedule(self, reason: Optional[str] = None):
        """Public API: schedule a debounced reconcile if enabled"""
        if not self.auto_enabled:
            logger.info("[Reconciler] AUTO_RECONCILE=0; skipping schedule (%s)", reason or "no reason")
            return
        async with self._lock:
            self._last_reason = reason
            # If a task is already pending, restart debounce window by cancelling and re-scheduling
            if self._pending and not self._pending.done():
                try:
                    self._pending.cancel()
                except Exception:
                    pass
            # Schedule new debounce worker
            self._pending = asyncio.create_task(self._debounced_worker(reason))
            logger.info(
                "[Reconciler] Scheduled reconcile in %ss (reason=%s)",
                self.debounce_seconds,
                reason or "n/a",
            )


# Singleton instance for import from API modules
reconciler = DebouncedReconciler()

