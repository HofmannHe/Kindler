#!/usr/bin/env python3
"""
Kindler Host API Server
轻量级API服务，在宿主机运行，执行create_env.sh/delete_env.sh等脚本
"""
import asyncio
import os
import subprocess
from pathlib import Path
from typing import Optional
from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
import uvicorn

app = FastAPI(title="Kindler Host API", version="1.0.0")

# 脚本目录
SCRIPTS_DIR = Path(__file__).parent.absolute()


class ClusterCreateRequest(BaseModel):
    """集群创建请求"""
    name: str
    provider: str = "k3d"
    node_port: int = 30080
    pf_port: int = 19000
    http_port: Optional[int] = None
    https_port: Optional[int] = None
    cluster_subnet: Optional[str] = None
    register_portainer: bool = True
    haproxy_route: bool = True
    register_argocd: bool = True


class ClusterDeleteRequest(BaseModel):
    """集群删除请求"""
    name: str


async def execute_script_stream(script_name: str, args: list):
    """
    执行脚本并流式返回输出
    
    Args:
        script_name: 脚本名称
        args: 参数列表
    
    Yields:
        脚本输出的每一行
    """
    script_path = SCRIPTS_DIR / script_name
    
    if not script_path.exists():
        yield f"[ERROR] Script not found: {script_path}\n"
        return
    
    # 构建命令
    cmd = [str(script_path)] + args
    
    try:
        # 创建子进程
        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            cwd=str(SCRIPTS_DIR)
        )
        
        # 流式读取输出
        while True:
            line = await process.stdout.readline()
            if not line:
                break
            
            decoded_line = line.decode('utf-8', errors='replace')
            yield decoded_line
        
        # 等待进程完成
        returncode = await process.wait()
        
        if returncode == 0:
            yield "[SUCCESS] Operation completed successfully\n"
        else:
            yield f"[ERROR] Script failed with exit code {returncode}\n"
    
    except Exception as e:
        yield f"[ERROR] Failed to execute script: {e}\n"


@app.get("/health")
async def health():
    """健康检查"""
    return {"status": "healthy"}


@app.post("/api/clusters/create")
async def create_cluster(request: ClusterCreateRequest):
    """
    创建集群（流式返回日志）
    """
    # 构建参数
    args = [
        "-n", request.name,
        "-p", request.provider,
        "--node-port", str(request.node_port),
        "--pf-port", str(request.pf_port),
    ]
    
    # 可选参数
    if request.http_port is not None:
        args.extend(["--http-port", str(request.http_port)])
    if request.https_port is not None:
        args.extend(["--https-port", str(request.https_port)])
    
    # 布尔标志
    if request.register_portainer:
        args.append("--register-portainer")
    else:
        args.append("--no-register-portainer")
    
    if request.haproxy_route:
        args.append("--haproxy-route")
    else:
        args.append("--no-haproxy-route")
    
    if request.register_argocd:
        args.append("--register-argocd")
    else:
        args.append("--no-register-argocd")
    
    # 返回流式响应
    return StreamingResponse(
        execute_script_stream("create_env.sh", args),
        media_type="text/plain"
    )


@app.post("/api/clusters/delete")
async def delete_cluster(request: ClusterDeleteRequest):
    """
    删除集群（流式返回日志）
    """
    args = ["-n", request.name]
    
    return StreamingResponse(
        execute_script_stream("delete_env.sh", args),
        media_type="text/plain"
    )


if __name__ == "__main__":
    # 监听在localhost:8888
    uvicorn.run(app, host="0.0.0.0", port=8888, log_level="info")

