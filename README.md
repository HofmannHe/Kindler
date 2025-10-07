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
   - Portainer: `https://<HAPROXY_HOST>` (self-signed cert, defaults to `https://192.168.51.30`)
   - ArgoCD: `http://<HAPROXY_HOST>` (defaults to `http://192.168.51.30`)
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

- **Portainer**: `https://portainer.devops.$BASE_DOMAIN` (default base domain: `192.168.51.30.sslip.io` → `https://portainer.devops.192.168.51.30.sslip.io`)
- **ArgoCD**: `http://argocd.devops.$BASE_DOMAIN`
- **Business Apps** (via domain routing, default base domain: `local`):
  ```bash
  # Example with default configuration (HAProxy HTTP port = 80)
  curl -H 'Host: dev.local' http://192.168.51.30
  curl -H 'Host: uat.local' http://192.168.51.30
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
│   ├── stop_env.sh         # Stop cluster (preserve config)
│   ├── start_env.sh        # Start stopped cluster
│   ├── delete_env.sh       # Permanently delete cluster (incl. CSV config)
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

#### Create Environment
```bash
# Create cluster (use CSV defaults)
./scripts/create_env.sh -n dev

# Create cluster (override options)
./scripts/create_env.sh -n dev -p kind --node-port 30081 --no-register-portainer
```

#### Stop/Start Environment (Preserve Configuration)
```bash
# Stop cluster (preserve CSV config and kubeconfig, free resources)
./scripts/stop_env.sh -n dev

# Restart stopped cluster
./scripts/start_env.sh -n dev
```

> **Use Case**: Temporarily stop clusters to save resources, can quickly resume later. Ideal for dev environments not currently needed.

#### Permanently Delete Environment
```bash
# Permanently delete cluster (auto-cleanup CSV config, Portainer registration, ArgoCD registration, HAProxy routes)
./scripts/delete_env.sh -n dev
```

> **Warning**: This operation will:
> - Delete Kubernetes cluster
> - Remove configuration from `config/environments.csv`
> - Unregister Portainer Edge Environment
> - Unregister ArgoCD cluster
> - Remove HAProxy routes
> - Auto-sync ApplicationSet (remove related Applications)

#### Clean All Resources
```bash
# Clean all resources (clusters, containers, networks, volumes)
./scripts/clean.sh
```

### Operation Comparison

| Operation | Cluster Running | CSV Config | Portainer | ArgoCD | Purpose |
|-----------|----------------|------------|-----------|--------|---------|
| **stop_env.sh** | ❌ Stopped | ✅ Kept | ✅ Kept | ✅ Kept | Temporarily free resources |
| **start_env.sh** | ✅ Running | ✅ Used | ✅ Resume | ✅ Resume | Restart stopped cluster |
| **delete_env.sh** | ❌ Deleted | ❌ Deleted | ❌ Unregistered | ❌ Unregistered | Permanently remove environment |

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
curl -kI https://${HAPROXY_HOST}
# Expected: HTTP/1.1 200 OK

# Portainer HTTP (redirect)
curl -I http://${HAPROXY_HOST}
# Expected: HTTP/1.1 301 Moved Permanently

# ArgoCD
curl -I http://${HAPROXY_HOST}
# Expected: HTTP/1.1 200 OK

# Cluster route (with domain header, adjust BASE_DOMAIN as needed)
curl -H 'Host: dev.local' -I http://${HAPROXY_HOST}
# Expected: HTTP/1.1 200 OK (or backend service response)
```

## Advanced Usage

### Domain Name Resolution

Kindler supports three DNS resolution strategies:

#### Option 1: sslip.io (Zero Configuration, Recommended) ✅

Uses public DNS service that automatically resolves to your IP:

```bash
# config/clusters.env (default)
BASE_DOMAIN=192.168.51.30.sslip.io
HAPROXY_HOST=192.168.51.30

# Access services directly
curl http://whoami.dev.192.168.51.30.sslip.io
curl http://whoami.uat.192.168.51.30.sslip.io
```

**Pros:**
- Zero configuration required
- Works immediately after installation
- Perfect for multi-user environments
- No local DNS setup needed

**Cons:**
- Longer domain names
- Requires internet connectivity for DNS resolution

#### Option 2: Local /etc/hosts (Clean Domains)

Manage local DNS entries with the provided script:

```bash
# Change BASE_DOMAIN to local domain
nano config/clusters.env
# Set: BASE_DOMAIN=local

# Sync all environments to /etc/hosts
sudo ./scripts/update_hosts.sh --sync

# Or add individual environment
sudo ./scripts/update_hosts.sh --add dev

# Access with clean domains
curl http://dev.local
curl http://uat.local

# Clean up when done
sudo ./scripts/update_hosts.sh --clean
```

**Script usage:**
```bash
sudo ./scripts/update_hosts.sh --sync       # Sync all from CSV
sudo ./scripts/update_hosts.sh --add dev    # Add single environment
sudo ./scripts/update_hosts.sh --remove dev # Remove environment
sudo ./scripts/update_hosts.sh --clean      # Remove all Kindler entries
sudo ./scripts/update_hosts.sh --help       # Show help
```

**Pros:**
- Clean, short domain names
- Fully local, no external dependencies
- Automatic backup of /etc/hosts before changes

**Cons:**
- Requires sudo privileges
- Manual script execution needed
- Each developer needs to run on their machine

#### Option 3: curl -H Method (Testing)

Use Host header without DNS configuration:

```bash
# No configuration needed
curl -H 'Host: dev.local' http://192.168.51.30
curl -H 'Host: uat.local' http://192.168.51.30
```

**Best for:** Quick testing and verification

### Multi-Environment Support

Kindler fully supports multiple environments with automatic DNS and HAProxy routing.

#### Example: Managing Multiple Environments

```bash
# Current environments defined in config/environments.csv
# devops, dev, uat, prod, dev-k3d, uat-k3d, prod-k3d, etc.

# Option 1: Access with sslip.io (default, zero config)
curl http://dev.192.168.51.30.sslip.io
curl http://uat.192.168.51.30.sslip.io
curl http://prod.192.168.51.30.sslip.io

# Option 2: Access with local domains (after running update_hosts.sh)
sudo ./scripts/update_hosts.sh --sync  # Syncs all environments at once
curl http://dev.local
curl http://uat.local
curl http://prod.local
```

#### Add a New Environment

1. **Add to CSV** (`config/environments.csv`):
   ```csv
   staging,k3d,30080,25001,true,true,25080,25443
   ```

2. **Create the cluster**:
   ```bash
   ./scripts/create_env.sh -n staging
   ```
   This automatically:
   - Creates k3d cluster
   - Registers to Portainer via Edge Agent
   - Registers to ArgoCD
   - Adds HAProxy route (ACL + backend)

3. **Access immediately**:
   ```bash
   # With sslip.io (works immediately)
   curl http://whoami.staging.192.168.51.30.sslip.io

   # With local domain (sync hosts first)
   sudo ./scripts/update_hosts.sh --add staging
   curl http://staging.local
   ```

#### HAProxy Routing Configuration

Each environment gets automatic HAProxy configuration:

```haproxy
# Frontend ACL (in compose/haproxy/haproxy.cfg)
frontend fe_http
  bind *:80

  # Auto-generated for each environment (host_<env>)
  acl host_dev  hdr_reg(host) -i ^[^.]+\\.dev\\.[^:]+
  use_backend be_dev if host_dev

  acl host_uat  hdr_reg(host) -i ^[^.]+\\.uat\\.[^:]+
  use_backend be_uat if host_uat

  acl host_prod  hdr_reg(host) -i ^[^.]+\\.prod\\.[^:]+
  use_backend be_prod if host_prod

# Backend routing to cluster NodePort
backend be_dev
  server s1 <dev-cluster-ip>:30080

backend be_uat
  server s1 <uat-cluster-ip>:30080

backend be_prod
  server s1 <prod-cluster-ip>:30080
```

**How it works:**
1. User accesses `http://dev.192.168.51.30.sslip.io`
2. DNS resolves to `192.168.51.30` (HAProxy)
3. HAProxy reads Host header: `dev.192.168.51.30.sslip.io`
4. ACL `host_dev` matches → routes to `be_dev` backend
5. Request forwarded to dev cluster container IP on port 30080

**View current routes:**
```bash
docker exec haproxy-gw cat /usr/local/etc/haproxy/haproxy.cfg | grep -A 2 "acl host_"
```

**Sync routes from CSV:**
```bash
./scripts/haproxy_sync.sh         # Add missing routes
./scripts/haproxy_sync.sh --prune # Add missing + remove unlisted
```

### Custom Domain Routing

To use your own domain:

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
   curl -H 'Host: dev.k8s.example.com' http://192.168.51.30
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
   curl -I http://192.168.51.30/haproxy/stats
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
