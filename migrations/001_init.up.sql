-- =====================================================
-- BitMirror – Initial Database Schema (Multi‑User Ready)
-- PostgreSQL 16 + TimescaleDB
-- =====================================================

-- Ensure TimescaleDB extension is available
CREATE EXTENSION IF NOT EXISTS timescaledb;

-- -----------------------------------------------------
-- 0. User Profiles (master table)
-- -----------------------------------------------------
CREATE TABLE user_profiles (
    id           INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    role         VARCHAR(100) NOT NULL,          -- e.g., 'owner', 'family', 'friend'
    relationship VARCHAR(50),                    -- e.g., 'self', 'spouse', 'child'
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
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
    UNIQUE (user_id, key)                        -- each key unique per user
);

-- -----------------------------------------------------
-- 2. Health Metrics (daily aggregates, per user) – Hypertable
-- -----------------------------------------------------
CREATE TABLE health_metrics (
    user_id           INT NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    date              DATE NOT NULL,
    steps             INT,
    heart_rate_avg    INT,
    heart_rate_max    INT,
    sleep_minutes     INT,
    calories_burned   INT,
    active_minutes    INT,
    source_updated_at TIMESTAMPTZ,
    imported_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, date),
    CONSTRAINT positive_steps CHECK (steps >= 0),
    CONSTRAINT positive_heart_rate CHECK (heart_rate_avg BETWEEN 30 AND 250)
);

SELECT create_hypertable('health_metrics', 'date', chunk_time_interval => INTERVAL '30 days');

-- -----------------------------------------------------
-- 3. Body Measurements (per user) – Hypertable
-- -----------------------------------------------------
CREATE TABLE body_measurements (
    measured_at       TIMESTAMPTZ NOT NULL,
    id                BIGINT GENERATED ALWAYS AS IDENTITY,
    user_id           INT NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    measurement_type  VARCHAR(50) NOT NULL,
    value             NUMERIC(10, 2) NOT NULL,
    unit              VARCHAR(20) NOT NULL,
    source            VARCHAR(50),
    notes             TEXT,
    PRIMARY KEY (measured_at, id)
);

SELECT create_hypertable('body_measurements', 'measured_at', chunk_time_interval => INTERVAL '30 days');

CREATE INDEX idx_body_measurements_user_type ON body_measurements (user_id, measurement_type, measured_at DESC);

-- -----------------------------------------------------
-- 4. Exercise Sessions (per user)
-- -----------------------------------------------------
CREATE TABLE exercise_sessions (
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id       INT NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    started_at    TIMESTAMPTZ NOT NULL,
    ended_at      TIMESTAMPTZ,
    workout_type  VARCHAR(30) NOT NULL,
    title         VARCHAR(255),
    notes         TEXT,
    source        VARCHAR(50) DEFAULT 'manual',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_exercise_sessions_user_time ON exercise_sessions (user_id, started_at DESC);

-- -----------------------------------------------------
-- 5. Exercise Sets (linked to session, user derived via session)
-- -----------------------------------------------------
CREATE TABLE exercise_sets (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    session_id      BIGINT NOT NULL REFERENCES exercise_sessions(id) ON DELETE CASCADE,
    exercise_name   VARCHAR(100) NOT NULL,
    set_number      INT NOT NULL DEFAULT 1,
    weight_kg       NUMERIC(8, 2),
    reps            INT,
    duration_seconds INT,
    distance_m      NUMERIC(10, 2),
    is_pr           BOOLEAN NOT NULL DEFAULT FALSE,
    notes           TEXT,
    UNIQUE (session_id, set_number, exercise_name)
);

-- -----------------------------------------------------
-- 6. Personal Records (per user, optionally linked to session/set)
-- -----------------------------------------------------
CREATE TABLE personal_records (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id         INT NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    exercise_name   VARCHAR(100) NOT NULL,
    metric_type     VARCHAR(20) NOT NULL,
    value           NUMERIC(12, 2) NOT NULL,
    unit            VARCHAR(20) NOT NULL,
    achieved_at     TIMESTAMPTZ NOT NULL,
    notes           TEXT,
    source          VARCHAR(50) DEFAULT 'manual',
    session_id      BIGINT REFERENCES exercise_sessions(id) ON DELETE SET NULL,
    set_id          BIGINT REFERENCES exercise_sets(id) ON DELETE SET NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_personal_records_user_exercise ON personal_records (user_id, exercise_name, achieved_at DESC);

-- -----------------------------------------------------
-- 7. GitHub Events (per user) – Hypertable
-- -----------------------------------------------------
CREATE TABLE github_events (
    time          TIMESTAMPTZ NOT NULL,
    id            BIGINT GENERATED ALWAYS AS IDENTITY,
    user_id       INT NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    event_type    VARCHAR(20) NOT NULL,
    repo          VARCHAR(255) NOT NULL,
    branch        VARCHAR(255),
    commit_sha    VARCHAR(40),
    title         TEXT,
    url           TEXT,
    additions     INT,
    deletions     INT,
    PRIMARY KEY (time, id)
);

SELECT create_hypertable('github_events', 'time', chunk_time_interval => INTERVAL '7 days');

CREATE INDEX idx_github_events_user_repo_time ON github_events (user_id, repo, time DESC);

-- -----------------------------------------------------
-- 8. Location History (per user) – Hypertable
-- -----------------------------------------------------
CREATE TABLE location_history (
    time        TIMESTAMPTZ NOT NULL,
    id          BIGINT GENERATED ALWAYS AS IDENTITY,
    user_id     INT NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    latitude    DOUBLE PRECISION NOT NULL,
    longitude   DOUBLE PRECISION NOT NULL,
    accuracy    INT,
    altitude    DOUBLE PRECISION,
    source      VARCHAR(50) DEFAULT 'google_maps',
    PRIMARY KEY (time, id)
);

SELECT create_hypertable('location_history', 'time', chunk_time_interval => INTERVAL '7 days');

-- -----------------------------------------------------
-- 9. OAuth Tokens (per user, encrypted at application layer)
-- -----------------------------------------------------
CREATE TABLE oauth_tokens (
    user_id       INT NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    provider      VARCHAR(20) NOT NULL,
    access_token  TEXT NOT NULL,
    refresh_token TEXT,
    expires_at    TIMESTAMPTZ NOT NULL,
    scope         TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, provider)
);

-- -----------------------------------------------------
-- 10. Sync State (per user, per source)
-- -----------------------------------------------------
CREATE TABLE sync_state (
    user_id       INT NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    source        VARCHAR(50) NOT NULL,
    last_sync_at  TIMESTAMPTZ,
    last_status   VARCHAR(20),
    error_message TEXT,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, source)
);

-- -----------------------------------------------------
-- 11. Life Milestones & Tags (per user for milestones, global tags/categories)
-- -----------------------------------------------------
CREATE TABLE milestone_categories (
    id          INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        VARCHAR(50) UNIQUE NOT NULL,
    description TEXT
);

CREATE TABLE life_milestones (
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id       INT NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    category_id   INT REFERENCES milestone_categories(id) ON DELETE RESTRICT,
    occurred_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    title         VARCHAR(255) NOT NULL,
    content       TEXT NOT NULL,
    is_mistake    BOOLEAN NOT NULL DEFAULT FALSE,
    lesson_learned TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_life_milestones_user_time ON life_milestones (user_id, occurred_at DESC);

CREATE TABLE tags (
    id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name VARCHAR(50) UNIQUE NOT NULL
);

CREATE TABLE milestone_tags (
    milestone_id BIGINT REFERENCES life_milestones(id) ON DELETE CASCADE,
    tag_id       INT REFERENCES tags(id) ON DELETE RESTRICT,
    PRIMARY KEY (milestone_id, tag_id)
);
