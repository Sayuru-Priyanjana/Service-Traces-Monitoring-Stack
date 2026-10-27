"""Weighted traffic for the monitoring lab.

Host (-H) should be the nginx front door on app1: http://192.168.56.11
Inventory is also hit directly so its own request charts have plenty of data.
Run via scripts/load-test.ps1 (Locust in Docker on the monitor VM).
"""
import random

from locust import HttpUser, between, task

INVENTORY = "http://192.168.56.12:8002"
ITEMS = [f"item-{i}" for i in range(1, 11)]


class ShopUser(HttpUser):
    wait_time = between(0.2, 1.0)

    @task(5)
    def list_orders(self):
        self.client.get("/orders", name="GET /orders")

    @task(3)
    def create_order(self):
        with self.client.post(
            "/orders",
            json={"item_id": random.choice(ITEMS), "qty": random.randint(1, 3)},
            name="POST /orders",
            catch_response=True,
        ) as resp:
            # 409 (out of stock) is a valid business answer, not a load-test failure
            if resp.status_code in (201, 409):
                resp.success()

    @task(2)
    def get_order(self):
        with self.client.get(
            f"/orders/{random.randint(1, 200)}", name="GET /orders/{id}", catch_response=True
        ) as resp:
            if resp.status_code in (200, 404):
                resp.success()

    @task(1)
    def flaky(self):
        self.client.get("/orders/flaky", name="GET /orders/flaky")

    @task(1)
    def unknown_item(self):
        with self.client.post(
            "/orders", json={"item_id": "does-not-exist"}, name="POST /orders (unknown)", catch_response=True
        ) as resp:
            if resp.status_code == 404:
                resp.success()

    @task(3)
    def inventory_stock(self):
        self.client.get(f"{INVENTORY}/stock/{random.choice(ITEMS)}", name="inventory GET /stock/{id}")

    @task(1)
    def inventory_all(self):
        self.client.get(f"{INVENTORY}/stock", name="inventory GET /stock")
