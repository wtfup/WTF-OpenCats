# Transactional email — Amazon SES

WTF-OpenCats sends candidate and recruiter mail through Amazon SES using a
dedicated, least-privilege IAM user. Nothing else in the account is reachable
with those credentials.

## What sends, and to whom

| Trigger | Recipient | Subject constant |
|---|---|---|
| Candidate applies via career portal | the candidate | `CAREERS_CANDIDATEAPPLY_SUBJECT` |
| Candidate applies via career portal | job order owner / recruiter | `CAREERS_OWNERAPPLY_SUBJECT` |
| Pipeline status change | the candidate | `CANDIDATE_STATUSCHANGE_SUBJECT` |
| Calendar event reminder | the event owner | `$GLOBALS['eventReminderEmail']` |

Everything is sent **From: HR@wtfgyms.com**.

## Setup

SES lives in account **835303655371** (`--profile default`), region
**ap-south-1** — the same account and region that already runs the HR outreach
pipeline. `wtfgyms.com` was already a verified identity with DKIM verified and
production access enabled, so **no new DNS records were needed** and the domain's
existing SPF/DKIM posture is untouched.

- IAM user: `wtf-opencats-ses`
- Inline policy: `send-as-hr-wtfgyms-only`
- SMTP endpoint: `email-smtp.ap-south-1.amazonaws.com:587`, STARTTLS

The policy allows exactly `ses:SendEmail` and `ses:SendRawEmail`, only against
the `wtfgyms.com` identity, and only when the From address is HR@wtfgyms.com:

```json
"Condition": { "StringEqualsIgnoreCase": { "ses:FromAddress": "HR@wtfgyms.com" } }
```

Verified by negative test — all three of these are denied:

| Attempt | Result |
|---|---|
| Send as `HR@wtfgyms.com` | allowed |
| Send as `noreply@wtfgyms.com` | AccessDenied |
| `ses:ListIdentities` | AccessDenied |
| `s3:ListAllMyBuckets` | AccessDenied |

## The SMTP password is not the IAM secret

SES derives the SMTP password from the IAM secret key via a SigV4 HMAC chain.
Feeding the raw secret to the SMTP endpoint fails authentication. The derivation
is a small script; regenerate it if the key is ever rotated.

## Two things that were silently broken

1. **`MAIL_MAILER` was 0** — OpenCATS' "disabled" mode, with no MTA in the PHP
   container either. No mail had ever been sent: not application confirmations,
   not recruiter alerts, not status changes. Meanwhile the career portal was
   telling every applicant a confirmation email was on its way.

2. **The admin user's email was `admin@example.com`**, the stock placeholder.
   Recruiter alerts for every application would have been sent there and bounced.
   On an account that also runs a large outreach pipeline, avoidable bounces are
   not cosmetic — they push up the account bounce rate and threaten sending
   reputation for everything. Set to HR@wtfgyms.com.

## Rotating the credential

```
aws iam create-access-key --user-name wtf-opencats-ses --profile default
# derive the SMTP password, update MAIL_SMTP_USER / MAIL_SMTP_PASS in
# /srv/cats/config/config.php on the instance, then:
aws iam delete-access-key --user-name wtf-opencats-ses --access-key-id <old> --profile default
```

`config.php` is not in git and is bind-mounted from `/srv/cats/config/`, so the
credential never enters the repository or a container image.
