"""Database service - interacts with PostgreSQL via kubectl"""
import subprocess
import logging
from typing import Optional, List, Dict

logger = logging.getLogger(__name__)


class DBService:
    """Service to interact with Kindler PostgreSQL database"""
    
    def __init__(
        self,
        context: str = "k3d-devops",
        namespace: str = "paas",
        pod: str = "postgresql-0",
        user: str = "kindler",
        db_name: str = "kindler"
    ):
        self.context = context
        self.namespace = namespace
        self.pod = pod
        self.user = user
        self.db_name = db_name
    
    async def execute_query(self, sql: str) -> str:
        """Execute SQL query and return result"""
        try:
            cmd = [
                "kubectl", "--context", self.context,
                "exec", "-i", self.pod, "-n", self.namespace,
                "--",
                "psql", "-U", self.user, "-d", self.db_name,
                "-t", "-A", "-c", sql
            ]
            
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=30
            )
            
            if result.returncode != 0:
                logger.error(f"SQL query failed: {result.stderr}")
                raise RuntimeError(f"Database query failed: {result.stderr}")
            
            return result.stdout.strip()
        
        except subprocess.TimeoutExpired:
            logger.error("Database query timeout")
            raise RuntimeError("Database query timeout")
        except Exception as e:
            logger.error(f"Database error: {e}")
            raise
    
    async def is_available(self) -> bool:
        """Check if database is available"""
        try:
            await self.execute_query("SELECT 1;")
            return True
        except Exception:
            return False
    
    async def list_clusters(self) -> List[Dict[str, any]]:
        """List all clusters from database"""
        sql = """
            SELECT name, provider, subnet, node_port, pf_port, http_port, https_port,
                   created_at, updated_at
            FROM clusters
            ORDER BY created_at;
        """
        result = await self.execute_query(sql)
        
        if not result:
            return []
        
        clusters = []
        for line in result.split('\n'):
            if not line:
                continue
            parts = line.split('|')
            if len(parts) >= 7:
                clusters.append({
                    "name": parts[0],
                    "provider": parts[1],
                    "subnet": parts[2] if parts[2] else None,
                    "node_port": int(parts[3]) if parts[3] else None,
                    "pf_port": int(parts[4]) if parts[4] else None,
                    "http_port": int(parts[5]) if parts[5] else None,
                    "https_port": int(parts[6]) if parts[6] else None,
                    "created_at": parts[7] if len(parts) > 7 else None,
                    "updated_at": parts[8] if len(parts) > 8 else None,
                })
        
        return clusters
    
    async def get_cluster(self, name: str) -> Optional[Dict[str, any]]:
        """Get cluster by name"""
        sql = f"""
            SELECT name, provider, subnet, node_port, pf_port, http_port, https_port,
                   created_at, updated_at
            FROM clusters
            WHERE name = '{name}';
        """
        result = await self.execute_query(sql)
        
        if not result:
            return None
        
        parts = result.split('|')
        if len(parts) >= 7:
            return {
                "name": parts[0],
                "provider": parts[1],
                "subnet": parts[2] if parts[2] else None,
                "node_port": int(parts[3]) if parts[3] else None,
                "pf_port": int(parts[4]) if parts[4] else None,
                "http_port": int(parts[5]) if parts[5] else None,
                "https_port": int(parts[6]) if parts[6] else None,
                "created_at": parts[7] if len(parts) > 7 else None,
                "updated_at": parts[8] if len(parts) > 8 else None,
            }
        
        return None
    
    async def cluster_exists(self, name: str) -> bool:
        """Check if cluster exists in database"""
        sql = f"SELECT COUNT(*) FROM clusters WHERE name = '{name}';"
        result = await self.execute_query(sql)
        return result.strip() == "1"

