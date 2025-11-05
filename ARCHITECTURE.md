# Kindler Architecture Documentation

> Last Updated: 2025-10-27

## Overview

Kindler is a lightweight local Kubernetes cluster management platform that provides a unified interface for creating, managing, and deploying applications to multiple Kubernetes clusters (k3d/kind).

## Core Components

### 1. HAProxy Gateway (Port 80/443/5432)

**Purpose**: Unified entry point for all services including database access

**Responsibilities**:
- HTTP/HTTPS routing to management UI (Portainer, ArgoCD, WebUI)
- HTTP/HTTPS routing to application services (whoami, etc.)
- **TCP proxy for PostgreSQL (Port 5432)** - exposing PostgreSQL from devops cluster
- TLS termination and redirect

**Configuration**:
- Static routes for management services (`compose/infrastructure/haproxy.cfg`)
- Dynamic routes for business cluster applications
- PostgreSQL TCP proxy: `listen postgres` → `devops_cluster:30432`

### 2. PostgreSQL Database (Unified Data Store)

**Purpose**: Central metadata store accessed by all components

**Architecture**:
```
PostgreSQL Pod (devops cluster)
  └─ Service: postgresql-nodeport (NodePort 30432)
      └─ HAProxy TCP Proxy (Port 5432)
          ├─ WebUI Backend
          ├─ Host API Server (scripts/host_api_server.py)
          └─ Test Scripts
```

**Access Pattern**:
- **Internal** (within devops cluster): `postgresql-nodeport:5432`
- **External** (from host/WebUI): `haproxy-gw:5432` (via HAProxy TCP proxy)

**Database**: `kindler`  
**User**: `kindler`  
**Schema**:
```sql
-- Clusters table
CREATE TABLE clusters (
  name VARCHAR(63) PRIMARY KEY,
  provider VARCHAR(10) NOT NULL CHECK (provider IN ('k3d', 'kind')),
  subnet CIDR,
  node_port INTEGER NOT NULL,
  pf_port INTEGER NOT NULL,
  http_port INTEGER NOT NULL,
  https_port INTEGER NOT NULL,
  server_ip VARCHAR(45),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Operations log table
CREATE TABLE operations (
  id SERIAL PRIMARY KEY,
  cluster_name VARCHAR(63) REFERENCES clusters(name) ON DELETE CASCADE,
  operation VARCHAR(50) NOT NULL,
  status VARCHAR(20) NOT NULL,
  log_output TEXT,
  started_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  completed_at TIMESTAMP,
  error_message TEXT
);
```

**Why PostgreSQL via HAProxy?**
1. **Unified Access**: All components access database through same entry point
2. **Future Flexibility**: Easy to replace with external PostgreSQL by changing HAProxy backend
3. **Network Simplicity**: No need for complex network routing
4. **Connection Pooling**: HAProxy can provide connection management
5. **Security**: Single point for access control and monitoring

**Design Principles**:
- **Simple**: No high-availability, no replication (local development focus)
- **Replaceable**: Architecture allows easy swap to external database
- **Observable**: All database connections visible through HAProxy stats

### 3. WebUI (Kindler Management Interface)

**Purpose**: Web-based cluster management UI

**Components**:
- **Frontend**: React SPA (Nginx, Port 3001)
- **Backend**: FastAPI (Python, Port 8001)

**Database Connection**:
```yaml
Environment Variables:
  PG_HOST: haproxy-gw        # Connect via HAProxy
  PG_PORT: 5432              # HAProxy PostgreSQL proxy port
  PG_USER: kindler
  PG_PASSWORD: postgres123
  PG_DATABASE: kindler
```

**Backend Connection Logic**:
1. Try PostgreSQL first (via HAProxy)
2. Fallback to SQLite if PostgreSQL unavailable
3. Auto-create schema if needed

### 4. Host API Server

**Purpose**: Bridge between WebUI backend and shell scripts

**Location**: `scripts/host_api_server.py`

**Database Access**: Same as WebUI (via HAProxy)

**Responsibilities**:
- Execute `create_env.sh` and `delete_env.sh`
- Update cluster metadata in PostgreSQL
- Provide REST API for WebUI backend

### 5. DevOps Cluster (Management Cluster)

**Purpose**: Run all infrastructure services

**Services**:
- ArgoCD (GitOps)
- PostgreSQL (Metadata Store)
- Portainer Agent (Optional, for monitoring)

**Network**: `k3d-shared` (172.18.0.0/16)

**Special Characteristics**:
- Uses shared network for stable IP addressing
- `server_ip` in database is the k3d-shared network IP (e.g., 172.18.0.6)
- All management services accessible via NodePort

### 6. Business Clusters

**Purpose**: Run application workloads

**Cluster Naming Principle** ⚠️ **IMPORTANT**:
- ✅ Cluster names are **business-oriented** (e.g., `dev`, `uat`, `prod`, `staging`, `feature-a`)
- ✅ Provider type (`k3d` or `kind`) is a **configuration attribute**, NOT part of the name
- ❌ **NEVER** use provider type in cluster names (e.g., ~~`dev-kind`~~, ~~`prod-k3d`~~)

**Preset Clusters** (defined in `config/environments.csv`):
- `dev` (provider: k3d, default)
- `uat` (provider: k3d, default)
- `prod` (provider: k3d, default)

Users can modify the `provider` field in `environments.csv` to switch between `k3d` and `kind`.

**Dynamic Clusters**:
Users can create additional clusters via WebUI or CLI:
```bash
# CLI example
scripts/create_env.sh -n staging -p k3d
scripts/create_env.sh -n customer-x -p kind
```

**Provider Types**:
- **k3d clusters**: Use independent subnets (10.101.0.0/16, 10.102.0.0/16, etc.)
- **kind clusters**: Use Docker bridge network

**Registration**:
1. K8s cluster created (k3d/kind)
2. Metadata saved to PostgreSQL (via HAProxy)
3. Registered to ArgoCD (for GitOps)
4. Registered to Portainer (for management UI)
5. HAProxy route added (for application access)
6. Git branch created (same name as cluster)

## Data Flow

### Cluster Creation Flow

```
User → WebUI Frontend
  → WebUI Backend (FastAPI)
    → Host API Server (POST /api/execute/create)
      → scripts/create_env.sh
        ├─ Create K8s cluster (k3d/kind)
        ├─ Wait for container IP assignment (max 60s)
        ├─ Save to PostgreSQL (via HAProxy:5432)
        │   └─ INSERT INTO clusters ...
        ├─ Register to ArgoCD
        ├─ Create Git branch
        ├─ Register to Portainer
        └─ Add HAProxy route
```

### Cluster Deletion Flow

```
User → WebUI Frontend
  → WebUI Backend (FastAPI)
    → Host API Server (POST /api/execute/delete)
      → scripts/delete_env.sh
        ├─ Delete K8s cluster
        ├─ Remove HAProxy route
        ├─ Unregister from Portainer
        ├─ Delete Git branch
        ├─ Unregister from ArgoCD
        └─ Delete from PostgreSQL (via HAProxy:5432)
            └─ DELETE FROM clusters ...
```

## Network Architecture

### Network Topology

```
┌─────────────────────────────────────────────────────────┐
│ Host Machine (192.168.51.30)                            │
│                                                          │
│  ┌────────────────────────────────────────────────────┐ │
│  │ Docker Bridge (172.17.0.0/16)                      │ │
│  │   ├─ HAProxy (haproxy-gw)                          │ │
│  │   ├─ Portainer                                     │ │
│  │   ├─ WebUI Backend                                 │ │
│  │   └─ WebUI Frontend                                │ │
│  └────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌────────────────────────────────────────────────────┐ │
│  │ k3d-shared Network (172.18.0.0/16)                 │ │
│  │   ├─ HAProxy (connected for devops access)         │ │
│  │   ├─ WebUI Backend (connected for K8s API access)  │ │
│  │   └─ devops cluster (172.18.0.6)                   │ │
│  │       └─ PostgreSQL NodePort (30432)               │ │
│  └────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌──────────────────────────────────────────────────────┐ │
│  │ Business Cluster Networks                            │ │
│  │ (预置集群：dev, uat, prod - 默认 k3d)               │ │
│  │                                                      │ │
│  │   ├─ dev (10.101.0.0/16, provider: k3d)             │ │
│  │   ├─ uat (10.102.0.0/16, provider: k3d)             │ │
│  │   └─ prod (10.103.0.0/16, provider: k3d)            │ │
│  │                                                      │ │
│  │ 注: 用户可通过 WebUI/CLI 动态创建其他业务集群       │ │
│  │     集群名称不耦合 provider 类型                     │ │
│  └──────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

### Port Mapping

**Host Ports (via HAProxy)**:
- 80/443: HTTP/HTTPS traffic (management UI + applications)
- 5432: PostgreSQL TCP proxy

**NodePort Ranges**:
- devops cluster: 30800 (ArgoCD), 30432 (PostgreSQL)
- Business clusters: 30080 (Traefik Ingress)

## Database Strategy

### Why PostgreSQL?

1. **Structured Data**: Relational model fits cluster metadata perfectly
2. **ACID Guarantees**: Important for cluster lifecycle operations
3. **Foreign Keys**: Automatic cascade delete for operations logs
4. **Concurrent Access**: Multiple components can safely access
5. **Future-Ready**: Easy to scale or replace with managed PostgreSQL

### Why via HAProxy?

1. **Abstraction**: Components don't need to know database location
2. **Flexibility**: Easy to switch backends (internal → external DB)
3. **Consistency**: Same gateway pattern as other services
4. **Observability**: HAProxy stats show database connections
5. **Security**: Single point for access control

### Why NOT High-Availability?

This is a **local development tool**, not production infrastructure:
- Single user, single machine usage
- Data loss acceptable (cluster metadata is reproducible)
- Simplicity > redundancy
- Easy to backup entire Docker volume if needed

### Migration Path to External PostgreSQL

If you need to use external PostgreSQL:

1. Deploy PostgreSQL externally (RDS, Cloud SQL, self-hosted)
2. Update HAProxy backend in `compose/infrastructure/haproxy.cfg`:
```haproxy
backend be_postgres
  mode tcp
  server postgres_external <external-ip>:5432 check
```
3. Run schema migration:
```bash
kubectl --context k3d-devops -n paas exec postgresql-0 -- \
  pg_dump -U kindler kindler | \
  psql -h <external-host> -U kindler kindler
```
4. Update `scripts/bootstrap.sh` to skip internal PostgreSQL deployment
5. All components continue working without code changes

## Testing Architecture

### Test Idempotency (Zero Manual Operations)

All tests are designed to be idempotent and require zero manual intervention:

**Three-Layer Idempotency**:

1. **Test Suite Level** (`tests/run_tests.sh all`):
   - Clean all clusters (`scripts/clean.sh --all`)
   - Bootstrap devops + 3 preset business clusters (dev, uat, prod - 默认 k3d)
   - Verify initial state (4 clusters total: devops + dev + uat + prod)
   - Run all tests (fail-fast)
   - Verify final state (no orphaned resources)

2. **Test Module Level** (`tests/webui_api_test.sh`):
   - Create 4 test clusters (k3d+kind × 2)
   - Preserve 2 for inspection (test-api-*)
   - Delete and verify 2 (test-e2e-*)

3. **Test Case Level** (individual E2E tests):
   - Defensive cleanup (5 layers: K8s + DB + ArgoCD + Git + Portainer)
   - Unique naming (using $$)
   - Trap-based cleanup

**Database Testing**:
- Tests use real PostgreSQL via HAProxy
- Defensive cleanup removes test cluster records
- Verification checks database consistency

## Future Enhancements

### Possible Improvements (NOT current scope)

1. **Database Replication**: Add read replicas for query performance
2. **Connection Pooling**: PgBouncer layer between HAProxy and PostgreSQL
3. **Backup Automation**: Scheduled pg_dump to host filesystem
4. **External Database Support**: Configuration option for external PostgreSQL
5. **Multi-User Support**: Authentication and authorization

### Out of Scope

- High availability (not needed for local dev)
- Distributed PostgreSQL (single machine deployment)
- Real-time replication (data loss acceptable)
- Complex backup strategies (Docker volumes sufficient)

## References

- [HAProxy Configuration](compose/infrastructure/haproxy.cfg)
- [WebUI Docker Compose](webui/docker-compose.yml)
- [Database Schema](scripts/init_db.sh)
- [Bootstrap Script](scripts/bootstrap.sh)
- [Test Framework](tests/README.md)

