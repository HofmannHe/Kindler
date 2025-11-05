"""Test cluster API endpoints"""
import pytest
from httpx import AsyncClient
from unittest.mock import patch, AsyncMock


@pytest.mark.asyncio
async def test_list_clusters_empty(client: AsyncClient):
    """Test listing clusters when none exist"""
    with patch("app.api.clusters.db_service.list_clusters", new_callable=AsyncMock) as mock_list:
        mock_list.return_value = []
        
        response = await client.get("/api/clusters")
        assert response.status_code == 200
        assert response.json() == []


@pytest.mark.asyncio
async def test_list_clusters_with_data(client: AsyncClient):
    """Test listing clusters with data"""
    mock_clusters = [
        {
            "name": "test-cluster",
            "provider": "k3d",
            "subnet": None,
            "node_port": 30080,
            "pf_port": 19001,
            "http_port": 18090,
            "https_port": 18443,
            "created_at": "2024-01-01 00:00:00",
            "updated_at": "2024-01-01 00:00:00"
        }
    ]
    
    with patch("app.api.clusters.db_service.list_clusters", new_callable=AsyncMock) as mock_list:
        # API now uses declarative actual_state from DB; no kubectl/node probing
        mock_clusters[0]["actual_state"] = "running"
        mock_list.return_value = mock_clusters

        response = await client.get("/api/clusters")
        assert response.status_code == 200

        data = response.json()
        assert len(data) == 1
        assert data[0]["name"] == "test-cluster"
        assert data[0]["provider"] == "k3d"
        assert data[0]["status"] == "running"


@pytest.mark.asyncio
async def test_create_cluster(client: AsyncClient):
    """Test creating a cluster"""
    cluster_data = {
        "name": "new-cluster",
        "provider": "k3d",
        "node_port": 30080,
        "pf_port": 19001,
        "http_port": 18090,
        "https_port": 18443,
        "cluster_subnet": "10.101.0.0/16",
        "register_portainer": True,
        "haproxy_route": True,
        "register_argocd": True
    }
    
    with patch("app.api.clusters.db_service.cluster_exists", new_callable=AsyncMock) as mock_exists:
        mock_exists.return_value = False
        
        response = await client.post("/api/clusters", json=cluster_data)
        assert response.status_code == 202
        
        data = response.json()
        assert "task_id" in data
        assert data["status"] == "pending"
        assert "new-cluster" in data["message"]


@pytest.mark.asyncio
async def test_create_cluster_already_exists(client: AsyncClient):
    """Test creating a cluster that already exists"""
    cluster_data = {
        "name": "existing-cluster",
        "provider": "k3d",
        "node_port": 30080,
        "pf_port": 19001,
        "http_port": 18090,
        "https_port": 18443
    }
    
    with patch("app.api.clusters.db_service.cluster_exists", new_callable=AsyncMock) as mock_exists:
        mock_exists.return_value = True
        
        response = await client.post("/api/clusters", json=cluster_data)
        assert response.status_code == 409
        assert "already exists" in response.json()["detail"]


@pytest.mark.asyncio
async def test_get_cluster(client: AsyncClient):
    """Test getting a specific cluster"""
    mock_cluster = {
        "name": "test-cluster",
        "provider": "k3d",
        "subnet": None,
        "node_port": 30080,
        "pf_port": 19001,
        "http_port": 18090,
        "https_port": 18443,
        "created_at": "2024-01-01 00:00:00",
        "updated_at": "2024-01-01 00:00:00"
    }
    
    with patch("app.api.clusters.db_service.get_cluster", new_callable=AsyncMock) as mock_get:
        # API returns actual_state/status from DB; no live node checks
        mock_cluster["actual_state"] = "running"
        mock_get.return_value = mock_cluster

        response = await client.get("/api/clusters/test-cluster")
        assert response.status_code == 200

        data = response.json()
        assert data["name"] == "test-cluster"
        assert data["provider"] == "k3d"
        assert data["status"] == "running"


@pytest.mark.asyncio
async def test_get_cluster_not_found(client: AsyncClient):
    """Test getting a non-existent cluster"""
    with patch("app.api.clusters.db_service.get_cluster", new_callable=AsyncMock) as mock_get:
        mock_get.return_value = None
        
        response = await client.get("/api/clusters/nonexistent")
        assert response.status_code == 404


@pytest.mark.asyncio
async def test_delete_cluster(client: AsyncClient):
    """Test deleting a cluster"""
    with patch("app.api.clusters.db_service.cluster_exists", new_callable=AsyncMock) as mock_exists:
        mock_exists.return_value = True
        
        response = await client.delete("/api/clusters/test-cluster")
        assert response.status_code == 202
        
        data = response.json()
        assert "task_id" in data
        assert data["status"] == "pending"


@pytest.mark.asyncio
async def test_delete_cluster_not_found(client: AsyncClient):
    """Test deleting a non-existent cluster"""
    with patch("app.api.clusters.db_service.cluster_exists", new_callable=AsyncMock) as mock_exists:
        mock_exists.return_value = False
        
        response = await client.delete("/api/clusters/nonexistent")
        assert response.status_code == 404


@pytest.mark.asyncio
async def test_get_cluster_status(client: AsyncClient):
    """Test getting cluster status"""
    mock_cluster = {
        "name": "test-cluster",
        "provider": "k3d"
    }
    
    with patch("app.api.clusters.db_service.get_cluster", new_callable=AsyncMock) as mock_get:
        # Only declarative state + global services are reported; nodes_* are deprecated (0)
        mock_cluster_with_state = dict(mock_cluster)
        mock_cluster_with_state["actual_state"] = "running"
        mock_get.return_value = mock_cluster_with_state

        response = await client.get("/api/clusters/test-cluster/status")
        assert response.status_code == 200

        data = response.json()
        assert data["name"] == "test-cluster"
        assert data["status"] == "running"
        assert data["nodes_ready"] == 0
        assert data["nodes_total"] == 0


@pytest.mark.asyncio
async def test_start_cluster(client: AsyncClient):
    """Test starting a cluster"""
    with patch("app.api.clusters.db_service.cluster_exists", new_callable=AsyncMock) as mock_exists:
        mock_exists.return_value = True
        
        response = await client.post("/api/clusters/test-cluster/start")
        assert response.status_code == 202
        
        data = response.json()
        assert "task_id" in data


@pytest.mark.asyncio
async def test_stop_cluster(client: AsyncClient):
    """Test stopping a cluster"""
    with patch("app.api.clusters.db_service.cluster_exists", new_callable=AsyncMock) as mock_exists:
        mock_exists.return_value = True
        
        response = await client.post("/api/clusters/test-cluster/stop")
        assert response.status_code == 202
        
        data = response.json()
        assert "task_id" in data
