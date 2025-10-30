<template>
  <n-card :title="task.message" size="small" style="margin-bottom: 16px;">
    <template #header-extra>
      <n-tag :type="statusType">{{ statusText }}</n-tag>
    </template>
    
    <n-space vertical>
      <n-progress
        type="line"
        :percentage="task.progress"
        :status="progressStatus"
        :show-indicator="true"
      />
      
      <div v-if="task.error" style="color: red;">
        <strong>错误:</strong> {{ task.error }}
      </div>
      
      <n-collapse v-if="task.logs && task.logs.length > 0">
        <n-collapse-item title="查看日志" name="logs">
          <n-scrollbar style="max-height: 300px;">
            <n-code :code="logsText" language="bash" />
          </n-scrollbar>
        </n-collapse-item>
      </n-collapse>
    </n-space>
  </n-card>
</template>

<script setup>
import { computed } from 'vue'
import { NCard, NTag, NSpace, NProgress, NCollapse, NCollapseItem, NScrollbar, NCode } from 'naive-ui'

const props = defineProps({
  task: {
    type: Object,
    required: true
  }
})

const statusType = computed(() => {
  switch (props.task.status) {
    case 'completed':
      return 'success'
    case 'failed':
      return 'error'
    case 'running':
      return 'info'
    default:
      return 'default'
  }
})

const statusText = computed(() => {
  const statusMap = {
    pending: '等待中',
    running: '运行中',
    completed: '已完成',
    failed: '失败'
  }
  return statusMap[props.task.status] || props.task.status
})

const progressStatus = computed(() => {
  if (props.task.status === 'failed') return 'error'
  if (props.task.status === 'completed') return 'success'
  return 'default'
})

const logsText = computed(() => {
  return props.task.logs.join('\n')
})
</script>

