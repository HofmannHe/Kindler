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
import { NSpace, NButton, NDataTable, NTag, NPopconfirm, useMessage } from 'naive-ui'
import { clusterAPI, configAPI, taskWebSocket } from '../api/client'
import CreateClusterModal from '../components/CreateClusterModal.vue'
import TaskProgress from '../components/TaskProgress.vue'

const router = useRouter()
const message = useMessage()

const clusters = ref([])
const config = ref(null)
const loading = ref(false)
const showCreateModal = ref(false)
const activeTasks = ref([])

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
        running: { type: 'success', text: '运行中' },
        stopped: { type: 'warning', text: '已停止' },
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
              onPositiveClick: () => handleDeleteCluster(row.name)
            },
            {
              trigger: () => h(
                NButton,
                { size: 'small', type: 'error' },
                { default: () => '删除' }
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
        
        // If task completed or failed, reload clusters and remove after 5 seconds
        if (task.status === 'completed' || task.status === 'failed') {
          loadClusters()
          setTimeout(() => {
            const removeIndex = activeTasks.value.findIndex(t => t.task_id === taskId)
            if (removeIndex !== -1) {
              activeTasks.value.splice(removeIndex, 1)
            }
            taskWebSocket.unsubscribe(taskId, handleTaskUpdate)
          }, 5000)
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
          }, 5000)
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
          }, 5000)
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
          }, 5000)
        }
      }
    }
    
    taskWebSocket.subscribe(taskId, handleTaskUpdate)
  } catch (error) {
    message.error('删除集群失败: ' + error.message)
  }
}

// Lifecycle hooks
onMounted(() => {
  loadClusters()
  loadConfig()
  taskWebSocket.connect()
})

onUnmounted(() => {
  // Clean up WebSocket subscriptions
  activeTasks.value.forEach(task => {
    taskWebSocket.unsubscribe(task.task_id, () => {})
  })
})
</script>

