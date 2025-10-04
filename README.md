# Kindler

> A lightweight local development environment orchestrator powered by Portainer CE, HAProxy, and Kubernetes (kind/k3d)

**Kindler** provides a simple, fast, and efficient way to manage containerized applications and lightweight Kubernetes clusters through a unified gateway and management interface.

[中文文档](./README_CN.md) | [English](./README.md)

## Features

- 🚀 **Unified Gateway**: Single entry point via HAProxy for all services
- 🎯 **Centralized Management**: Manage containers and clusters through Portainer CE
- 🔄 **GitOps Ready**: Built-in ArgoCD for declarative application deployment
- 🌐 **Domain-based Routing**: Automatic HAProxy configuration for environment access
- 🛠️ **Flexible Backends**: Support both kind and k3d Kubernetes distributions
- 📦 **Automated Registration**: Auto-register clusters to Portainer and ArgoCD
- 🔒 **Production-ready**: TLS support with automatic redirects

## Architecture

### System Topology

```mermaid
graph TB
    subgraph External["External Access"]
        USER[User/Browser]
    end

    subgraph Gateway["HAProxy Gateway"]
        HAP[HAProxy Container<br/>haproxy-gw]
        PORTS["Configurable Ports:<br/>Portainer HTTPS/HTTP<br/>ArgoCD HTTP<br/>Cluster Routes HTTP"]
    end

    subgraph Management["Management Layer"]
        PORT[Portainer CE]
        DEVOPS["devops Cluster<br/>(k3d/kind)<br/>+ ArgoCD"]
    end

    subgraph Business["Business Clusters (Examples)"]
        ENV1["Environment 1<br/>(kind)"]
        ENV2["Environment 2<br/>(k3d)"]
        ENVN["...<br/>(defined in CSV)"]
    end

    USER -->|HTTPS/HTTP| HAP
    HAP --> PORTS
    PORTS -.->|Manage| PORT
    PORTS -.->|GitOps| DEVOPS
    PORTS -.->|Route by Domain| Business

    PORT -->|Edge Agent| ENV1
    PORT -->|Edge Agent| ENV2
    PORT -->|Edge Agent| ENVN

    DEVOPS -->|kubectl| ENV1
    DEVOPS -->|kubectl| ENV2
    DEVOPS -->|kubectl| ENVN

    classDef gateway fill:#e1f5ff,stroke:#01579b,stroke-width:2px
    classDef management fill:#f3e5f5,stroke:#4a148c,stroke-width:2px
    classDef business fill:#e8f5e9,stroke:#1b5e20,stroke-width:2px

    class HAP,PORTS gateway
    class PORT,DEVOPS management
    class ENV1,ENV2,ENVN business
```

> **Note**: The diagram shows a simplified topology. Actual cluster count and configuration are defined in `config/environments.csv`. All ports and domain names are configurable via `config/clusters.env` and `config/secrets.env`.

### Request Flow

```mermaid
sequenceDiagram
    participant User
    participant HAProxy
    participant Portainer
    participant ArgoCD
    participant K8sCluster as Business Cluster

    User->>HAProxy: Access Portainer UI
    HAProxy->>Portainer: Forward request
    Portainer-->>User: Management UI

    User->>Portainer: Deploy application
    Portainer->>K8sCluster: Edge Agent command
    K8sCluster-->>Portainer: Status update

    User->>HAProxy: Access ArgoCD UI
    HAProxy->>ArgoCD: Forward request
    ArgoCD->>K8sCluster: Deploy via kubectl
    K8sCluster-->>ArgoCD: Sync status

    User->>HAProxy: Access app (with Host header)
    HAProxy->>K8sCluster: Route to cluster NodePort
    K8sCluster-->>User: Application response
```

## Quick Start

### Prerequisites

- Docker Engine (20.10+)
- Docker Compose (v2.0+)
- kubectl (for k8s cluster management)
- One of: kind (v0.20+) or k3d (v5.6+)

### Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/hofmannhe/kindler.git
   cd kindler
   ```

2. **Configure environment** (optional, defaults are provided)
   ```bash
   # Edit configuration files as needed
   nano config/clusters.env    # HAProxy host, base domain, versions
   nano config/secrets.env     # Admin passwords
   nano config/environments.csv # Cluster definitions
   ```

3. **Bootstrap infrastructure**
   ```bash
   ./scripts/bootstrap.sh
   ```
   This will:
   - Start Portainer CE container
   - Start HAProxy gateway
   - Create `devops` management cluster
   - Deploy ArgoCD

4. **Access management interfaces**
   - Portainer: `https://<HAPROXY_HOST>:23343` (self-signed cert, defaults to `https://192.168.51.30:23343`)
   - ArgoCD: `http://<HAPROXY_HOST>:23800` (defaults to `http://192.168.51.30:23800`)
     - Username: `admin`
     - Password: See `config/secrets.env`

### Create Business Clusters

Create clusters defined in `config/environments.csv`:

```bash
# Create a single environment
./scripts/create_env.sh -n dev

# Create multiple environments from CSV
for env in dev uat prod; do
  ./scripts/create_env.sh -n $env
done
```

The script will automatically:
- ✅ Create the Kubernetes cluster (kind/k3d based on CSV config)
- ✅ Register to Portainer via Edge Agent
- ✅ Register to ArgoCD with kubectl context
- ✅ Configure HAProxy domain routing (if enabled in CSV)

### Access Your Clusters

Access points depend on your configuration in `config/clusters.env` and `config/environments.csv`:

- **Portainer**: `https://<HAPROXY_HOST>:23343` (default: `https://192.168.51.30:23343`)
- **ArgoCD**: `http://<HAPROXY_HOST>:23800` (default: `http://192.168.51.30:23800`)
- **Business Apps** (via domain routing, default base domain: `local`):
  ```bash
  # Example with default configuration
  curl -H 'Host: dev.local' http://192.168.51.30:23080
  curl -H 'Host: uat.local' http://192.168.51.30:23080
  ```

## Project Structure

```
kindler/
├── clusters/           # k3d/kind cluster configurations
├── compose/            # Docker Compose files
│   ├── haproxy/       # HAProxy gateway setup
│   └── portainer/     # Portainer CE setup
├── config/            # Configuration files
│   ├── environments.csv    # Environment definitions
│   ├── clusters.env        # Cluster image versions
│   └── secrets.env         # Passwords and tokens
├── scripts/           # Management scripts
│   ├── bootstrap.sh        # Initialize infrastructure
│   ├── create_env.sh       # Create business cluster
│   ├── delete_env.sh       # Delete cluster
│   ├── clean.sh            # Clean all resources
│   └── haproxy_sync.sh     # Sync HAProxy routes
├── manifests/         # Kubernetes manifests
│   └── argocd/        # ArgoCD installation
└── tests/             # Test scripts
```

## Configuration

### Environment Definition (CSV)

Edit `config/environments.csv` to define your environments:

```csv
# env,provider,node_port,pf_port,register_portainer,haproxy_route,http_port,https_port
dev,kind,30080,19001,true,true,18090,18443
uat,kind,30080,29001,true,true,28080,28443
prod,kind,30080,39001,true,true,38080,38443
dev-k3d,k3d,30080,19002,true,true,18091,18444
```

**Columns:**
- `env`: Environment name (unique identifier)
- `provider`: `kind` or `k3d`
- `node_port`: Cluster NodePort for Traefik (default: 30080)
- `pf_port`: Port-forward local port (for debugging)
- `register_portainer`: Auto-register to Portainer (`true`/`false`)
- `haproxy_route`: Add HAProxy domain route (`true`/`false`)
- `http_port`: Cluster HTTP port mapping
- `https_port`: Cluster HTTPS port mapping

### Cluster Images

Configure Kubernetes versions in `config/clusters.env`:

```bash
KIND_NODE_IMAGE=kindest/node:v1.31.12
K3D_IMAGE=rancher/k3s:v1.31.5-k3s1
```

### Port Configuration

Default ports are configured in HAProxy. Modify `compose/haproxy/haproxy.cfg` if needed:

- Portainer HTTPS: `23343` (default)
- Portainer HTTP: `23380` (redirects to HTTPS)
- ArgoCD: `23800` (default)
- Cluster Routes: `23080` (default)

### Domain Configuration

Set base domain in `config/clusters.env`:

```bash
BASE_DOMAIN=local  # Clusters will be accessible as <env>.local
HAPROXY_HOST=192.168.51.30  # Gateway entry point
```

## Management Commands

### Cluster Lifecycle

```bash
# Create cluster (use CSV defaults)
./scripts/create_env.sh -n dev

# Create cluster (override options)
./scripts/create_env.sh -n dev -p kind --node-port 30081 --no-register-portainer

# Delete specific cluster
./scripts/delete_env.sh -n dev -p kind

# Clean all resources (clusters, containers, networks, volumes)
./scripts/clean.sh
```

### HAProxy Route Management

```bash
# Sync routes from CSV
./scripts/haproxy_sync.sh

# Sync and prune unlisted routes
./scripts/haproxy_sync.sh --prune
```

### Portainer Management

```bash
# Start/update Portainer
./scripts/portainer.sh up

# Manually add endpoint
./scripts/portainer.sh add-endpoint myenv https://cluster-ip:9001
```

## Port Reference

| Service | Default Port | Protocol | Purpose | Configurable |
|---------|--------------|----------|---------|--------------|
| Portainer HTTP | 23380 | HTTP | Redirects to HTTPS | Yes (haproxy.cfg) |
| Portainer HTTPS | 23343 | HTTPS | Management UI | Yes (haproxy.cfg) |
| ArgoCD | 23800 | HTTP | GitOps interface | Yes (haproxy.cfg) |
| Cluster Routes | 23080 | HTTP | Domain-based routing | Yes (haproxy.cfg) |

> **Note**: All ports can be customized by editing `compose/haproxy/haproxy.cfg` and restarting HAProxy.

## Verification

Default configuration verification (adjust for your settings):

```bash
# Replace with your HAPROXY_HOST from config/clusters.env
HAPROXY_HOST=192.168.51.30

# Portainer HTTPS
curl -kI https://${HAPROXY_HOST}:23343
# Expected: HTTP/1.1 200 OK

# Portainer HTTP (redirect)
curl -I http://${HAPROXY_HOST}:23380
# Expected: HTTP/1.1 301 Moved Permanently

# ArgoCD
curl -I http://${HAPROXY_HOST}:23800
# Expected: HTTP/1.1 200 OK

# Cluster route (with domain header, adjust BASE_DOMAIN as needed)
curl -H 'Host: dev.local' -I http://${HAPROXY_HOST}:23080
# Expected: HTTP/1.1 200 OK (or backend service response)
```

## Advanced Usage

### Custom Domain Routing

By default, clusters are accessible via `<env>.local`. To use custom domains:

1. Update `BASE_DOMAIN` in `config/clusters.env`:
   ```bash
   BASE_DOMAIN=k8s.example.com
   ```

2. Re-sync HAProxy routes:
   ```bash
   ./scripts/haproxy_sync.sh --prune
   ```

3. Access via custom domain:
   ```bash
   curl -H 'Host: dev.k8s.example.com' http://192.168.51.30:23080
   ```

### Multi-Node Clusters

Edit cluster config files in `clusters/` to add worker nodes:

```yaml
# clusters/dev-cluster.yaml (kind)
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

```yaml
# clusters/dev-k3d-cluster.yaml (k3d)
apiVersion: k3d.io/v1alpha5
kind: Simple
servers: 1
agents: 2
```

## Testing

Run smoke tests for a cluster:

```bash
./scripts/smoke.sh dev
```

Test results are logged to `docs/TEST_REPORT.md`.

## Troubleshooting

### Portainer Edge Agent Not Connecting

1. Check Edge Agent logs:
   ```bash
   kubectl logs -n portainer deploy/portainer-agent
   ```

2. Verify network connectivity:
   ```bash
   docker network inspect k3d-dev
   ```

3. Ensure HAProxy can reach cluster containers:
   ```bash
   docker network connect k3d-dev haproxy-gw
   ```

### HAProxy Route Not Working

1. Check HAProxy configuration:
   ```bash
   docker exec haproxy-gw cat /usr/local/etc/haproxy/haproxy.cfg
   ```

2. Verify backend health:
   ```bash
   curl -I http://192.168.51.30:23080/haproxy/stats
   ```

3. Re-sync routes:
   ```bash
   ./scripts/haproxy_sync.sh --prune
   ```

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'feat: add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

See [AGENTS.md](./AGENTS.md) for detailed development guidelines.

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [Portainer CE](https://www.portainer.io/) - Container management platform
- [HAProxy](http://www.haproxy.org/) - High-performance load balancer
- [kind](https://kind.sigs.k8s.io/) - Kubernetes in Docker
- [k3d](https://k3d.io/) - k3s in Docker
- [ArgoCD](https://argo-cd.readthedocs.io/) - GitOps continuous delivery

## Support

- 📚 Documentation: [docs/](./docs/)
- 🐛 Issues: [GitHub Issues](https://github.com/hofmannhe/kindler/issues)
- 💬 Discussions: [GitHub Discussions](https://github.com/hofmannhe/kindler/discussions)
