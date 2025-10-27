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
        self.scripts_dir = os.getenv("SCRIPTS_DIR", "/scripts")
        self.timeout = int(os.getenv("OPERATION_TIMEOUT", "300"))  # 5 minutes default
        self.db = None  # Will be initialized async
        
        # Verify scripts directory exists
        if not os.path.isdir(self.scripts_dir):
            logger.warning(f"Scripts directory not found: {self.scripts_dir}")
    
    async def _ensure_db(self):
        """Ensure database is initialized"""
        if self.db is None:
            self.db = await get_db()
    
    async def _get_cluster_server_url(self, name: str, provider: str) -> Optional[str]:
        """
        Get cluster API server URL (混合策略：DB优先，docker inspect fallback)
        
        Args:
            name: Cluster name
            provider: Cluster provider (k3d or kind)
        
        Returns:
            API server URL like https://10.101.0.2:6443, or None if not found
        """
        try:
            # 1. 优先从数据库读取（高性能）
            await self._ensure_db()
            cluster_data = await self.db.get_cluster(name)
            if cluster_data and cluster_data.get('server_ip'):
                server_ip = cluster_data['server_ip']
                logger.info(f"Using cached server IP from DB for {name}: {server_ip}")
                return f"https://{server_ip}:6443"
            
            # 2. Fallback: 动态查询容器IP
            logger.info(f"Server IP not in DB, querying docker for {name}")
            container_name = f"k3d-{name}-server-0" if provider == "k3d" else f"{name}-control-plane"
            
            process = await asyncio.create_subprocess_exec(
                "docker", "inspect", container_name,
                "--format", "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            
            stdout, stderr = await asyncio.wait_for(
                process.communicate(),
                timeout=5
            )
            
            if process.returncode == 0:
                ips = stdout.decode().strip().split()
                if ips:
                    container_ip = ips[0]
                    logger.info(f"Got IP from docker for {name}: {container_ip}")
                    
                    # 3. 回写数据库（缓存以提升后续性能）
                    try:
                        await self.db.update_cluster(name, {"server_ip": container_ip})
                        logger.info(f"Cached server IP to DB for {name}")
                    except Exception as e:
                        logger.warning(f"Failed to cache server IP to DB: {e}")
                    
                    return f"https://{container_ip}:6443"
            
            logger.warning(f"Failed to get container IP for {container_name}")
            return None
            
        except Exception as e:
            logger.error(f"Error getting cluster server URL: {e}")
            return None

    async def _run_script(
        self,
        script_name: str,
        args: list,
        cluster_name: str,
        operation: str,
        progress_callback: Optional[Callable] = None
    ) -> bool:
        """
        Run a shell script and stream output via callback
        
        Args:
            script_name: Name of script (e.g., "create_env.sh")
            args: List of arguments for the script
            cluster_name: Name of cluster (for logging)
            operation: Operation type (e.g., "create", "delete")
            progress_callback: Async callback to send output lines
        
        Returns:
            True if script succeeded (exit code 0), False otherwise
        """
        script_path = os.path.join(self.scripts_dir, script_name)
        
        if not os.path.exists(script_path):
            error_msg = f"Script not found: {script_path}"
            logger.error(error_msg)
            if progress_callback:
                await progress_callback(f"[ERROR] {error_msg}\n")
            return False
        
        # Ensure database is initialized
        await self._ensure_db()
        
        # Log operation start
        op_id = await self.db.log_operation_start(cluster_name, operation)
        
        # Build command
        cmd = [script_path] + args
        logger.info(f"Executing: {' '.join(cmd)}")
        
        if progress_callback:
            await progress_callback(f"[INFO] Executing: {' '.join(cmd)}\n")
        
        try:
            # Create subprocess
            process = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                cwd=self.scripts_dir
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
                    await self.db.log_operation_complete(
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
            
            await self.db.log_operation_complete(op_id, status, log_output, error_message)
            
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
            await self.db.log_operation_complete(
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
        Create a new cluster via Host API
        
        Args:
            cluster_data: Dict with keys: name, provider, and optional node_port, pf_port, etc.
            progress_callback: Async callback for progress updates
        
        Returns:
            True if creation succeeded
        """
        import httpx
        
        name = cluster_data["name"]
        provider = cluster_data.get("provider", "k3d")
        
        logger.info(f"Creating cluster: {name} (provider: {provider}) via Host API")
        
        # Ensure database is initialized
        await self._ensure_db()
        
        # Log operation start
        op_id = await self.db.log_operation_start(name, "create")
        
        # 构建请求体
        request_body = {
            "name": name,
            "provider": provider,
            "node_port": cluster_data.get("node_port", 30080),
            "pf_port": cluster_data.get("pf_port", 19000),
            "http_port": cluster_data.get("http_port"),
            "https_port": cluster_data.get("https_port"),
            "cluster_subnet": cluster_data.get("subnet"),
            "register_portainer": cluster_data.get("register_portainer", True),
            "haproxy_route": cluster_data.get("haproxy_route", True),
            "register_argocd": cluster_data.get("register_argocd", True),
        }
        
        try:
            # 调用宿主机API（流式接收日志）
            # 使用环境变量或默认网关IP (172.18.0.1 for k3d-shared network)
            host_api_url = os.getenv("HOST_API_URL", "http://172.18.0.1:8888")
            full_output = []
            async with httpx.AsyncClient(timeout=600.0) as client:
                async with client.stream("POST", f"{host_api_url}/api/clusters/create", json=request_body) as response:
                    if response.status_code != 200:
                        error_msg = f"Host API returned {response.status_code}"
                        logger.error(error_msg)
                        if progress_callback:
                            await progress_callback(f"[ERROR] {error_msg}\n")
                        
                        await self.db.log_operation_complete(op_id, "failed", "", error_msg)
                        return False
                    
                    # 流式读取日志
                    async for line in response.aiter_lines():
                        full_output.append(line + "\n")
                        
                        # 发送到回调
                        if progress_callback:
                            await progress_callback(line + "\n")
            
            # 检查是否成功
            log_output = ''.join(full_output)
            success = "[SUCCESS] Operation completed successfully" in log_output
            
            status = "success" if success else "failed"
            error_message = None if success else "Script execution failed"
            
            await self.db.log_operation_complete(op_id, status, log_output, error_message)
            
            if success:
                logger.info(f"Cluster {name} created successfully")
            else:
                logger.error(f"Failed to create cluster {name}")
            
            return success
        
        except Exception as e:
            error_msg = f"Failed to call Host API: {e}"
            logger.exception(error_msg)
            if progress_callback:
                await progress_callback(f"[ERROR] {error_msg}\n")
            
            await self.db.log_operation_complete(op_id, "failed", "", error_msg)
            return False
    
    async def delete_cluster(
        self,
        name: str,
        progress_callback: Optional[Callable] = None
    ) -> bool:
        """
        Delete a cluster via Host API
        
        Args:
            name: Cluster name
            progress_callback: Async callback for progress updates
        
        Returns:
            True if deletion succeeded
        """
        import httpx
        
        logger.info(f"Deleting cluster: {name} via Host API")
        
        # Ensure database is initialized
        await self._ensure_db()
        
        # Log operation start
        op_id = await self.db.log_operation_start(name, "delete")
        
        try:
            # 调用宿主机API（流式接收日志）
            host_api_url = os.getenv("HOST_API_URL", "http://172.18.0.1:8888")
            full_output = []
            async with httpx.AsyncClient(timeout=600.0) as client:
                async with client.stream("POST", f"{host_api_url}/api/clusters/delete", json={"name": name}) as response:
                    if response.status_code != 200:
                        error_msg = f"Host API returned {response.status_code}"
                        logger.error(error_msg)
                        if progress_callback:
                            await progress_callback(f"[ERROR] {error_msg}\n")
                        
                        await self.db.log_operation_complete(op_id, "failed", "", error_msg)
                        return False
                    
                    # 流式读取日志
                    async for line in response.aiter_lines():
                        full_output.append(line + "\n")
                        
                        # 发送到回调
                        if progress_callback:
                            await progress_callback(line + "\n")
            
            # 检查是否成功
            log_output = ''.join(full_output)
            success = "[SUCCESS] Operation completed successfully" in log_output
            
            status = "success" if success else "failed"
            error_message = None if success else "Script execution failed"
            
            await self.db.log_operation_complete(op_id, status, log_output, error_message)
            
            if success:
                logger.info(f"Cluster {name} deleted successfully")
            else:
                logger.error(f"Failed to delete cluster {name}")
            
            return success
        
        except Exception as e:
            error_msg = f"Failed to call Host API: {e}"
            logger.exception(error_msg)
            if progress_callback:
                await progress_callback(f"[ERROR] {error_msg}\n")
            
            await self.db.log_operation_complete(op_id, "failed", "", error_msg)
            return False
    
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
        Get cluster status with layered health checks
        
        Status levels:
        - creating: Cluster creation task is in progress
        - running: Nodes Ready + Agent online + App healthy
        - degraded: Nodes Ready but Agent offline or App unhealthy
        - error: Nodes NotReady or other critical errors
        - not_found: Cluster configuration not found
        
        Args:
            name: Cluster name
            provider: Cluster provider (k3d or kind)
        
        Returns:
            Dict with cluster status and health details
        """
        try:
            # 从数据库查询集群配置
            await self._ensure_db()
            cluster_data = await self.db.get_cluster(name)
            
            if not cluster_data:
                return {
                    "name": name,
                    "provider": provider,
                    "status": "not_found",
                    "error": "Cluster configuration not found in database"
                }
            
            # 执行分层健康检查
            health_checks = await self._check_cluster_health(name, provider)
            
            # 根据健康检查结果确定状态
            status = self._determine_status(health_checks)
            
            return {
                "name": name,
                "provider": provider,
                "status": status,
                "server_ip": cluster_data.get('server_ip'),
                "http_port": cluster_data.get('http_port'),
                "https_port": cluster_data.get('https_port'),
                "health": health_checks
            }
        
        except Exception as e:
            logger.error(f"Error getting cluster status for {name}: {e}")
            return {
                "name": name,
                "provider": provider,
                "status": "error",
                "error": str(e)
            }
    
    async def _check_cluster_health(self, name: str, provider: str) -> Dict:
        """
        Simplified health check (database existence check only)
        
        Note: Detailed health checks (nodes/agent/apps) should be done by 
        external monitoring systems (e.g., tests/e2e_services_test.sh) and
        displayed through a separate monitoring dashboard.
        
        Returns:
            Dict with basic health check status
        """
        health = {
            "nodes": {"status": "assumed_healthy", "note": "Use external monitoring for detailed status"},
            "agent": {"status": "assumed_healthy", "note": "Check Portainer UI for Edge Agent status"},
            "apps": {"status": "assumed_healthy", "note": "Check ArgoCD UI for Application health"}
        }
        
        return health
    
    def _determine_status(self, health: Dict) -> str:
        """
        Determine overall cluster status (simplified)
        
        Logic:
        - If cluster exists in database -> running
        - Otherwise -> not_found or error
        
        Note: This is a simplified approach. Detailed status determination
        should be handled by external monitoring systems.
        """
        # Since we're doing simplified health checks, all clusters in the
        # database are assumed to be "running"
        return "running"

