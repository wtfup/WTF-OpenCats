# WTF-OpenCats AWS footprint

Everything this project owns, in AWS account **246814138703** (`wtf-labs`),
region **ap-south-1**. Nothing outside this list belongs to WTF-OpenCats.

| Resource | ID | Purpose |
|---|---|---|
| EC2 instance | `i-0bc921f273f40cf6e` (t3.small) | the whole stack: Caddy + php-fpm + MariaDB |
| EBS volume | `vol-0a3126abdce36a6c0` (30 GB gp3) | root + `/srv/cats` state |
| Elastic IP | `13.232.227.134` (`eipalloc-092bc08745729de51`) | `careers.wtfgyms.com` target |
| Security group | `sg-0c9e5fdee056ad058` | 80/443 world, 22 office IP only |
| S3 bucket | `wtf-opencats-attachments-246814138703` | nightly backups + deploy artifacts |
| IAM role | `wtf-opencats-deploy` | GitHub Actions deploy, SSM SendCommand to the one instance |
| OIDC provider | `token.actions.githubusercontent.com` | trust anchor for the above |
| Route53 record | `careers.wtfgyms.com` A | **lives in account 835303655371**, not here |

Roughly ₹1,300/month, essentially all of it the t3.small.

## Not ours — do not touch

These share the account but belong to other WTF projects. They are the bulk of
the account's bill and none of them serve WTF-OpenCats:

- `nat-0868bcfd956b574e7` — wtf360-dev
- `wtf360-dev-shared` (RDS) — wtf360-dev
- `metaboliq-dev` (ALB, live targets) — metaboliq
- `i-0996905984afb3d26` (atlas-cmms) — atlas-cmms
- unassociated Elastic IPs — owner unconfirmed
- buckets `metaboliq-dev-*`, `wtf-cmms-*`, `wtf360-tofu-state-dev`

The OpenCATS instance sits in its own VPC (`vpc-029275e64229accad`) and uses none
of the shared networking above, so it can be rebuilt or destroyed without
touching any other project.

## Cost controls in place

- S3 lifecycle: `backups/` expire at 90 days; noncurrent versions at 30 days;
  incomplete multipart uploads aborted at 7 days. Without this the nightly dump
  plus versioning would grow without bound as resumes accumulate.
- `backup.sh` prunes its own local copies under `/srv/cats/backups` after 7 days.
