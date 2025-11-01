# 路由与入口规范（防回归）

本规范用于防止管理域名被错误路由到 devops 集群（典型表现：`portainer.devops.*` / `kindler.devops.*` 被转发到 ArgoCD）。

## 根因归纳（Root Cause）

- 在 HAProxy 的动态 ACL 中为 `devops` 生成了“泛匹配”规则：
  - `acl host_devops hdr_reg(host) -i ^[^.]+\.devops\.[^:]+`
  - `use_backend be_devops if host_devops`
- 该规则匹配所有 `*.devops.*`，优先级又高于静态管理路由，导致：
  - `portainer.devops.*` 与 `kindler.devops.*` 被错误路由到 `be_devops`（devops 集群 NodePort=30800，即 ArgoCD）

## 规范要求（Do / Don’t）

- 禁止：为 `devops` 生成动态 ACL/后端（不允许 `host_devops` / `be_devops`）。
- 必须：管理域名仅使用显式静态路由：
  - `portainer.devops.*` → `be_portainer`
  - `argocd.devops.*` → `be_argocd`
  - `kindler.devops.*` → `be_kindler`
  - `haproxy.devops.*` → `be_haproxy_stats`（带 /stat）
- 允许：动态 ACL/后端仅为“业务集群”（非 devops）生成，形如：
  - `whoami.<env>.<BASE_DOMAIN>` → `be_<env>`

## 实现保证（已落地）

- `scripts/haproxy_route.sh`：显式跳过 `devops` 的动态路由生成（防止再次写入错误 ACL）。
- `compose/infrastructure/haproxy.cfg`：
  - 移除 `host_devops` / `be_devops` 相关行。
  - 保留并仅使用静态管理路由（portainer/argocd/kindler/haproxy）。
- 回归用例：`tests/haproxy_regression_devops.sh`
  - 断言不存在 `host_devops` 与 `use_backend be_devops`。
  - 断言存在三大管理路由的显式规则。

## Git 与 whoami 建议

- `be_git` 固定转发到本地 GitLab 容器：`gitlab:6080`。
- `config/git.env` 允许通过 `BASE_DOMAIN` 动态渲染 `git.devops.$BASE_DOMAIN`。
- `scripts/setup_git.sh` 在无法直接访问域名时，回退使用 `127.0.0.1 + Host` 头访问 HAProxy。
- 若仍无法初始化仓库，请在 GitLab 中预先创建目标仓库，并确保凭证有效（见 `config/git.env`）。

## 变更前自检清单

- [ ] haproxy.cfg 中无 `host_devops` / `be_devops`
- [ ] `tests/haproxy_regression_devops.sh` 通过
- [ ] `portainer.devops.$BASE_DOMAIN` 返回 301/200
- [ ] `argocd.devops.$BASE_DOMAIN` 返回 200（或预期状态）
- [ ] 业务域名（如 `whoami.<env>.$BASE_DOMAIN`）返回 200 或 404（未部署时），不可误指向 ArgoCD

