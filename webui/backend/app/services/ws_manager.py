"""WebSocket connection manager for real-time log streaming"""
import asyncio
import logging
from typing import Dict, Set
from fastapi import WebSocket

logger = logging.getLogger(__name__)


class WebSocketManager:
    """Manage WebSocket connections for cluster operations"""
    
    def __init__(self):
        # cluster_name -> set of WebSocket connections
        self.active_connections: Dict[str, Set[WebSocket]] = {}
        self._lock = asyncio.Lock()
    
    async def connect(self, websocket: WebSocket, cluster_name: str):
        """Register a new WebSocket connection for a cluster"""
        await websocket.accept()
        
        async with self._lock:
            if cluster_name not in self.active_connections:
                self.active_connections[cluster_name] = set()
            self.active_connections[cluster_name].add(websocket)
        
        logger.info(f"WebSocket connected for cluster: {cluster_name}")
    
    async def disconnect(self, websocket: WebSocket, cluster_name: str):
        """Unregister a WebSocket connection"""
        async with self._lock:
            if cluster_name in self.active_connections:
                self.active_connections[cluster_name].discard(websocket)
                
                # Clean up empty sets
                if not self.active_connections[cluster_name]:
                    del self.active_connections[cluster_name]
        
        logger.info(f"WebSocket disconnected for cluster: {cluster_name}")
    
    async def broadcast(self, cluster_name: str, message: str):
        """Broadcast message to all connections for a cluster"""
        if cluster_name not in self.active_connections:
            return
        
        # Create a copy to avoid issues if connections are closed during iteration
        connections = list(self.active_connections.get(cluster_name, []))
        
        disconnected = []
        for websocket in connections:
            try:
                await websocket.send_text(message)
            except Exception as e:
                logger.error(f"Failed to send message to WebSocket: {e}")
                disconnected.append(websocket)
        
        # Clean up disconnected websockets
        if disconnected:
            async with self._lock:
                for ws in disconnected:
                    self.active_connections[cluster_name].discard(ws)
    
    async def send_to(self, websocket: WebSocket, message: str):
        """Send message to a specific WebSocket connection"""
        try:
            await websocket.send_text(message)
        except Exception as e:
            logger.error(f"Failed to send message to WebSocket: {e}")
            raise
    
    def has_connections(self, cluster_name: str) -> bool:
        """Check if there are active connections for a cluster"""
        return cluster_name in self.active_connections and len(self.active_connections[cluster_name]) > 0


# Global WebSocket manager instance
_ws_manager: WebSocketManager = None


def get_ws_manager() -> WebSocketManager:
    """Get or create global WebSocket manager instance"""
    global _ws_manager
    if _ws_manager is None:
        _ws_manager = WebSocketManager()
    return _ws_manager

