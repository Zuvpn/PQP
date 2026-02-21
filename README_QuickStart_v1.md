# PQP v1 — Quick Start (5 Minute Setup)

Version: v1
Date: 2026-02-21

======================================

## Architecture
Kharej Server → ROLE=server
Iran Server   → ROLE=client

======================================

## Step 1 — Install (Both Servers)

wget https://raw.githubusercontent.com/Zuvpn/PQP/main/install.sh
chmod +x install.sh
sudo bash install.sh

Then:
sudo pqp

======================================

## Step 2 — Setup Kharej (Server)

sudo pqp
→ Select Wizard
→ Location: kharej
→ KEY: same secret for both sides
→ LISTEN_PORT: 9999
→ Start services: y

Check:
systemctl status paqet@9999

======================================

## Step 3 — Setup Iran (Client)

sudo pqp
→ Wizard
→ Location: iran
→ SERVER_IP: <Kharej IP>
→ SERVER_PORT: 9999
→ AUTO_MTU: 1
→ MTU_RUNS: 3
→ Start services: y

Done ✅

======================================
