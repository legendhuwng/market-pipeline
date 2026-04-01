# Market Data Pipeline

A production-ready real-time market data pipeline built with Java 17, Spring Boot 4, Apache Kafka, RabbitMQ, MySQL, and Redis. The system simulates stock trading events, processes them through a multi-stage ETL pipeline, stores aggregated data in a Star Schema Data Warehouse, and exposes a secured REST API with caching.

---

## Architecture

```
┌─────────────────┐     HTTP POST      ┌─────────────────┐
│  Fake Generator │ ─────────────────► │  Ingest Service │
│     :8081       │                    │     :8080       │
└─────────────────┘                    └────────┬────────┘
                                                │ Kafka
                                                ▼
                                       ┌─────────────────┐
                                       │  Kafka Broker   │
                                       │ market.trades   │
                                       └────────┬────────┘
                                                │ consume batch
                                                ▼
                                       ┌─────────────────┐      ┌──────────────┐
                                       │  Raw Consumer   │─────►│  MySQL RAW   │
                                       │     :8082       │      │  raw_trade   │
                                       └────────┬────────┘      └──────────────┘
                                                │ RabbitMQ etl.staging
                                                ▼
                                       ┌─────────────────┐      ┌──────────────────┐
                                       │   ETL Worker    │─────►│ MySQL STAGING    │
                                       │     :8084       │      │  stg_trade_1m    │
                                       └────────┬────────┘      ├──────────────────┤
                                                │               │  MySQL DW        │
                                                │               │  fact_market_1m  │
                                                │               │  dim_time        │
                                                │               │  dim_symbol      │
                                                │               └──────────────────┘
                                                │ cache.invalidate
                                                ▼
                                       ┌─────────────────┐      ┌──────────────┐
                                       │ Report Service  │◄────►│    Redis     │
                                       │     :8085       │      │  Cache TTL   │
                                       └─────────────────┘      └──────────────┘
                                                ▲
                                         JWT Bearer Token
                                         REST API Client
```

---

## Tech Stack

| Component | Technology |
|-----------|-----------|
| Language | Java 17 |
| Framework | Spring Boot 4.0.5 |
| Message Streaming | Apache Kafka (Confluent 7.5) |
| Job Orchestration | RabbitMQ 3.12 |
| Database | MySQL 8.0 |
| Cache | Redis 7.2 |
| ORM | Spring Data JPA / Hibernate 7 |
| Security | Spring Security + JWT (jjwt 0.11.5) |
| API Docs | SpringDoc OpenAPI / Swagger UI |
| Observability | Spring Boot Actuator |
| Build | Maven 3.9 |
| Container | Docker + Docker Compose |

---

## Services

### 1. Fake Generator `:8081`
Simulates a stock exchange by continuously generating trade events for 10 Vietnamese stock symbols (VCB, VNM, HPG, FPT, MSN, TCB, BID, CTG, VIC, GAS). Price fluctuates randomly ±1% from the base price. Throughput is configurable at runtime.

**Runtime control API:**
```bash
GET  /generator/status          # view status + sent count
POST /generator/start           # start generating
POST /generator/stop            # stop generating
POST /generator/speed?ms=100    # change interval (ms)
```

### 2. Ingest Service `:8080`
The entry point of the pipeline. Validates incoming trade events and publishes them to Kafka. Uses idempotent producer (`acks=all`, `enable.idempotence=true`) to prevent data loss.

- `POST /api/trades` — receives and validates events
- `GET  /api/health` — health check with received count

**Validation rules:** `eventId` not blank, `symbol` max 10 chars, `price > 0`, `volume > 0`, `eventTime` not null.

### 3. Raw Consumer `:8082`
Consumes events from Kafka in batches of up to 200 records, batch-inserts into `raw_trade` (immutable raw layer), then groups events by `(symbol, minute)` and publishes staging jobs to RabbitMQ.

- Kafka consumer group: `raw-consumer-group`
- Batch size: 200 records
- Queue output: `etl.staging`

### 4. ETL Worker `:8084`
The core processing engine. Consumes staging jobs from RabbitMQ and runs a 2-stage ETL pipeline within a single `@Transactional` boundary:

**Stage 1 — RAW → STAGING:**
Reads all trades for a given `(symbol, minute)` window, computes OHLCV aggregation, upserts into `stg_trade_1m`.

**Stage 2 — STAGING → FACT:**
Upserts `dim_time` dimension record, then writes to `fact_market_1m`. Idempotent — skips if fact record already exists. After successful insert, publishes a `cache.invalidate` event to RabbitMQ.

**Reliability:** 3 retries with exponential backoff → DLQ on final failure. Dead Letter Queue: `etl.staging.dlq`.

**Observability endpoint:**
```bash
GET /actuator/etl   # totalJobs, successJobs, failedJobs, successRate, avgDurationMs
GET /actuator/health
```

### 5. Report Service `:8085`
REST API to query the Data Warehouse. Secured with stateless JWT authentication. Integrates Redis cache (cache-aside pattern) with 60-second TTL and preloads hot symbols on startup.

**Authentication:**
```bash
POST /auth/login   # returns JWT Bearer token
```

**Query API (requires Bearer token):**
```bash
GET /api/stocks                              # all data, paginated
GET /api/stocks?symbol=VCB                   # filter by symbol
GET /api/stocks?symbol=VCB&size=10&page=0    # pagination
GET /api/stocks?minPrice=80&maxPrice=90      # price range filter
GET /api/stocks?from=2026-03-29T17:00:00     # time range filter
GET /api/stocks/symbols                      # list available symbols
GET /swagger-ui.html                         # Swagger UI (no auth)
GET /actuator/health                         # health check
```

**Default users:**

| Username | Password | Role |
|----------|----------|------|
| user | user123 | USER |
| admin | admin123 | ADMIN |

---

## Database Schema

### RAW Layer (`market_raw`)
```sql
raw_trade
  event_id   VARCHAR(36)  PK
  symbol     VARCHAR(10)
  price      DECIMAL(18,4)
  volume     BIGINT
  event_time DATETIME(3)
  created_at DATETIME(3)
  INDEX idx_symbol_time (symbol, event_time)
```

### Staging Layer (`market_staging`)
```sql
stg_trade_1m
  id           BIGINT  PK AUTO_INCREMENT
  symbol       VARCHAR(10)
  time_bucket  DATETIME
  open_price   DECIMAL(18,4)
  close_price  DECIMAL(18,4)
  high_price   DECIMAL(18,4)
  low_price    DECIMAL(18,4)
  total_volume BIGINT
  event_count  INT
  UNIQUE (symbol, time_bucket)
```

### Data Warehouse (`market_dw`) — Star Schema
```
dim_symbol ──┐
             ├── fact_market_1m
dim_time   ──┘

fact_market_1m: avg/max/min/open/close price, total_volume, trade_count per (symbol, minute)
dim_time:       ts, minute_of_hour, hour_of_day, day_of_month, month_of_year, year
dim_symbol:     symbol, company_name, sector, exchange
```

---

## Prerequisites

- Docker Desktop (or Docker Engine + Docker Compose plugin)
- Java 17+ (for local development / running services outside Docker)
- Maven 3.9+ (for building)

---

## Quick Start

### 1. Clone and start infrastructure + all services

```bash
git clone <repo-url>
cd market-pipeline

# Start everything (builds images automatically)
docker compose up -d --build

# Check status
docker compose ps
```

### 2. Verify pipeline is running

```bash
# Watch live data flow (updates every 2 seconds)
watch -n 2 'docker exec market-mysql mysql -umarket_user -pmarket123 \
  -e "SELECT \"raw\" tbl,COUNT(*) cnt FROM market_raw.raw_trade \
      UNION SELECT \"staging\",COUNT(*) FROM market_staging.stg_trade_1m \
      UNION SELECT \"fact\",COUNT(*) FROM market_dw.fact_market_1m;" 2>/dev/null'
```

### 3. Test the API

```bash
# Login
TOKEN=$(curl -s -X POST http://localhost:8085/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"user","password":"user123"}' | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

# Query stocks
curl -s "http://localhost:8085/api/stocks?symbol=VCB&size=5" \
  -H "Authorization: Bearer $TOKEN" | python3 -m json.tool
```

---

## Service URLs

| Service | URL | Description |
|---------|-----|-------------|
| Ingest Service | http://localhost:8080 | Trade event ingestion |
| Fake Generator | http://localhost:8081 | Generator control API |
| Raw Consumer | http://localhost:8082 | Kafka consumer |
| ETL Worker | http://localhost:8084 | ETL metrics + health |
| Report Service | http://localhost:8085 | REST API + Swagger |
| RabbitMQ UI | http://localhost:15672 | Queue management (rabbit_user/rabbit123) |
| phpMyAdmin | http://localhost:8888 | MySQL browser (market_user/market123) |
| Portainer | http://localhost:9000 | Docker management |

---

## Configuration

All services use environment variables for Docker deployment. Key variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `SPRING_DATASOURCE_URL` | MySQL JDBC URL | localhost:3306 |
| `SPRING_KAFKA_BOOTSTRAP_SERVERS` | Kafka broker | localhost:9092 |
| `SPRING_RABBITMQ_HOST` | RabbitMQ host | localhost |
| `SPRING_DATA_REDIS_HOST` | Redis host | localhost |
| `GENERATOR_INTERVAL_MS` | Event generation interval | 500 |
| `JWT_SECRET` | JWT signing secret | (set in yml) |

---

## Resetting Data

```bash
# Full reset (removes all data and volumes)
docker compose down -v
docker compose up -d --build

# Truncate tables only (keep containers running)
docker exec market-mysql mysql -umarket_user -pmarket123 -e "
  USE market_raw;     TRUNCATE TABLE raw_trade;
  USE market_staging; TRUNCATE TABLE stg_trade_1m;
  USE market_dw;      SET FOREIGN_KEY_CHECKS=0;
                      TRUNCATE TABLE fact_market_1m;
                      TRUNCATE TABLE dim_time;
                      SET FOREIGN_KEY_CHECKS=1;"
docker exec market-redis redis-cli -a redis123 --no-auth-warning FLUSHALL
```

---

## Performance Benchmarks (WSL2 Ubuntu 24.04)

Measured via load test suite (`load-test-bash/`) on a local WSL2 environment.
Test method: bash + curl, no external tool required.

---

### Ingest Service `:8080`

Ramp test from 1 → 300 concurrent workers, 20s per level.

| Concurrent workers | Actual RPS | p95 (ms) | p99 (ms) | Error rate |
|-------------------|-----------|---------|---------|-----------|
| 1 | 32 | 25 | 28 | 0% ✅ |
| 5 | 72 | 61 | 75 | 0% ✅ |
| 10 | 101 | 89 | 108 | 0% ✅ |
| 20 | 120 | 162 | 199 | 0% ✅ |
| **50** | **118** | **410** | **472** | **0% ✅** |
| 100 | 128 | 790 | 903 | 0% ⚠️ |
| 150 | 147 | 1021 | 1170 | 0% ⚠️ |
| 200 | 145 | 1388 | 1589 | 0% ⚠️ |
| 300 | 151 | 1889 | 2150 | 0% ⚠️ |

**Sweet spot: 20–50 concurrent senders** → ~120 RPS, p99 < 500ms.

Throughput plateaus at ~150 RPS regardless of workers — bottleneck is Kafka
producer throughput and Spring MVC thread pool, not connection count.

---

### Kafka `market.trades` topic

Steady-state throughput test, 45s per level. Consumer group: `raw-consumer-group`.

| Senders | Produced | Consumed | Produce RPS | Consume RPS | Lag |
|--------|---------|---------|------------|------------|-----|
| 10 | 6,080 | 6,080 | 135 | 135 | 0 ✅ |
| 50 | 7,303 | 7,303 | 162 | 162 | 0 ✅ |
| 100 | 6,228 | 6,228 | 138 | 138 | 0 ✅ |
| 200 | 7,466 | 7,466 | 166 | 166 | 0 ✅ |
| 400 | 6,488 | 6,488 | 144 | 144 | 0 ✅ |
| 600 | 7,403 | 7,403 | 165 | 165 | 0 ✅ |

**Kafka + Raw Consumer are not the bottleneck.** Lag stays at 0 across all load
levels. Stable throughput ~130–165 msg/s with `batch-size=200`, `concurrency=3`.

---

### ETL Worker `:8084`

End-to-end pipeline test: ingest event → visible in `fact_market_1m`.

| Stage | Target RPS | Kafka lag | RabbitMQ backlog | ETL avg (ms) | E2E latency (avg) |
|-------|-----------|----------|----------------|------------|-----------------|
| LOW   | 20 rps | 0–5 | 0 ✅ | ~11 ms | ~1,341 ms |
| MID   | 100 rps | 13–24 | 0 ✅ | ~13 ms | ~1,874 ms |
| HIGH  | 300 rps | 0 | 1,633 ⚠️ | ~17 ms | ~4,809 ms |

**ETL sweet spot: ≤ 80 staging jobs/s** (corresponds to ~100 raw events/s with
deduplication). Above this threshold, `etl.staging` backlog starts accumulating.

RabbitMQ observe results (120s real-time monitoring at mixed load):

| Time window | Queue behavior | out_rate | Status |
|------------|---------------|---------|--------|
| 23:05:18–23:06:24 | ready=0 stable | ≈ in_rate | ✅ healthy |
| 23:06:28–23:06:51 | brief spikes, self-recovers | 33–52/s | ⚠️ warning |
| 23:06:48–23:07:15 | backlog 382→768, no recovery | 21–25/s | ❌ overload |

ETL overload trigger: sustained `in_rate > 80 msg/s` for more than ~15s.
Root cause: `setConcurrentConsumers=2` limits throughput to `2 × (1000ms / 17ms) ≈ 117 jobs/s`
theoretical, but actual DB contention (HikariCP pool=10, 4 queries/job) caps it at ~70–80 jobs/s.

---

### Report Service `:8085`

Ramp test from 1 → 400 workers, 20s per level. Mix: 50% cache-hit / 50% DB query.

| Workers | RPS | Cache hit p95 (ms) | Cache hit p99 (ms) |
|--------|-----|------------------|------------------|
| 1 | 30 | 49 | 58 | 
| 5 | 48 | 55 | 67 |
| 10 | 70 | 87 | 108 |
| **20** | **82** | **170** | **198** |
| 50 | 97 | 413 | 554 |
| 100 | 96 | 847 | 1,369 |
| 200 | 93 | 2,170 | 2,881 |
| 300 | 108 | 2,261 | 3,555 |
| 400 | 125 | 2,491 | 3,175 |

**Sweet spot: ≤ 20 concurrent API clients** → p99 < 200ms on cached queries.

Redis hit ratio: **99.9%** (14,975 hits / 11 misses) — preload on startup works.
Cache TTL: 60s. Cache invalidation triggered by ETL via `cache.invalidate` queue.

---

### Recommended operating parameters

Based on load test results, the following settings keep all services within
healthy thresholds simultaneously:

| Parameter | Current | Recommended | Location |
|-----------|---------|-------------|----------|
| Generator interval | 500ms | **50–100ms** (10–20 rps) | `docker-compose.yml` |
| Kafka partitions | 3 | 3 (sufficient) | `docker-compose.yml` |
| Raw consumer batch-size | 200 | 200 (sufficient) | `raw-consumer/application.yml` |
| Raw consumer concurrency | 3 | 3 (sufficient) | `KafkaConsumerConfig.java` |
| ETL `setConcurrentConsumers` | 2 | **8** | `RabbitMQConfig.java` |
| ETL `maxConcurrentConsumers` | 5 | **15** | `RabbitMQConfig.java` |
| ETL HikariCP pool size | 10 | **20** | `etl-worker/application.yml` |
| Redis TTL | 60s | 60s (sufficient) | `report-service/application.yml` |

Applying the ETL concurrency fix raises ETL throughput from ~70 jobs/s to
~350 jobs/s (theoretical), which keeps `etl.staging` backlog at 0 up to ~300 rps ingest load.

---

## Project Structure

```
market-pipeline/
├── docker-compose.yml
├── init/
│   └── mysql/
│       └── 01-init.sql          # Schema + seed data
├── fake-generator/              # Spring Boot :8081
├── ingest-service/              # Spring Boot :8080
├── raw-consumer/                # Spring Boot :8082
├── etl-worker/                  # Spring Boot :8084
└── report-service/              # Spring Boot :8085
```

Each service follows the standard Spring Boot Maven structure:
```
service/
├── Dockerfile
├── pom.xml
└── src/main/
    ├── java/com/market/...
    └── resources/application.yml
```

---

## License

MIT