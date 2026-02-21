# PQP - MTU Anti-noise + MTU_CAP

## 1) چند بار تست کامل MTU و گرفتن Median
در `pqp.env`:
- `MTU_RUNS=3`
- `MTU_MEDIAN=1`

اسکریپت تست MTU را ۳ بار انجام می‌دهد و مقدار **میانه** را انتخاب می‌کند (ضد نویز).

## 2) نگه داشتن AUTO_MTU و تعیین سقف با MTU_CAP
Adaptive MTU دیگر `AUTO_MTU=0` نمی‌کند.
به جای آن:
- `MTU_CAP` را تنظیم می‌کند
- Auto MTU همچنان فعال می‌ماند، ولی خروجی Auto هیچوقت از سقف بالاتر نمی‌رود.

مثال:
- `MTU_CAP=1370`
