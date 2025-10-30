import axios from 'axios'

// Create axios instance
const apiClient = axios.create({
  baseURL: '/api',
  timeout: 300000, // 5 minutes for long-running operations
  headers: {
    'Content-Type': 'application/json'
  }
})

// Cluster API
export const clusterAPI = {
  // List all clusters
  list() {
    return apiClient.get('/clusters')
  },
  
  // Get cluster by name
  get(name) {
    return apiClient.get(`/clusters/${name}`)
  },
  
  // Create cluster
  create(clusterData) {
    return apiClient.post('/clusters', clusterData)
  },
  
  // Delete cluster
  delete(name) {
    return apiClient.delete(`/clusters/${name}`)
  },
  
  // Get cluster status
  status(name) {
    return apiClient.get(`/clusters/${name}/status`)
  },
  
  // Start cluster
  start(name) {
    return apiClient.post(`/clusters/${name}/start`)
  },
  
  // Stop cluster
  stop(name) {
    return apiClient.post(`/clusters/${name}/stop`)
  }
}

// Task API
export const taskAPI = {
  // Get task status
  get(taskId) {
    return apiClient.get(`/tasks/${taskId}`)
  }
}

// Config API
export const configAPI = {
  get() {
    return apiClient.get('/config')
  }
}

// WebSocket for real-time updates
export class TaskWebSocket {
  constructor() {
    this.ws = null
    this.listeners = new Map()
    this.reconnectTimer = null
  }
  
  connect() {
    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
    const wsUrl = `${protocol}//${window.location.host}/ws/tasks`
    
    this.ws = new WebSocket(wsUrl)
    
    this.ws.onopen = () => {
      console.log('WebSocket connected')
      // Send ping every 30 seconds to keep connection alive
      this.pingInterval = setInterval(() => {
        if (this.ws && this.ws.readyState === WebSocket.OPEN) {
          this.ws.send(JSON.stringify({ type: 'ping' }))
        }
      }, 30000)
    }
    
    this.ws.onmessage = (event) => {
      try {
        const data = JSON.parse(event.data)
        
        if (data.type === 'task_update' && data.task) {
          const taskId = data.task.task_id
          const callbacks = this.listeners.get(taskId)
          if (callbacks) {
            callbacks.forEach(callback => callback(data.task))
          }
        }
      } catch (error) {
        console.error('WebSocket message error:', error)
      }
    }
    
    this.ws.onerror = (error) => {
      console.error('WebSocket error:', error)
    }
    
    this.ws.onclose = () => {
      console.log('WebSocket closed')
      if (this.pingInterval) {
        clearInterval(this.pingInterval)
      }
      // Attempt to reconnect after 5 seconds
      this.reconnectTimer = setTimeout(() => this.connect(), 5000)
    }
  }
  
  subscribe(taskId, callback) {
    if (!this.listeners.has(taskId)) {
      this.listeners.set(taskId, [])
    }
    this.listeners.get(taskId).push(callback)
    
    // Send subscription message
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify({
        type: 'subscribe',
        task_id: taskId
      }))
    }
  }
  
  unsubscribe(taskId, callback) {
    const callbacks = this.listeners.get(taskId)
    if (callbacks) {
      const index = callbacks.indexOf(callback)
      if (index > -1) {
        callbacks.splice(index, 1)
      }
      
      if (callbacks.length === 0) {
        this.listeners.delete(taskId)
        
        // Send unsubscription message
        if (this.ws && this.ws.readyState === WebSocket.OPEN) {
          this.ws.send(JSON.stringify({
            type: 'unsubscribe',
            task_id: taskId
          }))
        }
      }
    }
  }
  
  disconnect() {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer)
    }
    if (this.pingInterval) {
      clearInterval(this.pingInterval)
    }
    if (this.ws) {
      this.ws.close()
      this.ws = null
    }
  }
}

// Global WebSocket instance
export const taskWebSocket = new TaskWebSocket()

