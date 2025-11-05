"""Basic E2E tests for Web GUI"""
import pytest
import os
from playwright.async_api import async_playwright, Page, expect


BASE_DOMAIN = os.getenv("BASE_DOMAIN", "192.168.51.30.sslip.io")
WEBUI_URL = f"http://kindler.devops.{BASE_DOMAIN}"


@pytest.mark.asyncio
@pytest.mark.e2e
async def test_homepage_loads():
    """Test that the homepage loads successfully"""
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        page = await browser.new_page()
        
        try:
            # Navigate to homepage
            response = await page.goto(WEBUI_URL, wait_until="networkidle", timeout=30000)
            assert response.status == 200
            
            # Check for main heading
            heading = page.locator("h2").first
            await expect(heading).to_contain_text("Kindler")
            
            # Check for create cluster button
            create_button = page.locator("button:has-text('创建集群')")
            await expect(create_button).to_be_visible()
            
        finally:
            await browser.close()


@pytest.mark.asyncio
@pytest.mark.e2e
async def test_cluster_list_loads():
    """Test that cluster list table renders"""
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        page = await browser.new_page()
        
        try:
            await page.goto(WEBUI_URL, wait_until="networkidle", timeout=30000)
            
            # Wait for table to load (it might be empty)
            # The data table should be present even if empty
            table = page.locator(".n-data-table")
            await expect(table).to_be_visible(timeout=10000)
            
        finally:
            await browser.close()


@pytest.mark.asyncio
@pytest.mark.e2e
async def test_create_cluster_modal_opens():
    """Test that create cluster modal opens"""
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        page = await browser.new_page()
        
        try:
            await page.goto(WEBUI_URL, wait_until="networkidle", timeout=30000)
            
            # Click create cluster button
            create_button = page.locator("button:has-text('创建集群')")
            await create_button.click()
            
            # Wait for modal to appear
            modal = page.locator(".n-modal")
            await expect(modal).to_be_visible(timeout=5000)
            
            # Check for form fields
            name_input = page.locator("input[name='name']")
            await expect(name_input).to_be_visible()
            
            provider_select = page.locator("select[name='provider']")
            await expect(provider_select).to_be_visible()
            
            # Close modal
            cancel_button = page.locator("button:has-text('取消')")
            await cancel_button.click()
            
        finally:
            await browser.close()


@pytest.mark.asyncio
@pytest.mark.e2e
@pytest.mark.skipif(
    not os.getenv("E2E_FULL_TEST"),
    reason="Full E2E test requires running environment, set E2E_FULL_TEST=1"
)
async def test_create_cluster_workflow():
    """
    Test complete cluster creation workflow
    
    WARNING: This test actually creates a cluster!
    Only run this in a test environment.
    Set E2E_FULL_TEST=1 to enable.
    """
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=False, slow_mo=500)
        page = await browser.new_page()
        
        cluster_name = "e2e-test-cluster"
        
        try:
            # Navigate to homepage
            await page.goto(WEBUI_URL, wait_until="networkidle", timeout=30000)
            
            # Open create modal
            await page.click("button:has-text('创建集群')")
            
            # Wait for modal
            await page.wait_for_selector(".n-modal", state="visible")
            
            # Fill form
            await page.fill("input[name='name']", cluster_name)
            # Provider should default to k3d
            
            # Submit form
            await page.click("button:has-text('创建'):not(:has-text('取消'))")
            
            # Modal should close
            await page.wait_for_selector(".n-modal", state="hidden", timeout=5000)
            
            # Should show task progress
            task_card = page.locator(".n-card:has-text('创建集群')")
            await expect(task_card).to_be_visible(timeout=5000)
            
            # Wait for task to complete (this can take 2-3 minutes)
            success_tag = page.locator(".n-tag:has-text('已完成')")
            await expect(success_tag).to_be_visible(timeout=300000)  # 5 minutes max
            
            # Cluster should appear in list
            cluster_link = page.locator(f"a:has-text('{cluster_name}')")
            await expect(cluster_link).to_be_visible()
            
            # Clean up - delete the cluster
            await page.goto(WEBUI_URL)
            
            # Find delete button for this cluster
            row = page.locator(f"tr:has-text('{cluster_name}')")
            delete_button = row.locator("button:has-text('删除')")
            await delete_button.click()
            
            # Confirm deletion
            confirm_button = page.locator("button:has-text('确定')")
            await confirm_button.click()
            
            # Wait for deletion task
            delete_task = page.locator(".n-card:has-text('删除集群')")
            await expect(delete_task).to_be_visible(timeout=5000)
            
            # Wait for completion
            await expect(delete_task.locator(".n-tag:has-text('已完成')")).to_be_visible(timeout=180000)
            
        finally:
            await browser.close()


@pytest.mark.asyncio
@pytest.mark.e2e
async def test_api_health_via_proxy():
    """Test that API health endpoint is accessible via frontend proxy"""
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        context = await browser.new_context()
        page = await context.new_page()
        
        try:
            # Make API request through frontend
            response = await page.request.get(f"{WEBUI_URL}/api/health")
            assert response.status == 200
            
            data = await response.json()
            assert data["status"] == "healthy"
            
        finally:
            await browser.close()

