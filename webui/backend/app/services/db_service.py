"""Database service - interacts with SQLite database"""
import logging
import os
from typing import Optional, List, Dict
from ..db import get_db

logger = logging.getLogger(__name__)


class DBService:
    """Service to interact with Kindler SQLite database"""
    
    def __init__(self):
        # Initialize SQLite database
        self.db = get_db()
        logger.info("DBService initialized with SQLite database")
        
        # Sync from CSV if exists (one-way: CSV → SQLite)
        csv_path = os.getenv("CSV_PATH", "/app/config/environments.csv")
        if os.path.exists(csv_path):
            try:
                self.db.sync_from_csv(csv_path)
                logger.info(f"Synced clusters from {csv_path}")
            except Exception as e:
                logger.warning(f"Failed to sync from CSV: {e}")
    
    async def is_available(self) -> bool:
        """Check if database is available"""
        try:
            # Simple test query
            self.db.list_clusters()
            return True
        except Exception as e:
            logger.error(f"Database not available: {e}")
            return False
    
    async def list_clusters(self) -> List[Dict[str, any]]:
        """List all clusters from database"""
        try:
            return self.db.list_clusters()
        except Exception as e:
            logger.error(f"Failed to list clusters: {e}")
            return []
    
    async def get_cluster(self, name: str) -> Optional[Dict[str, any]]:
        """Get cluster by name"""
        try:
            return self.db.get_cluster(name)
        except Exception as e:
            logger.error(f"Failed to get cluster {name}: {e}")
            return None
    
    async def cluster_exists(self, name: str) -> bool:
        """Check if cluster exists in database"""
        try:
            return self.db.cluster_exists(name)
        except Exception as e:
            logger.error(f"Failed to check cluster existence {name}: {e}")
            return False
    
    async def create_cluster(self, cluster_data: Dict) -> bool:
        """Create a new cluster record in database"""
        try:
            self.db.insert_cluster(cluster_data)
            logger.info(f"Created cluster record: {cluster_data['name']}")
            return True
        except Exception as e:
            logger.error(f"Failed to create cluster: {e}")
            return False
    
    async def update_cluster(self, name: str, updates: Dict) -> bool:
        """Update cluster record in database"""
        try:
            result = self.db.update_cluster(name, updates)
            if result:
                logger.info(f"Updated cluster: {name}")
            return result
        except Exception as e:
            logger.error(f"Failed to update cluster {name}: {e}")
            return False
    
    async def delete_cluster(self, name: str) -> bool:
        """Delete a cluster record from database"""
        try:
            result = self.db.delete_cluster(name)
            if result:
                logger.info(f"Deleted cluster record: {name}")
            return result
        except Exception as e:
            logger.error(f"Failed to delete cluster {name}: {e}")
            return False

