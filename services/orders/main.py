"""orders service (app1:8001).

Calls the inventory service over HTTP to check and reserve stock. Instrumented at
runtime by `opentelemetry-instrument` (see orders.service). The only OTel code here
tags every request with a `user.action` (see UserActionMiddleware).
"""
import asyncio
import itertools
import os
import random
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, HTTPException
from opentelemetry import baggage, context, trace
from opentelemetry.processor.baggage import BaggageSpanProcessor
from pydantic import BaseModel
from starlette.routing import Match

INVENTORY_URL = os.getenv("INVENTORY_URL", "http://192.168.56.12:8002")
# Probability that GET /orders/flaky returns HTTP 500.
FLAKY_ERROR_RATE = float(os.getenv("FLAKY_ERROR_RATE", "0.3"))
USER_ACTION = "user.action"

# Copy the user.action baggage entry onto every span started in this process
# (httpx client spans, ...). The tracer provider was set up by opentelemetry-instrument.
trace.get_tracer_provider().add_span_processor(BaggageSpanProcessor(lambda key: key == USER_ACTION))

client = httpx.AsyncClient(base_url=INVENTORY_URL, timeout=5.0)


@asynccontextmanager
async def lifespan(_: FastAPI):
    yield
    await client.aclose()


app = FastAPI(title="orders", lifespan=lifespan)


def route_template(scope) -> str | None:
    """The matched route TEMPLATE (e.g. /orders/{order_id}), never the raw URL."""
    for route in app.router.routes:
        match, _ = route.matches(scope)
        if match == Match.FULL:
            return route.path
    return None


class UserActionMiddleware:
    """orders is the entry service: name the user action as "<METHOD> <route template>"
    and put it in OTel baggage, so it travels to inventory with the traceparent header.

    The server span already exists when this runs (the OTel middleware is outermost),
    so it gets the attribute directly; spans started later get it from the baggage
    via BaggageSpanProcessor, in this service and in inventory.
    """

    def __init__(self, asgi_app):
        self.app = asgi_app

    async def __call__(self, scope, receive, send):
        template = route_template(scope) if scope["type"] == "http" else None
        if template is None or template == "/health":
            await self.app(scope, receive, send)
            return
        action = f'{scope["method"]} {template}'
        trace.get_current_span().set_attribute(USER_ACTION, action)
        token = context.attach(baggage.set_baggage(USER_ACTION, action))
        try:
            await self.app(scope, receive, send)
        finally:
            context.detach(token)


app.add_middleware(UserActionMiddleware)

_ids = itertools.count(1)
ORDERS: dict[int, dict] = {}


class OrderIn(BaseModel):
    item_id: str
    qty: int = 1


async def jitter(lo_ms: int = 5, hi_ms: int = 80) -> None:
    await asyncio.sleep(random.uniform(lo_ms, hi_ms) / 1000)


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/orders")
async def list_orders(limit: int = 20):
    await jitter()
    return list(ORDERS.values())[-limit:]


@app.get("/orders/flaky")
async def flaky():
    """Fails randomly so the error-rate charts always have something to show."""
    await jitter(20, 150)
    if random.random() < FLAKY_ERROR_RATE:
        trace.get_current_span().record_exception(RuntimeError("random failure (flaky endpoint)"))
        raise HTTPException(status_code=500, detail="random failure (flaky endpoint)")
    return {"status": "lucky"}


@app.get("/orders/{order_id}")
async def get_order(order_id: int):
    await jitter()
    order = ORDERS.get(order_id)
    if order is None:
        raise HTTPException(status_code=404, detail="order not found")
    return order


@app.post("/orders", status_code=201)
async def create_order(body: OrderIn):
    await jitter(10, 60)
    try:
        stock = await client.get(f"/stock/{body.item_id}")
        if stock.status_code == 404:
            raise HTTPException(status_code=404, detail="unknown item")
        stock.raise_for_status()

        reserve = await client.post(f"/stock/{body.item_id}/reserve", params={"qty": body.qty})
        if reserve.status_code == 409:
            raise HTTPException(status_code=409, detail="insufficient stock")
        reserve.raise_for_status()
    except httpx.HTTPError as exc:
        # the httpx client span records the exception too; this puts it on the server span
        trace.get_current_span().record_exception(exc)
        raise HTTPException(status_code=502, detail=f"inventory unavailable: {exc}") from exc

    order_id = next(_ids)
    ORDERS[order_id] = {"id": order_id, "item_id": body.item_id, "qty": body.qty}
    if len(ORDERS) > 1000:
        ORDERS.pop(next(iter(ORDERS)))
    return ORDERS[order_id]
