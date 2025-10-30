import { createApp } from 'vue'
import { createRouter, createWebHistory } from 'vue-router'
import naive from 'naive-ui'
import App from './App.vue'
import ClusterList from './views/ClusterList.vue'
import ClusterDetail from './views/ClusterDetail.vue'

// Create router
const router = createRouter({
  history: createWebHistory(),
  routes: [
    {
      path: '/',
      name: 'clusters',
      component: ClusterList
    },
    {
      path: '/clusters/:name',
      name: 'cluster-detail',
      component: ClusterDetail
    }
  ]
})

// Create and mount app
const app = createApp(App)
app.use(router)
app.use(naive)
app.mount('#app')

