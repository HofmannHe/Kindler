#!/usr/bin/env python3
"""
Database module for kindler Web UI.
Supports both PostgreSQL (primary) and SQLite (fallback) backends.
"""

import sqlite3
import asyncpg
import logging
import os
from pathlib import Path
from datetime import datetime
from typing import Optional, List, Dict, Any
from contextlib import asynccontextmanager
from abc import ABC, abstractmethod

logger = logging.getLogger(__name__)


class DatabaseBackend(ABC):
    """Abstract base class for database backends"""
    
    @abstractmethod
    async def connect(self):
        """Establish database connection"""
        pass
    
    @abstractmethod
    async def disconnect(self):
        """Close database connection"""
        pass
    
    @abstractmethod
    async def get_cluster(self, name: str) -> Optional[Dict[str, Any]]:
        """Get cluster by name"""
        pass
    
    @abstractmethod
    async def list_clusters(self) -> List[Dict[str, Any]]:
        """List all clusters"""
        pass
    
    @abstractmethod
    async def insert_cluster(self, cluster: Dict[str, Any]) -> int:
        """Insert new cluster"""
        pass
    
    @abstractmethod
    async def update_cluster(self, name: str, updates: Dict[str, Any]) -> bool:
        """Update cluster"""
        pass
    
    @abstractmethod
    async def delete_cluster(self, name: str) -> bool:
        """Delete cluster"""
        pass
    
    @abstractmethod
    async def cluster_exists(self, name: str) -> bool:
        """Check if cluster exists"""
        pass
    
    @abstractmethod
    async def log_operation_start(self, cluster_name: str, operation: str) -> int:
        """Log operation start"""
        pass
    
    @abstractmethod
    async def log_operation_complete(self, operation_id: int, status: str, 
                                    log_output: str = None, error_message: str = None):
        """Log operation completion"""
        pass
    
    @abstractmethod
    async def get_cluster_operations(self, cluster_name: str, limit: int = 50) -> List[Dict[str, Any]]:
        """Get operations for a cluster"""
        pass


class PostgreSQLBackend(DatabaseBackend):
    """PostgreSQL database backend (connects to devops cluster)"""
    
    def __init__(self, host: str, port: int, database: str, user: str, password: str):
        self.host = host
        self.port = port
        self.database = database
        self.user = user
        self.password = password
        self.pool: Optional[asyncpg.Pool] = None
    
    async def connect(self):
        """Establish PostgreSQL connection pool"""
        try:
            self.pool = await asyncpg.create_pool(
                host=self.host,
                port=self.port,
                database=self.database,
                user=self.user,
                password=self.password,
                min_size=2,
                max_size=10,
                timeout=30.0
            )
            
            # Initialize schema if needed
            await self._init_db()
            
            logger.info(f"PostgreSQL connected: {self.host}:{self.port}/{self.database}")
        except Exception as e:
            logger.error(f"PostgreSQL connection failed: {e}")
            raise
    
    async def disconnect(self):
        """Close PostgreSQL connection pool"""
        if self.pool:
            await self.pool.close()
            logger.info("PostgreSQL disconnected")
    
    async def _init_db(self):
        """Initialize database schema"""
        async with self.pool.acquire() as conn:
            # Clusters table
            await conn.execute("""
                CREATE TABLE IF NOT EXISTS clusters (
                    id SERIAL PRIMARY KEY,
                    name TEXT UNIQUE NOT NULL,
                    provider TEXT NOT NULL,
                    subnet TEXT,
                    node_port INTEGER,
                    pf_port INTEGER,
                    http_port INTEGER,
                    https_port INTEGER,
                    status TEXT DEFAULT 'unknown',
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            """)
            
            # Operations log table
            await conn.execute("""
                CREATE TABLE IF NOT EXISTS operations (
                    id SERIAL PRIMARY KEY,
                    cluster_name TEXT,
                    operation TEXT NOT NULL,
                    status TEXT NOT NULL,
                    log_output TEXT,
                    started_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    completed_at TIMESTAMP,
                    error_message TEXT,
                    FOREIGN KEY (cluster_name) REFERENCES clusters(name) ON DELETE CASCADE
                )
            """)
            
            # Indexes
            await conn.execute("""
                CREATE INDEX IF NOT EXISTS idx_clusters_name ON clusters(name)
            """)
            await conn.execute("""
                CREATE INDEX IF NOT EXISTS idx_operations_cluster ON operations(cluster_name)
            """)
            await conn.execute("""
                CREATE INDEX IF NOT EXISTS idx_operations_status ON operations(status)
            """)
    
    def _serialize_row(self, row) -> Dict[str, Any]:
        """Convert database row to serializable dict"""
        if not row:
            return None
        data = dict(row)
        # Convert special types to strings for JSON serialization
        for key, value in data.items():
            if value is None:
                continue
            # Convert datetime to ISO format string
            if isinstance(value, datetime):
                data[key] = value.isoformat()
            # Convert IPv4Network/IPv6Network to string
            elif hasattr(value, '__str__') and type(value).__name__ in ('IPv4Network', 'IPv6Network', 'IPv4Address', 'IPv6Address'):
                data[key] = str(value)
        return data
    
    async def get_cluster(self, name: str) -> Optional[Dict[str, Any]]:
        """Get cluster by name"""
        async with self.pool.acquire() as conn:
            row = await conn.fetchrow("SELECT * FROM clusters WHERE name = $1", name)
            return self._serialize_row(row) if row else None
    
    async def list_clusters(self) -> List[Dict[str, Any]]:
        """List all clusters"""
        async with self.pool.acquire() as conn:
            rows = await conn.fetch("SELECT * FROM clusters ORDER BY created_at DESC")
            return [self._serialize_row(row) for row in rows]
    
    async def insert_cluster(self, cluster: Dict[str, Any]) -> int:
        """Insert new cluster - returns 1 for success, clusters table has no id column"""
        async with self.pool.acquire() as conn:
            await conn.execute("""
                INSERT INTO clusters (name, provider, subnet, node_port, pf_port, http_port, https_port)
                VALUES ($1, $2, $3, $4, $5, $6, $7)
            """, 
                cluster['name'],
                cluster['provider'],
                cluster.get('subnet'),
                cluster.get('node_port'),
                cluster.get('pf_port'),
                cluster.get('http_port'),
                cluster.get('https_port')
            )
            return 1  # Success indicator
    
    async def update_cluster(self, name: str, updates: Dict[str, Any]) -> bool:
        """Update cluster"""
        if not updates:
            return False
        
        # Build dynamic UPDATE query
        set_clauses = []
        values = []
        param_idx = 1
        
        for key, value in updates.items():
            if key not in ('id', 'name', 'created_at'):  # Immutable fields
                set_clauses.append(f"{key} = ${param_idx}")
                values.append(value)
                param_idx += 1
        
        if not set_clauses:
            return False
        
        # Always update updated_at
        set_clauses.append(f"updated_at = ${param_idx}")
        values.append(datetime.now())
        param_idx += 1
        
        values.append(name)  # WHERE condition
        
        query = f"UPDATE clusters SET {', '.join(set_clauses)} WHERE name = ${param_idx}"
        
        async with self.pool.acquire() as conn:
            result = await conn.execute(query, *values)
            return result.split()[-1] != '0'  # Check affected rows
    
    async def delete_cluster(self, name: str) -> bool:
        """Delete cluster"""
        async with self.pool.acquire() as conn:
            result = await conn.execute("DELETE FROM clusters WHERE name = $1", name)
            return result.split()[-1] != '0'
    
    async def cluster_exists(self, name: str) -> bool:
        """Check if cluster exists"""
        async with self.pool.acquire() as conn:
            row = await conn.fetchrow("SELECT 1 FROM clusters WHERE name = $1 LIMIT 1", name)
            return row is not None
    
    async def log_operation_start(self, cluster_name: str, operation: str) -> int:
        """Log operation start"""
        async with self.pool.acquire() as conn:
            row = await conn.fetchrow("""
                INSERT INTO operations (cluster_name, operation, status, started_at)
                VALUES ($1, $2, 'running', $3)
                RETURNING id
            """, cluster_name, operation, datetime.now())
            return row['id']
    
    async def log_operation_complete(self, operation_id: int, status: str, 
                                    log_output: str = None, error_message: str = None):
        """Log operation completion"""
        async with self.pool.acquire() as conn:
            await conn.execute("""
                UPDATE operations
                SET status = $1, completed_at = $2, log_output = $3, error_message = $4
                WHERE id = $5
            """, status, datetime.now(), log_output, error_message, operation_id)
    
    async def get_cluster_operations(self, cluster_name: str, limit: int = 50) -> List[Dict[str, Any]]:
        """Get operations for a cluster"""
        async with self.pool.acquire() as conn:
            rows = await conn.fetch("""
                SELECT * FROM operations
                WHERE cluster_name = $1
                ORDER BY started_at DESC
                LIMIT $2
            """, cluster_name, limit)
            return [dict(row) for row in rows]


class SQLiteBackend(DatabaseBackend):
    """SQLite database backend (fallback mode)"""
    
    def __init__(self, db_path: str = "/data/kindler-webui/kindler.db"):
        self.db_path = db_path
        self._ensure_db_dir()
    
    def _ensure_db_dir(self):
        """Ensure database directory exists"""
        db_dir = Path(self.db_path).parent
        db_dir.mkdir(parents=True, exist_ok=True)
    
    async def connect(self):
        """Initialize SQLite database"""
        await self._init_db()
        logger.info(f"SQLite initialized: {self.db_path}")
    
    async def disconnect(self):
        """SQLite doesn't need explicit disconnect"""
        pass
    
    def _get_sync_conn(self):
        """Get synchronous SQLite connection"""
        conn = sqlite3.connect(self.db_path, timeout=30.0)
        conn.row_factory = sqlite3.Row
        return conn
    
    async def _init_db(self):
        """Initialize database schema"""
        conn = self._get_sync_conn()
        try:
            cursor = conn.cursor()
            
            # Clusters table
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS clusters (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT UNIQUE NOT NULL,
                    provider TEXT NOT NULL,
                    subnet TEXT,
                    node_port INTEGER,
                    pf_port INTEGER,
                    http_port INTEGER,
                    https_port INTEGER,
                    status TEXT DEFAULT 'unknown',
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            """)
            
            # Operations log table
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS operations (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    cluster_name TEXT,
                    operation TEXT NOT NULL,
                    status TEXT NOT NULL,
                    log_output TEXT,
                    started_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    completed_at TIMESTAMP,
                    error_message TEXT,
                    FOREIGN KEY (cluster_name) REFERENCES clusters(name) ON DELETE CASCADE
                )
            """)
            
            # Indexes
            cursor.execute("CREATE INDEX IF NOT EXISTS idx_clusters_name ON clusters(name)")
            cursor.execute("CREATE INDEX IF NOT EXISTS idx_operations_cluster ON operations(cluster_name)")
            cursor.execute("CREATE INDEX IF NOT EXISTS idx_operations_status ON operations(status)")
            
            conn.commit()
        finally:
            conn.close()
    
    async def get_cluster(self, name: str) -> Optional[Dict[str, Any]]:
        """Get cluster by name"""
        conn = self._get_sync_conn()
        try:
            cursor = conn.cursor()
            cursor.execute("SELECT * FROM clusters WHERE name = ?", (name,))
            row = cursor.fetchone()
            return dict(row) if row else None
        finally:
            conn.close()
    
    async def list_clusters(self) -> List[Dict[str, Any]]:
        """List all clusters"""
        conn = self._get_sync_conn()
        try:
            cursor = conn.cursor()
            cursor.execute("SELECT * FROM clusters ORDER BY created_at DESC")
            return [dict(row) for row in cursor.fetchall()]
        finally:
            conn.close()
    
    async def insert_cluster(self, cluster: Dict[str, Any]) -> int:
        """Insert new cluster"""
        conn = self._get_sync_conn()
        try:
            cursor = conn.cursor()
            cursor.execute("""
                INSERT INTO clusters (name, provider, subnet, node_port, pf_port, http_port, https_port)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            """, (
                cluster['name'],
                cluster['provider'],
                cluster.get('subnet'),
                cluster.get('node_port'),
                cluster.get('pf_port'),
                cluster.get('http_port'),
                cluster.get('https_port')
            ))
            conn.commit()
            return cursor.lastrowid
        finally:
            conn.close()
    
    async def update_cluster(self, name: str, updates: Dict[str, Any]) -> bool:
        """Update cluster"""
        if not updates:
            return False
        
        set_clauses = []
        values = []
        for key, value in updates.items():
            if key not in ('id', 'name', 'created_at'):
                set_clauses.append(f"{key} = ?")
                values.append(value)
        
        if not set_clauses:
            return False
        
        set_clauses.append("updated_at = ?")
        values.append(datetime.now().isoformat())
        values.append(name)
        
        conn = self._get_sync_conn()
        try:
            cursor = conn.cursor()
            query = f"UPDATE clusters SET {', '.join(set_clauses)} WHERE name = ?"
            cursor.execute(query, values)
            conn.commit()
            return cursor.rowcount > 0
        finally:
            conn.close()
    
    async def delete_cluster(self, name: str) -> bool:
        """Delete cluster"""
        conn = self._get_sync_conn()
        try:
            cursor = conn.cursor()
            cursor.execute("DELETE FROM clusters WHERE name = ?", (name,))
            conn.commit()
            return cursor.rowcount > 0
        finally:
            conn.close()
    
    async def cluster_exists(self, name: str) -> bool:
        """Check if cluster exists"""
        conn = self._get_sync_conn()
        try:
            cursor = conn.cursor()
            cursor.execute("SELECT 1 FROM clusters WHERE name = ? LIMIT 1", (name,))
            return cursor.fetchone() is not None
        finally:
            conn.close()
    
    async def log_operation_start(self, cluster_name: str, operation: str) -> int:
        """Log operation start"""
        conn = self._get_sync_conn()
        try:
            cursor = conn.cursor()
            cursor.execute("""
                INSERT INTO operations (cluster_name, operation, status, started_at)
                VALUES (?, ?, 'running', ?)
            """, (cluster_name, operation, datetime.now().isoformat()))
            conn.commit()
            return cursor.lastrowid
        finally:
            conn.close()
    
    async def log_operation_complete(self, operation_id: int, status: str, 
                                    log_output: str = None, error_message: str = None):
        """Log operation completion"""
        conn = self._get_sync_conn()
        try:
            cursor = conn.cursor()
            cursor.execute("""
                UPDATE operations
                SET status = ?, completed_at = ?, log_output = ?, error_message = ?
                WHERE id = ?
            """, (status, datetime.now().isoformat(), log_output, error_message, operation_id))
            conn.commit()
        finally:
            conn.close()
    
    async def get_cluster_operations(self, cluster_name: str, limit: int = 50) -> List[Dict[str, Any]]:
        """Get operations for a cluster"""
        conn = self._get_sync_conn()
        try:
            cursor = conn.cursor()
            cursor.execute("""
                SELECT * FROM operations
                WHERE cluster_name = ?
                ORDER BY started_at DESC
                LIMIT ?
            """, (cluster_name, limit))
            return [dict(row) for row in cursor.fetchall()]
        finally:
            conn.close()


class Database:
    """Database manager with automatic backend selection (PostgreSQL → SQLite fallback)"""
    
    def __init__(self):
        self.backend: Optional[DatabaseBackend] = None
        self._connected = False
    
    async def connect(self):
        """Connect to database (auto-select backend)"""
        if self._connected:
            return
        
        # Try PostgreSQL first
        pg_host = os.getenv("PG_HOST")
        pg_port = int(os.getenv("PG_PORT", "5432"))
        pg_database = os.getenv("PG_DATABASE", "paas")
        pg_user = os.getenv("PG_USER", "postgres")
        pg_password = os.getenv("PG_PASSWORD", "")
        
        if pg_host and pg_password:
            try:
                logger.info(f"Attempting PostgreSQL connection: {pg_host}:{pg_port}/{pg_database}")
                self.backend = PostgreSQLBackend(
                    host=pg_host,
                    port=pg_port,
                    database=pg_database,
                    user=pg_user,
                    password=pg_password
                )
                await self.backend.connect()
                self._connected = True
                logger.info("✓ Using PostgreSQL backend (primary)")
                return
            except Exception as e:
                logger.warning(f"PostgreSQL connection failed: {e}")
                logger.info("Falling back to SQLite")
        else:
            logger.info("PostgreSQL not configured, using SQLite")
        
        # Fallback to SQLite
        db_path = os.getenv("SQLITE_PATH", "/data/kindler-webui/kindler.db")
        self.backend = SQLiteBackend(db_path)
        await self.backend.connect()
        self._connected = True
        logger.info("✓ Using SQLite backend (fallback)")
    
    async def disconnect(self):
        """Disconnect from database"""
        if self.backend and self._connected:
            await self.backend.disconnect()
            self._connected = False
    
    # Proxy all methods to backend
    async def get_cluster(self, name: str) -> Optional[Dict[str, Any]]:
        if not self._connected:
            await self.connect()
        return await self.backend.get_cluster(name)
    
    async def list_clusters(self) -> List[Dict[str, Any]]:
        if not self._connected:
            await self.connect()
        return await self.backend.list_clusters()
    
    async def insert_cluster(self, cluster: Dict[str, Any]) -> int:
        if not self._connected:
            await self.connect()
        return await self.backend.insert_cluster(cluster)
    
    async def update_cluster(self, name: str, updates: Dict[str, Any]) -> bool:
        if not self._connected:
            await self.connect()
        return await self.backend.update_cluster(name, updates)
    
    async def delete_cluster(self, name: str) -> bool:
        if not self._connected:
            await self.connect()
        return await self.backend.delete_cluster(name)
    
    async def cluster_exists(self, name: str) -> bool:
        if not self._connected:
            await self.connect()
        return await self.backend.cluster_exists(name)
    
    async def log_operation_start(self, cluster_name: str, operation: str) -> int:
        if not self._connected:
            await self.connect()
        return await self.backend.log_operation_start(cluster_name, operation)
    
    async def log_operation_complete(self, operation_id: int, status: str, 
                                    log_output: str = None, error_message: str = None):
        if not self._connected:
            await self.connect()
        return await self.backend.log_operation_complete(operation_id, status, log_output, error_message)
    
    async def get_cluster_operations(self, cluster_name: str, limit: int = 50) -> List[Dict[str, Any]]:
        if not self._connected:
            await self.connect()
        return await self.backend.get_cluster_operations(cluster_name, limit)


# Global database instance
_db_instance: Optional[Database] = None


async def get_db() -> Database:
    """Get or create global database instance"""
    global _db_instance
    if _db_instance is None:
        _db_instance = Database()
        await _db_instance.connect()
    return _db_instance


async def close_db():
    """Close global database connection"""
    global _db_instance
    if _db_instance is not None:
        await _db_instance.disconnect()
        _db_instance = None
