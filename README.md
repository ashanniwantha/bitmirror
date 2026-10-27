---

# BitMirror — Personal Digital Twin Backend

## 1. Project Overview
**BitMirror** is a backend service that acts as a "Personal Data Lake." It automatically collects data about my daily life (health metrics, GitHub activity, location history) from external platforms and stores them in a structured time-series database. 

**Long-term goals:**
- Expose REST APIs for a future frontend dashboard.
- Feed structured data into LLMs for personal analytics and Q&A.
- Enable deep data analysis (e.g., "What is my average heart rate on high-step days?").

## 2. Technical Stack
| Component | Technology | Justification |
| :--- | :--- | :--- |
| **Language** | Go 1.22+ | High concurrency, excellent standard library, ideal for scheduled jobs and APIs. |
| **Database** | PostgreSQL 16 + TimescaleDB | Postgres for relational integrity; TimescaleDB extension for time-series partitioning, compression, and continuous aggregates. |
| **Cache** | Redis 7 | For rate-limiting, caching OAuth tokens, and temporary job locks. |
| **Routing** | `go-chi/chi` | Lightweight, idiomatic, supports middleware chaining. |
| **DB Driver** | `jackc/pgx/v5` | High-performance Postgres driver with `pgxpool` for connection pooling. |
| **Configuration** | `joho/godotenv` | Environment variable management. |
| **Logging** | `log/slog` (stdlib) | Structured logging with JSON/Text outputs based on environment. |
| **Scheduling** | `robfig/cron/v3` | In-process cron jobs for daily data syncs. |
| **Containerization** | Docker & Docker Compose | For local development and dependency isolation. |

## 3. Architecture (Layered / Clean)
The codebase follows a strict **Dependency Inversion** principle to keep business logic decoupled from infrastructure.

- **`cmd/api/`**: The entry point (`main.go`). Wires everything together (config, logger, db, cache, router, server).
- **`internal/domain/`**: **Pure entities and Repository Interfaces**. Defines what a `HealthMetric` or `PersonalMetadata` *is* and what operations (`Repository` interfaces) the service needs. No external dependencies.
- **`internal/repository/`**: **Concrete implementations** of the domain interfaces. Handles raw SQL (`pgx`) or Redis commands. Depends on `domain`.
- **`internal/service/`**: **Business logic & Cron jobs**. Orchestrates: calls `Client` to fetch external data → transforms it → calls `Repository` to save it. Depends on `domain` interfaces.
- **`internal/client/`**: **Raw HTTP calls** to external APIs (GitHub, Google Fit). Handles OAuth2 token injection and retries.
- **`internal/handler/`**: **HTTP REST endpoints**. Parses requests, calls `Service`, writes JSON responses.
- **`pkg/`**: Shared utilities (e.g., `logger`).

## 4. Folder Structure (Current)
```
.
├── cmd/
│   └── api/
│       └── main.go                # Entry point (wiring & graceful shutdown)
├── internal/
│   ├── cache/
│   │   └── redis.go               # Redis client initialization
│   ├── config/
│   │   └── config.go              # Env loading & struct mapping
│   ├── database/
│   │   └── postgres.go            # pgxpool initialization & tracer setup
│   ├── domain/
│   │   ├── health.go              # HealthMetric struct
│   │   └── metadata.go            # PersonalMetadata struct
│   ├── handler/
│   │   └── health.go              # /health Ping endpoint
│   └── repository/                # (TO BE IMPLEMENTED)
├── migrations/
│   ├── 001_initial_schema.up.sql  # SQL to create tables
│   └── 001_initial_schema.down.sql # SQL to rollback
├── pkg/
│   └── logger/
│       └── logger.go              # slog initialization
├── .env                           # Local environment variables (IGNORED by git)
├── docker-compose.yml             # TimescaleDB & Redis services
├── go.mod                         # Go module dependencies
└── README.md                      # This file
```

## 5. Database Schema (Finalized)
*Architectural Decision:* Health metrics are stored as **daily aggregates** (one row per day). Thus, `date` is the **Primary Key**—avoiding the performance penalty of random UUIDs on the TimescaleDB hypertable.

### Table 1: `personal_metadata`
Stores static or rarely-changing personal information.
```sql
CREATE TABLE personal_metadata (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    key         VARCHAR(50) UNIQUE NOT NULL,
    value       TEXT NOT NULL,
    updated_at  TIMESTAMPTZ DEFAULT NOW()
);
```
*Examples:* `birth_date`, `height_cm`, `weight_kg`, `fitness_goal`.

### Table 2: `health_metrics` (TimescaleDB Hypertable)
Primary container for daily health stats. `date` is the natural Primary Key.
```sql
CREATE TABLE health_metrics (
    date              DATE PRIMARY KEY,
    steps             INT,
    heart_rate_avg    INT,
    heart_rate_max    INT,
    sleep_minutes     INT,
    calories_burned   INT,
    active_minutes    INT,
    source_updated_at TIMESTAMPTZ,
    imported_at       TIMESTAMPTZ DEFAULT NOW()
);

-- Convert to hypertable (chunked monthly)
SELECT create_hypertable('health_metrics', 'date', chunk_time_interval => INTERVAL '30 days');

-- A strict table to keep categories clean and typo-free
CREATE TABLE milestone_categories (
    id          INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        VARCHAR(50) UNIQUE NOT NULL, -- e.g., 'Career', 'Family', 'Personal Growth', 'Health'
    description TEXT
);

-- The updated core Storybook table
CREATE TABLE life_milestones (
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    category_id   INT REFERENCES milestone_categories(id) ON DELETE RESTRICT, -- Enforces valid category
    occurred_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    title         VARCHAR(255) NOT NULL,
    content       TEXT NOT NULL,
    is_mistake    BOOLEAN NOT NULL DEFAULT FALSE,
    lesson_learned TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Flexible Tags table (e.g., #first-time, #achievement, #hard-choice)
CREATE TABLE tags (
    id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name VARCHAR(50) UNIQUE NOT NULL
);

-- The Bridge Table (Links multiple tags to multiple milestones)
CREATE TABLE milestone_tags (
    milestone_id BIGINT REFERENCES life_milestones(id) ON DELETE CASCADE,
    tag_id       INT REFERENCES tags(id) ON DELETE RESTRICT,
    PRIMARY KEY (milestone_id, tag_id)
);

```

### Table 3: `sync_state` (Planned for later)
Will track OAuth tokens and last-sync timestamps for external sources.

## 6. Go Domain Models
The `internal/domain/` package defines the structs used across layers.

**`HealthMetric`** (`health.go`):
```go
type HealthMetric struct {
    Date            time.Time `json:"date"`
    Steps           *int      `json:"steps,omitempty"`
    HeartRateAvg    *int      `json:"heart_rate_avg,omitempty"`
    HeartRateMax    *int      `json:"heart_rate_max,omitempty"`
    SleepMinutes    *int      `json:"sleep_minutes,omitempty"`
    CaloriesBurned  *int      `json:"calories_burned,omitempty"`
    ActiveMinutes   *int      `json:"active_minutes,omitempty"`
    SourceUpdatedAt time.Time `json:"source_updated_at"`
    ImportedAt      time.Time `json:"imported_at"`
}
```

## 7. Setup & Running Locally
1.  **Clone the repo**:
    ```bash
    git clone <repo-url>
    cd BitMirror
    ```

2.  **Create `.env`** (Copy the content below):
    ```env
    APP_ENV=development
    APP_PORT=8008
    
    DB_HOST=localhost
    DB_PORT=5432
    DB_USER=postgres
    DB_PASSWORD=postgres
    DB_NAME=digital_twin
    
    # Pool settings
    DB_MAX_CONNS=10
    DB_MIN_CONNS=2
    DB_MAX_CONN_LIFETIME=30m
    DB_MAX_CONN_IDLE_TIME=5m
    DB_HEALTH_CHECK_PERIOD=1m
    DB_CONNECT_TIMEOUT=5s
    DB_PING_TIMEOUT=3s
    
    # Redis
    REDIS_HOST=localhost
    REDIS_PORT=6379
    REDIS_PASSWORD=
    REDIS_DB=0
    REDIS_PING_TIMEOUT=3s
    ```

3.  **Start the infrastructure** (Postgres + Redis):
    ```bash
    docker-compose up -d
    ```

4.  **Run the migrations** (Manually for now, until a migration tool is added):
    ```bash
    docker exec -it bitmirror-postgres psql -U postgres -d digital_twin -f migrations/001_initial_schema.up.sql
    ```

5.  **Run the application**:
    ```bash
    go mod tidy
    go run cmd/api/main.go
    ```

6.  **Verify**:
    ```bash
    curl http://localhost:8008/health
    # Expected output: ok
    ```

## 8. Current Development Status (Sprint 0)
- [x] **Project Scaffolding**: Folder structure, Go module.
- [x] **Docker Compose**: TimescaleDB and Redis with health checks.
- [x] **Configuration & Logging**: `slog` with JSON/Text handlers.
- [x] **Database Wiring**: `pgxpool` with connection tracing and graceful shutdown.
- [x] **Redis Wiring**: Connection pooling and ping verification.
- [x] **Migrations**: `001_initial_schema` with `personal_metadata` and `health_metrics`.
- [x] **API Handler**: `/health` endpoint.
- [ ] **Repository Layer**: Write `HealthRepository` interface and PostgreSQL implementation.
- [ ] **Service Layer**: Health sync logic and cron scheduling.
- [ ] **Client Layer**: Google Fit and GitHub API integration.
- [ ] **OAuth2 Token Manager**: Auto-refresh and storage.

## 9. Future Roadmap (To be built)
1. **GitHub Integration**: Fetch commits and contribution activity.
2. **Google Fit Integration**: Pull steps, heart rate, sleep, and calories via OAuth2.
3. **Historical Import**: CLI tool to ingest Google Takeout ZIP data.
4. **Google Maps Timeline**: Location history via Takeout or API.
5. **Frontend/LLM**: Expose REST APIs and connect to a RAG pipeline.

---