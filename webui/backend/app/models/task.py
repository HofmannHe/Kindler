"""Task data models"""
from typing import Optional, List
from datetime import datetime
from pydantic import BaseModel, Field


class TaskStatus(BaseModel):
    """Task status information"""
    task_id: str
    status: str = Field(..., pattern="^(pending|running|completed|failed)$")
    progress: int = Field(default=0, ge=0, le=100)
    message: Optional[str] = None
    logs: List[str] = Field(default_factory=list)
    error: Optional[str] = None
    created_at: datetime
    updated_at: datetime
    completed_at: Optional[datetime] = None


class TaskCreate(BaseModel):
    """Task creation response"""
    task_id: str
    status: str
    message: str

