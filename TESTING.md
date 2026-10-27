# Load and failure testing

All commands are run from **Windows PowerShell** in the project folder. They use
`vagrant ssh` or call the VMs directly over the host-only network, so nothing extra is
installed on Windows.

Open Grafana → **Service Monitoring** (http://192.168.56.10:3000, admin/admin), set the
time range to **Last 15 minutes** and auto-refresh to **10s** while testing.

> If PowerShell refuses to run the scripts ("running scripts is disabled"), allow them for
> the current window only: `Set-ExecutionPolicy -Scope Process Bypass`.

| # | Test | Command | What should change in Grafana |
|---|------|---------|-------------------------------|
| 1 | Baseline load | `.\scripts\load-test.ps1 -Users 20 -Duration 5m` | **Total requests/sec** rises to roughly 20–40 req/s. Per-service **Requests/sec by route** shows the weighted routes (`/orders` highest). **Latency p50/p95**: orders ≈ 50–150 ms (it waits on inventory), inventory ≈ 60–120 ms. **Error rate %** stays at a few percent from `/orders/flaky` and the default 2% inventory errors. Service **CPU %**, **Memory**, **Threads** go up for orders, inventory, nginx and redis. |
| 2 | Heavier load | `.\scripts\load-test.ps1 -Users 80 -SpawnRate 10 -Duration 5m` | Requests/sec climbs and then levels off. p95 latency rises once the single-core app VMs saturate. **Host CPU %** for app1/app2 approaches 100%. |
| 3 | CPU stress on a VM | `.\scripts\stress-cpu.ps1 -Vm app2 -Seconds 120` (run during a load test) | **Host CPU %** for app2 jumps to ~100% (Hosts row; also *Node Exporter Full*). inventory **Latency p95** rises because it competes for the single CPU. Per-service **CPU %** for inventory may *drop* (it gets less CPU time). stress-ng itself is not a monitored service, so it does not get a service row. |
| 4 | Stop a service | `.\scripts\service-control.ps1 -Service inventory -Action stop` | **Services up** drops by 1 (e.g. 4 → 3). inventory **Service running**: both the process line and the systemd line drop to 0. orders **Error rate %** jumps (POST /orders now returns 502) and the Locust summary shows failures. inventory **Requests/sec** stops. |
| 5 | Start it again | `.\scripts\service-control.ps1 -Service inventory -Action start` | Everything from test 4 recovers within ~15–30 s. **Memory resident** for inventory starts from a lower value (fresh process). |
| 6 | Stop the front door | `.\scripts\service-control.ps1 -Service nginx -Action stop` | nginx **Service running** goes to 0, **Services up** drops, and orders **Requests/sec** falls to almost 0 because Locust goes through nginx. inventory still gets its direct traffic. Start again with `-Action start`. |
| 7 | Stop redis | `.\scripts\service-control.ps1 -Service redis -Action stop` | redis **Service running** goes to 0. inventory **Error rate %** is ~100% (it can't reach redis), and orders errors follow. Start again with `-Action start`. |
| 8 | Inject latency | `.\scripts\inject-latency.ps1 -Ms 500` | inventory **Latency p50/p95** rises by ~500 ms. orders latency rises by ~1 s, because each POST /orders makes two inventory calls. **Total requests/sec** drops, since Locust users wait longer. |
| 9 | Inject errors | `.\scripts\inject-latency.ps1 -Ms 0 -ErrorRate 0.3` | inventory **Error rate %** ≈ 30%. orders error rate rises (POST /orders → 502). The top **Error rate %** stat turns orange/red. |
| 10 | Reset chaos | `.\scripts\inject-latency.ps1 -Reset` (or `-Show` to inspect) | Latency and errors return to baseline. Restarting inventory.service also resets it. |
| 11 | Filters | In the dashboard, set **Service** = `orders` only, then **Host** = `app2` | Only the orders row remains. With Host = app2 the Service list narrows to services on app2 (inventory, redis), and the Hosts row shows app2 only. Changing the time picker (e.g. *Last 6 hours*) re-scales every chart. |

## Phase 2: trace tests

Keep traffic flowing while you test: run `.\scripts\load-test.ps1 -Users 10 -Duration 10m`
in a second PowerShell window. Each test shows where to look in Grafana, plus a
`find-trace.ps1` command that prints the newest matching trace as a span tree (red = ERROR,
yellow = exception message). A trace becomes searchable a few seconds after it finishes, so
wait ~30–45 s after each change.

| # | Test | Commands | What you should see |
|---|------|----------|---------------------|
| T1 | Slow span from injected latency | `.\scripts\inject-latency.ps1 -Ms 500` → wait 45 s → `.\scripts\find-trace.ps1 '{ resource.service.name = "inventory" && kind = server && duration > 500ms } && { resource.service.name = "orders" }' -Minutes 5` → `.\scripts\inject-latency.ps1 -Reset` | A `POST /orders` trace of ~1.2 s. Both inventory server spans (`GET /stock/{item_id}`, `POST /stock/{item_id}/reserve`) take ~530 ms, while their redis children (`GET`, `EXISTS`, `DECRBY`) take ~2 ms. So the delay is in inventory's own code, not in redis or the network. **Grafana:** *Traces* → "Slow traces (> 300 ms)" fills up, and "p95 latency per span_name" jumps for the inventory spans. *Service Monitoring* → inventory latency p95 ≈ 600 ms; click an exemplar diamond to open such a trace. |
| T2 | Error span with exception message | `.\scripts\inject-latency.ps1 -Ms 0 -ErrorRate 0.5` → wait 45 s → `.\scripts\find-trace.ps1 '{ resource.service.name = "inventory" && status = error } && { resource.service.name = "orders" }' -Minutes 2` → `.\scripts\inject-latency.ps1 -Reset` | inventory `POST /stock/{item_id}/reserve` is red, `http=500`, with `exception: RuntimeError: injected failure (chaos error_rate=0.5)`. Its parent, the orders `POST` client span, is red with http 500. The orders root `POST /orders` is red with `http=502` and `httpx.HTTPStatusError: Server error '500 Internal Server Error' ...`. **Grafana:** *Traces* → "Error traces" and "Error rate % per service" rise for both services. In Explore, open a trace → the inventory span → *Events* → `exception`. |
| T3 | Stopped inventory, failing call in orders | `.\scripts\service-control.ps1 -Service inventory -Action stop` → wait 40 s → `.\scripts\find-trace.ps1 '{ resource.service.name = "orders" && name = "POST /orders" && status = error }' -Minutes 1` → `.\scripts\service-control.ps1 -Service inventory -Action start` | The trace has **only orders spans**: `POST /orders` (`http=502`, ERROR) → client span `GET` (ERROR) with `exception: httpx.ConnectError: All connection attempts failed`. No inventory span exists because nothing answered. **Grafana:** *Traces* → service graph edge orders → inventory turns red ("Failed calls between services"); *Actions* (`POST /orders`) → inventory disappears from the calls panels while it is down. |
| T4 | Service graph orders → inventory → redis | Just traffic | *Traces* → **Service graph** shows `user → orders → inventory → redis` (plus `user → inventory` from the direct Locust calls). Check from PowerShell: `.\scripts\verify-traces.ps1` lists the edges `orders -> inventory` and `inventory -> redis`. Explore → Tempo → *Service Graph* shows the same. |
| T5 | Per-action stats | Just traffic (the locustfile calls all routes) | *Actions* → the **Action** dropdown lists `GET /orders`, `GET /orders/{order_id}`, `GET /orders/flaky` and `POST /orders` automatically. With `POST /orders`, the **Service** dropdown and "Calls per service" show **orders and inventory**; with a `GET` action only orders. The traces table (`{ span.user.action = "$action" }`) lists example traces in which every span, including the redis spans in inventory, carries `user.action`. |
| T6 | A new action appears automatically | Call a route that hasn't been used yet, e.g. `Invoke-RestMethod http://192.168.56.11/orders/999 -SkipHttpErrorCheck` (PowerShell 7) or open http://192.168.56.11/orders/999 in a browser | After ~1 min, `GET /orders/{order_id}` is in the dropdown (if it wasn't already). Nothing was configured; the label comes from the trace. |

## Verifying everything automatically

```powershell
.\scripts\load-test.ps1 -Users 20 -Duration 2m
.\scripts\verify.ps1
.\scripts\verify-traces.ps1
```

`verify.ps1` checks that all Prometheus targets are UP (including Tempo) and that
`service_name` exists on process, systemd and OTel metrics. It also checks that Grafana serves
the dashboards and that the Prometheus and Tempo datasources are healthy. Finally it runs
**every panel query of Service Monitoring, Traces and Actions** through Grafana's
`/api/ds/query` (Prometheus and TraceQL panels alike). Repeated service-row panels are checked
once per service, and the Actions dashboard is checked for `-Action "POST /orders"`. The HTTP
panels of nginx and redis are reported as "no data expected", because those two are
monitored only at the process and systemd level, not via OpenTelemetry.

`verify-traces.ps1` checks Tempo `/ready` (from inside the monitor VM), prints one
connected trace with spans from orders, inventory and redis, checks the service-graph and
span-metrics series in Prometheus, and counts exemplars from both sources.

## Running things by hand inside the VMs

```powershell
vagrant ssh app2 -c "sudo stress-ng --cpu 1 --timeout 60s"
vagrant ssh app2 -c "curl -s localhost:8002/admin/chaos"
vagrant ssh app1 -c "curl -s localhost/orders"
vagrant ssh monitor -c "cd /opt/monitoring && docker compose ps"
```
