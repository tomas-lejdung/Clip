package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/tomas-lejdung/Clip/server/internal/config"
	httpapi "github.com/tomas-lejdung/Clip/server/internal/http"
)

var version = "development"

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	if err := run(logger); err != nil {
		logger.Error("server stopped", "error", err)
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	configuration, err := config.FromEnvironment(version)
	if err != nil {
		return fmt.Errorf("configuration: %w", err)
	}
	flag.StringVar(&configuration.Address, "address", configuration.Address, "HTTP listen address")
	flag.Parse()
	if err := configuration.Validate(); err != nil {
		return fmt.Errorf("configuration: %w", err)
	}

	service, err := httpapi.New(configuration, logger)
	if err != nil {
		return fmt.Errorf("initialize service: %w", err)
	}
	server := httpapi.HTTPServer(configuration, service.Handler())
	serverErrors := make(chan error, 1)
	go func() {
		logger.Info("Clip Live Share server listening", "address", configuration.Address, "version", configuration.ServerVersion)
		serverErrors <- server.ListenAndServe()
	}()

	signalContext, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	select {
	case err := <-serverErrors:
		service.Close()
		if !httpapi.IsExpectedServerClose(err) {
			return err
		}
		return nil
	case <-signalContext.Done():
	}

	shutdownContext, cancel := context.WithTimeout(context.Background(), configuration.ShutdownTimeout)
	defer cancel()
	serverShutdown := make(chan error, 1)
	go func() {
		serverShutdown <- httpapi.Shutdown(shutdownContext, server)
	}()
	if err := service.Shutdown(shutdownContext); err != nil {
		return fmt.Errorf("service shutdown: %w", err)
	}
	if err := <-serverShutdown; err != nil {
		return err
	}
	if err := <-serverErrors; !httpapi.IsExpectedServerClose(err) {
		return err
	}
	logger.Info("Clip Live Share server stopped")
	return nil
}
