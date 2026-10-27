package database

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/tracelog"
)

type PoolConfig struct {
	DSN               string
	Logger            *slog.Logger
	MaxConns          int
	MinConns          int
	MaxConnLifetime   time.Duration
	MaxConnIdleTime   time.Duration
	HealthCheckPeriod time.Duration
	ConnectTimeout    time.Duration
	PingTimeout       time.Duration
}

func NewPool(ctx context.Context, cfg PoolConfig) (*pgxpool.Pool, error) {
	// Guard against nil logger to prevent any future panics
	logger := cfg.Logger
	if logger == nil {
		logger = slog.Default()
	}

	poolConfig, err := pgxpool.ParseConfig(cfg.DSN)
	if err != nil {
		return nil, fmt.Errorf("Unable to parse pool config: %w", err)
	}

	// Only overried defaults if explicitly provided in cfg
	if cfg.MaxConns > 0 {
		poolConfig.MaxConns = int32(cfg.MaxConns)
	}
	if cfg.MinConns > 0 {
		poolConfig.MinConns = int32(cfg.MinConns)
	}
	if cfg.MaxConnLifetime > 0 {
		poolConfig.MaxConnLifetime = cfg.MaxConnLifetime
	}
	if cfg.MaxConnIdleTime > 0 {
		poolConfig.MaxConnIdleTime = cfg.MaxConnIdleTime
	}
	if cfg.HealthCheckPeriod > 0 {
		poolConfig.HealthCheckPeriod = cfg.HealthCheckPeriod
	}

	// Set strict fallback timeouts for network safety
	connectTimeout := cfg.ConnectTimeout
	if connectTimeout == 0 {
		connectTimeout = 5 * time.Second
	}
	poolConfig.ConnConfig.ConnectTimeout = connectTimeout

	pingTimeout := cfg.PingTimeout
	if pingTimeout == 0 {
		pingTimeout = 3 * time.Second
	}

	// Industry Standard: Wire slog into pgx tracer logs
	// This automatically pipes internal query issues and pool warnings into your structured logger
	poolConfig.ConnConfig.Tracer = &tracelog.TraceLog{
		LogLevel: tracelog.LogLevelWarn, // Log warnings and errors by default
		Logger: tracelog.LoggerFunc(func(ctx context.Context, level tracelog.LogLevel, msg string, data map[string]any) {
			attrs := make([]any, 0, len(data))
			for k, v := range data {
				attrs = append(attrs, slog.Any(k, v))
			}

			// Map pgx levels to Go's structured slog levels
			switch level {
			case tracelog.LogLevelError:
				logger.ErrorContext(ctx, msg, attrs...)
			case tracelog.LogLevelWarn:
				logger.WarnContext(ctx, msg, attrs...)
			case tracelog.LogLevelInfo:
				logger.InfoContext(ctx, msg, attrs...)
			default:
				logger.DebugContext(ctx, msg, attrs...)
			}
		}),
	}

	logger.InfoContext(ctx, "initializing database connection pool...")

	// Use a bounded context pool creation for prevent infinite hanging
	createCtx, cancel := context.WithTimeout(ctx, connectTimeout)
	defer cancel()

	pool, err := pgxpool.NewWithConfig(createCtx, poolConfig)
	if err != nil {
		return nil, fmt.Errorf("unable to create connection pool: %w", err)
	}

	// Ping verification remains safe and structured
	pingCtx, cancel := context.WithTimeout(ctx, pingTimeout)
	defer cancel()

	if err := pool.Ping(pingCtx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("unable to ping database: %w", err)
	}

	return pool, nil
}
