# PQP - Paqet Quick Panel
Advanced Tunnel Automation for Paqet (KCP)  
Version: Profiles + Smart Auto MTU + Adaptive MTU  
Generated: 2026-02-20

---

# 📦 معرفی پروژه

PQP یک اسکریپت مدیریتی حرفه‌ای برای نصب، تنظیم و مدیریت تانل Paqet بین سرور ایران و خارج است.

ویژگی‌ها:

- نصب خودکار Paqet (amd64 / arm64)
- پشتیبانی Multi-Port
- Forward خودکار چند پورت ایران به خارج
- Smart Auto MTU (Binary Search + Verify + Fallback)
- Adaptive MTU (کاهش خودکار در صورت Fragmentation)
- پروفایل آماده: low-traffic / balanced / max-speed
- کرون‌جاب هوشمند
- مدیریت کامل سرویس‌ها
- حذف کامل یا حذف فقط سرویس‌ها

---

# 🚀 نصب سریع

روی هر دو سرور (ایران و خارج):

```bash
wget https://raw.githubusercontent.com/Zuvpn/PQP/main/install.sh
chmod +x install.sh
sudo bash install.sh
sudo pqp
```

---

# 🧭 راه‌اندازی تانل بین دو سرور

## سرور خارج (Server)

1) اجرای اسکریپت:
   sudo pqp

2) Edit settings و تنظیم:

ROLE=server  
LISTEN_PORT=9999  
KEY=YOUR_SECRET_KEY  
PROFILE=balanced  

3) Apply PROFILE  
4) Generate config  
5) Start all services  

---

## سرور ایران (Client)

1) Edit settings و تنظیم:

ROLE=client  
SERVER_IP=IP_KHAREJ  
SERVER_PORT=9999  
KEY=YOUR_SECRET_KEY  
SOCKS_PORT=1080  
FORWARDS="443:127.0.0.1:4000"  
PROFILE=low-traffic  

2) Apply PROFILE  
3) Generate config  
4) Start all services  

---

# 🔁 Forward پورت‌ها

فرمت:

IR_PORT:DEST_HOST:DEST_PORT

مثال:

FORWARDS="443:127.0.0.1:4000,8443:127.0.0.1:4001"

---

# 📊 پروفایل‌ها

## low-traffic
کمترین مصرف ترافیک  
mode=normal  
window کوچک‌تر  
margin بالا  

## balanced
تعادل سرعت و مصرف  

## max-speed
بیشترین سرعت  
ممکن است 10-30٪ مصرف اضافه ایجاد کند  

---

# 🧠 Smart Auto MTU

مراحل:

1. DF Ping Binary Search
2. Verify چندباره
3. Fallback در صورت بلاک بودن ICMP
4. محاسبه kcp.mtu

فرمول:

kcp.mtu = (best_payload + 28) - MTU_MARGIN

---

# 🤖 Adaptive MTU

اگر fragmentation رخ دهد:

- MTU بررسی می‌شود
- step-down انجام می‌شود
- کانفیگ بازسازی
- سرویس ریستارت می‌شود

فعال‌سازی کرون:

sudo pqp --cron-on

---

# 📋 معرفی کامل گزینه‌های منو

1) Install/Update paqet binary  
2) Edit settings  
3) Apply PROFILE  
4) Generate config  
5) Start all services  
6) Restart all services  
7) Stop all services  
8) Status  
9) Adaptive MTU now  
10) Cron ON  
11) Cron OFF  
12) Remove services only  
13) Uninstall everything  

---

# 📈 میزان مصرف ترافیک

بدون تانل: 100٪  

با Paqet:

low-traffic ≈ 1.05x  
balanced ≈ 1.1x  
max-speed ≈ 1.2x تا 1.3x  

با MTU صحیح و profile مناسب معمولاً مصرف اضافه زیر 10٪ می‌ماند.

---

# 🛡 نکات کاهش مصرف

PROFILE=low-traffic  
MTU_MARGIN=95  
MTU_VERIFY=5  
KCP_MODE=normal  

---

# 🔥 توصیه‌های حرفه‌ای

- فعال‌سازی BBR روی هر دو سرور
- استفاده از CPU واقعی
- بررسی vnstat و iftop برای مانیتورینگ مصرف

---

# 🧹 حذف کامل

sudo pqp --uninstall

---

# ✅ نتیجه

نسخه فعلی PQP:

✔ پایدار  
✔ خودتنظیم MTU  
✔ مصرف بهینه  
✔ مناسب استفاده Production  

