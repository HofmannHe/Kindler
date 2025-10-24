"""Task manager for background operations"""
import asyncio
import logging
from datetime import datetime
from typing import Dict, Optional, Callable
from uuid import uuid4

from ..models.task import TaskStatus

logger = logging.getLogger(__name__)


class TaskManager:
    """Manage background tasks with status tracking"""
    
    def __init__(self):
        self.tasks: Dict[str, TaskStatus] = {}
        self.callbacks: Dict[str, list] = {}  # task_id -> list of callbacks
        self._lock = asyncio.Lock()
    
    def create_task(self, message: str = "Task created") -> str:
        """Create a new task and return task_id"""
        task_id = str(uuid4())
        
        now = datetime.utcnow()
        task_status = TaskStatus(
            task_id=task_id,
            status="pending",
            progress=0,
            message=message,
            logs=[],
            created_at=now,
            updated_at=now
        )
        
        self.tasks[task_id] = task_status
        self.callbacks[task_id] = []
        
        logger.info(f"Created task {task_id}: {message}")
        return task_id
    
    def get_task(self, task_id: str) -> Optional[TaskStatus]:
        """Get task status by ID"""
        return self.tasks.get(task_id)
    
    async def update_task(
        self,
        task_id: str,
        status: Optional[str] = None,
        progress: Optional[int] = None,
        message: Optional[str] = None,
        log_line: Optional[str] = None,
        error: Optional[str] = None
    ):
        """Update task status and notify callbacks"""
        async with self._lock:
            task = self.tasks.get(task_id)
            if not task:
                logger.warning(f"Task {task_id} not found")
                return
            
            if status:
                task.status = status
                if status in ("completed", "failed"):
                    task.completed_at = datetime.utcnow()
            
            if progress is not None:
                task.progress = max(0, min(100, progress))
            
            if message:
                task.message = message
            
            if log_line:
                task.logs.append(log_line)
                # Keep only last 500 lines to prevent memory issues
                if len(task.logs) > 500:
                    task.logs = task.logs[-500:]
            
            if error:
                task.error = error
            
            task.updated_at = datetime.utcnow()
            
            # Notify all callbacks
            for callback in self.callbacks.get(task_id, []):
                try:
                    await callback(task)
                except Exception as e:
                    logger.error(f"Error in task callback: {e}")
    
    def add_callback(self, task_id: str, callback: Callable):
        """Add a callback to be notified when task updates"""
        if task_id not in self.callbacks:
            self.callbacks[task_id] = []
        
        self.callbacks[task_id].append(callback)
    
    def remove_callback(self, task_id: str, callback: Callable):
        """Remove a callback"""
        if task_id in self.callbacks:
            try:
                self.callbacks[task_id].remove(callback)
            except ValueError:
                pass
    
    async def run_task(
        self,
        task_id: str,
        coro: Callable,
        *args,
        **kwargs
    ):
        """Run a coroutine as a background task"""
        try:
            await self.update_task(task_id, status="running", progress=10)
            
            # Execute the coroutine
            result = await coro(*args, **kwargs)
            
            # Handle different return types
            if isinstance(result, tuple):
                # (success: bool, message: str)
                success, message = result
            elif isinstance(result, bool):
                # bool only: use default messages
                success = result
                message = "Operation completed successfully" if success else "Operation failed"
            else:
                # Treat any other non-False value as success
                success = bool(result)
                message = str(result)
            
            if success:
                await self.update_task(
                    task_id,
                    status="completed",
                    progress=100,
                    message=message
                )
            else:
                await self.update_task(
                    task_id,
                    status="failed",
                    progress=100,
                    error=message
                )
        
        except Exception as e:
            logger.error(f"Task {task_id} failed: {e}", exc_info=True)
            await self.update_task(
                task_id,
                status="failed",
                progress=100,
                error=str(e)
            )
    
    def cleanup_old_tasks(self, max_age_seconds: int = 3600):
        """Remove tasks older than max_age_seconds"""
        now = datetime.utcnow()
        task_ids_to_remove = []
        
        for task_id, task in self.tasks.items():
            age = (now - task.created_at).total_seconds()
            if age > max_age_seconds and task.status in ("completed", "failed"):
                task_ids_to_remove.append(task_id)
        
        for task_id in task_ids_to_remove:
            del self.tasks[task_id]
            if task_id in self.callbacks:
                del self.callbacks[task_id]
            logger.info(f"Cleaned up old task {task_id}")


# Global task manager instance
task_manager = TaskManager()

