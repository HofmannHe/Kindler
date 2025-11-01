"""Cluster management API endpoints"""
import logging
from typing import List
from fastapi import APIRouter, HTTPException, BackgroundTasks

from ..models.cluster import ClusterCreate, ClusterInfo, ClusterStatus, ClusterUpdate
from ..models.task import TaskCreate
from ..services.db_service import DBService
from ..services.cluster_service import ClusterService
from ..services.task_manager import task_manager
from ..websocket.manager import ws_manager

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/clusters", tags=["clusters"])

# Service instances
db_service = DBService()
cluster_service = ClusterService()


@router.get("", response_model=List[ClusterInfo])
async def list_clusters():
    """List all clusters"""
    try:
        db_clusters = await db_service.list_clusters()

        # Enhance with runtime status and include reconcile fields
        result = []
        for cluster in db_clusters:
            status_info = await cluster_service.get_cluster_status(
                cluster["name"], cluster["provider"]
            )

            cluster_info = ClusterInfo(
                name=cluster["name"],
                provider=cluster["provider"],
                node_port=cluster.get("node_port", 30080),
                pf_port=cluster.get("pf_port", 19000),
                http_port=cluster.get("http_port", 18080),
                https_port=cluster.get("https_port", 18443),
                cluster_subnet=cluster.get("subnet"),
                register_portainer=True,
                haproxy_route=True,
                register_argocd=True,
                status=status_info.get("status", "unknown"),
                created_at=cluster.get("created_at"),
                updated_at=cluster.get("updated_at"),
                desired_state=cluster.get("desired_state"),
                actual_state=cluster.get("actual_state"),
                last_reconciled_at=cluster.get("last_reconciled_at"),
                reconcile_error=cluster.get("reconcile_error"),
            )
            result.append(cluster_info)

        return result
    
    except Exception as e:
        logger.error(f"Error listing clusters: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.post("", response_model=TaskCreate, status_code=202)
async def create_cluster(cluster: ClusterCreate, background_tasks: BackgroundTasks):
    """
    Create a new cluster (declarative - declares desired state)
    
    This API uses declarative approach:
    1. WebUI writes desired state to database
    2. Background reconciler (scripts/reconciler.sh) creates the actual cluster
    3. Reconciler executes on host, same as predefined clusters (dev/uat/prod)
    
    This ensures WebUI creation is as stable as predefined cluster creation.
    """
    try:
        # Check if cluster already exists
        exists = await db_service.cluster_exists(cluster.name)
        if exists:
            raise HTTPException(
                status_code=409,
                detail=f"Cluster {cluster.name} already exists"
            )
        
        # Declare desired state in database (reconciler will handle actual creation)
        await db_service.create_cluster({
            "name": cluster.name,
            "provider": cluster.provider,
            "node_port": cluster.node_port,
            "pf_port": cluster.pf_port,
            "http_port": cluster.http_port,
            "https_port": cluster.https_port,
            "subnet": cluster.cluster_subnet,
            "desired_state": "present",      # Declare: we want this cluster
            "actual_state": "unknown",        # Actual: reconciler will update
            "status": "pending"               # For compatibility
        })
        
        logger.info(f"Cluster creation declared: {cluster.name} ({cluster.provider})")
        logger.info(f"Reconciler will create the cluster on host (same as predefined clusters)")
        
        return TaskCreate(
            task_id=f"reconcile-{cluster.name}",  # Reconciler task
            status="pending",
            message=f"Cluster creation declared. Reconciler will create {cluster.name} on host."
        )
    
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error declaring cluster creation: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/{name}", response_model=ClusterInfo)
async def get_cluster(name: str):
    """Get cluster details"""
    try:
        cluster = await db_service.get_cluster(name)
        if not cluster:
            raise HTTPException(status_code=404, detail=f"Cluster {name} not found")
        
        status_info = await cluster_service.get_cluster_status(
            cluster["name"],
            cluster["provider"]
        )
        
        return ClusterInfo(
            name=cluster["name"],
            provider=cluster["provider"],
            node_port=cluster.get("node_port", 30080),
            pf_port=cluster.get("pf_port", 19000),
            http_port=cluster.get("http_port", 18080),
            https_port=cluster.get("https_port", 18443),
            cluster_subnet=cluster.get("subnet"),
            register_portainer=True,
            haproxy_route=True,
            register_argocd=True,
            status=status_info.get("status", "unknown"),
            created_at=cluster.get("created_at"),
            updated_at=cluster.get("updated_at"),
            desired_state=cluster.get("desired_state"),
            actual_state=cluster.get("actual_state"),
            last_reconciled_at=cluster.get("last_reconciled_at"),
            reconcile_error=cluster.get("reconcile_error"),
        )
    
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error getting cluster: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/{name}", response_model=TaskCreate, status_code=202)
async def delete_cluster(name: str, background_tasks: BackgroundTasks):
    """
    Delete a cluster (declarative):
    - Protect devops cluster
    - Update desired_state to 'absent'
    - Reconciler performs actual deletion
    """
    try:
        # Protect devops cluster
        if name == "devops":
            raise HTTPException(status_code=403, detail="devops cluster cannot be deleted")

        # Check if cluster exists
        exists = await db_service.cluster_exists(name)
        if not exists:
            raise HTTPException(status_code=404, detail=f"Cluster {name} not found")

        # Update desired state to 'absent'; reconciler will handle actual deletion
        await db_service.update_cluster(name, {
            "desired_state": "absent",
            # clear previous error to avoid confusion for new action
            "reconcile_error": None,
        })

        # Return a reconcile task stub (WebSocket can still track generic progress if needed)
        return TaskCreate(
            task_id=f"reconcile-delete-{name}",
            status="pending",
            message=f"Cluster deletion declared. Reconciler will delete {name}."
        )

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error declaring cluster deletion: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/{name}/status", response_model=ClusterStatus)
async def get_cluster_status(name: str):
    """Get detailed cluster status"""
    try:
        # Check if cluster exists in DB
        cluster = await db_service.get_cluster(name)
        if not cluster:
            raise HTTPException(status_code=404, detail=f"Cluster {name} not found")
        
        # Get runtime status
        status_info = await cluster_service.get_cluster_status(
            cluster["name"],
            cluster["provider"]
        )
        
        return ClusterStatus(
            name=name,
            status=status_info.get("status", "unknown"),
            nodes_ready=status_info.get("nodes_ready", 0),
            nodes_total=status_info.get("nodes_total", 0),
            portainer_status="unknown",  # TODO: Query Portainer API
            argocd_status="unknown",  # TODO: Query ArgoCD API
            error_message=status_info.get("error")
        )
    
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error getting cluster status: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/{name}/start", response_model=TaskCreate, status_code=202)
async def start_cluster(name: str, background_tasks: BackgroundTasks):
    """Start a stopped cluster (async operation)"""
    try:
        # Check if cluster exists
        exists = await db_service.cluster_exists(name)
        if not exists:
            raise HTTPException(status_code=404, detail=f"Cluster {name} not found")
        
        # Create task
        task_id = task_manager.create_task(f"Starting cluster {name}")
        
        # Add WebSocket callback
        async def ws_callback(task_status):
            await ws_manager.broadcast_task_update(task_id, {
                "type": "task_update",
                "task": task_status.dict()
            })
        
        task_manager.add_callback(task_id, ws_callback)
        
        # Progress callback
        async def progress_callback(log_line: str):
            await task_manager.update_task(task_id, log_line=log_line)
        
        # Run start in background
        background_tasks.add_task(
            task_manager.run_task,
            task_id,
            cluster_service.start_cluster,
            name=name,
            progress_callback=progress_callback
        )
        
        return TaskCreate(
            task_id=task_id,
            status="pending",
            message=f"Cluster start task created for {name}"
        )
    
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error starting cluster: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/{name}/stop", response_model=TaskCreate, status_code=202)
async def stop_cluster(name: str, background_tasks: BackgroundTasks):
    """Stop a running cluster (async operation)"""
    try:
        # Check if cluster exists
        exists = await db_service.cluster_exists(name)
        if not exists:
            raise HTTPException(status_code=404, detail=f"Cluster {name} not found")
        
        # Create task
        task_id = task_manager.create_task(f"Stopping cluster {name}")
        
        # Add WebSocket callback
        async def ws_callback(task_status):
            await ws_manager.broadcast_task_update(task_id, {
                "type": "task_update",
                "task": task_status.dict()
            })
        
        task_manager.add_callback(task_id, ws_callback)
        
        # Progress callback
        async def progress_callback(log_line: str):
            await task_manager.update_task(task_id, log_line=log_line)
        
        # Run stop in background
        background_tasks.add_task(
            task_manager.run_task,
            task_id,
            cluster_service.stop_cluster,
            name=name,
            progress_callback=progress_callback
        )
        
        return TaskCreate(
            task_id=task_id,
            status="pending",
            message=f"Cluster stop task created for {name}"
        )
    
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error stopping cluster: {e}")
        raise HTTPException(status_code=500, detail=str(e))
