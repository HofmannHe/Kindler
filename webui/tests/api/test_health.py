"""Test health endpoints"""
import pytest
from httpx import AsyncClient


@pytest.mark.asyncio
async def test_health_check(client: AsyncClient):
    """Test health check endpoint"""
    response = await client.get("/api/health")
    assert response.status_code == 200
    
    data = response.json()
    assert data["status"] == "healthy"
    assert "service" in data
    assert "version" in data


@pytest.mark.asyncio
async def test_config_endpoint(client: AsyncClient):
    """Test config endpoint"""
    response = await client.get("/api/config")
    assert response.status_code == 200
    
    data = response.json()
    assert "base_domain" in data
    assert "providers" in data
    assert isinstance(data["providers"], list)
    assert "kind" in data["providers"]
    assert "k3d" in data["providers"]

