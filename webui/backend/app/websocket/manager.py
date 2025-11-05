"""WebSocket connection manager"""
import logging
from typing import Dict, Set
from fastapi import WebSocket

logger = logging.getLogger(__name__)


class WebSocketManager:
    """Manage WebSocket connections for real-time updates"""
    
    def __init__(self):
        # All active connections
        self.active_connections: Set[WebSocket] = set()
        
        # Task subscriptions: task_id -> set of websockets
        self.task_subscriptions: Dict[str, Set[WebSocket]] = {}
    
    async def connect(self, websocket: WebSocket):
        """Accept a new WebSocket connection"""
        await websocket.accept()
        self.active_connections.add(websocket)
        logger.info(f"WebSocket connected. Total connections: {len(self.active_connections)}")
    
    def disconnect(self, websocket: WebSocket):
        """Remove a WebSocket connection"""
        self.active_connections.discard(websocket)
        
        # Remove from all subscriptions
        for task_id, subscribers in list(self.task_subscriptions.items()):
            subscribers.discard(websocket)
            if not subscribers:
                del self.task_subscriptions[task_id]
        
        logger.info(f"WebSocket disconnected. Total connections: {len(self.active_connections)}")
    
    def subscribe_task(self, websocket: WebSocket, task_id: str):
        """Subscribe a WebSocket to task updates"""
        if task_id not in self.task_subscriptions:
            self.task_subscriptions[task_id] = set()
        
        self.task_subscriptions[task_id].add(websocket)
        logger.debug(f"WebSocket subscribed to task {task_id}")
    
    def unsubscribe_task(self, websocket: WebSocket, task_id: str):
        """Unsubscribe a WebSocket from task updates"""
        if task_id in self.task_subscriptions:
            self.task_subscriptions[task_id].discard(websocket)
            if not self.task_subscriptions[task_id]:
                del self.task_subscriptions[task_id]
        
        logger.debug(f"WebSocket unsubscribed from task {task_id}")
    
    async def broadcast_task_update(self, task_id: str, data: dict):
        """Send task update to all subscribed WebSockets"""
        if task_id not in self.task_subscriptions:
            return
        
        dead_connections = set()
        
        for websocket in self.task_subscriptions[task_id]:
            try:
                await websocket.send_json(data)
            except Exception as e:
                logger.error(f"Error sending to WebSocket: {e}")
                dead_connections.add(websocket)
        
        # Clean up dead connections
        for websocket in dead_connections:
            self.disconnect(websocket)
    
    async def broadcast_all(self, data: dict):
        """Broadcast message to all connected WebSockets"""
        dead_connections = set()
        
        for websocket in self.active_connections:
            try:
                await websocket.send_json(data)
            except Exception as e:
                logger.error(f"Error broadcasting to WebSocket: {e}")
                dead_connections.add(websocket)
        
        # Clean up dead connections
        for websocket in dead_connections:
            self.disconnect(websocket)


# Global WebSocket manager instance
ws_manager = WebSocketManager()

