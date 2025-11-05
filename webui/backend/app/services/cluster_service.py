"""Cluster management service - Real cluster operations via subprocess"""
import asyncio
import logging
import os
from typing import Optional, Dict, Callable
from pathlib import Path
from .db_service import DBService
from ..db import get_db

logger = logging.getLogger(__name__)


class ClusterService:
    """Service for cluster operations using real scripts"""
    
    def __init__(self):
        self.base_domain = os.getenv("BASE_DOMAIN", "192.168.51.30.sslip.io")
        self.scripts_dir = os.getenv("SCRIPTS_DIR", "/app/scripts")
        self.timeout = int(os.getenv("OPERATION_TIMEOUT", "300"))  # 5 minutes default
        self.db = get_db()
        
        # Verify scripts directory exists
        if not os.path.isdir(self.scripts_dir):
            logger.error(f"Scripts directory not found: {self.scripts_dir}")
            logger.info(f"Available directories: {os.listdir('/app')}")
            raise RuntimeError(f"Scripts directory not found: {self.scripts_dir}")
    
    async def _run_script(
        self,
        script_name: str,
        args: list,
        cluster_name: str,
        operation: str,
        progress_callback: Optional[Callable] = None
    ) -> bool:
        """
        Run a shell script ON THE HOST (not in container) to match stable predefined cluster creation
        
        This executes scripts in the same environment as predefined clusters (dev/uat/prod),
        ensuring complete tool chain availability (k3d, kind, docker, kubectl, etc.)
        
        Args:
            script_name: Name of script (e.g., "create_env.sh")
            args: List of arguments for the script
            cluster_name: Name of cluster (for logging)
            operation: Operation type (e.g., "create", "delete")
            progress_callback: Async callback to send output lines
        
        Returns:
            True if script succeeded (exit code 0), False otherwise
        """
        # Execute on host using nsenter to enter host namespaces
        # This matches EXACTLY how predefined clusters are created (direct host execution)
        
        # Log operation start
        op_id = self.db.log_operation_start(cluster_name, operation)
        
        # Build command to execute on host using nsenter
        # nsenter -t 1 -m -u -n -i executes in host's namespaces
        script_path = f"/home/cloud/github/hofmannhe/kindler/scripts/{script_name}"
        
        # Build full command
        cmd = [
            "nsenter", "-t", "1", "-m", "-u", "-i", "-n",
            "su", "-", "cloud", "-c",
            f"cd /home/cloud/github/hofmannhe/kindler && {script_path} {' '.join(args)}"
        ]
        
        logger.info(f"Executing on host (nsenter): {script_name} {' '.join(args)}")
        
        if progress_callback:
            await progress_callback(f"[INFO] Executing on host: {script_name} {' '.join(args)}\n")
        
        try:
            # Create subprocess
            process = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT
            )
            
            # Stream output
            full_output = []
            while True:
                try:
                    # Read with timeout
                    line = await asyncio.wait_for(
                        process.stdout.readline(),
                        timeout=self.timeout
                    )
                    
                    if not line:
                        break
                    
                    decoded_line = line.decode('utf-8', errors='replace')
                    full_output.append(decoded_line)
                    
                    # Send to callback
                    if progress_callback:
                        await progress_callback(decoded_line)
                
                except asyncio.TimeoutError:
                    error_msg = f"Operation timeout after {self.timeout}s"
                    logger.error(error_msg)
                    if progress_callback:
                        await progress_callback(f"[ERROR] {error_msg}\n")
                    
                    # Kill the process
                    process.kill()
                    await process.wait()
                    
                    # Log failure
                    self.db.log_operation_complete(
                        op_id,
                        "timeout",
                        ''.join(full_output),
                        error_msg
                    )
                    return False
            
            # Wait for process to complete
            returncode = await process.wait()
            
            # Log completion
            log_output = ''.join(full_output)
            status = "success" if returncode == 0 else "failed"
            error_message = None if returncode == 0 else f"Exit code: {returncode}"
            
            self.db.log_operation_complete(op_id, status, log_output, error_message)
            
            if returncode == 0:
                if progress_callback:
                    await progress_callback(f"[SUCCESS] Operation completed successfully\n")
                return True
            else:
                error_msg = f"Script failed with exit code {returncode}"
                logger.error(error_msg)
                if progress_callback:
                    await progress_callback(f"[ERROR] {error_msg}\n")
                return False
        
        except Exception as e:
            error_msg = f"Failed to execute script: {e}"
            logger.exception(error_msg)
            if progress_callback:
                await progress_callback(f"[ERROR] {error_msg}\n")
            
            # Log failure
            self.db.log_operation_complete(
                op_id,
                "error",
                ''.join(full_output) if 'full_output' in locals() else "",
                error_msg
            )
            return False
    
    async def create_cluster(
        self,
        cluster_data: Dict,
        progress_callback: Optional[Callable] = None
    ) -> bool:
        """
        Create a new cluster
        
        Args:
            cluster_data: Dict with keys: name, provider, and optional node_port, pf_port, etc.
            progress_callback: Async callback for progress updates
        
        Returns:
            True if creation succeeded
        """
        name = cluster_data["name"]
        provider = cluster_data.get("provider", "k3d")
        
        logger.info(f"Creating cluster: {name} (provider: {provider})")
        
        # Build arguments for create_env.sh
        args = [
            "-n", name,
            "-p", provider
        ]
        
        # Add optional parameters
        if "node_port" in cluster_data:
            args.extend(["--node-port", str(cluster_data["node_port"])])
        if "pf_port" in cluster_data:
            args.extend(["--pf-port", str(cluster_data["pf_port"])])
        
        # Execute creation script
        # Note: create_env.sh already writes to SQLite database, so we don't need to write again
        success = await self._run_script(
            "create_env.sh",
            args,
            name,
            "create",
            progress_callback
        )
        
        # create_env.sh handles database insertion with retry logic and IP allocation
        # WebUI should not duplicate this operation to avoid data inconsistency
        if success:
            # Verify that the cluster was actually created and recorded in database
            # This ensures script completion (including IP allocation)
            db_service = DBService()
            cluster = await db_service.get_cluster(name)
            if not cluster:
                logger.warning(f"Cluster {name} created but not found in database - script may have failed")
                return False
        
        return success
    
    async def delete_cluster(
        self,
        name: str,
        progress_callback: Optional[Callable] = None
    ) -> bool:
        """
        Delete a cluster
        
        Args:
            name: Cluster name
            progress_callback: Async callback for progress updates
        
        Returns:
            True if deletion succeeded
        """
        logger.info(f"Deleting cluster: {name}")
        
        # Build arguments for delete_env.sh
        args = ["-n", name]
        
        # Execute deletion script
        success = await self._run_script(
            "delete_env.sh",
            args,
            name,
            "delete",
            progress_callback
        )
        
        # delete_env.sh already handles database deletion, so we don't need to delete again
        # Just verify deletion succeeded
        return success
    
    async def start_cluster(
        self,
        name: str,
        progress_callback: Optional[Callable] = None
    ) -> bool:
        """
        Start a stopped cluster
        
        Args:
            name: Cluster name
            progress_callback: Async callback for progress updates
        
        Returns:
            True if start succeeded
        """
        logger.info(f"Starting cluster: {name}")
        
        # Build arguments for start_env.sh
        args = [name]
        
        # Execute start script
        success = await self._run_script(
            "start_env.sh",
            args,
            name,
            "start",
            progress_callback
        )
        
        if success:
            # Update status in database
            db_service = DBService()
            await db_service.update_cluster(name, {"status": "running"})
        
        return success
    
    async def stop_cluster(
        self,
        name: str,
        progress_callback: Optional[Callable] = None
    ) -> bool:
        """
        Stop a running cluster
        
        Args:
            name: Cluster name
            progress_callback: Async callback for progress updates
        
        Returns:
            True if stop succeeded
        """
        logger.info(f"Stopping cluster: {name}")
        
        # Build arguments for stop_env.sh
        args = [name]
        
        # Execute stop script
        success = await self._run_script(
            "stop_env.sh",
            args,
            name,
            "stop",
            progress_callback
        )
        
        if success:
            # Update status in database
            db_service = DBService()
            await db_service.update_cluster(name, {"status": "stopped"})
        
        return success
    
    async def get_cluster_status(self, name: str, provider: str = "k3d") -> Dict:
        """
        Get cluster status using kubectl
        
        Args:
            name: Cluster name
            provider: Cluster provider (k3d or kind)
        
        Returns:
            Dict with cluster status information
        """
        context = f"{provider}-{name}"
        
        try:
            # Try container kubectl first
            async def _kubectl_cmd(cmd: list[str]):
                proc = await asyncio.create_subprocess_exec(
                    *cmd,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE
                )
                out, err = await asyncio.wait_for(proc.communicate(), timeout=10)
                return proc.returncode, out, err

            rc, stdout, stderr = await _kubectl_cmd([
                "kubectl", "--context", context, "get", "nodes", "-o", "json"
            ])

            # Fallback: run host kubectl via nsenter (enter host namespaces)
            if rc != 0:
                rc, stdout, stderr = await _kubectl_cmd([
                    "nsenter", "-t", "1", "-m", "-u", "-i", "-n",
                    "kubectl", "--context", context, "get", "nodes", "-o", "json"
                ])

            if rc == 0:
                import json
                nodes_data = json.loads(stdout.decode())
                
                nodes = []
                for item in nodes_data.get("items", []):
                    node_name = item["metadata"]["name"]
                    conditions = item["status"].get("conditions", [])
                    ready_condition = next(
                        (c for c in conditions if c["type"] == "Ready"),
                        None
                    )
                    status = ready_condition["status"] if ready_condition else "Unknown"
                    roles = item["metadata"].get("labels", {}).get("node-role.kubernetes.io/master", "")
                    
                    nodes.append({
                        "name": node_name,
                        "status": "Ready" if status == "True" else "NotReady",
                        "roles": ["control-plane", "master"] if roles else ["worker"]
                    })
                
                return {
                    "name": name,
                    "provider": provider,
                    "status": "running" if nodes else "unknown",
                    "nodes": nodes
                }
            else:
                # Cluster not running or not accessible
                return {
                    "name": name,
                    "provider": provider,
                    "status": "stopped",
                    "error": stderr.decode() if stderr else "Cluster not accessible"
                }
        
        except asyncio.TimeoutError:
            return {
                "name": name,
                "provider": provider,
                "status": "timeout",
                "error": "kubectl timeout"
            }
        except Exception as e:
            logger.error(f"Failed to get cluster status: {e}")
            return {
                "name": name,
                "provider": provider,
                "status": "error",
                "error": str(e)
            }
    
    def get_cluster_urls(self, name: str) -> Dict[str, str]:
        """Get cluster access URLs"""
        return {
            "whoami": f"http://whoami.{name}.{self.base_domain}",
            "portainer": f"https://portainer.devops.{self.base_domain}",
            "argocd": f"http://argocd.devops.{self.base_domain}",
            "haproxy_stats": f"http://haproxy.devops.{self.base_domain}/stat"
        }


# Singleton instance
_cluster_service = None


def get_cluster_service() -> ClusterService:
    """Get cluster service singleton"""
    global _cluster_service
    if _cluster_service is None:
        _cluster_service = ClusterService()
    return _cluster_service
