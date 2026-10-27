"""Generates the provisioned Grafana dashboards in monitoring/grafana/dashboards/.

    python scripts/generate-dashboards.py

Edit the panels here rather than the JSON files, then re-run and `vagrant provision monitor`.
(Node Exporter Full is the unmodified grafana.com dashboard 1860 and is not generated.)
"""
import json
import pathlib

OUT = pathlib.Path(__file__).resolve().parent.parent / "monitoring" / "grafana" / "dashboards"

PROM = {"type": "prometheus", "uid": "prometheus"}
TEMPO = {"type": "tempo", "uid": "tempo"}
RATE = "$__rate_interval"

# OTel HTTP server metric as emitted by opentelemetry-instrumentation-fastapi 0.66b1
# (old HTTP semantic conventions). See README "How the filters work".
DUR = "http_server_duration_milliseconds"
STATUS = "http_status_code"
ROUTE = "http_target"


class Dash:
    """Collects panels with unique ids and a running y position."""

    def __init__(self):
        self.panels = []
        self.y = 0
        self._id = 0

    def nid(self):
        self._id += 1
        return self._id

    def row(self, title, repeat=None):
        r = {"id": self.nid(), "type": "row", "title": title, "collapsed": False, "panels": [],
             "gridPos": {"x": 0, "y": self.y, "w": 24, "h": 1}}
        if repeat:
            r["repeat"] = repeat
        self.panels.append(r)
        self.y += 1

    def add(self, *panels):
        """Adds panels laid out left-to-right on the current line, then moves down."""
        h = 0
        for p in panels:
            p["id"] = self.nid()
            p["gridPos"]["y"] = self.y
            h = max(h, p["gridPos"]["h"])
            self.panels.append(p)
        self.y += h


def prom_target(expr, legend="", ref="A", exemplar=False):
    t = {"datasource": PROM, "expr": expr, "legendFormat": legend, "refId": ref, "range": True, "instant": False}
    if exemplar:
        t["exemplar"] = True
    return t


def ts(title, targets, x, w, h, unit="short", desc="", no_value=None, min0=True, extra=None, exemplar=False):
    p = {
        "type": "timeseries", "title": title, "description": desc, "datasource": PROM,
        "gridPos": {"x": x, "y": 0, "w": w, "h": h},
        "targets": [prom_target(e, l, chr(65 + i), exemplar) for i, (e, l) in enumerate(targets)],
        "fieldConfig": {
            "defaults": {
                "unit": unit,
                "custom": {"drawStyle": "line", "lineWidth": 2, "fillOpacity": 10, "showPoints": "never",
                           "spanNulls": False},
                **({"min": 0} if min0 else {}),
                **({"noValue": no_value} if no_value else {}),
            },
            "overrides": [],
        },
        "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
                    "tooltip": {"mode": "multi", "sort": "desc"}},
    }
    if extra:
        p["fieldConfig"]["defaults"].update(extra)
    return p


def stat(title, targets, x, w, h, unit="short", desc="", thresholds=None, decimals=None):
    return {
        "type": "stat", "title": title, "description": desc, "datasource": PROM,
        "gridPos": {"x": x, "y": 0, "w": w, "h": h},
        "targets": [prom_target(e, l, chr(65 + i)) for i, (e, l) in enumerate(targets)],
        "fieldConfig": {"defaults": {
            "unit": unit, **({"decimals": decimals} if decimals is not None else {}),
            "color": {"mode": "thresholds"},
            "thresholds": {"mode": "absolute", "steps": thresholds or [{"color": "green", "value": None}]},
        }, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                    "colorMode": "value", "graphMode": "area", "justifyMode": "auto", "textMode": "auto",
                    "orientation": "auto"},
    }


def traceql_table(title, query, x, w, h, desc="", limit=20):
    return {
        "type": "table", "title": title, "description": desc, "datasource": TEMPO,
        "gridPos": {"x": x, "y": 0, "w": w, "h": h},
        "targets": [{"datasource": TEMPO, "refId": "A", "queryType": "traceql", "query": query,
                     "limit": limit, "tableType": "traces"}],
        "fieldConfig": {"defaults": {}, "overrides": []},
        "options": {"showHeader": True, "cellHeight": "sm"},
    }


def query_var(name, label, query, multi=True):
    return {
        "name": name, "label": label, "type": "query", "datasource": PROM,
        "query": {"query": query, "refId": name}, "definition": query,
        "multi": multi, "includeAll": multi,
        "current": {"selected": True, "text": ["All"], "value": ["$__all"]} if multi else {},
        "refresh": 2, "sort": 1,
    }


def link(title, uid, slug, icon="dashboard"):
    # keepTime + includeVars carry the time range and $service over to the other dashboard
    return {"title": title, "type": "link", "url": f"/d/{uid}/{slug}", "icon": icon,
            "keepTime": True, "includeVars": True, "targetBlank": False}


def dashboard(uid, title, tags, variables, panels, links, refresh="30s"):
    return {
        "uid": uid, "title": title, "tags": tags, "timezone": "browser", "editable": True,
        "graphTooltip": 1, "schemaVersion": 41, "version": 1, "refresh": refresh,
        "time": {"from": "now-1h", "to": "now"},
        "timepicker": {"refresh_intervals": ["10s", "30s", "1m", "5m", "15m", "30m", "1h"]},
        "templating": {"list": variables},
        "annotations": {"list": [{
            "builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"}, "enable": True, "hide": True,
            "iconColor": "rgba(0, 211, 255, 1)", "name": "Annotations & Alerts", "type": "dashboard",
        }]},
        "links": links,
        "panels": panels,
    }


RED_GREEN = [{"color": "green", "value": None}, {"color": "orange", "value": 1}, {"color": "red", "value": 5}]
LINK_SERVICES = link("Service Monitoring", "service-monitoring", "service-monitoring")
LINK_TRACES = link("Traces", "traces", "traces", icon="bolt")
LINK_NODE = {"title": "Node Exporter Full", "type": "link", "url": "/d/rYdddlPWk/node-exporter-full",
             "icon": "dashboard"}


# --------------------------------------------------------------------------------------
# Service Monitoring (phase 1) - process / systemd / OTel HTTP metrics per service_name
# --------------------------------------------------------------------------------------
def service_monitoring():
    d = Dash()
    sel = 'service_name=~"$service", instance=~"$host"'
    http_total = f'sum(rate({DUR}_count{{{sel}}}[{RATE}]))'
    http_5xx = f'sum(rate({DUR}_count{{{sel}, {STATUS}=~"5.."}}[{RATE}]))'
    no_http = "no HTTP metrics (not OTel-instrumented, or no traffic)"

    d.row("Overview (selected services and hosts)")
    d.add(
        stat("Services up", [
            (f'sum(node_systemd_unit_state{{{sel}, state="active"}})', "up"),
            (f'count(node_systemd_unit_state{{{sel}, state="active"}})', "total"),
        ], 0, 6, 5, desc="systemd units in state active / total monitored units for the selected services."),
        stat("Total requests/sec", [(http_total, "req/s")], 6, 6, 5, unit="reqps", decimals=1,
             desc=f"Sum of HTTP server request rate from OpenTelemetry ({DUR}_count)."),
        stat("Error rate %", [(f'100 * ({http_5xx} or vector(0)) / {http_total}', "5xx %")], 12, 6, 5,
             unit="percent", decimals=2, thresholds=RED_GREEN,
             desc="5xx responses / all responses (OTel HTTP server metric)."),
        stat("Memory (resident)", [(f'sum(namedprocess_namegroup_memory_bytes{{{sel}, memtype="resident"}})', "RSS")],
             18, 6, 5, unit="bytes", desc="Resident memory of all selected service processes (process-exporter)."),
    )

    d.row("Service: $service", repeat="service")
    d.add(
        ts("Service running", [
            (f'sum by (instance) (namedprocess_namegroup_num_procs{{{sel}}})', "{{instance}} processes"),
            (f'sum by (instance) (node_systemd_unit_state{{{sel}, state="active"}})', "{{instance}} systemd active (1=yes)"),
        ], 0, 6, 7, desc="Process count (process-exporter) and systemd active state (node_exporter). "
                          "Drops to 0 when the service is stopped.", extra={"decimals": 0}),
        ts("CPU %", [(f'sum by (instance) (rate(namedprocess_namegroup_cpu_seconds_total{{{sel}}}[{RATE}])) * 100', "{{instance}}")],
           6, 6, 7, unit="percent", desc="CPU used by the service processes (user+system), 100% = one core."),
        ts("Memory resident", [(f'sum by (instance) (namedprocess_namegroup_memory_bytes{{{sel}, memtype="resident"}})', "{{instance}}")],
           12, 6, 7, unit="bytes"),
        ts("Threads", [(f'sum by (instance) (namedprocess_namegroup_num_threads{{{sel}}})', "{{instance}}")],
           18, 6, 7, extra={"decimals": 0}),
    )
    d.add(
        ts("Requests/sec by route", [(f'sum by ({ROUTE}) (rate({DUR}_count{{{sel}}}[{RATE}]))', "{{" + ROUTE + "}}")],
           0, 8, 8, unit="reqps", no_value=no_http),
        ts("Latency p50 / p95", [
            (f'histogram_quantile(0.50, sum by (le) (rate({DUR}_bucket{{{sel}}}[{RATE}])))', "p50"),
            (f'histogram_quantile(0.95, sum by (le) (rate({DUR}_bucket{{{sel}}}[{RATE}])))', "p95"),
        ], 8, 8, 8, unit="ms", no_value=no_http, exemplar=True,
           desc=f"histogram_quantile over {DUR}_bucket. Diamonds are exemplars: click one to open that "
                "request's trace in Tempo."),
        ts("Error rate % (5xx / total)", [
            (f'100 * (sum(rate({DUR}_count{{{sel}, {STATUS}=~"5.."}}[{RATE}])) or vector(0)) / sum(rate({DUR}_count{{{sel}}}[{RATE}]))', "5xx %"),
        ], 16, 8, 8, unit="percent", no_value=no_http),
    )

    d.row("Hosts ($host)")
    h = 'instance=~"$host"'
    d.add(
        ts("Host CPU %", [(f'100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{{job="node", {h}, mode="idle"}}[{RATE}])))', "{{instance}}")],
           0, 6, 8, unit="percent", extra={"max": 100}),
        ts("Host memory used %", [(f'100 * (1 - node_memory_MemAvailable_bytes{{job="node", {h}}} / node_memory_MemTotal_bytes{{job="node", {h}}})', "{{instance}}")],
           6, 6, 8, unit="percent", extra={"max": 100}),
        ts("Disk used % (/)", [
            (f'100 * (1 - node_filesystem_avail_bytes{{job="node", {h}, mountpoint="/"}} / node_filesystem_size_bytes{{job="node", {h}, mountpoint="/"}})', "{{instance}} used %"),
        ], 12, 6, 8, unit="percent", extra={"max": 100}),
        ts("Network rx / tx", [
            (f'sum by (instance) (rate(node_network_receive_bytes_total{{job="node", {h}, device!~"lo|docker.*|veth.*"}}[{RATE}]))', "{{instance}} rx"),
            (f'-sum by (instance) (rate(node_network_transmit_bytes_total{{job="node", {h}, device!~"lo|docker.*|veth.*"}}[{RATE}]))', "{{instance}} tx"),
        ], 18, 6, 8, unit="Bps", min0=False, desc="Receive positive, transmit negative."),
    )

    host_var = query_var("host", "Host", 'label_values(up{job="node"}, instance)')
    host_var["allValue"] = ".+"
    variables = [host_var, query_var("service", "Service",
                                     'label_values(namedprocess_namegroup_num_procs{instance=~"$host"}, service_name)')]
    return dashboard("service-monitoring", "Service Monitoring", ["lab", "services", "opentelemetry"],
                     variables, d.panels, [LINK_NODE, LINK_TRACES])


# --------------------------------------------------------------------------------------
# Traces (phase 2) - Tempo service graph, span-metrics, TraceQL searches
# --------------------------------------------------------------------------------------
def span_red(d, sel, by, legend, title_suffix, kind_note):
    """Request rate / error % / p95 rows from Tempo span-metrics, grouped by `by`."""
    calls = f"traces_spanmetrics_calls_total{{{sel}}}"
    errors = f'traces_spanmetrics_calls_total{{{sel}, status_code="STATUS_CODE_ERROR"}}'
    d.add(
        ts(f"Request rate {title_suffix}", [(f"sum by ({by}) (rate({calls}[{RATE}]))", legend)],
           0, 8, 8, unit="reqps", desc=f"traces_spanmetrics_calls_total ({kind_note})."),
        ts(f"Error rate % {title_suffix}", [(
            f"100 * (sum by ({by}) (rate({errors}[{RATE}])) or (0 * sum by ({by}) (rate({calls}[{RATE}]))))"
            f" / sum by ({by}) (rate({calls}[{RATE}]))", legend)],
           8, 8, 8, unit="percent", desc=f"Spans with status ERROR / all spans ({kind_note})."),
        ts(f"p95 latency {title_suffix}", [(
            f"histogram_quantile(0.95, sum by (le, {by}) (rate(traces_spanmetrics_latency_bucket{{{sel}}}[{RATE}])))", legend)],
           16, 8, 8, unit="s", exemplar=True,
           desc=f"traces_spanmetrics_latency_bucket ({kind_note}). Exemplars link to traces."),
    )


def traces():
    d = Dash()
    svc = 'service=~"$service"'

    d.row("Service graph (Tempo metrics-generator)")
    d.add(
        {"type": "nodeGraph", "title": "Service graph", "datasource": TEMPO,
         "description": "Built from traces_service_graph_* series (all services; the graph is not filtered). "
                        "redis is a virtual node derived from the db.system attribute of client spans.",
         "gridPos": {"x": 0, "y": 0, "w": 14, "h": 12},
         "targets": [{"datasource": TEMPO, "refId": "A", "queryType": "serviceMap"}],
         "options": {}, "fieldConfig": {"defaults": {}, "overrides": []}},
        ts("Calls between services (edges)", [
            (f"sum by (client, server) (rate(traces_service_graph_request_total[{RATE}]))", "{{client}} → {{server}}"),
        ], 14, 10, 6, unit="reqps", desc="traces_service_graph_request_total per edge."),
    )
    # place the second edge panel under the first one, to the right of the node graph
    edge_fail = ts("Failed calls between services", [
        (f"sum by (client, server) (rate(traces_service_graph_request_failed_total[{RATE}]))", "{{client}} → {{server}}"),
    ], 14, 10, 6, unit="reqps", desc="traces_service_graph_request_failed_total per edge.")
    edge_fail["id"] = d.nid()
    edge_fail["gridPos"]["y"] = d.y - 6
    d.panels.append(edge_fail)

    d.row("Per service: incoming requests (server spans)")
    span_red(d, f'{svc}, span_kind="SPAN_KIND_SERVER"', "service", "{{service}}", "per service",
             "server spans = requests a service receives")

    d.row("Per operation (span_name, all span kinds)")
    span_red(d, svc, "service, span_name", "{{service}} · {{span_name}}", "per span_name",
             "every span: server, client (httpx, redis) and internal")

    d.row("Recent traces for $service (TraceQL)")
    d.add(
        traceql_table("Slow traces (> 300 ms)",
                      '{ resource.service.name =~ "${service:regex}" && traceDuration > 300ms }', 0, 12, 10,
                      desc="Traces that include the selected service and took longer than 300 ms end-to-end. "
                           "Click a trace ID to open it."),
        traceql_table("Error traces",
                      '{ resource.service.name =~ "${service:regex}" && status = error }', 12, 12, 10,
                      desc="Traces with at least one span in status ERROR in the selected service."),
    )

    variables = [query_var("service", "Service", "label_values(traces_spanmetrics_calls_total, service)")]
    return dashboard("traces", "Traces", ["lab", "traces", "tempo"], variables, d.panels,
                     [LINK_SERVICES, LINK_NODE])


# --------------------------------------------------------------------------------------
# Actions (phase 2, part B) - everything involved in one user action (entry route)
# --------------------------------------------------------------------------------------
def actions():
    d = Dash()
    act = 'user_action="$action"'
    sel = f'{act}, service=~"$service"'
    server = f'{sel}, span_kind="SPAN_KIND_SERVER"'

    d.row("Services involved in $action")
    calls_range = {
        "type": "bargauge", "title": "Calls per service in the time range", "datasource": PROM,
        "description": "Every service that handled at least one span of this action, discovered from the "
                       "traces (no manual list). Counts all spans: server, client (httpx, redis) and internal.",
        "gridPos": {"x": 0, "y": 0, "w": 8, "h": 8},
        "targets": [{**prom_target(f"sum by (service) (increase(traces_spanmetrics_calls_total{{{sel}}}[$__range]))",
                                   "{{service}}"), "range": False, "instant": True}],
        "fieldConfig": {"defaults": {"unit": "short", "decimals": 0, "min": 0}, "overrides": []},
        "options": {"orientation": "horizontal", "displayMode": "gradient", "showUnfilled": True,
                    "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
    }
    d.add(
        calls_range,
        ts("Calls/sec per service", [(f"sum by (service) (rate(traces_spanmetrics_calls_total{{{server}}}[{RATE}]))", "{{service}}")],
           8, 8, 8, unit="reqps", desc="Server spans per second, i.e. requests each service received as part of this action."),
        ts("Error rate % per service", [(
            f'100 * (sum by (service) (rate(traces_spanmetrics_calls_total{{{server}, status_code="STATUS_CODE_ERROR"}}[{RATE}]))'
            f" or (0 * sum by (service) (rate(traces_spanmetrics_calls_total{{{server}}}[{RATE}]))))"
            f" / sum by (service) (rate(traces_spanmetrics_calls_total{{{server}}}[{RATE}]))", "{{service}}")],
           16, 8, 8, unit="percent", desc="Server spans with status ERROR / all server spans, per service."),
    )
    d.add(
        ts("p95 latency per service", [(
            f"histogram_quantile(0.95, sum by (le, service) (rate(traces_spanmetrics_latency_bucket{{{server}}}[{RATE}])))", "{{service}}")],
           0, 12, 8, unit="s", exemplar=True, desc="Server spans. Exemplars link to example traces."),
        ts("p95 latency per span_name", [(
            f"histogram_quantile(0.95, sum by (le, service, span_name) (rate(traces_spanmetrics_latency_bucket{{{sel}}}[{RATE}])))",
            "{{service}} · {{span_name}}")],
           12, 12, 8, unit="s", exemplar=True,
           desc="Every operation in the action: server routes, outgoing HTTP calls and redis commands."),
    )

    d.row("Example traces")
    d.add(traceql_table("Traces for $action", '{ span.user.action = "$action" }', 0, 24, 10,
                        desc="TraceQL search on the user.action span attribute. Click a trace ID to open it."))

    action_var = query_var("action", "Action", "label_values(traces_spanmetrics_calls_total, user_action)", multi=False)
    variables = [action_var, query_var("service", "Service",
                                       'label_values(traces_spanmetrics_calls_total{user_action="$action"}, service)')]
    return dashboard("actions", "Actions", ["lab", "traces", "tempo", "actions"], variables, d.panels,
                     [LINK_SERVICES, LINK_TRACES])


LINK_ACTIONS = link("Actions", "actions", "actions", icon="apps")


def write(name, dash):
    path = OUT / name
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(dash, f, indent=2)
        f.write("\n")
    print(f"wrote {path.relative_to(OUT.parent.parent.parent)} ({len(dash['panels'])} panels)")


if __name__ == "__main__":
    for filename, build in (("service-monitoring.json", service_monitoring), ("traces.json", traces),
                            ("actions.json", actions)):
        dash = build()
        if dash["uid"] != "actions":
            dash["links"].append(LINK_ACTIONS)
        write(filename, dash)
