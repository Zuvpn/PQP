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
