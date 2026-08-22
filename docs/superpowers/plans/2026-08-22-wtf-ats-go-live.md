# WTF-OpenCats Go-Live Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Take the deployed WTF-OpenCats ATS from "working but stock-branded on an IP" to "WTF-branded, TLS-secured, backed up, and continuously deployable at careers.wtfgyms.com".

**Architecture:** Single t3.small EC2 in ap-south-1 running docker-compose (Caddy → php-fpm 8.4 → MariaDB 11). All mutable state on the host under `/srv/cats`, bind-mounted in. Career-portal branding lives entirely in DB rows (`career_portal_template_site`), so it is data, not code. Deployment is GitHub Actions → SSM RunShellScript → `git pull && docker compose up -d`.

**Tech Stack:** AWS EC2/S3/IAM/Route53/SSM, Docker Compose, Caddy 2 (auto-TLS), MariaDB 11, PHP 8.4, GitHub Actions with OIDC.

**Spec:** Derived from live session requirements — replace the static careers.wtfgyms.com landing page with the ATS careers portal, use S3 for storage, harden security, minimal infra, easy future updates.

## Global Constraints

- AWS profile `wtf-labs`, account `246814138703`, region `ap-south-1`.
- DNS zone `wtfgyms.com` (`Z038481734ITCB3JZU9FB`) lives in a DIFFERENT account, `835303655371` — use profile `default` for Route53 only.
- Instance `i-0bc921f273f40cf6e`, Elastic IP `13.232.227.134`.
- S3 bucket `wtf-opencats-attachments-246814138703` — public access blocked, SSE-S3, versioned, TLS-enforced.
- **CPL licence:** `lib/TemplateUtility.php:873-884` requires "Powered by OpenCATS" to remain "clearly legible on every rendered HTML document". Every template MUST retain it. Do not strip it without legal sign-off.
- Brand tokens (extracted from the live careers page): bg `#0b0b0d`, surfaces `#16161a` / `#1a1a1f`, border `#2a2a31`, accent `#ff5a1f`, accent-hover `#ff7a45`, text `#f4f4f2`, muted `#8a8a86`. Display font `'Arial Black','Helvetica Neue',Helvetica,Arial,sans-serif`.
- Never commit `config.php` — it holds DB credentials and is tracked upstream.
- Rollback for the DNS swap: the previous page is backed up; the CloudFront distribution `E2PSOKNRTO50EB` and bucket `careers-wtfgyms-835303655371` are left intact, so reverting is a single Route53 UPSERT back to the ALIAS.

---

### Task 1: Brand the career portal

**Files:**
- Create: `docs/careers-template/wtf-portal.sql` (idempotent seed for `career_portal_template_site`)
- Verify against: `modules/careers/CareersUI.php` (token contract), `lib/CareerPortal.php:40-52` (required template field list)

**Interfaces:**
- Consumes: token contract from `CareersUI.php` — `<searchResultsTable>`, `<numberOfOpenPositions>`, `<siteName>`, `<title>`, `<location>`, `<description>`, `<type>`, `<created>`, `<a-LinkMain>`, `<a-ListAll>`, `<applyContent>`, `<input-*>`, `<input-submit>`, `<questionnaire>`.
- Produces: a template row set under `career_portal_name = 'WTF Gyms'`, activated via the `activeBoard` row in `settings` (`settings_type = 4`).

- [ ] **Step 1: Confirm the required field list** — all 11 names in `CareerPortalSettings::$requiredTemplateFields` must exist or `getTemplate()` fills them with `''` and the page renders blank sections.
- [ ] **Step 2: Write the SQL seed** with `Header`, `Footer`, `CSS`, `Content - Main`, `Content - Search Results`, `Content - Job Details`, `Content - Apply for Position`, `Content - Thanks for your Submission`, `Content - Questionnaire`, `Content - Candidate Registration`, `Content - Candidate Profile`. CSS must target the generated markup: `table.sortable`, `tr.rowHeading`, `tr.evenTableRow`, `tr.oddTableRow`.
- [ ] **Step 3: Upload via S3** (SSM mangles large quoted payloads) and load with `mariadb < file`.
- [ ] **Step 4: Flip `activeBoard`** to `WTF Gyms`.
- [ ] **Step 5: Verify** — fetch `/careers/`, assert HTTP 200, WTF colours present, "Powered by OpenCATS" present, no `<` token left unsubstituted.
- [ ] **Step 6: Screenshot** and compare against the backed-up original.
- [ ] **Step 7: Commit** the SQL seed.

---

### Task 2: Seed real job orders

**Files:** none (data only)

**Rationale:** An empty job board is a worse public page than the static one regardless of styling. The swap is not safe until there is at least one live opening.

- [ ] **Step 1:** Create company "WTF Gyms" and departments per centre (`company_department`) — this is the multi-location model chosen over a schema change, because `joborder.company_department_id` already ships and the portal already renders it behind the `showDepartment` setting.
- [ ] **Step 2:** Create job orders for the six known role families: Personal Trainer, Group Fitness Instructor, Membership & Sales, Front Desk, Club Manager, Area/Regional Manager. Status must be in `JobOrderStatuses::getShareStatusSQL()` (`Active`) and `public = 1`, else they will not appear.
- [ ] **Step 3:** Verify each appears on `/careers/` and its detail page loads.

---

### Task 3: DNS cutover + TLS

**Files:** `/opt/opencats/docker/.env` on the instance (`SITE_ADDRESS`)

- [ ] **Step 1:** Route53 UPSERT `careers.wtfgyms.com` A → `13.232.227.134`, TTL 60 (profile `default`).
- [ ] **Step 2:** Wait for propagation; confirm `dig +short careers.wtfgyms.com` returns the EIP.
- [ ] **Step 3:** Set `SITE_ADDRESS=careers.wtfgyms.com` in `.env`, restart Caddy so ACME HTTP-01 can complete.
- [ ] **Step 4:** Verify `https://careers.wtfgyms.com/` returns 200 with a valid Let's Encrypt cert and 443 is open.
- [ ] **Step 5:** Re-verify every security block over HTTPS (`/attachments/`, `/config.php`, `/installtest.php` → 404).

---

### Task 4: Nightly backups to S3

**Files:**
- Create: `docker/backup.sh` (in repo), installed to `/srv/cats/backup.sh`

- [ ] **Step 1:** Write `backup.sh` — `mysqldump` via `docker compose exec -T mariadb`, tar of `/srv/cats/attachments` and `config.php`, upload to `s3://wtf-opencats-attachments-246814138703/backups/`, prune local copies older than 7 days.
- [ ] **Step 2:** Install and `chmod 700`; add root crontab entry at 02:00 IST (20:30 UTC).
- [ ] **Step 3:** Run once manually and verify objects land in S3 (`aws s3 ls`).
- [ ] **Step 4:** Prove restorability — list the dump, confirm non-zero size and that it contains `CREATE TABLE`.
- [ ] **Step 5:** Commit `backup.sh`.

---

### Task 5: CI/CD via GitHub Actions + SSM

**Files:**
- Create: `.github/workflows/deploy.yml`

**Rationale:** Not CodePipeline (≈$1/mo plus CodeBuild + artifact bucket + IAM to accomplish `git pull` on one box). Not Azure DevOps (code is on GitHub; splitting CI across clouds for one PHP box is worse). SSM means **no SSH key in CI secrets**.

- [ ] **Step 1:** Create IAM OIDC provider for GitHub + role `wtf-opencats-deploy` trusted to `repo:wtfup/WTF-OpenCats:ref:refs/heads/master`, permissions limited to `ssm:SendCommand` on that one instance and the `AWS-RunShellScript` document.
- [ ] **Step 2:** Write the workflow — on push to master, assume the role, `ssm send-command` running `git pull && docker compose -f docker-compose.prod.yml up -d --build`, then poll for success and fail the job on non-Success.
- [ ] **Step 3:** Verify with a trivial commit that the workflow completes and the box moves to the new SHA.
- [ ] **Step 4:** Document rollback: `git checkout <sha> && docker compose up -d`.

---

## Self-Review

**Spec coverage:** replace careers page → Tasks 1-3. Use S3 → bucket done + Task 4. Fix security → done pre-plan (`8bbd006`) + Task 3 Step 5 re-verification. Minimal infra → single EC2, no ALB/RDS/Fargate. Easy future updates → Task 5.

**Known gap deliberately deferred:** a native S3 storage adapter inside `Attachments`/`FileUtility` (8+ call sites). Résumés stay on EBS with S3 backup; the security issue is solved at the web-server layer, which is where it actually lives.

**Ordering constraint:** Task 3 MUST come after Tasks 1 and 2 — swapping DNS to an unbranded or empty job board is a visible downgrade from the current live page.
