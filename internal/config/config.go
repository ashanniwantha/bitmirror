package config

import (
	"fmt"
	"log"
	"os"
	"strconv"
	"time"

	"github.com/joho/godotenv"
)

type Config struct {
	AppEnv  string
	AppPort int

	// Database
	DBHost     string
	DBPort     int
	DBUser     string
	DBPassword string
	DBName     string

	// Pool
	DBMaxConns          int
	DBMinConns          int
	DBMaxConnLifetime   time.Duration
	DBMaxConnIdleTime   time.Duration
	DBHealthCheckPeriod time.Duration
	DBConnectTimeout    time.Duration
	DBPingTimeout       time.Duration

	// Redis
	RedisHost        string
	RedisPort        int
	RedisPassword    string
	RedisDB          int
	RedisPingTimeout time.Duration
}

func LoadConfig() (*Config, error) {
	// Load .env if present
	if err := godotenv.Load(); err != nil {
		log.Println("No .env file found, reading from system environment variables")
	}

	cfg := &Config{
		AppEnv:  getEnv("APP_ENV", "production"),
		AppPort: getEnvAsInt("APP_PORT", 8008),

		// Database
		DBHost:     getEnv("DB_HOST", "localhost"),
		DBPort:     getEnvAsInt("DB_PORT", 5432),
		DBUser:     getEnv("DB_USER", "postgres"),
		DBPassword: os.Getenv("DB_PASSWORD"),
		DBName:     getEnv("DB_NAME", "me_myself_I"),

		// Pool
		DBMaxConns:          getEnvAsInt("DB_MAX_CONNS", 20),
		DBMinConns:          getEnvAsInt("DB_MIN_CONNS", 5),
		DBMaxConnLifetime:   getEnvAsDuration("DB_MAX_CONN_LIFETIME", 30*time.Minute),
		DBMaxConnIdleTime:   getEnvAsDuration("DB_MAX_CONN_IDLE_TIME", 5*time.Minute),
		DBHealthCheckPeriod: getEnvAsDuration("DB_HEALTH_CHECK_PERIOD", 1*time.Minute),
		DBConnectTimeout:    getEnvAsDuration("DB_CONNECT_TIMEOUT", 3*time.Second),
		DBPingTimeout:       getEnvAsDuration("DB_PING_TIMEOUT", 3*time.Second),

		// Redis
		RedisHost:        getEnv("REDIS_HOST", "localhost"),
		RedisPort:        getEnvAsInt("REDIS_PORT", 6379),
		RedisPassword:    os.Getenv("REDIS_PASSWORD"),
		RedisDB:          getEnvAsInt("REDIS_DB", 0),
		RedisPingTimeout: getEnvAsDuration("REDIS_PING_TIMEOUT", 3*time.Second),
	}

	if cfg.DBPassword == "" {
		return nil, fmt.Errorf("DB_PASSWORD is required but not set")
	}

	return cfg, nil
}

func getEnv(key, fallback string) string {
	if value, exists := os.LookupEnv(key); exists {
		return value
	}
	return fallback
}

func getEnvAsInt(key string, fallback int) int {
	valueStr := getEnv(key, "")
	value, err := strconv.Atoi(valueStr)

	if err != nil {
		return fallback
	}

	return value
}

func getEnvAsDuration(key string, fallback time.Duration) time.Duration {
	valueStr := getEnv(key, "")
	value, err := time.ParseDuration(valueStr)

	if err != nil {
		return fallback
	}

	return value
}
