#!/usr/bin/env bash
# 设置 devops 集群的存储支持
# 预拉取 local-path-provisioner 所需的所有镜像

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"

echo "=========================================="
echo "  设置 devops 集群存储支持"
echo "=========================================="
echo ""

# local-path-provisioner 需要的镜像列表
# 注意：必须使用完整的 rancher/mirrored-library-busybox 镜像名称
STORAGE_IMAGES=(
  "rancher/local-path-provisioner:v0.0.30"
  "rancher/mirrored-library-busybox:1.36.1"
)

echo "[STORAGE] 预拉取存储相关镜像..."
for img in "${STORAGE_IMAGES[@]}"; do
  if prefetch_image "$img"; then
    echo "  [+] $img"
  else
    echo "  [!] 预拉取失败: $img (将在集群中直接拉取)" >&2
  fi
done

echo ""
echo "[STORAGE] 导入镜像到 devops 集群..."
for img in "${STORAGE_IMAGES[@]}"; do
  if docker images -q "$img" >/dev/null 2>&1; then
    echo "  导入 $img..."
    k3d image import "$img" -c devops 2>/dev/null || echo "  [WARN] 导入失败: $img"
  fi
done

echo ""
echo "[STORAGE] 重启 local-path-provisioner..."
kubectl --context k3d-devops delete pod -n kube-system -l app=local-path-provisioner 2>/dev/null || true

echo ""
echo "[STORAGE] 等待 local-path-provisioner 就绪..."
kubectl --context k3d-devops wait --for=condition=ready pod \
  -l app=local-path-provisioner -n kube-system --timeout=60s || {
    echo "[ERROR] local-path-provisioner 未能就绪"
    kubectl --context k3d-devops get pods -n kube-system | grep local-path
    exit 1
  }

echo ""
echo "=========================================="
echo "✅ 存储支持设置完成！"
echo "=========================================="
echo ""
echo "验证："
echo "  kubectl --context k3d-devops get storageclass"
echo "  kubectl --context k3d-devops get pods -n kube-system | grep local-path"
echo ""

