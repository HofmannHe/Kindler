<template>
  <div>
    <n-space vertical :size="24">
      <!-- Header -->
      <n-space justify="space-between" align="center">
        <n-space align="center">
          <n-button text @click="$router.push('/')">
            <template #icon>
              <span>←</span>
            </template>
          </n-button>
          <h1>{{ cluster?.name || clusterName }}</h1>
          <n-tag v-if="cluster" :type="statusTagType">{{ statusText }}</n-tag>
        </n-space>
        <n-button @click="loadCluster" :loading="loading">刷新</n-button>
      </n-space>
      
      <!-- Cluster Info -->
      <n-card title="集群信息" v-if="cluster">
        <n-descriptions :column="2" bordered>
          <n-descriptions-item label="名称">{{ cluster.name }}</n-descriptions-item>
          <n-descriptions-item label="Provider">{{ cluster.provider }}</n-descriptions-item>
          <n-descriptions-item label="状态">{{ statusText }}</n-descriptions-item>
          <n-descriptions-item label="Node Port">{{ cluster.node_port }}</n-descriptions-item>
          <n-descriptions-item label="Port Forward Port">{{ cluster.pf_port }}</n-descriptions-item>
          <n-descriptions-item label="HTTP Port">{{ cluster.http_port }}</n-descriptions-item>
          <n-descriptions-item label="HTTPS Port">{{ cluster.https_port }}</n-descriptions-item>
          <n-descriptions-item label="子网" v-if="cluster.cluster_subnet">
            {{ cluster.cluster_subnet }}
          </n-descriptions-item>
          <n-descriptions-item label="创建时间">
            {{ cluster.created_at ? new Date(cluster.created_at).toLocaleString('zh-CN') : '-' }}
          </n-descriptions-item>
          <n-descriptions-item label="更新时间">
            {{ cluster.updated_at ? new Date(cluster.updated_at).toLocaleString('zh-CN') : '-' }}
          </n-descriptions-item>
        </n-descriptions>
      </n-card>
      
      <!-- Cluster Status -->
      <n-card title="运行状态" v-if="status">
        <n-descriptions :column="2" bordered>
          <n-descriptions-item label="节点状态">
            {{ status.nodes_ready }} / {{ status.nodes_total }} Ready
          </n-descriptions-item>
          <n-descriptions-item label="错误信息" v-if="status.error_message">
            <n-text type="error">{{ status.error_message }}</n-text>
          </n-descriptions-item>
        </n-descriptions>
      </n-card>
      
      <!-- Quick Links -->
      <n-card title="快速链接" v-if="cluster">
        <n-space>
          <n-button 
            tag="a" 
            :href="`http://whoami.${cluster.name}.${baseDomain}`" 
            target="_blank"
          >
            访问 Whoami 应用
          </n-button>
          <n-button 
            tag="a" 
            :href="`http://portainer.devops.${baseDomain}`" 
            target="_blank"
          >
            Portainer
          </n-button>
          <n-button 
            tag="a" 
            :href="`http://argocd.devops.${baseDomain}`" 
            target="_blank"
          >
            ArgoCD
          </n-button>
        </n-space>
      </n-card>
    </n-space>
  </div>
</template>

<script setup>
import { ref, computed, onMounted } from 'vue'
import { useRoute } from 'vue-router'
import { NSpace, NButton, NCard, NTag, NText, NDescriptions, NDescriptionsItem, useMessage } from 'naive-ui'
import { clusterAPI, configAPI } from '../api/client'

const route = useRoute()
const message = useMessage()

const clusterName = route.params.name
const cluster = ref(null)
const status = ref(null)
const loading = ref(false)
const baseDomain = ref('192.168.51.30.sslip.io')

const statusText = computed(() => {
  if (!cluster.value) return '-'
  const statusMap = {
    running: '运行中',
    stopped: '已停止',
    error: '错误',
    unknown: '未知'
  }
  return statusMap[cluster.value.status] || cluster.value.status
})

const statusTagType = computed(() => {
  if (!cluster.value) return 'default'
  const typeMap = {
    running: 'success',
    stopped: 'warning',
    error: 'error',
    unknown: 'default'
  }
  return typeMap[cluster.value.status] || 'default'
})

const getStatusType = (status) => {
  if (status === 'online' || status === 'healthy') return 'success'
  if (status === 'offline' || status === 'degraded') return 'error'
  return 'default'
}

const loadCluster = async () => {
  loading.value = true
  try {
    // Load cluster info
    const clusterResponse = await clusterAPI.get(clusterName)
    cluster.value = clusterResponse.data
    
    // Load cluster status
    const statusResponse = await clusterAPI.status(clusterName)
    status.value = statusResponse.data
  } catch (error) {
    message.error('加载集群信息失败: ' + error.message)
  } finally {
    loading.value = false
  }
}

const loadConfig = async () => {
  try {
    const response = await configAPI.get()
    baseDomain.value = response.data.base_domain
  } catch (error) {
    console.error('Failed to load config:', error)
  }
}

onMounted(() => {
  loadCluster()
  loadConfig()
})
</script>

