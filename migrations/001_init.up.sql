-- =====================================================
-- BitMirror – Initial Database Schema (Multi-User Ready)
-- PostgreSQL 16 + TimescaleDB
-- =====================================================
--
-- STORAGE PHILOSOPHY
-- ------------------
-- Health data lives in three tiers so we get both detail AND efficiency:
--
--   1. health_metrics        daily aggregates (dashboard views, tiny, fast)
--   2. health_series         raw timestamped samples (compressed 10–20× by Timescale)
--   3. sleep_sessions,
--      exercise_sessions     structured multi-sample events
--
-- Compression is enabled on every hypertable; huge storage savings with no
-- query cost. Retention policies are provided (commented) for high-volume
-- tables — enable later if growth becomes a concern.
--
-- We deliberately DO NOT store:
--   • per-second workout GPS / pace samples (~100k rows per workout, low value)
--   • per-minute step counts (hourly or daily answers every real question)
--   • duplicate rows from multiple providers (Open Wearables arbitrates
--     source priority upstream; we only store its resolved output)
--   • empty / NULL readings (skip at app layer, not DB layer)
--
-- We DO store granular HR, HRV, SpO₂, respiratory rate, sleep stages,
-- and per-workout summaries because those unlock the LLM Q&A use cases in
-- the README ("what was my HR during that run?", "how did sleep affect
-- next-day steps?").
-- =====================================================

-- Ensure TimescaleDB extension is available
CREATE EXTENSION IF NOT EXISTS timescaledb;

-- -----------------------------------------------------
-- Shared trigger function for updated_at columns
-- -----------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- -----------------------------------------------------
-- 0. User Profiles (master table)
-- -----------------------------------------------------
CREATE TABLE user_profiles (
    id                      INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    role                    VARCHAR(100) NOT NULL,
    relationship            VARCHAR(50),
    -- IANA timezone name (e.g. 'Asia/Colombo'), NOT abbreviation.
    -- health_metrics.date is the user-local calendar date in this TZ.
    timezone                VARCHAR(50) NOT NULL DEFAULT 'UTC',
    -- OW's user UUID. NULL until the account is linked to Open Wearables.
    open_wearables_user_id  VARCHAR(36) UNIQUE,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- -----------------------------------------------------
-- 1. Personal Metadata (per user)
-- -----------------------------------------------------
CREATE TABLE personal_metadata (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id     INT NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    key         VARCHAR(50) NOT NULL,
    value       JSONB NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, key)
);

-- -----------------------------------------------------
-- 2. Health Metrics — daily aggregates (per user) — Hypertable
-- -----------------------------------------------------
CREATE TABLE health_metrics (
    user_id           INT NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    date              DATE NOT NULL,                 -- user-local calendar date
    steps             INT,
    heart_rate_avg    INT,
    heart_rate_max    INT,
    sleep_minutes     INT,
    calories_burned   INT,
    active_minutes    INT,
    -- Primary source that produced the winning numbers for that day.
    -- Per-provider detail lives in health_series, not here.
    source            VARCHAR(50) NOT NULL DEFAULT 'manual',
    source_updated_at TIMESTAMPTZ,
    imported_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, date),
    CONSTRAINT positive_steps        CHECK (steps IS NULL OR steps >= 0),
    CONSTRAINT valid_heart_rate_avg  CHECK (heart_rate_avg IS NULL OR heart_rate_avg BETWEEN 30 AND 250),
    CONSTRAINT valid_heart_rate_max  CHECK (heart_rate_max IS NULL OR heart_rate_max BETWEEN 30 AND 250)
);

SELECT create_hypertable('health_metrics', 'date', chunk_time_interval => INTERVAL '30 days');

ALTER TABLE health_metrics SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'user_id',
    timescaledb.compress_orderby   = 'date DESC'
);
SELECT add_compression_policy('health_metrics', INTERVAL '30 days');

-- -----------------------------------------------------
-- 3. Health Series — raw timestamped samples (per user) — Hypertable
-- -----------------------------------------------------
-- This is the detailed data lake. One row per (metric, timestamp, source).
-- metric_type examples: 'heart_rate', 'hrv', 'spo2', 'resp_rate',
--                       'steps_hourly', 'body_temp', 'blood_glucose'
CREATE TABLE health_series (
    recorded_at   TIMESTAMPTZ NOT NULL,
    id            BIGINT GENERATED ALWAYS AS IDENTITY,
    user_id       INT NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    metric_type   VARCHAR(50) NOT NULL,
    value         DOUBLE PRECISION NOT NULL,
    unit          VARCHAR(20),
    source        VARCHAR(50),
    -- OW's record ID. Required for idempotent re-syncs — without it,
    -- re-pulled data creates duplicates. NULL is permitted for manual
    -- entries; UNIQUE skips NULLs, so duplicates of NULL are allowed.
    external_id   VARCHAR(100),
    PRIMARY KEY (recorded_at, id),
    UNIQUE (user_id, metric_type, external_id)
);

SELECT create_hypertable('health_series', 'recorded_at', chunk_time_interval => INTERVAL '7 days');

CREATE INDEX idx_health_series_user_type_time
    ON health_series (user_id, metric_type, recorded_at DESC);

ALTER TABLE health_series SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'user_id, metric_type',
    timescaledb.compress_orderby   = 'recorded_at DESC'
);
SELECT add_compression_policy('health_series', INTERVAL '7 days');

-- Optional: cap raw history once it stops being interesting.
-- SELECT add_retention_policy('health_series', INTERVAL '5 years');

-- -----------------------------------------------------
-- 4. Sleep Sessions + Stages (per user)
-- -----------------------------------------------------
-- Aggregated sleep_minutes lives in health_metrics; detailed stage
-- breakdown (deep / light / rem / awake) lives here.
CREATE TABLE sleep_sessions (
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id       INT NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    started_at    TIMESTAMPTZ NOT NULL,
    ended_at      TIMESTAMPTZ NOT NULL,
    source        VARCHAR(50),
    external_id   VARCHAR(100),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, external_id)
);

CREATE INDEX idx_sleep_sessions_user_time
    ON sleep_sessions (user_id, started_at DESC);

CREATE TABLE sleep_stages (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    session_id   BIGINT NOT NULL REFERENCES sleep_sessions(id) ON DELETE CASCADE,
    stage        VARCHAR(20) NOT NULL,   -- 'awake','light','deep','rem'
    started_at   TIMESTAMPTZ NOT NULL,
    ended_at     TIMESTAMPTZ NOT NULL,
    external_id  VARCHAR(100),
    UNIQUE (session_id, started_at)
);

CREATE INDEX idx_sleep_stages_session
    ON sleep_stages (session_id, started_at);

-- -----------------------------------------------------
-- 5. Body Measurements (per user) — Hypertable
-- -----------------------------------------------------
CREATE TABLE body_measurements (
    measured_at       TIMESTAMPTZ NOT NULL,
    id                BIGINT GENERATED ALWAYS AS IDENTITY,
    user_id           INT NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    measurement_type  VARCHAR(50) NOT NULL,
    value             NUMERIC(10, 2) NOT NULL,
    unit              VARCHAR(20) NOT NULL,
    source            VARCHAR(50) NOT NULL DEFAULT 'manual',
    external_id       VARCHAR(100),
    notes             TEXT,
    PRIMARY KEY (measured_at, id),
    UNIQUE (user_id, source, external_id)
);

SELECT create_hypertable('body_measurements', 'measured_at', chunk_time_interval => INTERVAL '30 days');

CREATE INDEX idx_body_measurements_user_type
    ON body_measurements (user_id, measurement_type, measured_at DESC);

ALTER TABLE body_measurements SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'user_id, measurement_type',
    timescaledb.compress_orderby   = 'measured_at DESC'
);
SELECT add_compression_policy('body_measurements', INTERVAL '90 days');

-- -----------------------------------------------------
-- 6. Exercise Sessions (per user)
-- -----------------------------------------------------
CREATE TABLE exercise_sessions (
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id       INT NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    started_at    TIMESTAMPTZ NOT NULL,
    ended_at      TIMESTAMPTZ,
    workout_type  VARCHAR(50) NOT NULL,
    title         VARCHAR(255),
    notes         TEXT,
    source        VARCHAR(50) NOT NULL DEFAULT 'manual',
    external_id   VARCHAR(100),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, source, external_id)
);

CREATE INDEX idx_exercise_sessions_user_time
    ON exercise_sessions (user_id, started_at DESC);

-- -----------------------------------------------------
-- 7. Exercise Sets (linked to session; user derived via session)
-- -----------------------------------------------------
CREATE TABLE exercise_sets (
    id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    session_id       BIGINT NOT NULL REFERENCES exercise_sessions(id) ON DELETE CASCADE,
    exercise_name    VARCHAR(100) NOT NULL,
    set_number       INT NOT NULL DEFAULT 1,
    weight_kg        NUMERIC(8, 2),
    reps             INT,
    duration_seconds INT,
    distance_m       NUMERIC(10, 2),
    is_pr            BOOLEAN NOT NULL DEFAULT FALSE,
    notes            TEXT,
    UNIQUE (session_id, set_number, exercise_name)
);

-- -----------------------------------------------------
-- 8. Personal Records (per user)
-- -----------------------------------------------------
CREATE TABLE personal_records (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id         INT NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    exercise_name   VARCHAR(100) NOT NULL,
    metric_type     VARCHAR(50) NOT NULL,
    value           NUMERIC(12, 2) NOT NULL,
    unit            VARCHAR(20) NOT NULL,
    achieved_at     TIMESTAMPTZ NOT NULL,
    notes           TEXT,
    source          VARCHAR(50) NOT NULL DEFAULT 'manual',
    external_id     VARCHAR(100),
    session_id      BIGINT REFERENCES exercise_sessions(id) ON DELETE SET NULL,
    set_id          BIGINT REFERENCES exercise_sets(id) ON DELETE SET NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, source, external_id)
);

CREATE INDEX idx_personal_records_user_exercise
    ON personal_records (user_id, exercise_name, achieved_at DESC);

-- -----------------------------------------------------
-- 9. GitHub Events (per user) — Hypertable
-- -----------------------------------------------------
CREATE TABLE github_events (
    time         TIMESTAMPTZ NOT NULL,
    id           BIGINT GENERATED ALWAYS AS IDENTITY,
    user_id      INT NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    event_type   VARCHAR(50) NOT NULL,          -- 'PushEvent','PullRequestReviewEvent', ...
    repo         VARCHAR(255) NOT NULL,
    branch       VARCHAR(255),
    commit_sha   VARCHAR(64),                   -- SHA-1 (40) fits comfortably; headroom for SHA-256
    title        TEXT,
    url          TEXT,
    additions    INT,
    deletions    INT,
    -- GitHub's event id. Dedupe key for re-fetched recent activity.
    external_id  VARCHAR(100),
    PRIMARY KEY (time, id),
    UNIQUE (user_id, external_id)
);

SELECT create_hypertable('github_events', 'time', chunk_time_interval => INTERVAL '7 days');

CREATE INDEX idx_github_events_user_repo_time
    ON github_events (user_id, repo, time DESC);

ALTER TABLE github_events SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'user_id',
    timescaledb.compress_orderby   = 'time DESC'
);
SELECT add_compression_policy('github_events', INTERVAL '7 days');

-- -----------------------------------------------------
-- 10. Location History (per user) — Hypertable
-- -----------------------------------------------------
CREATE TABLE location_history (
    time         TIMESTAMPTZ NOT NULL,
    id           BIGINT GENERATED ALWAYS AS IDENTITY,
    user_id      INT NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    latitude     DOUBLE PRECISION NOT NULL,
    longitude    DOUBLE PRECISION NOT NULL,
    accuracy     INT,
    altitude     DOUBLE PRECISION,
    source       VARCHAR(50) NOT NULL DEFAULT 'google_maps',
    external_id  VARCHAR(100),
    PRIMARY KEY (time, id),
    UNIQUE (user_id, source, external_id)
);

SELECT create_hypertable('location_history', 'time', chunk_time_interval => INTERVAL '7 days');

ALTER TABLE location_history SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'user_id',
    timescaledb.compress_orderby   = 'time DESC'
);
SELECT add_compression_policy('location_history', INTERVAL '7 days');

-- Google Maps Timeline is high volume and rarely interesting past a year.
-- SELECT add_retention_policy('location_history', INTERVAL '2 years');

-- -----------------------------------------------------
-- 11. OAuth Tokens (per user, encrypted at application layer)
-- -----------------------------------------------------
CREATE TABLE oauth_tokens (
    user_id       INT NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    provider      VARCHAR(50) NOT NULL,
    access_token  TEXT NOT NULL,
    refresh_token TEXT,
    expires_at    TIMESTAMPTZ NOT NULL,
    scope         TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, provider)
);

-- -----------------------------------------------------
-- 12. Sync State (per user, per source)
-- -----------------------------------------------------
CREATE TABLE sync_state (
    user_id       INT NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    source        VARCHAR(50) NOT NULL,
    last_sync_at  TIMESTAMPTZ,
    -- Opaque cursor from Open Wearables. Use this, not last_sync_at,
    -- for incremental pulls — it survives ties and pagination quirks.
    last_cursor   TEXT,
    last_status   VARCHAR(20),
    error_message TEXT,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, source)
);

-- -----------------------------------------------------
-- 13. Life Milestones & Tags
-- -----------------------------------------------------
CREATE TABLE milestone_categories (
    id          INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        VARCHAR(50) UNIQUE NOT NULL,
    description TEXT
);

CREATE TABLE life_milestones (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id        INT NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    category_id    INT REFERENCES milestone_categories(id) ON DELETE RESTRICT,
    occurred_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    title          VARCHAR(255) NOT NULL,
    content        TEXT NOT NULL,
    is_mistake     BOOLEAN NOT NULL DEFAULT FALSE,
    lesson_learned TEXT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_life_milestones_user_time
    ON life_milestones (user_id, occurred_at DESC);

CREATE TABLE tags (
    id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name VARCHAR(50) UNIQUE NOT NULL
);

CREATE TABLE milestone_tags (
    milestone_id BIGINT REFERENCES life_milestones(id) ON DELETE CASCADE,
    tag_id       INT REFERENCES tags(id) ON DELETE RESTRICT,
    PRIMARY KEY (milestone_id, tag_id)
);

-- -----------------------------------------------------
-- updated_at triggers — fire automatically on UPDATE
-- -----------------------------------------------------
CREATE TRIGGER trg_personal_metadata_updated
    BEFORE UPDATE ON personal_metadata
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_sleep_sessions_updated
    BEFORE UPDATE ON sleep_sessions
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_exercise_sessions_updated
    BEFORE UPDATE ON exercise_sessions
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_oauth_tokens_updated
    BEFORE UPDATE ON oauth_tokens
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_sync_state_updated
    BEFORE UPDATE ON sync_state
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_life_milestones_updated
    BEFORE UPDATE ON life_milestones
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =====================================================
-- OPTIONAL (enable later): continuous aggregates for fast dashboards
-- =====================================================
-- Once health_series fills up, hour-bucket rollups make chart queries
-- near-instant without re-aggregating raw rows each time.
--
-- CREATE MATERIALIZED VIEW health_series_hourly
-- WITH (timescaledb.continuous) AS
-- SELECT
--     user_id,
--     metric_type,
--     time_bucket('1 hour', recorded_at) AS bucket,
--     AVG(value)     AS avg_value,
--     MIN(value)     AS min_value,
--     MAX(value)     AS max_value,
--     COUNT(*)       AS sample_count
-- FROM health_series
-- GROUP BY user_id, metric_type, bucket
-- WITH NO DATA;
--
-- SELECT add_continuous_aggregate_policy('health_series_hourly',
--     start_offset      => INTERVAL '2 hours',
--     end_offset        => INTERVAL '1 hour',
--     schedule_interval => INTERVAL '1 hour');
