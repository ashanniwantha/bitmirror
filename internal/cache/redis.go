package cache

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/redis/go-redis/v9"
)

type RedisConfig struct {
	URL         string // e.g., "redis://<user>:<password>@<host>:<port>/<db>"
	Logger      *slog.Logger
	PingTimeout time.Duration
}

// Named NewRedisClient to keep things clear inside the 'cache' package
func NewRedisClient(ctx context.Context, cfg RedisConfig) (*redis.Client, error) {
	// 1. Guard against nil logger to prevent any future panics
	logger := cfg.Logger
	if logger == nil {
		logger = slog.Default()
	}

	// 2. Parse the modern connection string (handles host, port, pass, and DB automatically)
	opts, err := redis.ParseURL(cfg.URL)
	if err != nil {
		return nil, fmt.Errorf("unable to parse redis connection string: %w", err)
	}

	// 3. Set strict fallback timeouts for network safety during startup
	pingTimeout := cfg.PingTimeout
	if pingTimeout == 0 {
		pingTimeout = 3 * time.Second // industry standard fallback
	}

	logger.InfoContext(ctx, "initializing redis client...")

	client := redis.NewClient(opts)

	// 4. Ping verification remains safe and structured
	pingCtx, cancel := context.WithTimeout(ctx, pingTimeout)
	defer cancel()

	if err := client.Ping(pingCtx).Err(); err != nil {
		client.Close()
		return nil, fmt.Errorf("unable to ping redis: %w", err)
	}

	logger.InfoContext(ctx, "redis connection established successfully")
	return client, nil
}
