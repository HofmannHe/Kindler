"""Cluster management service - calls shell scripts"""
import asyncio
import subprocess
import logging
import os
from typing import Optional, Dict, Callable
from pathlib import Path

logger = logging.getLogger(__name__)


class ClusterService:
    """Service to manage Kubernetes clusters via shell scripts"""
    
    def __init__(self, scripts_dir: str = "/app/scripts"):
        self.scripts_dir = Path(scripts_dir)
        if not self.scripts_dir.exists():
            # Fallback for development
            root_dir = Path(__file__).parent.parent.parent.parent.parent
            self.scripts_dir = root_dir / "scripts"
        
        logger.info(f"ClusterService initialized with scripts_dir: {self.scripts_dir}")
    
    async def _run_script(
        self,
        script_name: str,
        args: list,
        progress_callback: Optional[Callable[[str], None]] = None
    ) -> tuple[int, str, str]:
        """
        Run a shell script and capture output
        
        Returns: (exit_code, stdout, stderr)
        """
        script_path = self.scripts_dir / script_name
        if not script_path.exists():
            raise FileNotFoundError(f"Script not found: {script_path}")
        
        cmd = [str(script_path)] + args
        logger.info(f"Executing: {' '.join(cmd)}")
        
        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=str(self.scripts_dir.parent)
        )
        
        stdout_lines = []
        stderr_lines = []
        
        async def read_stream(stream, lines_list, is_stderr=False):
            """Read stream line by line and call progress callback"""
            while True:
                line = await stream.readline()
                if not line:
                    break
                
                line_str = line.decode('utf-8').rstrip()
                lines_list.append(line_str)
                
                if progress_callback:
                    prefix = "[STDERR] " if is_stderr else "[STDOUT] "
                    progress_callback(prefix + line_str)
                
                logger.debug(f"{'STDERR' if is_stderr else 'STDOUT'}: {line_str}")
        
        # Read stdout and stderr concurrently
        await asyncio.gather(
            read_stream(process.stdout, stdout_lines, is_stderr=False),
            read_stream(process.stderr, stderr_lines, is_stderr=True)
        )
        
        exit_code = await process.wait()
        
        stdout = '\n'.join(stdout_lines)
        stderr = '\n'.join(stderr_lines)
        
        logger.info(f"Script exited with code {exit_code}")
        
        return exit_code, stdout, stderr
    
    async def create_cluster(
        self,
        name: str,
        provider: str,
        node_port: Optional[int] = None,
        pf_port: Optional[int] = None,
        http_port: Optional[int] = None,
        https_port: Optional[int] = None,
        cluster_subnet: Optional[str] = None,
        register_portainer: bool = True,
        haproxy_route: bool = True,
        register_argocd: bool = True,
        progress_callback: Optional[Callable[[str], None]] = None
    ) -> tuple[bool, str]:
        """
        Create a new cluster
        
        Returns: (success, message)
        """
        args = ["-n", name, "-p", provider]
        
        if node_port:
            args.extend(["--node-port", str(node_port)])
        if pf_port:
            args.extend(["--pf-port", str(pf_port)])
        if http_port:
            args.extend(["--http-port", str(http_port)])
        if https_port:
            args.extend(["--https-port", str(https_port)])
        if cluster_subnet:
            args.extend(["--cluster-subnet", cluster_subnet])
        
        if not register_portainer:
            args.append("--no-register-portainer")
        if not haproxy_route:
            args.append("--no-haproxy-route")
        if not register_argocd:
            args.append("--no-register-argocd")
        
        try:
            exit_code, stdout, stderr = await self._run_script(
                "create_env.sh",
                args,
                progress_callback
            )
            
            if exit_code == 0:
                return True, f"Cluster {name} created successfully"
            else:
                error_msg = stderr or stdout or "Unknown error"
                return False, f"Failed to create cluster {name}: {error_msg}"
        
        except Exception as e:
            logger.error(f"Error creating cluster {name}: {e}")
            return False, f"Error creating cluster {name}: {str(e)}"
    
    async def delete_cluster(
        self,
        name: str,
        progress_callback: Optional[Callable[[str], None]] = None
    ) -> tuple[bool, str]:
        """
        Delete a cluster
        
        Returns: (success, message)
        """
        try:
            exit_code, stdout, stderr = await self._run_script(
                "delete_env.sh",
                [name],
                progress_callback
            )
            
            if exit_code == 0:
                return True, f"Cluster {name} deleted successfully"
            else:
                error_msg = stderr or stdout or "Unknown error"
                return False, f"Failed to delete cluster {name}: {error_msg}"
        
        except Exception as e:
            logger.error(f"Error deleting cluster {name}: {e}")
            return False, f"Error deleting cluster {name}: {str(e)}"
    
    async def start_cluster(
        self,
        name: str,
        progress_callback: Optional[Callable[[str], None]] = None
    ) -> tuple[bool, str]:
        """
        Start a stopped cluster
        
        Returns: (success, message)
        """
        try:
            exit_code, stdout, stderr = await self._run_script(
                "start_env.sh",
                [name],
                progress_callback
            )
            
            if exit_code == 0:
                return True, f"Cluster {name} started successfully"
            else:
                error_msg = stderr or stdout or "Unknown error"
                return False, f"Failed to start cluster {name}: {error_msg}"
        
        except Exception as e:
            logger.error(f"Error starting cluster {name}: {e}")
            return False, f"Error starting cluster {name}: {str(e)}"
    
    async def stop_cluster(
        self,
        name: str,
        progress_callback: Optional[Callable[[str], None]] = None
    ) -> tuple[bool, str]:
        """
        Stop a running cluster
        
        Returns: (success, message)
        """
        try:
            exit_code, stdout, stderr = await self._run_script(
                "stop_env.sh",
                [name],
                progress_callback
            )
            
            if exit_code == 0:
                return True, f"Cluster {name} stopped successfully"
            else:
                error_msg = stderr or stdout or "Unknown error"
                return False, f"Failed to stop cluster {name}: {error_msg}"
        
        except Exception as e:
            logger.error(f"Error stopping cluster {name}: {e}")
            return False, f"Error stopping cluster {name}: {str(e)}"
    
    async def get_cluster_status(self, name: str, provider: str) -> Dict[str, any]:
        """
        Get cluster status via kubectl
        
        Returns: dict with status information
        """
        context = f"{provider}-{name}"
        
        try:
            # Check if context exists
            result = subprocess.run(
                ["kubectl", "config", "get-contexts", context],
                capture_output=True,
                text=True,
                timeout=5
            )
            
            if result.returncode != 0:
                return {"status": "unknown", "error": "Context not found"}
            
            # Get nodes
            result = subprocess.run(
                ["kubectl", "--context", context, "get", "nodes", "-o", "json"],
                capture_output=True,
                text=True,
                timeout=10
            )
            
            if result.returncode != 0:
                return {"status": "error", "error": "Cannot access cluster"}
            
            import json
            nodes_data = json.loads(result.stdout)
            nodes_total = len(nodes_data.get("items", []))
            nodes_ready = sum(
                1 for node in nodes_data.get("items", [])
                if any(
                    cond.get("type") == "Ready" and cond.get("status") == "True"
                    for cond in node.get("status", {}).get("conditions", [])
                )
            )
            
            status = "running" if nodes_ready == nodes_total and nodes_total > 0 else "degraded"
            
            return {
                "status": status,
                "nodes_ready": nodes_ready,
                "nodes_total": nodes_total
            }
        
        except subprocess.TimeoutExpired:
            return {"status": "error", "error": "Timeout accessing cluster"}
        except Exception as e:
            logger.error(f"Error getting cluster status: {e}")
            return {"status": "error", "error": str(e)}

