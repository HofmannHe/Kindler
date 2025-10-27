"""FastAPI application entry point"""
import logging
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .api import clusters, tasks, websocket, services

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan events"""
    logger.info("Starting Kindler Web GUI Backend")
    
    # Initialize database with sample data (development mode)
    try:
        from .init_data import init_sample_data
        await init_sample_data()
        logger.info("Database initialization complete")
    except Exception as e:
        logger.error(f"Database initialization failed: {e}")
    
    # Restore running tasks from database
    try:
        from .services.task_manager import task_manager
        restored = await task_manager.restore_from_db()
        if restored > 0:
            logger.info(f"Restored {restored} running tasks from database")
    except Exception as e:
        logger.error(f"Task restoration failed: {e}")
    
    yield
    logger.info("Shutting down Kindler Web GUI Backend")


# Create FastAPI app
app = FastAPI(
    title="Kindler Web GUI API",
    description="RESTful API for managing Kubernetes clusters via Kindler",
    version="0.1.0",
    lifespan=lifespan
)

# Configure CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # In production, specify exact origins
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include routers
app.include_router(clusters.router)
app.include_router(tasks.router)
app.include_router(websocket.router)
app.include_router(services.router)


@app.get("/api/health")
async def health_check():
    """Health check endpoint"""
    return {
        "status": "healthy",
        "service": "kindler-webui-backend",
        "version": "0.1.0"
    }


@app.get("/api/config")
async def get_config():
    """Get system configuration"""
    return {
        "base_domain": os.getenv("BASE_DOMAIN", "192.168.51.30.sslip.io"),
        "providers": ["kind", "k3d"],
        "default_provider": "k3d",
        "default_node_port": 30080,
        "default_pf_port_range": [19001, 19999],
        "default_http_port_range": [18090, 18999],
        "default_https_port_range": [18443, 18999]
    }


if __name__ == "__main__":
    import uvicorn
    
    uvicorn.run(
        "app.main:app",
        host="0.0.0.0",
        port=8000,
        reload=True,
        log_level="info"
    )
