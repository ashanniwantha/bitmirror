package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/ashanniwantha/bitmirror/internal/cache"
	"github.com/ashanniwantha/bitmirror/internal/config"
	"github.com/ashanniwantha/bitmirror/internal/database"
	"github.com/ashanniwantha/bitmirror/internal/handler"
	"github.com/ashanniwantha/bitmirror/pkg/logger"
	"github.com/go-chi/chi/v5"
)

func main() {
	// Load ENV config
	cfg, err := config.LoadConfig()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Configuration error: %v", err)
		os.Exit(1)
	}

	log := logger.New(cfg.AppEnv)
	log.Info("starting application", "env", cfg.AppEnv, "port", cfg.AppPort)
	fmt.Printf("Database URL target: postgres://%s:***@%s:%d/%s\n",
		cfg.DBUser, cfg.DBHost, cfg.DBPort, cfg.DBName)

	// Database pool
	dsn := fmt.Sprintf("postgres://%s:%s@%s:%d/%s?sslmode=disable",
		cfg.DBUser, cfg.DBPassword, cfg.DBHost, cfg.DBPort, cfg.DBName)

	dbCfg := database.PoolConfig{
		DSN:               dsn,
		MaxConns:          cfg.DBMaxConns,
		MinConns:          cfg.DBMinConns,
		MaxConnLifetime:   cfg.DBMaxConnLifetime,
		MaxConnIdleTime:   cfg.DBMaxConnIdleTime,
		HealthCheckPeriod: cfg.DBHealthCheckPeriod,
		ConnectTimeout:    cfg.DBConnectTimeout,
		PingTimeout:       cfg.DBPingTimeout,
	}

	pool, err := database.NewPool(context.Background(), dbCfg)
	if err != nil {
		log.Error("failed to initialize database", "err", err)
		os.Exit(1)
	}
	defer pool.Close()

	log.Info("Database connected", "mode", cfg.AppEnv)

	// Format individual variables into a unified industry-standard URL
	redisURL := fmt.Sprintf("redis://:%s@%s:%d/%d",
		cfg.RedisPassword,
		cfg.RedisHost,
		cfg.RedisPort,
		cfg.RedisDB,
	)

	// Populate the updated RedisConfig struct
	redisCfg := cache.RedisConfig{
		URL:         redisURL,
		Logger:      log, // <-- Pass your *slog.Logger instance here
		PingTimeout: cfg.RedisPingTimeout,
	}

	// Call NewRedisClient from your cache package
	rdb, err := cache.NewRedisClient(context.Background(), redisCfg)
	if err != nil {
		log.Error("failed to initialize redis", "err", err)
		os.Exit(1)
	}
	defer rdb.Close()

	// Initialize the shared BaseHandler foundation once at the top
	healthH := handler.NewHealthHandler(pool, log)

	// Chi Router
	r := chi.NewRouter()

	r.Get("/health", healthH.Ping())

	// HTTP server with timeouts
	srv := &http.Server{
		Addr:         fmt.Sprintf(":%d", cfg.AppPort),
		Handler:      r,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// Start server
	go func() {
		log.Info("server starting", "addr", srv.Addr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Error("server error", "err", err)
			os.Exit(1)
		}
	}()

	// Graceful Shutdown
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	sig := <-quit
	log.Info("shutting down", "signal", sig.String())

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		log.Error("forced shutdown", "err", err)
	}

	log.Info("server stopped")

}
