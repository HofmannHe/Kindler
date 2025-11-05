"""
Global services status API
"""
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from typing import Dict, Optional
import asyncio
import logging
import httpx

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/services", tags=["services"])


class ServiceStatus(BaseModel):
    """Single service status"""
    name: str
    status: str  # healthy, degraded, offline, unknown
    url: Optional[str] = None
    message: Optional[str] = None


class GlobalServicesStatus(BaseModel):
    """All global services status"""
    portainer: ServiceStatus
    argocd: ServiceStatus
    haproxy: ServiceStatus
    git: Optional[ServiceStatus] = None  # Optional if git service not configured


async def check_http_service(name: str, url: str, timeout: int = 5) -> ServiceStatus:
    """Check HTTP service health"""
    try:
        async with httpx.AsyncClient(verify=False, timeout=timeout) as client:
            response = await client.get(url, follow_redirects=True)
            if response.status_code < 500:
                return ServiceStatus(
                    name=name,
                    status="healthy",
                    url=url,
                    message=f"HTTP {response.status_code}"
                )
            else:
                return ServiceStatus(
                    name=name,
                    status="degraded",
                    url=url,
                    message=f"HTTP {response.status_code}"
                )
    except Exception as e:
        return ServiceStatus(
            name=name,
            status="offline",
            url=url,
            message=str(e)[:100]
        )


@router.get("", response_model=GlobalServicesStatus)
async def get_services_status():
    """Get all global services status"""
    try:
        # Get base domain from config
        base_domain = "192.168.51.30.sslip.io"  # TODO: Load from config
        
        # Check all services concurrently
        portainer_task = check_http_service(
            "Portainer",
            f"http://portainer.devops.{base_domain}"
        )
        argocd_task = check_http_service(
            "ArgoCD", 
            f"http://argocd.devops.{base_domain}"
        )
        haproxy_task = check_http_service(
            "HAProxy",
            f"http://haproxy.devops.{base_domain}/stat"
        )
        git_task = check_http_service(
            "Git",
            f"http://git.devops.{base_domain}"
        )
        
        results = await asyncio.gather(
            portainer_task,
            argocd_task,
            haproxy_task,
            git_task,
            return_exceptions=True
        )
        
        portainer_status = results[0] if not isinstance(results[0], Exception) else ServiceStatus(
            name="Portainer", status="unknown", message="Check failed"
        )
        argocd_status = results[1] if not isinstance(results[1], Exception) else ServiceStatus(
            name="ArgoCD", status="unknown", message="Check failed"
        )
        haproxy_status = results[2] if not isinstance(results[2], Exception) else ServiceStatus(
            name="HAProxy", status="unknown", message="Check failed"
        )
        git_status = results[3] if not isinstance(results[3], Exception) else ServiceStatus(
            name="Git", status="unknown", message="Check failed"
        )
        
        return GlobalServicesStatus(
            portainer=portainer_status,
            argocd=argocd_status,
            haproxy=haproxy_status,
            git=git_status
        )
    
    except Exception as e:
        logger.error(f"Error getting services status: {e}")
        raise HTTPException(status_code=500, detail=str(e))
