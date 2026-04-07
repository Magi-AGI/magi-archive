# Google Workspace Email Setup for magi-agi.org

**Status:** Waiting for Google approval (as of 2026-01-04)

Once approved, follow these steps to complete the setup.

---

## Step 1: Verify Domain Ownership

After approval, Google will ask you to verify domain ownership.

### In Cloudflare DNS:

1. Go to **Cloudflare Dashboard** → magi-agi.org → **DNS**
2. Click **Add Record**
3. Add:
   - **Type:** `TXT`
   - **Name:** `@`
   - **Content:** `google-site-verification=XXXXX` (copy from Google Admin Console)
   - **TTL:** Auto
4. Click **Save**
5. Return to Google Admin Console and click **Verify**

**Note:** DNS propagation can take a few minutes. If verification fails, wait 5-10 minutes and try again.

---

## Step 2: Update MX Records

After domain verification, update MX records to route email to Google.

### In Cloudflare DNS:

**First, delete the existing MX record:**
- Delete: `mail.magi-agi.org` (priority 0)

**Then add Google's MX records:**

| Type | Name | Mail Server | Priority | TTL |
|------|------|-------------|----------|-----|
| MX | @ | ASPMX.L.GOOGLE.COM | 1 | Auto |
| MX | @ | ALT1.ASPMX.L.GOOGLE.COM | 5 | Auto |
| MX | @ | ALT2.ASPMX.L.GOOGLE.COM | 5 | Auto |
| MX | @ | ALT3.ASPMX.L.GOOGLE.COM | 10 | Auto |
| MX | @ | ALT4.ASPMX.L.GOOGLE.COM | 10 | Auto |

**Important:** Make sure to delete the old MX record first to avoid conflicts.

---

## Step 3: Update SPF Record

Update the SPF record to authorize both Google and SendGrid to send email.

### In Cloudflare DNS:

**Find existing TXT record with `v=spf1`** and update it, or create new:

- **Type:** `TXT`
- **Name:** `@`
- **Content:** `v=spf1 include:_spf.google.com include:sendgrid.net ~all`
- **TTL:** Auto

This allows both Google Workspace and SendGrid (used by the Decko app) to send email on behalf of magi-agi.org.

---

## Step 4: Set Up DKIM (Recommended)

DKIM adds a digital signature to emails, improving deliverability.

### In Google Admin Console:

1. Go to **Apps** → **Google Workspace** → **Gmail**
2. Click **Authenticate email**
3. Select your domain and click **Generate new record**
4. Copy the TXT record value

### In Cloudflare DNS:

- **Type:** `TXT`
- **Name:** `google._domainkey`
- **Content:** (paste the long string from Google)
- **TTL:** Auto

### Back in Google Admin Console:

1. Click **Start authentication**
2. Wait for verification (can take up to 48 hours)

---

## Step 5: Set Up DMARC (Optional but Recommended)

DMARC tells receiving servers what to do with emails that fail SPF/DKIM checks.

### In Cloudflare DNS:

- **Type:** `TXT`
- **Name:** `_dmarc`
- **Content:** `v=DMARC1; p=quarantine; rua=mailto:admin@magi-agi.org`
- **TTL:** Auto

**Policy options:**
- `p=none` - Monitor only (start here)
- `p=quarantine` - Send failures to spam
- `p=reject` - Block failures entirely

---

## Step 6: Test Email

After MX records propagate (5-60 minutes):

1. **Send a test email** from your new `@magi-agi.org` address to your Gmail
2. **Reply** to verify receiving works
3. **Check headers** to confirm DKIM/SPF pass

### Test tools:
- https://mxtoolbox.com/emailhealth/ - Check DNS records
- https://mail-tester.com/ - Test email deliverability

---

## Step 7: (Optional) Update Application Email

If you want the Decko application to send email via Google Workspace instead of SendGrid:

```bash
ssh magi-archive
sudo nano /home/ubuntu/magi-archive/.env.production
```

Update SMTP settings:
```
SMTP_ADDRESS=smtp.gmail.com
SMTP_PORT=587
SMTP_DOMAIN=magi-agi.org
SMTP_USER=noreply@magi-agi.org
SMTP_PASSWORD=<app-password>
SMTP_AUTHENTICATION=plain
SMTP_ENABLE_STARTTLS=true
```

**To get an App Password:**
1. Go to Google Admin Console → Security → App passwords
2. Generate a new app password for "Mail"
3. Use this 16-character password in SMTP_PASSWORD

Then restart the application:
```bash
sudo systemctl restart magi-archive
```

**Alternative:** Keep using SendGrid for application emails (simpler, already working).

---

## Troubleshooting

### Email not arriving
- Check MX records propagated: `nslookup -type=MX magi-agi.org`
- Verify no conflicting MX records exist
- Check spam folder

### DKIM verification failing
- Ensure TXT record name is exactly `google._domainkey`
- Wait up to 48 hours for propagation
- Check for typos in the long DKIM string

### SPF failures
- Verify SPF record includes all sending sources
- Use MXToolbox to validate SPF syntax

---

## Quick Reference: Final DNS Records

After setup, your Cloudflare DNS should have:

| Type | Name | Content |
|------|------|---------|
| TXT | @ | `google-site-verification=XXXXX` |
| TXT | @ | `v=spf1 include:_spf.google.com include:sendgrid.net ~all` |
| TXT | google._domainkey | `v=DKIM1; k=rsa; p=XXXXX...` |
| TXT | _dmarc | `v=DMARC1; p=quarantine; rua=mailto:admin@magi-agi.org` |
| MX | @ | ASPMX.L.GOOGLE.COM (priority 1) |
| MX | @ | ALT1.ASPMX.L.GOOGLE.COM (priority 5) |
| MX | @ | ALT2.ASPMX.L.GOOGLE.COM (priority 5) |
| MX | @ | ALT3.ASPMX.L.GOOGLE.COM (priority 10) |
| MX | @ | ALT4.ASPMX.L.GOOGLE.COM (priority 10) |

Plus your existing A/CNAME records for wiki, mcp, www, etc.
