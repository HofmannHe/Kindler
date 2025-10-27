"""Task management API endpoints"""
import logging
from typing import List
from fastapi import APIRouter, HTTPException, Query

from ..models.task import TaskStatus
from ..services.task_manager import task_manager

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/tasks", tags=["tasks"])


@router.get("", response_model=List[TaskStatus])
async def get_all_tasks(status: str = Query(None, description="Filter by status (pending, running, completed, failed)")):
    """Get all tasks, optionally filtered by status"""
    tasks = task_manager.get_all_tasks()
    
    # Filter by status if provided
    if status:
        tasks = [t for t in tasks if t.status == status]
    
    return tasks


@router.get("/{task_id}", response_model=TaskStatus)
async def get_task_status(task_id: str):
    """Get task status by ID"""
    task = task_manager.get_task(task_id)
    
    if not task:
        raise HTTPException(status_code=404, detail=f"Task {task_id} not found")
    
    return task

