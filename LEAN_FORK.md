# Lean Judge0 fork

API-compatible with Judge0 CE 1.13.1 for running code: clients keep calling
`POST /submissions/batch` and polling `GET /submissions/batch` (and the single
`POST /submissions`, `GET /submissions/:token`). Nothing on the client side changes.

**Redis is the only datastore.** There is no PostgreSQL: submissions are kept in Redis
with a TTL, just long enough to be created, run and polled.

## What changed

| Area | Change | Flag (default) |
|---|---|---|
| Storage | Submissions are JSON in Redis (`judge0:submission:<token>`) with a TTL that is refreshed on every save, so queued and running work never expires. Archives (`additional_files`) are stored once per SHA-256 (`judge0:files:<hash>`) and shared by all test cases with the same zip. Languages are read from `db/languages/*.rb` into memory. | `SUBMISSION_TTL_SECONDS` (`3600`), `REDIS_DB` (`0`) |
| Batch execution | Batch items with the same language, source, archive and compile settings run in **one** job: one unzip and one compile, then the items run **in parallel**, each in its own sandbox restored from the compiled snapshot (so looping test cases do not queue behind each other). Compile errors fail the whole group at once. | `ENABLE_BATCH_COMPILE_ONCE` (`true`), `BATCH_RUN_CONCURRENCY` (`5`, `1` = sequential) |
| Compile cache | Worker-local cache of compiled boxes and compile errors, keyed by SHA-256 of everything that affects compilation. Run then Submit of the same code skips compilation. | `ENABLE_COMPILE_CACHE` (`true`), `COMPILE_CACHE_DIR` (`/tmp/judge0-compile-cache`), `COMPILE_CACHE_TTL` (`600` s), `COMPILE_CACHE_MAX_MB` (`512`) |
| Polling | One `MGET` per batch poll; archives are never read on polls. `fields=*` returns the default fields (token, time, memory, stdout, stderr, compile_output, message, status). | `SLIM_UNIVERSAL_FIELDS` (`true`) |
| Workers | No fork per job, one sandbox per CPU, slower idle polling. Worker saves are never dropped by re-validation. | `FORK_PER_JOB` (`false`), `COUNT` (`nproc`), `INTERVAL` (`0.5`) |
| Probes | `GET /healthz`: no auth, no shell-outs, pings Redis. Use it instead of `/system_info`. | — |
| Usage analytics | MongoDB collections `requests` (one per API call: time, IP, origin, user agent, endpoint, status, latency, bytes in/out, batch size) and `executions` (one per judged batch: language, verdicts, CPU, memory, queue and run time, cache hit). Buffered, flushed every 2 s, never blocks requests or jobs; TTL index expires old data. Dashboard at `GET /usage` (page) and `GET /usage/stats?hours=N` (JSON, needs the API token). | `MONGODB_URI` (unset = off), `USAGE_DB` (`judge0_lean`), `USAGE_RETENTION_DAYS` (`180`) |
| Languages | Serve only listed languages. | `ENABLED_LANGUAGE_IDS` (unset = all), e.g. `71,89` |
| Telemetry | Off by default, telemetry cron removed. | `JUDGE0_TELEMETRY_ENABLE` (`false`) |
| Image | `Dockerfile.lean`: Ruby and isolate from upstream, Debian python3/gcc/g++, Temurin 17 and Node 20 baked in (checksum-verified), faster `java`/`javac` wrappers, precompiled `bits/stdc++.h` for `-std=c++17 -O2`. No Postgres client. | — |

## Not supported (needs a database)

- `GET /submissions` (listing): returns 400.
- `GET /statistics`: returns only the number of submissions issued and the TTL.
- Results are gone after `SUBMISSION_TTL_SECONDS`; poll within that window.

## Build

```
docker build -f Dockerfile.lean -t judge0-lean:1.13.1 .
```

Same image for server (`/api/scripts/server`) and workers (`/api/scripts/workers`).
Workers still need `privileged: true` and a cgroup v1 host, as with stock Judge0.
`POSTGRES_*` settings are ignored and can be removed.

## Local run (Docker Desktop / WSL2)

```
docker build -f Dockerfile.lean -t judge0-lean:1.13.1 .
docker compose -f docker-compose.local.yml up -d
```

API on `http://localhost:2358`, header `X-Auth-Token: local-dev-token`. Docker Desktop only
has cgroup v2, so the local stack runs isolate without cgroups and with
`ISOLATE_DISABLE_ADDRESS_SPACE_LIMIT=true` (Node 20 and the JVM cannot start under an
address-space limit). Memory is reported but **not enforced** locally. Never set that
flag in production.

## Deployment notes

- Redis must use `maxmemory-policy noeviction`; an evicting policy silently drops queued jobs and results. Persistence is optional (results are short-lived).
- Size Redis for `peak submissions per TTL × ~5 KB` plus archives; 1 hour at your peak is a few MB.
- Set `COUNT` to the worker container's CPU limit: in Kubernetes `nproc` reports the node's CPUs.
- Mount `COMPILE_CACHE_DIR` on an `emptyDir` so the cache survives container restarts on the same node.
