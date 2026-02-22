# PQP Tunnel (Zuvpn/PQP)

## Iran ↔ Foreign KCP Tunnel Manager

------------------------------------------------------------------------

# 🇬🇧 English Guide

## Overview

PQP is an automated manager for **paqet (KCP UDP tunnel)** designed for
stable Iran ↔ Foreign routing.

Features:

-   Deterministic KCP key generation
-   Automatic Router MAC detection
-   SOCKS5 proxy support
-   TCP forward support
-   Port conflict protection
-   systemd service management
-   Adaptive MTU tuning

------------------------------------------------------------------------

## Architecture

Iran (Client) ---\> KCP (UDP) ---\> Foreign (Server)

Iran provides SOCKS5 proxy.\
Foreign relays encrypted KCP packets.

------------------------------------------------------------------------

# Installation (Both Servers)

``` bash
curl -fsSL https://raw.githubusercontent.com/Zuvpn/PQP/main/install.sh | sudo bash
sudo pqp
```

------------------------------------------------------------------------

# Foreign Server Setup (ROLE = server)

Wizard Inputs:

-   Role: server
-   Listen Port: 2053
-   Profile: balanced
-   KEY: same on both servers

Open firewall:

``` bash
sudo ufw allow 2053/udp
```

Check:

``` bash
sudo systemctl status paqet@2053
sudo ss -lunp | grep 2053
```

------------------------------------------------------------------------

# Iran Server Setup (ROLE = client)

Wizard Inputs:

-   Role: client
-   Server IP: Foreign IP
-   Server Port: 2053
-   SOCKS Port: 80 (or 1080)

Test:

``` bash
curl --proxy socks5h://127.0.0.1:80 https://api.ipify.org
```

Should return Foreign IP.

------------------------------------------------------------------------

# MTU Settings Explained

  Setting             Description                        Recommended
  ------------------- ---------------------------------- -------------
  MTU                 Base tunnel MTU size               1350
  AUTO_MTU            Automatically detect optimal MTU   1 (enabled)
  MTU_MARGIN          Safety buffer below detected MTU   90
  MTU_MIN_PAYLOAD     Minimum payload size               1200
  MTU_MAX_PAYLOAD     Maximum payload size               1472
  MTU_FALLBACK_MODE   Fallback behavior if packet loss   auto
  MTU_RUNS            Number of MTU test attempts        3
  ADAPTIVE_MTU        Enable dynamic MTU adjustment      1
  ADAPT_STEP          Adjustment step size               12
  ADAPT_MIN_MTU       Minimum adaptive MTU               1200

### MTU Recommendation

-   Most VPS providers → 1350 works perfectly.
-   If packet loss → reduce to 1300.
-   If stable and low latency → can try 1380--1400.

------------------------------------------------------------------------

# Router MAC Auto Detection

Script automatically:

1.  Detects default gateway
2.  Pings gateway
3.  Reads ARP table
4.  Uses arping fallback

If detection fails:

``` bash
ip route show default
ping -c1 GATEWAY_IP
ip neigh show dev eth0
```

Example:

45.43.92.1 lladdr 28:99:3a:0c:5e:07 REACHABLE

Then edit:

``` bash
sudo nano /etc/paqet/paqet_2053.yaml
```

Set:

router_mac: "28:99:3a:0c:5e:07"

Restart:

``` bash
sudo systemctl restart paqet@2053
```

------------------------------------------------------------------------

# Port Conflict Protection

If SOCKS_PORT conflicts with forward ports:

-   Script disables pqp-forward@PORT
-   Masks service
-   Kills socat if running

------------------------------------------------------------------------

# Health Check

``` bash
curl --proxy socks5h://127.0.0.1:80 https://ifconfig.me
```

------------------------------------------------------------------------

------------------------------------------------------------------------

# 🇮🇷 راهنمای فارسی

## معرفی

PQP یک اسکریپت مدیریت تونل KCP (paqet) برای ارتباط پایدار بین سرور ایران
و خارج است.

ویژگی‌ها:

-   تولید خودکار KCP_KEY
-   تشخیص خودکار Router MAC
-   مدیریت SOCKS5
-   جلوگیری از تداخل پورت
-   تنظیم خودکار MTU

------------------------------------------------------------------------

## معماری

ایران (کلاینت) ---\> KCP (UDP) ---\> خارج (سرور)

ایران پروکسی SOCKS می‌دهد و خارج بسته‌ها را عبور می‌دهد.

------------------------------------------------------------------------

# نصب (روی هر دو سرور)

``` bash
curl -fsSL https://raw.githubusercontent.com/Zuvpn/PQP/main/install.sh | sudo bash
sudo pqp
```

------------------------------------------------------------------------

# تنظیم سرور خارج

-   Role = server
-   Listen Port = 2053
-   KEY یکسان با ایران

باز کردن پورت:

``` bash
sudo ufw allow 2053/udp
```

------------------------------------------------------------------------

# تنظیم سرور ایران

-   Role = client
-   Server IP = آی‌پی خارج
-   SOCKS Port = 80 یا 1080

تست:

``` bash
curl --proxy socks5h://127.0.0.1:80 https://api.ipify.org
```

باید آی‌پی خارج نمایش داده شود.

------------------------------------------------------------------------

# توضیح جدول MTU

  تنظیم          توضیح                     مقدار پیشنهادی
  -------------- ------------------------- ----------------
  MTU            اندازه بسته تونل          1350
  AUTO_MTU       تشخیص خودکار MTU          فعال (1)
  MTU_MARGIN     فاصله ایمن از حداکثر      90
  ADAPTIVE_MTU   تنظیم پویا                فعال
  ADAPT_STEP     مقدار تغییر در هر مرحله   12

### پیشنهاد عملی

-   بیشتر VPSها → 1350 عالی است.
-   اگر قطعی داشتید → 1300 تست کنید.
-   اگر پایدار بود → 1380 تست کنید.

------------------------------------------------------------------------

# اگر MAC تشخیص داده نشد

دستورها:

``` bash
ip route show default
ping -c1 GATEWAY_IP
ip neigh show dev eth0
```

مقدار MAC را در فایل کانفیگ وارد کنید:

    router_mac: "xx:xx:xx:xx:xx:xx"

ری‌استارت:

``` bash
sudo systemctl restart paqet@2053
```

------------------------------------------------------------------------

# تست سلامت نهایی

``` bash
curl --proxy socks5h://127.0.0.1:80 https://ifconfig.me
```

اگر آی‌پی خارج برگشت، تونل سالم است.

------------------------------------------------------------------------

GitHub: https://github.com/Zuvpn/PQP
