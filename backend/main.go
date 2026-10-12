package main

import (
	"agent-conductor/backend/config"
	"agent-conductor/backend/controllers"
	"agent-conductor/backend/database"
	"agent-conductor/backend/service"
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	c, err := config.Load()
	if err != nil {
		log.Fatal(err)
	}
	db, err := database.Open(c.DatabaseURL)
	if err != nil {
		log.Fatal("database initialization failed")
	}
	if len(os.Args) == 2 && os.Args[1] == "--create-user" {
		// Secrets are read from environment/stdin by the provisioning tool, never command-line arguments.
		if _, err := (service.Auth{DB: db}).CreateUser(context.Background(), os.Getenv("CONDUCTOR_USER_EMAIL"), os.Getenv("CONDUCTOR_USER_PASSWORD")); err != nil {
			log.Fatal(err)
		}
		fmt.Println("Account created")
		return
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		tick := time.NewTicker(15 * time.Minute)
		defer tick.Stop()
		for {
			if err := (service.Relay{DB: db}).Cleanup(ctx); err != nil && ctx.Err() == nil {
				log.Print("retention cleanup failed")
			}
			select {
			case <-ctx.Done():
				return
			case <-tick.C:
			}
		}
	}()
	server := &http.Server{Addr: c.Addr, Handler: controllers.New(c, db).Router(), ReadHeaderTimeout: 10 * time.Second, ReadTimeout: 20 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 << 10}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdown)
	}()
	log.Print("Conductor relay started")
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}
