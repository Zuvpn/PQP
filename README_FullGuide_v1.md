# PQP v1 — Full Setup Guide

Version: v1
Date: 2026-02-21

======================================

## Complete Flow

1) Install on both servers
2) Configure Kharej (Server)
3) Configure Iran (Client)
4) Verify services
5) Optimize MTU (Optional)
6) Enable Cron (Optional)

======================================

## CLI Reference

sudo pqp --wizard      # Interactive setup
sudo pqp --gen         # Generate config
sudo pqp --start       # Start services
sudo pqp --restart     # Restart services
sudo pqp --stop        # Stop services
sudo pqp --status      # Show status
sudo pqp --adapt-mtu   # Adaptive MTU
sudo pqp --cron-on     # Enable MTU cron
sudo pqp --cron-off    # Disable cron

======================================

## Example Multi-Port Setup

Kharej:
LISTEN_PORT=9999,8888

Iran:
SERVER_PORT=9999,8888

======================================

## Profiles

low-traffic → Lower bandwidth overhead
balanced    → Recommended
max-speed   → Higher speed, higher overhead

======================================

## Traffic Overhead (Approx)

low-traffic: 5%
balanced: 10%
max-speed: 20–25%

======================================
