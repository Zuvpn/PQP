# PQP v1 — راهنمای کامل نصب و راه‌اندازی (Iran ⇄ Kharej)

نسخه: **v1**  
تاریخ: 2026-02-21

---

## PQP چیه و چه کاری انجام می‌ده؟
PQP (Paqet Quick Panel) یک اسکریپت مدیریتی برای نصب، تنظیم و مدیریت تانل **Paqet روی KCP** بین دو سرور است:
- **سرور خارج (Kharej)** → نقش **Server**
- **سرور ایران (Iran)** → نقش **Client** (کلاینت، همراه با SOCKS و Forward)

هدف: ساخت یک تونل پایدار و سریع، با **Auto MTU هوشمند** و قابلیت **Adaptive MTU** برای کاهش fragmentation و نویز مسیر.

---

## پیش‌نیازها
- سیستم‌عامل لینوکسی (Ubuntu/Debian پیشنهاد می‌شود)
- دسترسی `root` یا `sudo`
- هر دو سرور اینترنت فعال داشته باشند
- پورت(های) تانل روی سرور خارج باز باشد (Firewall/Security Group)

> معماری شما طبق صحبت‌ها: **xray روی خارج** و سرورها **amd64**.

---

## نصب (روی هر دو سرور)
روی **هر دو سرور ایران و خارج** این دستورها را اجرا کن:

```bash
wget https://raw.githubusercontent.com/Zuvpn/PQP/main/install.sh
chmod +x install.sh
sudo bash install.sh
```
بعد از نصب:
```bash
sudo pqp
```

---

## سناریوی استاندارد: راه‌اندازی تانل بین خارج و ایران

### مرحله 1) روی سرور خارج (Kharej) — ساخت Server Tunnel
1) وارد منو شو:
```bash
sudo pqp
```
2) گزینه **2) Create/Update tunnel (Wizard Pro)** را انتخاب کن  
3) به سوال Location جواب بده:  
- `kharej`

4) مثال مقادیر:
- `KEY`: یک رمز مشترک (همین KEY باید روی ایران هم یکی باشد)
- `PROFILE`: `balanced`
- `LISTEN_PORT`:
  - تک‌پورت: `9999`
  - چندپورت: `9999,8888,7777`

5) در پایان اگر پرسید Start services now؟ → `y`

✅ چک وضعیت:
```bash
sudo pqp --status
systemctl status paqet@9999 --no-pager -l
```

---

### مرحله 2) روی سرور ایران (Iran) — ساخت Client Tunnel
1) منو:
```bash
sudo pqp
```
2) گزینه 2 ویزارد  
3) Location:  
- `iran`

4) مثال مقادیر:
- `SERVER_IP`: آی‌پی خارج (مثلاً `45.92.219.224`)
- `SERVER_PORT`: پورت‌های تانل خارج
  - مثال: `9999` یا `9999,8888`
- `SOCKS_PORT`: پیش‌فرض `1080`
- `FORWARDS` (اختیاری):
  - فرمت: `IR_LISTEN_PORT:DEST_HOST:DEST_PORT`
  - مثال: `443:127.0.0.1:4000,8443:127.0.0.1:4001`

5) MTU پیشنهادی:
- `AUTO_MTU=1`
- `MTU_RUNS=3`
- `MTU_CAP=0`

6) Start services now؟ → `y`

✅ چک وضعیت:
```bash
sudo pqp --status
systemctl status paqet@9999 --no-pager -l
```

---

## Forwarding چند پورت (روی ایران)
در `FORWARDS` تعریف کن:

```env
FORWARDS="443:127.0.0.1:4000,8443:127.0.0.1:4001"
```

سرویس‌های ساخته‌شده:
- `pqp-forward@443`
- `pqp-forward@8443`

✅ وضعیت:
```bash
systemctl status pqp-forward@443 --no-pager -l
```

---

## پروفایل‌ها
- **low-traffic**: کم‌مصرف‌تر
- **balanced**: تعادل
- **max-speed**: سریع‌تر با overhead بیشتر

بعد از تغییر:
```bash
sudo pqp --gen
sudo pqp --restart
```

---

## Smart Auto MTU و MTU_CAP
### Auto MTU ضد نویز
- `MTU_RUNS=2 یا 3`
- `MTU_MEDIAN=1`

### MTU_CAP (سقف امن)
```env
MTU_CAP=1370
```

---

## Adaptive MTU (کاهش خودکار MTU_CAP در صورت fragmentation)
اجرای دستی:
```bash
sudo pqp --adapt-mtu
```

کرون (هر 6 ساعت):
```bash
sudo pqp --cron-on
```
خاموش:
```bash
sudo pqp --cron-off
```

---

## راهنمای کامل CLI (همه مراحل)
```bash
sudo pqp --wizard
sudo pqp --gen
sudo pqp --start
sudo pqp --restart
sudo pqp --stop
sudo pqp --status
sudo pqp --adapt-mtu
sudo pqp --cron-on
sudo pqp --cron-off
```

---

## عیب‌یابی سریع

### سرویس بالا نمیاد
```bash
sudo pqp --status
journalctl -u paqet@9999 -n 80 --no-pager
```
دلایل رایج:
- KEY یکسان نیست
- پورت خارج باز نیست
- هنوز کانفیگ نساختی (`--gen`)

### Auto MTU می‌گه DF ping blocked
اسکریپت خودش fallback می‌کند؛ مشکلی نیست.

---

## محل فایل‌ها
- `/etc/pqp/pqp.env`
- `/etc/paqet/paqet_<port>.yaml`

ادیت دستی:
```bash
sudo nano /etc/pqp/pqp.env
sudo pqp --gen
sudo pqp --restart
```

---

## حذف کامل
از منو: **Uninstall everything**  
یا دستی:
```bash
sudo rm -rf /etc/pqp /etc/paqet /opt/paqet
sudo rm -f /usr/local/sbin/pqp /usr/local/bin/paqet
sudo systemctl daemon-reload
```

---

## چک‌لیست سریع
- [ ] خارج: Wizard → kharej → LISTEN_PORT → Start
- [ ] ایران: Wizard → iran → SERVER_IP/PORT → Start
- [ ] Status هر دو طرف OK
- [ ] در صورت نیاز: `--adapt-mtu` و `--cron-on`
