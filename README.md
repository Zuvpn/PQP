# PQP - Wizard Menu Update

## تغییر مورد نظر شما انجام شد
گزینه 2 در منو دیگر «Edit settings» نیست و تبدیل شد به:

**2) Create/Update tunnel (Wizard)**

این گزینه همه چیز را از کاربر می‌پرسد و خودش:
- فایل `/etc/pqp/pqp.env` را می‌سازد/آپدیت می‌کند
- PROFILE را اعمال می‌کند
- کانفیگ را تولید می‌کند
- در صورت تایید، سرویس‌ها را Start می‌کند

## نکته
اگر Adaptive MTU را قبل از Generate config بزنید، الان خودش اول کانفیگ را می‌سازد (دیگر خطای cannot read current mtu نمی‌گیرید).

## v1.1 Hotfix
- Fix شد گزینه **Install/Update paqet binary**: دانلود از GitHub با API (تشخیص asset صحیح) + اعتبارسنجی فایل (جلوگیری از Not Found/HTML/404).

## v1.1.1 Hotfix
- Fix شد نصب paqet بعد از extract: حالا اسم‌های مختلف باینری مثل `paqet_linux_amd64` را تشخیص می‌دهد و به `/usr/local/bin/paqet` نرمال می‌کند.

## v1.2 Crash-proof Hotfix
- رفع کرش‌های `unbound variable` در Auto MTU (تنظیم default برای متغیرها، median امن، pick_mtu امن) مخصوصاً روی سرور خارج.

## v1.3 Wizard Update (Iran multi-port → one tunnel port)
- Wizard روی هر دو سرور اول می‌پرسد ایران هست یا خارج.
- خارج: LISTEN_PORT + (اختیاری) IRAN_IP و امکان اعمال UFW allow.
- ایران: انتخاب یک TUNNEL_PORT (یک پورت) + انتخاب چند IRAN_IN_PORTS؛ همه‌ی پورت‌های ایران به یک DEST_PORT روی خارج فوروارد می‌شوند و FORWARDS خودکار ساخته می‌شود.

## v1.3.1 Stable
- Wizard گزینه 2 حالا همیشه ابتدا منو می‌دهد: **1) Iran (Client)** و **2) Kharej (Server)**.
- اضافه شدن تابع `is_ipv4()` و Self-check برای جلوگیری از خطاهای `command not found`.
