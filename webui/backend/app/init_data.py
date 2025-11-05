"""Initialize sample data for development/demo mode"""
import logging
import os

logger = logging.getLogger(__name__)

# Demo mode flag
DEMO_MODE = os.getenv("DEMO_MODE", "true").lower() == "true"

# In-memory mock database for demo mode
MOCK_CLUSTERS = [
    {
        "name": "mock-dev",
        "provider": "k3d",
        "subnet": "10.101.0.0/16",
        "node_port": 30080,
        "pf_port": 19001,
        "http_port": 18091,
        "https_port": 18443,
        "created_at": "2025-01-01T00:00:00",
        "updated_at": "2025-01-01T00:00:00"
    },
    {
        "name": "mock-uat",
        "provider": "k3d",
        "subnet": "10.102.0.0/16",
        "node_port": 30080,
        "pf_port": 19002,
        "http_port": 18092,
        "https_port": 18444,
        "created_at": "2025-01-01T01:00:00",
        "updated_at": "2025-01-01T01:00:00"
    },
    {
        "name": "mock-prod",
        "provider": "kind",
        "subnet": None,
        "node_port": 30080,
        "pf_port": 19003,
        "http_port": 18093,
        "https_port": 18445,
        "created_at": "2025-01-01T02:00:00",
        "updated_at": "2025-01-01T02:00:00"
    }
]


async def init_sample_data():
    """Initialize sample data in demo mode"""
    if DEMO_MODE:
        logger.info(f"Demo mode enabled - using in-memory mock database with {len(MOCK_CLUSTERS)} clusters")
        logger.info("Mock clusters: " + ", ".join([c["name"] for c in MOCK_CLUSTERS]))
    else:
        logger.info("Production mode - database operations will use real PostgreSQL")


def get_mock_clusters():
    """Get mock clusters list"""
    return MOCK_CLUSTERS.copy()


def get_mock_cluster(name: str):
    """Get a single mock cluster by name"""
    for cluster in MOCK_CLUSTERS:
        if cluster["name"] == name:
            return cluster.copy()
    return None


def add_mock_cluster(cluster_data: dict):
    """Add a new mock cluster to the in-memory database"""
    MOCK_CLUSTERS.append(cluster_data.copy())
    logger.info(f"Mock cluster added: {cluster_data['name']}")


def remove_mock_cluster(name: str):
    """Remove a mock cluster from the in-memory database"""
    global MOCK_CLUSTERS
    MOCK_CLUSTERS = [c for c in MOCK_CLUSTERS if c["name"] != name]
    logger.info(f"Mock cluster removed: {name}")


def cluster_exists_mock(name: str) -> bool:
    """Check if a mock cluster exists"""
    return any(c["name"] == name for c in MOCK_CLUSTERS)

