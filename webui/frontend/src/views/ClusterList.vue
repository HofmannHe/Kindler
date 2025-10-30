<template>
  <div>
    <n-space vertical :size="24">
      <!-- Header Actions -->
      <n-space justify="space-between">
        <h1>Kubernetes 集群</h1>
        <n-space>
          <n-button @click="loadClusters" :loading="loading">
            <template #icon>
              <span>🔄</span>
            </template>
            刷新
          </n-button>
          <n-button type="primary" @click="showCreateModal = true">
            <template #icon>
              <span>➕</span>
            </template>
            创建集群
          </n-button>
        </n-space>
      </n-space>
      
      <!-- Global Services Status -->
      <n-card title="全局服务状态" style="margin-bottom: 16px;">
        <n-space :size="16">
          <n-statistic 
            v-if="services.portainer"
            label="Portainer" 
            :value="services.portainer.status"
          >
            <template #prefix>
              <n-icon :component="getServiceIcon(services.portainer.status)" :color="getServiceIconColor(services.portainer.status)" />
            </template>
          </n-statistic>
          
          <n-statistic 
            v-if="services.argocd"
            label="ArgoCD" 
            :value="services.argocd.status"
          >
            <template #prefix>
              <n-icon :component="getServiceIcon(services.argocd.status)" :color="getServiceIconColor(services.argocd.status)" />
            </template>
          </n-statistic>
          
          <n-statistic 
            v-if="services.haproxy"
            label="HAProxy" 
            :value="services.haproxy.status"
          >
            <template #prefix>
              <n-icon :component="getServiceIcon(services.haproxy.status)" :color="getServiceIconColor(services.haproxy.status)" />
            </template>
          </n-statistic>
          
          <n-statistic 
            v-if="services.git"
            label="Git" 
            :value="services.git.status"
          >
            <template #prefix>
              <n-icon :component="getServiceIcon(services.git.status)" :color="getServiceIconColor(services.git.status)" />
            </template>
          </n-statistic>
        </n-space>
        
        <template #action>
          <n-space>
            <n-button 
              v-if="services.portainer"
              tag="a" 
              :href="services.portainer.url" 
              target="_blank"
            >
              访问 Portainer
            </n-button>
            <n-button 
              v-if="services.argocd"
              tag="a" 
              :href="services.argocd.url" 
              target="_blank"
            >
              访问 ArgoCD
            </n-button>
            <n-button 
              @click="loadServicesStatus" 
              :loading="loadingServices"
            >
              <template #icon>
                <span>🔄</span>
              </template>
              刷新状态
            </n-button>
          </n-space>
        </template>
      </n-card>
      
      <!-- Active Tasks -->
      <div v-if="activeTasks.length > 0">
        <h3>正在进行的任务</h3>
        <task-progress
          v-for="task in activeTasks"
          :key="task.task_id"
          :task="task"
        />
      </div>
      
      <!-- Clusters Table -->
      <n-data-table
        :columns="columns"
        :data="clusters"
        :loading="loading"
        :pagination="{ pageSize: 10 }"
        :bordered="false"
      />
    </n-space>
    
    <!-- Create Cluster Modal -->
    <create-cluster-modal
      v-model:show="showCreateModal"
      :config="config"
      @submit="handleCreateCluster"
    />
  </div>
</template>

<script setup>
import { ref, h, onMounted, onUnmounted } from 'vue'
import { useRouter } from 'vue-router'
import { NSpace, NButton, NDataTable, NTag, NPopconfirm, NCard, NStatistic, NIcon, useMessage } from 'naive-ui'
import { CheckmarkCircle, CloseCircle, AlertCircle, HelpCircle } from '@vicons/ionicons5'
import { clusterAPI, configAPI, servicesAPI, taskAPI, taskWebSocket } from '../api/client'
import CreateClusterModal from '../components/CreateClusterModal.vue'
import TaskProgress from '../components/TaskProgress.vue'

const router = useRouter()
const message = useMessage()

const clusters = ref([])
const config = ref(null)
const loading = ref(false)
const showCreateModal = ref(false)
const activeTasks = ref([])
const services = ref({})
const loadingServices = ref(false)

// Table columns
const columns = [
  {
    title: '名称',
    key: 'name',
    render: (row) => {
      return h(
        'a',
        {
          style: 'cursor: pointer; color: #18a058;',
          onClick: () => router.push(`/clusters/${row.name}`)
        },
        row.name
      )
    }
  },
  {
    title: 'Provider',
    key: 'provider',
    width: 100
  },
  {
    title: '状态',
    key: 'status',
    width: 100,
    render: (row) => {
      const statusMap = {
        creating: { type: 'info', text: '创建中' },
        running: { type: 'success', text: '运行中' },
        stopped: { type: 'warning', text: '已停止' },
        degraded: { type: 'warning', text: '降级' },
        error: { type: 'error', text: '错误' },
        unknown: { type: 'default', text: '未知' }
      }
      const status = statusMap[row.status] || statusMap.unknown
      return h(NTag, { type: status.type }, () => status.text)
    }
  },
  {
    title: 'HTTP Port',
    key: 'http_port',
    width: 120
  },
  {
    title: 'HTTPS Port',
    key: 'https_port',
    width: 120
  },
  {
    title: '创建时间',
    key: 'created_at',
    width: 180,
    render: (row) => row.created_at ? new Date(row.created_at).toLocaleString('zh-CN') : '-'
  },
  {
    title: '操作',
    key: 'actions',
    width: 200,
    render: (row) => {
      return h(NSpace, null, {
        default: () => [
          h(
            NButton,
            {
              size: 'small',
              onClick: () => handleStartCluster(row.name),
              disabled: row.status === 'running'
            },
            { default: () => '启动' }
          ),
          h(
            NButton,
            {
              size: 'small',
              onClick: () => handleStopCluster(row.name),
              disabled: row.status !== 'running'
            },
            { default: () => '停止' }
          ),
          h(
            NPopconfirm,
            {
              onPositiveClick: () => handleDeleteCluster(row.name),
              disabled: row.name === 'devops'
            },
            {
              trigger: () => h(
                NButton,
                { 
                  size: 'small', 
                  type: 'error',
                  disabled: row.name === 'devops'
                },
                { default: () => row.name === 'devops' ? '删除（管理集群不可删除）' : '删除' }
              ),
              default: () => `确定要删除集群 ${row.name} 吗？此操作不可逆。`
            }
          )
        ]
      })
    }
  }
]

// Load clusters
const loadClusters = async () => {
  loading.value = true
  try {
    const response = await clusterAPI.list()
    clusters.value = response.data
  } catch (error) {
    message.error('加载集群列表失败: ' + error.message)
  } finally {
    loading.value = false
  }
}

// Load config
const loadConfig = async () => {
  try {
    const response = await configAPI.get()
    config.value = response.data
  } catch (error) {
    message.error('加载配置失败: ' + error.message)
  }
}

// Load services status
const loadServicesStatus = async () => {
  loadingServices.value = true
  try {
    const response = await servicesAPI.getGlobalStatus()
    services.value = response.data
  } catch (error) {
    message.error('加载服务状态失败: ' + error.message)
  } finally {
    loadingServices.value = false
  }
}

// Get service status icon
const getServiceIcon = (status) => {
  const iconMap = {
    healthy: CheckmarkCircle,
    degraded: AlertCircle,
    offline: CloseCircle,
    unknown: HelpCircle
  }
  return iconMap[status] || HelpCircle
}

// Get service status type (for color)
const getServiceType = (status) => {
  const typeMap = {
    healthy: 'success',
    degraded: 'warning',
    offline: 'error',
    unknown: 'default'
  }
  return typeMap[status] || 'default'
}

// Get service icon color
const getServiceIconColor = (status) => {
  const colorMap = {
    healthy: '#18a058',
    degraded: '#f0a020',
    offline: '#d03050',
    unknown: '#808080'
  }
  return colorMap[status] || '#808080'
}

// Handle create cluster
const handleCreateCluster = async (formData) => {
  try {
    const response = await clusterAPI.create(formData)
    const taskId = response.data.task_id
    
    message.success('创建任务已提交')
    showCreateModal.value = false
    
    // Add task to active tasks
    activeTasks.value.push({
      task_id: taskId,
      status: 'pending',
      progress: 0,
      message: `创建集群 ${formData.name}`,
      logs: []
    })
    
    // Subscribe to task updates
    const handleTaskUpdate = (task) => {
      const index = activeTasks.value.findIndex(t => t.task_id === taskId)
      if (index !== -1) {
        activeTasks.value[index] = task
        
        // If task completed or failed, reload clusters and remove after 30 seconds
        if (task.status === 'completed' || task.status === 'failed') {
          loadClusters()
          setTimeout(() => {
            const removeIndex = activeTasks.value.findIndex(t => t.task_id === taskId)
            if (removeIndex !== -1) {
              activeTasks.value.splice(removeIndex, 1)
            }
            taskWebSocket.unsubscribe(taskId, handleTaskUpdate)
          }, 30000)  // 从5秒延长到30秒，给用户更多时间查看日志
        }
      }
    }
    
    taskWebSocket.subscribe(taskId, handleTaskUpdate)
  } catch (error) {
    message.error('创建集群失败: ' + error.message)
  }
}

// Handle start cluster
const handleStartCluster = async (name) => {
  try {
    const response = await clusterAPI.start(name)
    const taskId = response.data.task_id
    
    message.success('启动任务已提交')
    
    // Similar task tracking as create
    activeTasks.value.push({
      task_id: taskId,
      status: 'pending',
      progress: 0,
      message: `启动集群 ${name}`,
      logs: []
    })
    
    const handleTaskUpdate = (task) => {
      const index = activeTasks.value.findIndex(t => t.task_id === taskId)
      if (index !== -1) {
        activeTasks.value[index] = task
        if (task.status === 'completed' || task.status === 'failed') {
          loadClusters()
          setTimeout(() => {
            const removeIndex = activeTasks.value.findIndex(t => t.task_id === taskId)
            if (removeIndex !== -1) activeTasks.value.splice(removeIndex, 1)
            taskWebSocket.unsubscribe(taskId, handleTaskUpdate)
          }, 30000)  // 从5秒延长到30秒，给用户更多时间查看日志
        }
      }
    }
    
    taskWebSocket.subscribe(taskId, handleTaskUpdate)
  } catch (error) {
    message.error('启动集群失败: ' + error.message)
  }
}

// Handle stop cluster
const handleStopCluster = async (name) => {
  try {
    const response = await clusterAPI.stop(name)
    const taskId = response.data.task_id
    
    message.success('停止任务已提交')
    
    activeTasks.value.push({
      task_id: taskId,
      status: 'pending',
      progress: 0,
      message: `停止集群 ${name}`,
      logs: []
    })
    
    const handleTaskUpdate = (task) => {
      const index = activeTasks.value.findIndex(t => t.task_id === taskId)
      if (index !== -1) {
        activeTasks.value[index] = task
        if (task.status === 'completed' || task.status === 'failed') {
          loadClusters()
          setTimeout(() => {
            const removeIndex = activeTasks.value.findIndex(t => t.task_id === taskId)
            if (removeIndex !== -1) activeTasks.value.splice(removeIndex, 1)
            taskWebSocket.unsubscribe(taskId, handleTaskUpdate)
          }, 30000)  // 从5秒延长到30秒，给用户更多时间查看日志
        }
      }
    }
    
    taskWebSocket.subscribe(taskId, handleTaskUpdate)
  } catch (error) {
    message.error('停止集群失败: ' + error.message)
  }
}

// Handle delete cluster
const handleDeleteCluster = async (name) => {
  // Double check: prevent devops cluster deletion
  if (name === 'devops') {
    message.error('devops 集群是管理集群，不能删除')
    return
  }
  
  try {
    const response = await clusterAPI.delete(name)
    const taskId = response.data.task_id
    
    message.success('删除任务已提交')
    
    activeTasks.value.push({
      task_id: taskId,
      status: 'pending',
      progress: 0,
      message: `删除集群 ${name}`,
      logs: []
    })
    
    const handleTaskUpdate = (task) => {
      const index = activeTasks.value.findIndex(t => t.task_id === taskId)
      if (index !== -1) {
        activeTasks.value[index] = task
        if (task.status === 'completed' || task.status === 'failed') {
          loadClusters()
          setTimeout(() => {
            const removeIndex = activeTasks.value.findIndex(t => t.task_id === taskId)
            if (removeIndex !== -1) activeTasks.value.splice(removeIndex, 1)
            taskWebSocket.unsubscribe(taskId, handleTaskUpdate)
          }, 30000)  // 从5秒延长到30秒，给用户更多时间查看日志
        }
      }
    }
    
    taskWebSocket.subscribe(taskId, handleTaskUpdate)
  } catch (error) {
    message.error('删除集群失败: ' + error.message)
  }
}

// Restore running/recent tasks from backend (after page refresh)
const restoreTasks = async () => {
  try {
    // Get all recent tasks (running, completed, failed)
    const response = await taskAPI.list()
    const allTasks = response.data || []
    
    // Filter: only show running tasks + recently completed/failed tasks (within last 10 minutes)
    const now = new Date()
    const recentTasks = allTasks.filter(task => {
      if (task.status === 'running' || task.status === 'pending') {
        return true
      }
      
      // For completed/failed tasks, only show if updated within last 10 minutes
      if (task.status === 'completed' || task.status === 'failed') {
        const updatedAt = new Date(task.updated_at)
        const ageMinutes = (now - updatedAt) / 1000 / 60
        return ageMinutes < 10
      }
      
      return false
    })
    
    recentTasks.forEach(task => {
      // Add to activeTasks
      activeTasks.value.push(task)
      
      // Subscribe to WebSocket updates (only for running/pending tasks)
      if (task.status === 'running' || task.status === 'pending') {
        const handleTaskUpdate = (updatedTask) => {
          const index = activeTasks.value.findIndex(t => t.task_id === task.task_id)
          if (index !== -1) {
            activeTasks.value[index] = updatedTask
            
            // If completed/failed, reload clusters and remove after 30 seconds (给用户更多时间查看)
            if (updatedTask.status === 'completed' || updatedTask.status === 'failed') {
              loadClusters()
              setTimeout(() => {
                const removeIndex = activeTasks.value.findIndex(t => t.task_id === task.task_id)
                if (removeIndex !== -1) {
                  activeTasks.value.splice(removeIndex, 1)
                }
                taskWebSocket.unsubscribe(task.task_id, handleTaskUpdate)
              }, 30000)  // 从5秒延长到30秒
            }
          }
        }
        
        taskWebSocket.subscribe(task.task_id, handleTaskUpdate)
      }
    })
    
    if (recentTasks.length > 0) {
      const runningCount = recentTasks.filter(t => t.status === 'running' || t.status === 'pending').length
      const completedCount = recentTasks.filter(t => t.status === 'completed' || t.status === 'failed').length
      message.info(`已加载 ${runningCount} 个运行中的任务和 ${completedCount} 个最近完成的任务`)
    }
  } catch (error) {
    console.error('Failed to restore tasks:', error)
  }
}

// Lifecycle hooks
onMounted(() => {
  loadClusters()
  loadConfig()
  loadServicesStatus()
  taskWebSocket.connect()
  
  // Restore running tasks after WebSocket connects
  setTimeout(restoreTasks, 1000)
})

onUnmounted(() => {
  // Clean up WebSocket subscriptions
  activeTasks.value.forEach(task => {
    taskWebSocket.unsubscribe(task.task_id, () => {})
  })
})
</script>

