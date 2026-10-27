"""inventory service (app2:8002).

Keeps stock levels in redis. Has a small chaos API (/admin/chaos) to inject extra
latency and errors at runtime. Instrumented by `opentelemetry-instrument`.
"""
import asyncio
import os
import random
from contextlib import asynccontextmanager

import redis.asyncio as redis
from fastapi import FastAPI, HTTPException
from opentelemetry import trace
from opentelemetry.processor.baggage import BaggageSpanProcessor
from pydantic import BaseModel

REDIS_URL = os.getenv("REDIS_URL", "redis://127.0.0.1:6379/0")

# orders sends a `user.action` baggage entry; copy it onto every span here, including
# the server span and the redis client spans. (Direct calls to inventory have no action.)
trace.get_tracer_provider().add_span_processor(BaggageSpanProcessor(lambda key: key == "user.action"))
ITEMS = [f"item-{i}" for i in range(1, 11)]
RESTOCK_TO = 500

r = redis.from_url(REDIS_URL, decode_responses=True)


@asynccontextmanager
async def lifespan(_: FastAPI):
    for item in ITEMS:
        await r.setnx(f"stock:{item}", RESTOCK_TO)
    yield
    await r.aclose()


app = FastAPI(title="inventory", lifespan=lifespan)


class Chaos(BaseModel):
    latency_ms: int = int(os.getenv("CHAOS_LATENCY_MS", "0"))
    error_rate: float = float(os.getenv("CHAOS_ERROR_RATE", "0.02"))


chaos = Chaos()


async def simulate(lo_ms: int = 10, hi_ms: int = 120) -> None:
    """Random base latency + injected latency; fails with probability error_rate."""
    await asyncio.sleep((random.uniform(lo_ms, hi_ms) + chaos.latency_ms) / 1000)
    if random.random() < chaos.error_rate:
        # HTTPException becomes a normal 500 response, so record the reason on the span
        # explicitly: it shows up as an exception event (with message) in the trace.
        trace.get_current_span().record_exception(
            RuntimeError(f"injected failure (chaos error_rate={chaos.error_rate})"))
        raise HTTPException(status_code=500, detail="injected failure")


@app.get("/health")
async def health():
    await r.ping()
    return {"status": "ok"}


@app.get("/stock")
async def all_stock():
    await simulate()
    values = await r.mget([f"stock:{i}" for i in ITEMS])
    return {item: int(v or 0) for item, v in zip(ITEMS, values)}


@app.get("/stock/{item_id}")
async def get_stock(item_id: str):
    await simulate()
    value = await r.get(f"stock:{item_id}")
    if value is None:
        raise HTTPException(status_code=404, detail="unknown item")
    return {"item_id": item_id, "qty": int(value)}


@app.post("/stock/{item_id}/reserve")
async def reserve(item_id: str, qty: int = 1):
    await simulate(5, 60)
    key = f"stock:{item_id}"
    if not await r.exists(key):
        raise HTTPException(status_code=404, detail="unknown item")
    left = await r.decrby(key, qty)
    if left < 0:
        await r.incrby(key, qty)
        raise HTTPException(status_code=409, detail="insufficient stock")
    if left < 20:
        # keep the demo running forever
        await r.set(key, RESTOCK_TO)
    return {"item_id": item_id, "qty": left}


@app.post("/stock/{item_id}/restock")
async def restock(item_id: str, qty: int = RESTOCK_TO):
    await simulate(5, 30)
    await r.set(f"stock:{item_id}", qty)
    return {"item_id": item_id, "qty": qty}


@app.get("/admin/chaos")
async def get_chaos():
    return chaos


@app.post("/admin/chaos")
async def set_chaos(body: Chaos):
    """Example: {"latency_ms": 500, "error_rate": 0.2}. Reset with {"latency_ms": 0, "error_rate": 0.02}."""
    chaos.latency_ms = max(0, body.latency_ms)
    chaos.error_rate = min(1.0, max(0.0, body.error_rate))
    return chaos
