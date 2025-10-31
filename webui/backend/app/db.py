#!/usr/bin/env python3
"""
SQLite database module for kindler Web UI.
Replaces PostgreSQL dependency for cluster configuration storage.
"""

import sqlite3
from pathlib import Path
from datetime import datetime
from typing import Optional, List, Dict, Any
from contextlib import contextmanager
import os


class Database:
    """SQLite database manager for kindler clusters"""
    
    def __init__(self, db_path: str = "/data/kindler-webui/kindler.db"):
        self.db_path = db_path
        self._ensure_db_dir()
        self._init_db()
    
    def _ensure_db_dir(self):
        """Ensure database directory exists"""
        db_dir = Path(self.db_path).parent
        db_dir.mkdir(parents=True, exist_ok=True)
    
    @contextmanager
    def _get_conn(self):
        """Get database connection with context manager"""
        conn = sqlite3.connect(self.db_path, timeout=30.0)
        conn.row_factory = sqlite3.Row  # Enable dict-like access
        try:
            yield conn
            conn.commit()
        except Exception as e:
            conn.rollback()
            raise e
        finally:
            conn.close()
    
    def _init_db(self):
        """Initialize database schema"""
        with self._get_conn() as conn:
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
            cursor.execute("""
                CREATE INDEX IF NOT EXISTS idx_clusters_name ON clusters(name)
            """)
            cursor.execute("""
                CREATE INDEX IF NOT EXISTS idx_operations_cluster ON operations(cluster_name)
            """)
            cursor.execute("""
                CREATE INDEX IF NOT EXISTS idx_operations_status ON operations(status)
            """)
            
            conn.commit()
    
    # Cluster CRUD operations
    
    def get_cluster(self, name: str) -> Optional[Dict[str, Any]]:
        """Get cluster by name"""
        with self._get_conn() as conn:
            cursor = conn.cursor()
            cursor.execute("SELECT * FROM clusters WHERE name = ?", (name,))
            row = cursor.fetchone()
            return dict(row) if row else None
    
    def list_clusters(self) -> List[Dict[str, Any]]:
        """List all clusters"""
        with self._get_conn() as conn:
            cursor = conn.cursor()
            cursor.execute("SELECT * FROM clusters ORDER BY created_at DESC")
            return [dict(row) for row in cursor.fetchall()]
    
    def insert_cluster(self, cluster: Dict[str, Any]) -> int:
        """Insert new cluster"""
        with self._get_conn() as conn:
            cursor = conn.cursor()
            cursor.execute("""
                INSERT INTO clusters (name, provider, subnet, node_port, pf_port, http_port, https_port, status)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, (
                cluster['name'],
                cluster['provider'],
                cluster.get('subnet'),
                cluster.get('node_port'),
                cluster.get('pf_port'),
                cluster.get('http_port'),
                cluster.get('https_port'),
                cluster.get('status', 'creating')
            ))
            return cursor.lastrowid
    
    def update_cluster(self, name: str, updates: Dict[str, Any]) -> bool:
        """Update cluster"""
        if not updates:
            return False
        
        # Build dynamic UPDATE query
        set_clauses = []
        values = []
        for key, value in updates.items():
            if key not in ('id', 'name', 'created_at'):  # Immutable fields
                set_clauses.append(f"{key} = ?")
                values.append(value)
        
        if not set_clauses:
            return False
        
        # Always update updated_at
        set_clauses.append("updated_at = ?")
        values.append(datetime.now().isoformat())
        
        values.append(name)  # WHERE condition
        
        with self._get_conn() as conn:
            cursor = conn.cursor()
            query = f"UPDATE clusters SET {', '.join(set_clauses)} WHERE name = ?"
            cursor.execute(query, values)
            return cursor.rowcount > 0
    
    def delete_cluster(self, name: str) -> bool:
        """Delete cluster"""
        with self._get_conn() as conn:
            cursor = conn.cursor()
            cursor.execute("DELETE FROM clusters WHERE name = ?", (name,))
            return cursor.rowcount > 0
    
    def cluster_exists(self, name: str) -> bool:
        """Check if cluster exists"""
        with self._get_conn() as conn:
            cursor = conn.cursor()
            cursor.execute("SELECT 1 FROM clusters WHERE name = ? LIMIT 1", (name,))
            return cursor.fetchone() is not None
    
    # Operation logging
    
    def log_operation_start(self, cluster_name: str, operation: str) -> int:
        """Log operation start"""
        with self._get_conn() as conn:
            cursor = conn.cursor()
            cursor.execute("""
                INSERT INTO operations (cluster_name, operation, status, started_at)
                VALUES (?, ?, 'running', ?)
            """, (cluster_name, operation, datetime.now().isoformat()))
            return cursor.lastrowid
    
    def log_operation_complete(self, operation_id: int, status: str, log_output: str = None, error_message: str = None):
        """Log operation completion"""
        with self._get_conn() as conn:
            cursor = conn.cursor()
            cursor.execute("""
                UPDATE operations
                SET status = ?, completed_at = ?, log_output = ?, error_message = ?
                WHERE id = ?
            """, (status, datetime.now().isoformat(), log_output, error_message, operation_id))
    
    def get_cluster_operations(self, cluster_name: str, limit: int = 50) -> List[Dict[str, Any]]:
        """Get operations for a cluster"""
        with self._get_conn() as conn:
            cursor = conn.cursor()
            cursor.execute("""
                SELECT * FROM operations
                WHERE cluster_name = ?
                ORDER BY started_at DESC
                LIMIT ?
            """, (cluster_name, limit))
            return [dict(row) for row in cursor.fetchall()]
    
    # CSV synchronization
    
    def sync_from_csv(self, csv_file: str):
        """Sync clusters from environments.csv (one-way: CSV → SQLite)"""
        import csv
        
        if not os.path.exists(csv_file):
            return
        
        with open(csv_file, 'r') as f:
            # Read all lines and filter out comments
            all_lines = f.readlines()
            # Find the header line (first non-comment line)
            header_line = None
            data_start = 0
            for i, line in enumerate(all_lines):
                stripped = line.strip()
                if stripped and not stripped.startswith('#'):
                    header_line = line
                    data_start = i
                    break
            
            if not header_line:
                return
            
            # Create a file-like object from remaining lines
            import io
            csv_content = ''.join([header_line] + all_lines[data_start + 1:])
            reader = csv.DictReader(io.StringIO(csv_content))
            
            for row in reader:
                if 'env' not in row or not row['env']:
                    continue
                cluster_name = row['env']
                
                # Check if exists
                existing = self.get_cluster(cluster_name)
                if existing:
                    # Update if CSV has changes
                    self.update_cluster(cluster_name, {
                        'provider': row['provider'],
                        'node_port': int(row['node_port']) if row.get('node_port') else None,
                        'pf_port': int(row['pf_port']) if row.get('pf_port') else None,
                        'http_port': int(row['http_port']) if row.get('http_port') else None,
                        'https_port': int(row['https_port']) if row.get('https_port') else None,
                    })
                else:
                    # Insert new
                    self.insert_cluster({
                        'name': cluster_name,
                        'provider': row['provider'],
                        'node_port': int(row['node_port']) if row.get('node_port') else None,
                        'pf_port': int(row['pf_port']) if row.get('pf_port') else None,
                        'http_port': int(row['http_port']) if row.get('http_port') else None,
                        'https_port': int(row['https_port']) if row.get('https_port') else None,
                        'status': 'unknown'  # Will be updated by actual cluster check
                    })


# Global database instance
_db_instance: Optional[Database] = None


def get_db() -> Database:
    """Get or create global database instance"""
    global _db_instance
    if _db_instance is None:
        db_path = os.getenv("DB_PATH", "/data/kindler-webui/kindler.db")
        _db_instance = Database(db_path)
    return _db_instance

