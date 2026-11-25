# judge0-lean

**A faster, leaner, drop-in Judge0.** Same API as Judge0 CE 1.13.1, no database, compiles
once per batch, and sandboxes on modern cgroup v2 hosts (tested on EKS AL2023 and Docker
Desktop/WSL2).

It runs code through Judge0's **Multi-file program** language (`language_id: 89`): your
archive brings a `run` script (and optionally `compile`), and the image ships the
toolchains they call: `node` 20, `python3`, `javac`/`java` 17, `gcc` and `g++`.

If your app already talks to Judge0, point it at judge0-lean and keep your code as is:
`POST /submissions/batch`, `GET /submissions/batch`, `POST /submissions`,
`GET /submissions/:token`, base64, `X-Auth-Token`, statuses and response fields all behave
the same.

> judge0-lean is an independent, modified version of [Judge0](https://github.com/judge0/judge0)
> by Herman Zvonimir Došilović, released under the same GPLv3 license. It is not affiliated
> with or endorsed by the Judge0 project.

## Why judge0-lean

| | Judge0 CE 1.13.1 | judge0-lean |
|---|---|---|
| Datastore | PostgreSQL + Redis | **Redis only** (submissions expire after a TTL) |
| Batch of N test cases, same code | N jobs, **N compilations** | 1 job, **1 compilation**, N parallel runs |
| Same code submitted again (Run, then Submit) | Compiles again | **Compile cache**, no recompilation |
| Compilation error in a batch | Computed N times | Computed once, applied to all |
| Sandbox | isolate 1.x, needs **cgroup v1** | **isolate 2.1.2, cgroup v2** |
| Memory/CPU of student code | Outside the container's limits | **Inside the worker container's cgroup** (Kubernetes limits and HPA see it) |
| Batch poll | `SELECT *` per poll (loads source and archives) | One Redis `MGET`, archives never read |
| Worker per job | Forks the Rails process | No fork per job |
| Health probe | `/system_info` (shells out to `lscpu`, `free`) | **`/healthz`** (no auth, Redis ping) |
| Archives in a batch | Stored once per test case | Stored once per content hash |
| JDK / Node | Downloaded or swapped at container start | Baked in (Temurin 17, Node 20) |
| Telemetry | On | Off |

### Measured

Two Sum problem, 5 test cases per Submit, through a real browser client, on the
local Docker stack with real cgroup v2 limits:

| Case | Result |
|---|---|
| JavaScript, Python, Java, C++, C (multi-file and single-file) | Accepted, 0.3–1.1 s per Submit |
| Infinite loop in all 5 test cases | Time Limit Exceeded for all 5 in ~3 s |
| Allocating past the 128 MB limit (C, JavaScript) | Killed by the memory limit |
| Broken Java/C/C++ | Compilation Error with compiler output |

## Quick start

```bash
docker build -f Dockerfile.lean -t judge0-lean:1.13.1 .
docker compose -f docker-compose.local.yml up -d
curl http://localhost:2358/healthz
```

The API listens on `http://localhost:2358` with header `X-Auth-Token: local-dev-token`.

```bash
mkdir demo && printf 'print(input()[::-1])\n' > demo/main.py && printf 'python3 main.py\n' > demo/run
(cd demo && zip -q ../demo.zip main.py run)
curl -s -X POST "http://localhost:2358/submissions?base64_encoded=true&wait=true" \
  -H "X-Auth-Token: local-dev-token" -H "Content-Type: application/json" \
  -d "{\"language_id\": 89, \"additional_files\": \"$(base64 -w0 demo.zip)\", \"stdin\": \"$(printf judge0 | base64)\"}"
```

## Kubernetes

[`k8s/`](k8s/) deploys the API (2 pods), Redis (1) and auto-scaling workers on EKS, with an
HTTPS Ingress. Workers run privileged and delegate part of their own cgroup to isolate, so
student code is capped by the pod's CPU and memory limits. See [`k8s/README.md`](k8s/README.md)
for deploy and event-scaling commands.

## Configuration

Everything in Judge0's `judge0.conf` still applies (time, memory and process limits, auth,
queue size, ...). New settings, all optional:

| Variable | Default | Purpose |
|---|---|---|
| `SUBMISSION_TTL_SECONDS` | `3600` | How long submissions and results stay in Redis |
| `ENABLE_BATCH_COMPILE_ONCE` | `true` | One compilation per batch of identical submissions |
| `BATCH_RUN_CONCURRENCY` | `5` | Sandboxes a batch job runs in parallel |
| `ENABLE_COMPILE_CACHE` | `true` | Worker-local cache of compiled sandboxes |
| `COMPILE_CACHE_TTL` / `COMPILE_CACHE_MAX_MB` | `600` / `512` | Cache lifetime and size |
| `SLIM_UNIVERSAL_FIELDS` | `true` | `fields=*` returns the default fields only |
| `ENABLED_LANGUAGE_IDS` | `89` | Language ids to serve (the image only ships the toolchains above) |

Full details and design notes: [LEAN_FORK.md](LEAN_FORK.md).

## Differences to know

- No `GET /submissions` listing and a minimal `/statistics`: there is no history to list.
- Results disappear after `SUBMISSION_TTL_SECONDS`, so poll within that window.
- Redis must run with `maxmemory-policy noeviction`.

## License and credits

GPLv3, like Judge0. Built on [Judge0](https://github.com/judge0/judge0) and
[isolate](https://github.com/ioi/isolate). The original Judge0 README is kept in
[docs/UPSTREAM_README.md](docs/UPSTREAM_README.md).
