# Deploying with an AI agent

This file has two parts:

1. **[Instructions for you](#part-1-instructions-for-you)**: what to prepare and fill in before handing the work over.
2. **[The prompt](#part-2-the-prompt)**: copy everything inside the box into the agent (e.g. Claude Code)
   after filling in the `{{...}}` placeholders.

The agent follows [README.md](README.md) and the scripts in this folder. It does not invent its
own setup. It stops and asks before anything that can affect running applications.

---

## Part 1: Instructions for you

### Before you start

| # | Prepare | Why |
|---|---------|-----|
| 1 | A machine where the agent runs, with this repository cloned and **SSH access (sudo)** to every server | The agent copies `deploy/` to the servers and runs the scripts over SSH |
| 2 | The list of servers: name, private IP, SSH user, and which applications run on each | Fills `HOST_NAME`, `targets/*.yml`, `SYSTEMD_UNITS`, the process-exporter groups |
| 3 | Which server hosts the monitoring stack (dedicated, or one of the app servers) | Sizing: [README.md → Sizing](README.md#sizing-monitoring-stack) |
| 4 | Grafana URL (DNS name or IP), and optionally a real TLS certificate (`grafana.crt` with full chain + `grafana.key`) | Without a certificate a self-signed one is created |
| 5 | Where alerts go: e-mail (SMTP host, sender, recipients, password) or Slack / Teams / webhook URL | `alertmanager/alertmanager.yml` |
| 6 | The network that may open Grafana (e.g. office / VPN range) | `GRAFANA_ALLOWED_SOURCES` |
| 7 | A **maintenance window** if applications will be instrumented: each instrumented service is restarted once | Step 7 of the prompt |
| 8 | The Grafana admin password, kept in a password manager | Do **not** write it into the prompt (the agent asks for it at runtime) |

### Choose what the agent may do

The prompt has a `{{SCOPE}}` placeholder. Pick one:

- **`monitoring-only`**: install Docker, the monitoring stack, agents and firewall rules.
  Applications are not touched, so you get host, process and systemd metrics but no HTTP
  metrics or traces yet.
- **`full`**: also instrument the listed applications with OpenTelemetry. Each one is
  restarted (with your approval, one at a time).

### After the agent finishes

1. Read its final report. It lists every server, what was changed, the verification
   results, and anything it skipped.
2. Log into Grafana, change the admin password if you gave a temporary one, and create
   personal accounts.
3. Commit your `targets/*.yml`, `alertmanager.yml` and `process-exporter/config.yml` changes to
   git. **Never** commit `deploy/.env` or `monitoring/certs/`.
4. Keep the rollback section of the report: it lists the exact commands to undo every change.

---

## Part 2: The prompt

Fill in every `{{...}}`, then paste the whole block.

````text
You are deploying a production monitoring stack (OpenTelemetry Collector, Prometheus,
Alertmanager, Tempo, Grafana, node_exporter, process-exporter) to the servers below, using
ONLY the files and scripts in the `deploy/` folder of this repository. Read deploy/README.md
and deploy/.env.example completely before doing anything. They are the source of truth; if
this prompt and the README disagree, stop and ask me.

## Inputs

Servers (name | private IP | SSH user | applications / systemd units on it):
{{SERVER_TABLE}}
  e.g.
  app1       | 10.0.0.11 | ubuntu | nginx, orders (orders.service, Python/uvicorn in /opt/orders/venv)
  app2       | 10.0.0.12 | ubuntu | inventory (inventory.service), redis (redis-server.service)
  monitoring | 10.0.0.10 | ubuntu | (monitoring stack only)

Monitoring stack runs on:         {{MONITORING_SERVER_NAME}}
Grafana URL:                      {{GRAFANA_URL}}            e.g. https://grafana.example.com:3000/
Grafana certificate:              {{CERT}}                   "self-signed" or local paths to grafana.crt + grafana.key
Networks allowed to open Grafana: {{GRAFANA_ALLOWED_SOURCES}} e.g. 10.20.0.0/16
Alert receiver:                   {{ALERT_RECEIVER}}         e.g. e-mail to ops@example.com via smtp.example.com:587
Environment name:                 {{ENVIRONMENT}}            e.g. production
Scope:                            {{SCOPE}}                  "monitoring-only" or "full"
Applications to instrument (only if scope = full):
{{APPS_TO_INSTRUMENT}}
  e.g. orders on app1 (Python, systemd unit orders.service), inventory on app2 (Python, inventory.service)

## Rules (follow all of them)

1. Ask me before every step that can affect a running application or the network:
   restarting or reconfiguring an application, stopping/removing an existing exporter or
   service, enabling ufw, or anything not described in deploy/README.md. Show the exact
   commands and wait for "yes".
2. Never print, log or commit secrets. Ask me for the Grafana admin password, SMTP password
   and webhook URLs when you need them; write them only into deploy/.env (chmod 600) or into
   files mounted read-only by Alertmanager. Never put them in shell history (use files or
   `read -s`), never in git.
3. Never run `ufw enable`, never change ufw's default policy, never flush iptables. Only the
   provided firewall scripts may change firewall rules.
4. Never use `docker compose down -v` or delete Docker volumes: they hold the monitoring data.
5. Do not edit the pinned image versions, the dashboards, or the collector/Tempo pipelines.
   You may edit only: deploy/.env, monitoring/prometheus/targets/*.yml,
   monitoring/alertmanager/alertmanager.yml, agent/process-exporter/config.yml, the
   `redis-server -> redis` style name mappings in monitoring/prometheus/prometheus.yml,
   and (scope = full) the applications' systemd units / env files.
6. Work on one server at a time and verify it before moving on. If a check fails, stop,
   show me the output, and propose a fix. Do not work around a failing check.
7. Keep a change log as you go (server, file/command, what changed) for the final report
   and for rollback.

## Procedure

### Step 1: Preflight (all servers, read-only)
On every server, collect and show me in one table:
- OS and version (`. /etc/os-release`), CPU count, RAM, free disk on / and /var/lib/docker
- `systemctl is-system-running`, time sync (`timedatectl show -p NTPSynchronized`)
- Docker present? (`docker --version`, `docker compose version`)
- ufw status (`ufw status`), and whether iptables has a DOCKER-USER chain
- Ports already in use: `ss -ltnp` filtered for 3000 3200 4317 4318 8888 9090 9093 9100 9256 13133
  (any existing node_exporter on 9100 or process-exporter on 9256 conflicts with the agent:
  report it and ask me whether to stop and disable it)
- Running services: `systemctl list-units --type=service --state=running --no-legend`
- The command lines of the applications (`ps -eo pid,user,args`) so you can write
  process-exporter patterns
Also check that every app server can reach the monitoring server's IP (ping or `nc -zv` later
once 4317 is open) and the monitoring server can reach each server.
Flag anything below the sizing in deploy/README.md. Wait for my go-ahead.

### Step 2: Prepare the configuration locally
In the repository copy on your machine:
1. `cp deploy/.env.example deploy/.env`. Fill the SHARED and MONITORING SERVER ONLY sections:
   OTLP_BIND_IP and GATEWAY_OTLP_ENDPOINT = monitoring server private IP (OTLP_BIND_IP must be
   a specific IP, never 0.0.0.0), MONITORING_SOURCES = monitoring server IP,
   OTLP_ALLOWED_SOURCES = ALL server IPs including the monitoring server itself,
   GRAFANA_ROOT_URL, GRAFANA_CERT_CN/SANS matching the Grafana URL and IP,
   GRAFANA_ALLOWED_SOURCES, DEPLOYMENT_ENVIRONMENT. Leave GRAFANA_ADMIN_PASSWORD as change-me
   for now (set on the server in step 4).
2. Create monitoring/prometheus/targets/node.yml and process.yml from the .example files:
   one entry per server (including the monitoring server), `instance` = server name.
3. Edit agent/process-exporter/config.yml: one group per application, group name = the
   application's service name, pattern from the command lines found in step 1. Keep nginx /
   redis / other entries that apply.
4. For every systemd unit whose name differs from its service name (e.g. redis-server ->
   redis), make sure a mapping exists in monitoring/prometheus/prometheus.yml.
5. Configure the receiver in monitoring/alertmanager/alertmanager.yml (secrets via
   *_file settings, see the comments in that file).
Naming rule (must hold for every service): OTEL_SERVICE_NAME = process-exporter group name
= systemd unit name without .service (or mapped in prometheus.yml).
Show me a summary of the per-server values (HOST_NAME, EXPORTER_BIND_IP, SYSTEMD_UNITS) and
the diff of all edited files. Wait for approval.

### Step 3: Copy and install Docker (every server)
- Copy the deploy/ folder to /opt/observability on each server (scp/rsync; make sure files
  keep LF line endings). `sudo chmod +x /opt/observability/*/deploy.sh /opt/observability/scripts/*.sh`.
- On each server, write /opt/observability/.env from the prepared file and set the
  PER-SERVER section for that server: HOST_NAME (= its `instance` in targets/*.yml),
  EXPORTER_BIND_IP (= its private IP), SYSTEMD_UNITS (single-quoted regex of the units it
  runs plus ssh, e.g. '(nginx|orders|ssh)\.service'), COMPOSE_PROFILES=otel.
  `sudo chmod 600 /opt/observability/.env`.
- `sudo /opt/observability/scripts/install-docker.sh` where Docker is missing.

### Step 4: Monitoring server
- Set GRAFANA_ADMIN_PASSWORD in /opt/observability/.env on this server (ask me for it).
- If a real certificate was given, copy it to /opt/observability/monitoring/certs/grafana.crt
  and grafana.key before deploying.
- `cd /opt/observability/monitoring && sudo ./deploy.sh`. It validates all configs, starts
  the stack and waits for readiness. It must end with ">>> ready".
- `sudo /opt/observability/scripts/firewall-monitoring.sh --install`
  and show me `sudo iptables -S MONITORING-FW`.

### Step 5: Agent (every server, monitoring server first)
- `cd /opt/observability/agent && sudo ./deploy.sh`. It must end with "exporters up" and
  "otel-agent healthy", and list the expected process groups. If a group is missing, fix
  agent/process-exporter/config.yml and re-run.
- `sudo /opt/observability/scripts/firewall-agent.sh`. If ufw is inactive, report that and
  do not enable it.

### Step 6: Verify the monitoring setup (on the monitoring server)
Run and show the output of:
- `curl -s localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | "\(.health) \(.labels.job) \(.labels.instance) \(.lastError)"'`
  Expect: every node and process target up for every server, plus prometheus, otel-collector,
  otelcol, alertmanager, tempo.
- `curl -s localhost:9090/api/v1/rules | jq -r '.data.groups[].rules[] | "\(.health) \(.name)"'`
  Expect: 13 rules, none with health "err".
- For each of node_systemd_unit_state and namedprocess_namegroup_num_procs:
  `curl -s --data-urlencode "query=count by (service_name, instance) (<metric>)" localhost:9090/api/v1/query | jq -c '.data.result[].metric'`
  Expect: every application appears with the right service_name on the right instance.
- `curl -sk -u admin "https://127.0.0.1:${GRAFANA_PORT:-3000}/api/search?type=dash-db" | jq -r '.[].title'`
  (prompt for the password; do not put it on the command line). Expect 4 dashboards.
- Alert delivery test without touching any service:
  `cd /opt/observability/monitoring && sudo docker compose exec alertmanager amtool alert add deployment_test severity=warning --annotation=summary="Deployment test, please ignore" --alertmanager.url=http://localhost:9093`
  Ask me to confirm the notification arrived (it may take ~30 s, group_wait).
- From one app server: `nc -zv <monitoring IP> 4317` succeeds. From a machine NOT in
  OTLP_ALLOWED_SOURCES it must fail (ask me if you have no such machine).
- From my network: Grafana URL opens with a valid (or the expected self-signed) certificate.

### Step 7: Instrument applications (only if scope = full)
For each application, one at a time, and only after my "yes" for that application:
1. Show me the plan: language, how it is started, the exact unit/env changes.
2. Python: install `opentelemetry-distro opentelemetry-exporter-otlp` into the app's venv,
   run `opentelemetry-bootstrap -a install`, and prefix the start command with
   `<venv>/bin/opentelemetry-instrument`. Other languages: follow the table in
   deploy/README.md (Java agent / Node require / .NET auto-instrumentation) and tell me which
   dashboard panels need the stable-convention queries (see README).
3. Install deploy/app-instrumentation/otel.env.example as /etc/otel/<service>.env with
   OTEL_SERVICE_NAME=<service> (naming rule!), add `EnvironmentFile=/etc/otel/<service>.env`
   to the unit (drop-in via `systemctl edit` preferred), `systemctl daemon-reload`.
4. Restart the application only when I confirm. Then check: the service is active, its
   health endpoint answers, and within 1 minute
   `count by (service_name, instance) (http_server_duration_milliseconds_count)` (Python) or
   `count by (service_name, instance) (http_server_request_duration_seconds_count)` (others)
   shows it, and Tempo has traces:
   `curl -s -G localhost:3200/api/search --data-urlencode 'q={ resource.service.name = "<service>" }' --data-urlencode limit=3`
5. If the application fails to start or errors increase: immediately revert the drop-in,
   daemon-reload, restart, verify it is healthy, and tell me.

### Step 8: Final report
Give me:
1. A table per server: role, HOST_NAME, what was installed, firewall changes, result.
2. All verification outputs from step 6 (and 7), condensed, with pass/fail.
3. Everything skipped or still open (e.g. ufw inactive, alert receiver not confirmed,
   non-Python apps needing dashboard query changes, existing exporters left in place).
4. The change log and the exact rollback commands for each server:
   - agent:      cd /opt/observability/agent && sudo docker compose down
   - monitoring: cd /opt/observability/monitoring && sudo docker compose down   (keeps data volumes)
   - firewall (monitoring): sudo systemctl disable --now monitoring-firewall.service;
                 sudo iptables -D DOCKER-USER -j MONITORING-FW; sudo iptables -F MONITORING-FW; sudo iptables -X MONITORING-FW;
                 sudo rm /etc/systemd/system/monitoring-firewall.service; sudo systemctl daemon-reload
   - firewall (agent):  sudo ufw delete allow proto tcp from <monitoring IP> to any port 9100,9256;
                 sudo ufw delete deny proto tcp to any port 9100,9256
   - per instrumented app: remove the drop-in / EnvironmentFile line, daemon-reload, restart
   - any exporter or service you stopped in step 1: how to re-enable it
5. Next steps for me: change/rotate the Grafana admin password, create user accounts,
   commit the non-secret config changes.

## Known pitfalls (from testing this setup)
- Docker-published ports bypass ufw; that is why firewall-monitoring.sh uses DOCKER-USER.
  Do not try to "fix" this with ufw rules.
- SYSTEMD_UNITS must be single-quoted in .env (bash sources the file; parentheses break it).
- The agent's OTLP listener is 127.0.0.1:4317 and the gateway's is <OTLP_BIND_IP>:4317; they
  only coexist on the monitoring server because OTLP_BIND_IP is not 0.0.0.0.
- The agent also uses 127.0.0.1:13133 (health) and 127.0.0.1:8888 (own metrics).
- HOST_NAME on a server must equal its `instance` label in targets/*.yml, otherwise the
  dashboards' Host filter splits one server in two.
- GRAFANA_ADMIN_PASSWORD only applies on the first start of Grafana (empty grafana-data
  volume). To change it later: `docker compose exec grafana grafana cli admin reset-admin-password`.
- Tempo needs up to ~1 minute before /ready answers; deploy.sh waits up to 3 minutes.
- A brand-new `HostDiskFillsIn24h` pending alert on the monitoring server right after
  deployment is normal (image pulls and fresh volumes); it clears on its own.
````
