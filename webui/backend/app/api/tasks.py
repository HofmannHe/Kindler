"""Task management API endpoints"""
import logging
from fastapi import APIRouter, HTTPException

from ..models.task import TaskStatus
from ..services.task_manager import task_manager

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/tasks", tags=["tasks"])


@router.get("/{task_id}", response_model=TaskStatus)
async def get_task_status(task_id: str):
    """Get task status by ID"""
    task = task_manager.get_task(task_id)
    
    if not task:
        raise HTTPException(status_code=404, detail=f"Task {task_id} not found")
    
    return task

