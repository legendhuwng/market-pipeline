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

## Performance Benchmarks (WSL Ubuntu 24.04)

Measured on a local WSL2 environment:

| Generator interval | Throughput | ETL queue pending |
|-------------------|-----------|-------------------|
| 500ms | 2 rec/s | 0 ✅ |
| 100ms | 10 rec/s | 0 ✅ |
| 50ms | 19 rec/s | 0 ✅ |
| 1ms | ~317 rec/s | ~3 ✅ |

ETL average processing time: **~10ms per job**. ETL success rate: **100%**.

On a native Linux server, throughput is expected to be 5–10× higher.

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