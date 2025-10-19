"""WebSocket API endpoint"""
import logging
from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from ..websocket.manager import ws_manager

logger = logging.getLogger(__name__)

router = APIRouter(tags=["websocket"])


@router.websocket("/ws/tasks")
async def websocket_endpoint(websocket: WebSocket):
    """WebSocket endpoint for real-time task updates"""
    await ws_manager.connect(websocket)
    
    try:
        while True:
            # Receive messages from client
            data = await websocket.receive_json()
            
            # Handle subscription requests
            if data.get("type") == "subscribe":
                task_id = data.get("task_id")
                if task_id:
                    ws_manager.subscribe_task(websocket, task_id)
                    await websocket.send_json({
                        "type": "subscribed",
                        "task_id": task_id
                    })
            
            elif data.get("type") == "unsubscribe":
                task_id = data.get("task_id")
                if task_id:
                    ws_manager.unsubscribe_task(websocket, task_id)
                    await websocket.send_json({
                        "type": "unsubscribed",
                        "task_id": task_id
                    })
            
            elif data.get("type") == "ping":
                await websocket.send_json({"type": "pong"})
    
    except WebSocketDisconnect:
        logger.info("WebSocket disconnected normally")
    except Exception as e:
        logger.error(f"WebSocket error: {e}")
    finally:
        ws_manager.disconnect(websocket)

