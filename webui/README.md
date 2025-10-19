# Kindler Web GUI

Modern web interface for managing Kubernetes clusters (kind/k3d).

## Quick Start

```bash
# Start Web GUI services
docker compose -f compose/infrastructure/docker-compose.yml up -d kindler-webui-backend kindler-webui-frontend

# Access Web GUI
open http://kindler.devops.192.168.51.30.sslip.io
```

## Documentation

- [使用指南 (Chinese)](../docs/WEBUI.md)
- [API Documentation](http://kindler.devops.192.168.51.30.sslip.io/docs)

## Project Structure

```
webui/
├── backend/              # FastAPI backend
│   ├── app/
│   │   ├── api/         # REST API endpoints
│   │   ├── services/    # Business logic
│   │   ├── models/      # Data models
│   │   ├── websocket/   # WebSocket management
│   │   └── main.py      # Application entry
│   ├── requirements.txt
│   └── Dockerfile
├── frontend/            # Vue 3 frontend
│   ├── src/
│   │   ├── components/  # UI components
│   │   ├── views/       # Page views
│   │   ├── api/         # API client
│   │   └── main.js
│   ├── package.json
│   └── Dockerfile
├── docker-compose.yml   # Standalone compose file
└── tests/
    ├── api/            # API unit tests
    ├── e2e/            # E2E tests with Playwright
    └── run_tests.sh    # Test runner
```

## Development

### Backend

```bash
cd backend
pip install -r requirements.txt
python -m app.main
```

### Frontend

```bash
cd frontend
npm install
npm run dev
```

### Testing

```bash
cd tests

# Install dependencies
pip install -r requirements.txt
playwright install chromium

# Run tests
./run_tests.sh all
```

## Features

- ✅ Create, delete, start, stop k3d/kind clusters
- ✅ Real-time progress updates via WebSocket
- ✅ Concurrent operations support
- ✅ Auto-registration with Portainer and ArgoCD
- ✅ Auto-configuration of HAProxy routes
- ✅ Cluster status monitoring

## Tech Stack

- **Backend**: FastAPI, Python 3.11, WebSockets
- **Frontend**: Vue 3, Vite, Naive UI
- **Database**: PostgreSQL (via kubectl)
- **Testing**: Pytest, Playwright
- **Deployment**: Docker Compose

## License

See [LICENSE](../LICENSE)

