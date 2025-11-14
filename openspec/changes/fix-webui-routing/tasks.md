1. - [x] 复现并记录通过 WebUI 创建集群后 whoami 404 的现象，确认 HAProxy 配置未更新，找出漏检原因。
2. - [x] 更新脚本根目录探测逻辑（`lib.sh`）以支持 `KINDLER_ROOT` 覆盖，并通过 docker-compose 为 `kindler-webui-backend` 挂载宿主机仓库 + 设置该变量。
3. - [x] 重启 WebUI backend，使用 WebUI/API 再次创建测试集群，确保 HAProxy 立即获得路由；对遗留的 test/test1 运行 `haproxy_sync.sh --prune` 或 add route 纠偏。
4. - [x] 补充 specs（tooling-scripts）说明“容器中运行的脚本也必须更新宿主机 HAProxy/compose 文件”，并记录回归结果（docs/TEST_REPORT.md、curl 验证）。
5. - [x] 执行完整回归（脚本 + smoke + bats），验证 whoami 域名与 Portainer/ArgoCD 状态一致。
