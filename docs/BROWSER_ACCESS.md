# ArgoCD 浏览器访问配置指南

## 服务器端验证结果 ✅

所有服务器端测试已通过：
- ✅ HAProxy 端口 23080 正常监听
- ✅ localhost:23080 访问成功
- ✅ 192.168.51.30:23080 访问成功
- ✅ 所有 K3D 集群域名路由正常

## 本地浏览器访问配置

### 步骤 1: 配置本地 hosts 文件

**重要**: 以下操作需要在**您的本地电脑**（不是服务器）上执行。

#### Windows 系统
1. 以管理员身份打开记事本
2. 打开文件: `C:\Windows\System32\drivers\etc\hosts`
3. 在文件末尾添加：
```
192.168.51.30  dev-k3d-argocd.local uat-k3d-argocd.local prod-k3d-argocd.local
192.168.51.30  dev-argocd.local uat-argocd.local prod-argocd.local
```
4. 保存文件

#### macOS/Linux 系统
1. 打开终端
2. 编辑 hosts 文件：
```bash
sudo nano /etc/hosts
```
3. 在文件末尾添加：
```
192.168.51.30  dev-k3d-argocd.local uat-k3d-argocd.local prod-k3d-argocd.local
192.168.51.30  dev-argocd.local uat-argocd.local prod-argocd.local
```
4. 保存文件 (Ctrl+O, Enter, Ctrl+X)

### 步骤 2: 验证 DNS 解析

在本地电脑的终端/命令提示符中执行：

```bash
# 测试网络连通性
ping 192.168.51.30

# 测试域名解析
ping dev-k3d-argocd.local

# 测试 HTTP 访问
curl -H "Host: dev-k3d-argocd.local" http://192.168.51.30:23080
```

如果看到 "ArgoCD" 相关内容，说明配置成功。

### 步骤 3: 浏览器访问

打开浏览器，访问以下 URL：

#### K3D 集群 ArgoCD
- http://dev-k3d-argocd.local:23080
- http://uat-k3d-argocd.local:23080
- http://prod-k3d-argocd.local:23080

#### KIND 集群 ArgoCD
- http://dev-argocd.local:23080
- http://uat-argocd.local:23080
- http://prod-argocd.local:23080

## 备选方案：使用浏览器插件

如果无法修改 hosts 文件，可以使用浏览器插件：

### Chrome/Edge
1. 安装 "ModHeader" 插件
2. 添加请求头：
   - Name: `Host`
   - Value: `dev-k3d-argocd.local`
3. 直接访问: http://192.168.51.30:23080

### Firefox
1. 安装 "Modify Header Value" 插件
2. 配置相同的 Host 头
3. 直接访问: http://192.168.51.30:23080

## 故障排查

### 问题 1: 无法 ping 通 192.168.51.30
**原因**: 本地电脑与服务器不在同一网络
**解决**:
- 确保本地电脑能访问服务器网络
- 检查防火墙设置
- 尝试使用 VPN 或 SSH 隧道

### 问题 2: ping 通但浏览器无法访问
**原因**: 防火墙阻止了 23080 端口
**解决**: 在服务器上开放端口
```bash
sudo ufw allow 23080/tcp
# 或
sudo firewall-cmd --add-port=23080/tcp --permanent
sudo firewall-cmd --reload
```

### 问题 3: 显示 "404 Not Found"
**原因**: Host header 不正确
**解决**:
- 检查 hosts 文件配置是否正确
- 确保域名拼写无误
- 清除浏览器 DNS 缓存

### 问题 4: 显示 "Connection Refused"
**原因**: HAProxy 未运行或端口未监听
**解决**: 在服务器上检查
```bash
docker ps | grep haproxy
netstat -tuln | grep 23080
```

## 技术架构

```
本地浏览器
    ↓
    ↓ http://dev-k3d-argocd.local:23080
    ↓
DNS 解析 (hosts 文件)
    ↓ 192.168.51.30:23080
    ↓
HAProxy (Host header 路由)
    ↓
K3D 集群节点:30800 (NodePort)
    ↓
ArgoCD Service (ClusterIP)
    ↓
ArgoCD Pod
```

## 完整验证清单

在配置完成后，请验证以下所有项：

- [ ] 本地电脑可以 ping 通 192.168.51.30
- [ ] 本地电脑可以 ping 通 dev-k3d-argocd.local
- [ ] curl 命令可以获取 ArgoCD 页面内容
- [ ] 浏览器可以访问 http://dev-k3d-argocd.local:23080
- [ ] 浏览器显示 "ArgoCD - GitOps CD Platform" 标题
- [ ] 所有 6 个集群的 ArgoCD 都可以访问

## 联系信息

- 服务器 IP: **192.168.51.30**
- HAProxy 端口: **23080**
- ArgoCD NodePort: **30800**

---

最后更新: 2025-10-01