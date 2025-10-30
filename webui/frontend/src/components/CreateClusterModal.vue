<template>
  <n-modal v-model:show="showModal" preset="card" title="创建集群" style="width: 600px;">
    <n-form ref="formRef" :model="formData" :rules="rules" label-placement="left" label-width="120">
      <n-form-item label="集群名称" path="name">
        <n-input v-model:value="formData.name" placeholder="例如: dev, uat, prod" />
      </n-form-item>
      
      <n-form-item label="Provider" path="provider">
        <n-select v-model:value="formData.provider" :options="providerOptions" />
      </n-form-item>
      
      <n-form-item label="Node Port" path="node_port">
        <n-input-number v-model:value="formData.node_port" :min="1024" :max="65535" style="width: 100%;" />
      </n-form-item>
      
      <n-form-item label="Port Forward Port" path="pf_port">
        <n-input-number v-model:value="formData.pf_port" :min="1024" :max="65535" style="width: 100%;" />
      </n-form-item>
      
      <n-form-item label="HTTP Port" path="http_port">
        <n-input-number v-model:value="formData.http_port" :min="1024" :max="65535" style="width: 100%;" />
      </n-form-item>
      
      <n-form-item label="HTTPS Port" path="https_port">
        <n-input-number v-model:value="formData.https_port" :min="1024" :max="65535" style="width: 100%;" />
      </n-form-item>
      
      <n-form-item label="集群子网" path="cluster_subnet">
        <n-input 
          v-model:value="formData.cluster_subnet" 
          placeholder="例如: 10.101.0.0/16 (可选，仅 k3d)"
        />
      </n-form-item>
      
      <n-form-item label="注册选项">
        <n-space vertical>
          <n-checkbox v-model:checked="formData.register_portainer">注册到 Portainer</n-checkbox>
          <n-checkbox v-model:checked="formData.haproxy_route">添加 HAProxy 路由</n-checkbox>
          <n-checkbox v-model:checked="formData.register_argocd">注册到 ArgoCD</n-checkbox>
        </n-space>
      </n-form-item>
    </n-form>
    
    <template #footer>
      <n-space justify="end">
        <n-button @click="handleCancel">取消</n-button>
        <n-button type="primary" @click="handleSubmit" :loading="loading">创建</n-button>
      </n-space>
    </template>
  </n-modal>
</template>

<script setup>
import { ref, computed, watch } from 'vue'
import { NModal, NForm, NFormItem, NInput, NInputNumber, NSelect, NCheckbox, NButton, NSpace } from 'naive-ui'

const props = defineProps({
  show: Boolean,
  config: Object
})

const emit = defineEmits(['update:show', 'submit'])

const showModal = computed({
  get: () => props.show,
  set: (val) => emit('update:show', val)
})

const formRef = ref(null)
const loading = ref(false)

const providerOptions = [
  { label: 'k3d', value: 'k3d' },
  { label: 'kind', value: 'kind' }
]

const formData = ref({
  name: '',
  provider: 'k3d',
  node_port: 30080,
  pf_port: 19001,
  http_port: 18090,
  https_port: 18443,
  cluster_subnet: '',
  register_portainer: true,
  haproxy_route: true,
  register_argocd: true
})

// Auto-fill ports based on config
watch(() => props.config, (newConfig) => {
  if (newConfig) {
    formData.value.node_port = newConfig.default_node_port || 30080
    // Use mid-range values for default ports
    formData.value.pf_port = newConfig.default_pf_port_range?.[0] || 19001
    formData.value.http_port = newConfig.default_http_port_range?.[0] || 18090
    formData.value.https_port = newConfig.default_https_port_range?.[0] || 18443
  }
}, { immediate: true })

const rules = {
  name: [
    { required: true, message: '请输入集群名称', trigger: 'blur' },
    { 
      pattern: /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/,
      message: '集群名称只能包含小写字母、数字和连字符',
      trigger: 'blur'
    }
  ],
  provider: [
    { required: true, message: '请选择 Provider', trigger: 'change' }
  ],
  node_port: [
    { type: 'number', required: true, message: '请输入 Node Port', trigger: 'blur' }
  ],
  pf_port: [
    { type: 'number', required: true, message: '请输入 Port Forward Port', trigger: 'blur' }
  ],
  http_port: [
    { type: 'number', required: true, message: '请输入 HTTP Port', trigger: 'blur' }
  ],
  https_port: [
    { type: 'number', required: true, message: '请输入 HTTPS Port', trigger: 'blur' }
  ]
}

const handleCancel = () => {
  showModal.value = false
}

const handleSubmit = async () => {
  try {
    await formRef.value?.validate()
    loading.value = true
    
    // Emit submit event with form data
    emit('submit', { ...formData.value })
    
    // Reset form
    formData.value = {
      name: '',
      provider: 'k3d',
      node_port: 30080,
      pf_port: 19001,
      http_port: 18090,
      https_port: 18443,
      cluster_subnet: '',
      register_portainer: true,
      haproxy_route: true,
      register_argocd: true
    }
  } catch (error) {
    console.error('Validation error:', error)
  } finally {
    loading.value = false
  }
}
</script>

