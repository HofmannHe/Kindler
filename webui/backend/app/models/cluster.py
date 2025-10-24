"""Cluster data models"""
from typing import Optional
from pydantic import BaseModel, Field, field_validator
import re


class ClusterBase(BaseModel):
    """Base cluster configuration"""
    name: str = Field(..., min_length=1, max_length=63, pattern="^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")
    provider: str = Field(..., pattern="^(kind|k3d)$")
    node_port: int = Field(default=30080, ge=1024, le=65535)
    pf_port: Optional[int] = Field(default=None, ge=1024, le=65535)
    http_port: Optional[int] = Field(default=None, ge=1024, le=65535)
    https_port: Optional[int] = Field(default=None, ge=1024, le=65535)
    cluster_subnet: Optional[str] = Field(default=None)
    register_portainer: bool = True
    haproxy_route: bool = True
    register_argocd: bool = True

    @field_validator('cluster_subnet')
    @classmethod
    def validate_subnet(cls, v):
        """Validate cluster subnet format. Empty string or None is allowed."""
        if not v or v.strip() == "":
            return None
        pattern = r"^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$"
        if not re.match(pattern, v):
            raise ValueError(f"Cluster subnet must match pattern: {pattern}")
        return v


class ClusterCreate(ClusterBase):
    """Cluster creation request"""
    pass


class ClusterUpdate(BaseModel):
    """Cluster update request (partial updates allowed)"""
    provider: Optional[str] = Field(None, pattern="^(kind|k3d)$")
    node_port: Optional[int] = Field(None, ge=1024, le=65535)
    pf_port: Optional[int] = Field(None, ge=1024, le=65535)
    http_port: Optional[int] = Field(None, ge=1024, le=65535)
    https_port: Optional[int] = Field(None, ge=1024, le=65535)
    cluster_subnet: Optional[str] = Field(None, pattern=r"^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$")


class ClusterInfo(ClusterBase):
    """Full cluster information"""
    status: str = Field(default="unknown")  # running, stopped, creating, deleting, error
    created_at: Optional[str] = None
    updated_at: Optional[str] = None


class ClusterStatus(BaseModel):
    """Cluster status information"""
    name: str
    status: str  # running, stopped, unknown, error
    nodes_ready: int = 0
    nodes_total: int = 0
    portainer_status: str = "unknown"  # online, offline, unknown
    argocd_status: str = "unknown"  # healthy, degraded, unknown
    error_message: Optional[str] = None

