"""Task manager for background operations"""
import asyncio
import logging
import json
from datetime import datetime
from typing import Dict, Optional, Callable, List
from uuid import uuid4

from ..models.task import TaskStatus
from ..db import get_db

logger = logging.getLogger(__name__)


class TaskManager:
    """Manage background tasks with status tracking and lightweight persistence"""
    
    def __init__(self):
        self.tasks: Dict[str, TaskStatus] = {}
        self.callbacks: Dict[str, list] = {}  # task_id -> list of callbacks
        self._lock = asyncio.Lock()
        self._db = None  # Will be initialized async
    
    async def _ensure_db(self):
        """Ensure database connection is initialized"""
        if self._db is None:
            self._db = await get_db()
    
    async def create_task(self, message: str = "Task created") -> str:
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
        
        # Persist to database (only running tasks)
        await self._save_to_db(task_status)
        
        logger.info(f"Created task {task_id}: {message}")
        return task_id
    
    async def _save_to_db(self, task: TaskStatus):
        """Save task to database (lightweight persistence for running tasks only)"""
        try:
            await self._ensure_db()
            
            logs_json = json.dumps(task.logs)
            
            query = """
                INSERT INTO tasks (task_id, status, progress, message, logs, error, created_at, updated_at)
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
                ON CONFLICT (task_id) DO UPDATE SET
                    status = EXCLUDED.status,
                    progress = EXCLUDED.progress,
                    message = EXCLUDED.message,
                    logs = EXCLUDED.logs,
                    error = EXCLUDED.error,
                    updated_at = EXCLUDED.updated_at
            """
            
            # Access PostgreSQL pool directly
            if hasattr(self._db.backend, 'pool') and self._db.backend.pool:
                await self._db.backend.pool.execute(
                    query,
                    task.task_id,
                    task.status,
                    task.progress,
                    task.message,
                    logs_json,
                    task.error,
                    task.created_at,
                    task.updated_at
                )
            else:
                logger.warning("Database backend does not support task persistence")
        except Exception as e:
            logger.error(f"Failed to save task {task.task_id} to database: {e}")
    
    async def _delete_from_db(self, task_id: str):
        """Delete completed/failed task from database"""
        try:
            await self._ensure_db()
            
            if hasattr(self._db.backend, 'pool') and self._db.backend.pool:
                await self._db.backend.pool.execute("DELETE FROM tasks WHERE task_id = $1", task_id)
                logger.info(f"Deleted task {task_id} from database")
        except Exception as e:
            logger.error(f"Failed to delete task {task_id} from database: {e}")
    
    def get_task(self, task_id: str) -> Optional[TaskStatus]:
        """Get task status by ID"""
        return self.tasks.get(task_id)
    
    def get_all_tasks(self) -> List[TaskStatus]:
        """Get all tasks"""
        return list(self.tasks.values())
    
    async def restore_from_db(self):
        """Restore running tasks from database on startup"""
        try:
            await self._ensure_db()
            
            # Access PostgreSQL pool directly
            if not (hasattr(self._db.backend, 'pool') and self._db.backend.pool):
                logger.info("Database backend does not support task persistence")
                return 0
            
            rows = await self._db.backend.pool.fetch(
                "SELECT * FROM tasks WHERE status IN ('pending', 'running') ORDER BY created_at"
            )
            
            restored_count = 0
            for row in rows:
                task_id = row['task_id']
                
                # Parse logs from JSON
                try:
                    logs = json.loads(row['logs']) if row['logs'] else []
                except:
                    logs = []
                
                task_status = TaskStatus(
                    task_id=task_id,
                    status=row['status'],
                    progress=row['progress'],
                    message=row['message'],
                    logs=logs,
                    error=row['error'],
                    created_at=row['created_at'],
                    updated_at=row['updated_at']
                )
                
                self.tasks[task_id] = task_status
                self.callbacks[task_id] = []
                restored_count += 1
            
            if restored_count > 0:
                logger.info(f"Restored {restored_count} running tasks from database")
            
            return restored_count
        except Exception as e:
            logger.error(f"Failed to restore tasks from database: {e}")
            return 0
    
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
            
            # Sync to database if still running, delete if completed/failed
            if task.status in ("completed", "failed"):
                await self._delete_from_db(task_id)
            else:
                await self._save_to_db(task)
            
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

