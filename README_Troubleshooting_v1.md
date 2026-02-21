# PQP v1 — Troubleshooting & FAQ

Version: v1
Date: 2026-02-21

======================================

## Service Not Starting

Check:
sudo pqp --status
journalctl -u paqet@9999 -n 100 --no-pager

Common Causes:
- KEY mismatch
- Port blocked on Kharej
- Config not generated

======================================

## Adaptive MTU Error

Fix:
sudo pqp --gen
sudo pqp --adapt-mtu

======================================

## High Traffic Usage

Solutions:
- Use low-traffic profile
- Reduce KCP_CONN to 1
- Keep MTU optimized
- Avoid unnecessary multi-port

======================================

## DF ping blocked?

Normal behavior in some routes.
Script auto-fallback will apply safe MTU.

======================================
