package handler

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type HealthHandler struct {
	pool *pgxpool.Pool
	log  *slog.Logger
}

func NewHealthHandler(pool *pgxpool.Pool, log *slog.Logger) *HealthHandler {
	return &HealthHandler{
		pool: pool,
		log:  log,
	}
}

// Ping returns and http handler function that checks DB connectivity
func (h *HealthHandler) Ping() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()

		if err := h.pool.Ping(ctx); err != nil {
			w.WriteHeader(http.StatusServiceUnavailable)
			fmt.Fprint(w, "database unreachable")

			h.log.Error("database unreachable", "err", err)
			return
		}
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "ok")
	}
}
