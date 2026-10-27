-- =====================================================
-- BitMirror – Down Migration (Rollback)
-- Drops all tables created in 000001_init.up.sql
-- =====================================================

-- Drop join table first (depends on life_milestones and tags)
DROP TABLE IF EXISTS milestone_tags;

-- Drop tags (depends on nothing, but after join table)
DROP TABLE IF EXISTS tags;

-- Drop life_milestones (depends on milestone_categories and user_profiles)
DROP TABLE IF EXISTS life_milestones;

-- Drop milestone_categories
DROP TABLE IF EXISTS milestone_categories;

-- Drop sync_state (depends on user_profiles)
DROP TABLE IF EXISTS sync_state;

-- Drop oauth_tokens (depends on user_profiles)
DROP TABLE IF EXISTS oauth_tokens;

-- Drop location_history (hypertable) – actually drop table is enough
DROP TABLE IF EXISTS location_history;

-- Drop github_events (hypertable)
DROP TABLE IF EXISTS github_events;

-- Drop personal_records (depends on exercise_sessions, exercise_sets, user_profiles)
DROP TABLE IF EXISTS personal_records;

-- Drop exercise_sets (depends on exercise_sessions)
DROP TABLE IF EXISTS exercise_sets;

-- Drop exercise_sessions (depends on user_profiles)
DROP TABLE IF EXISTS exercise_sessions;

-- Drop body_measurements (hypertable)
DROP TABLE IF EXISTS body_measurements;

-- Drop health_metrics (hypertable)
DROP TABLE IF EXISTS health_metrics;

-- Drop personal_metadata (depends on user_profiles)
DROP TABLE IF EXISTS personal_metadata;

-- Drop user_profiles (master table)
DROP TABLE IF EXISTS user_profiles;

-- Note: The TimescaleDB extension is not dropped because it may be shared.
-- If you want to completely remove it, run: DROP EXTENSION IF EXISTS timescaledb CASCADE;