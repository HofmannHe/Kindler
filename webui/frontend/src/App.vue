<template>
  <n-config-provider :theme="darkTheme">
    <n-layout style="height: 100vh;">
      <n-layout-header bordered style="height: 64px; padding: 0 24px; display: flex; align-items: center;">
        <h2 style="margin: 0; cursor: pointer;" @click="$router.push('/')">
          Kindler - Kubernetes 集群管理
        </h2>
      </n-layout-header>
      
      <n-layout-content style="padding: 24px;">
        <router-view />
      </n-layout-content>
    </n-layout>
  </n-config-provider>
</template>

<script setup>
import { NConfigProvider, NLayout, NLayoutHeader, NLayoutContent, darkTheme } from 'naive-ui'
</script>

<style>
* {
  margin: 0;
  padding: 0;
  box-sizing: border-box;
}

body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
}

#app {
  height: 100vh;
}
</style>

