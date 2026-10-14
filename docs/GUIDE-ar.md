# دليل Launchpad بالعربي

## المشروع بجملة
منصة داخلية للمطورين (IDP). بدل ما المطور يفتح تذكرة ويستنى أيام عشان ياخد environment، بيضيف ملف YAML فيه 6 أسطر، وبعد ما يعمل PR و merge بيصير عنده environment شغّال على AWS خلال دقائق.

هاد بالضبط اللي مكتوب بالـ JD:
> Reduce environment provisioning time from days to minutes through automation and self-service

---

## خطة التعلّم والتشغيل (أسبوعين)

| اليوم | شو تعمل | شو تتعلم |
|---|---|---|
| 1–2 | اقرأ `modules/network` و `modules/platform`، وشغّل `make check` | VPC و subnets و SG chaining و ALB و ECS |
| 3–4 | اقرأ `modules/service` و `live/environments` و `tests/` | `for_each` و preconditions و remote state و `terraform test` |
| 5 | افتح حساب AWS جديد (Free plan) وشغّل `bootstrap/` | OIDC و IAM trust policies و S3 backend |
| 6 | ارفع الـ repo على GitHub، وحط الـ variables، وشغّل Apply ثم Deploy SafeBrief | GitHub Actions و environments و concurrency |
| 7 | جرّب **Create environment** من تبويب Actions | self-service وفكرة الـ golden path |
| 8–9 | `scripts/kind-up.sh` وجرّب self-heal | Argo CD و ApplicationSet و sync waves و hooks |
| 10 | Datadog free trial، وشغّل observability | dashboards و monitors as code |
| 11 | اكسر شغلات عن قصد: image غلط، replicas كثير، sqlite مع worker | circuit breaker و rollback و guard rails |
| 12–14 | اكتب بوست LinkedIn، وصوّر screenshots، وحضّر الأجوبة اللي تحت | التواصل، وهاد مطلوب بالـ JD |

**بعد كل تجربة على AWS شغّل "Destroy everything"**، عشان ما تصرف الـ credits.

---

## أسئلة المقابلة المتوقعة، وجوابك من المشروع

**س: كيف بتدير Terraform state لفريق كامل؟**
عملت S3 backend فيه versioning و encryption، ومع `use_lockfile` (الـ locking الأصلي بـ S3، فما بحتاج DynamoDB). وقسمت الـ state لطبقات: platform و environments و observability، وكل طبقة بتقرأ من اللي قبلها بـ `terraform_remote_state`. الفايدة إن blast radius صغير، وتغيير environment ما بيلمس الـ VPC.

**س: كيف الـ CI بيدخل على AWS؟**
عن طريق OIDC، فما في access keys أبداً. عندي ثلاث roles: plan (read-only) لأي PR، و apply بس من الـ environment المحمي `production`، و build للـ ECR بس من `main`.

**س: كيف بتعمل self-service بدون ما المطورين يخربوا شي؟**
عندي guard rails على ثلاث طبقات. الـ JSON Schema بيرفض الأخطاء بالـ editor والـ CI، و Terraform preconditions بتفحص وقت الـ plan، و `terraform test` بيتأكد إن الـ guard rails نفسها ما انكسرت. والـ schema كمان بيمنع أي أحد يحط `APP_KEY` أو `DB_PASSWORD` بالـ YAML.

**س: ليش ما في NAT Gateway؟**
لأنه بكلّف حوالي $32 بالشهر. الـ tasks موجودة بـ public subnets، بس الـ SG تبعها ما بيستقبل غير من الـ ALB. وكتبت القرار كـ ADR، وفيه كيف تحوّل للـ production (NAT أو VPC endpoints).

**س: شو GitOps عندك؟**
الـ Git هو مصدر الحقيقة بالمكانين. بالنسبة لـ ECS، الـ deploy هو commit بيغيّر `image_tag`، وبعده Terraform apply. وبالنسبة لـ Kubernetes، في Argo CD ApplicationSet بيعمل sync لكل overlay، ومع selfHeal أي `kubectl edit` يدوي بيرجع لحاله.

**س: كيف بتعرف إنه في مشكلة؟**
عندي Datadog monitors معمولة as code لكل environment تلقائياً: 5xx rate و p95 latency و healthy hosts، ومعهم runbook مكتوب.

**س: شو رح تحسّن لو عندك وقت أكثر؟**
أعمل Backstage catalog بيقرأ ملفات الـ YAML، وأنقل الشغل لـ EKS + External Secrets، وأعمل preview env لكل PR بالـ app repo، وأضيف OPA policies على الـ plan.

---

## كلمة صريحة
قبل المقابلة لازم تكون **شغّلت كل جزء بإيدك وكسرته وصلّحته**. الـ interviewer رح يسألك "ليش؟" على كل سطر، والجواب "Claude كتبه" مش جواب. بس جواب زي "جرّبت وطلعلي الخطأ الفلاني وصلّحته هيك" بيفرق كثير.
