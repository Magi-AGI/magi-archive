# Security Audit Summary

**Date:** 2026-01-04
**Auditor:** Claude Code (assisted)
**Target:** Magi Archive EC2 Server + MCP API

---

## Executive Summary

A comprehensive security audit was performed on the Magi Archive infrastructure. Several vulnerabilities were identified and remediated. The server is now significantly more secure.

**Overall Status:** ✅ Improved (6 of 9 items completed)

---

## Findings and Remediation

### Completed

| # | Finding | Severity | Status | Action Taken |
|---|---------|----------|--------|--------------|
| 1 | SSH brute force attacks detected | HIGH | ✅ Fixed | Installed fail2ban (3 retries, 1hr ban) |
| 2 | Cloudflare SSL "Flexible" mode | HIGH | ✅ Fixed | Installed Origin Certificate, enabled Full (Strict) |
| 3 | UFW firewall inactive | MEDIUM | ✅ Fixed | Enabled UFW, only ports 22/80/443 allowed |
| 4 | SSH open to 0.0.0.0/0 | MEDIUM | ✅ Fixed | User restricted to specific IP in AWS Security Group |
| 5 | No API rate limiting | MEDIUM | ✅ Fixed | Added nginx rate limiting (auth: 5/s, api: 30/s) |
| 6 | .env files world-readable (644) | MEDIUM | ✅ Fixed | Changed to 600 (owner-only) |

### Deferred

| # | Finding | Severity | Status | Notes |
|---|---------|----------|--------|-------|
| 7 | SendGrid API key potentially exposed | LOW | ⏸️ Deferred | Key was displayed in terminal; rotation recommended |
| 8 | MCP uses password auth | LOW | ⏸️ Deferred | API key auth available but optional improvement |
| 9 | Google Workspace email setup | N/A | ⏳ Waiting | Application submitted, awaiting Google approval |

---

## Detailed Findings

### 1. SSH Brute Force Attacks

**Finding:** Multiple IPs attempting SSH brute force:
- 102.88.137.213 (Nigeria)
- 103.179.56.9 (Indonesia)
- 45.78.223.67 (Unknown)

**Remediation:** Installed fail2ban with SSH jail:
- 3 failed attempts = 1 hour ban
- Already banned: 102.88.137.213

**Config:** `/etc/fail2ban/jail.local`

---

### 2. Cloudflare SSL Mode

**Finding:** SSL mode was "Flexible" - traffic between Cloudflare and origin server was unencrypted (HTTP).

**Remediation:**
- Installed Cloudflare Origin Certificate (valid until 2040)
- Configured nginx for HTTPS on port 443
- User changed Cloudflare SSL mode to "Full (Strict)"

**Files:**
- `/etc/ssl/cloudflare/magi-agi.org.pem`
- `/etc/ssl/cloudflare/magi-agi.org.key`
- `/etc/nginx/sites-available/magi-archive`
- `/etc/nginx/sites-available/mcp-magi-agi`

---

### 3. UFW Firewall

**Finding:** UFW was installed but inactive. All ports were accessible.

**Remediation:** Enabled UFW with minimal rules:
```
22/tcp  ALLOW  (SSH)
80/tcp  ALLOW  (HTTP - redirects to HTTPS)
443/tcp ALLOW  (HTTPS)
Default: DENY incoming
```

Port 3000 (Decko direct) is now blocked at server level.

---

### 4. AWS Security Group SSH Access

**Finding:** SSH (port 22) was open to 0.0.0.0/0 (entire internet).

**Remediation:** User restricted SSH to their IP (24.6.158.138/32).

**Note:** Instructions documented in `docs/SERVER-ACCESS.md` for IP changes.

---

### 5. API Rate Limiting

**Finding:** No rate limiting on API endpoints. Vulnerable to brute force and DoS.

**Remediation:** Added nginx rate limiting:

| Zone | Rate | Burst | Endpoint |
|------|------|-------|----------|
| auth | 5 req/s | 10 | /api/mcp/auth |
| api | 30 req/s | 50 | /api/* |
| general | 10 req/s | 20 | Wiki pages |

**Config:** `/etc/nginx/conf.d/rate-limiting.conf`

**Verification:** Compared to actual usage (peak 5 req/s) - limits provide 6x headroom.

---

### 6. File Permissions

**Finding:** Sensitive files had overly permissive permissions:
- `.env.production`: 664 (group/world readable)
- `database.yml`: 664
- `jwt_private.pem`: 600 (OK)

**Remediation:** Changed all sensitive files to 600 (owner-only):
```bash
chmod 600 /home/ubuntu/magi-archive/.env.production
chmod 600 /home/ubuntu/magi-archive/config/database.yml
chmod 600 /home/ubuntu/magi-archive-mcp/.env
chmod 600 /home/ubuntu/magi-archive-mcp/.env.production
```

---

### 7. Credential Rotation (Deferred)

**Finding:** SendGrid API key was displayed in terminal output during audit.

**Risk:** Low - would require access to terminal history.

**Recommendation:** Rotate SendGrid API key when convenient:
1. Generate new key at https://app.sendgrid.com/settings/api_keys
2. Update `/home/ubuntu/magi-archive/.env.production`
3. Restart application

---

### 8. MCP Authentication (Deferred)

**Finding:** MCP client uses username/password stored in `.env` files.

**Current Security:**
- ✅ HTTPS encryption (credentials encrypted in transit)
- ✅ JWT RS256 tokens (short-lived)
- ✅ Rate limiting on auth endpoint
- ✅ File permissions fixed (600)

**Optional Improvement:** Switch to API key authentication:
- No plaintext passwords in config
- Per-user rate limits and tracking
- Revocable without password changes

**Status:** Low priority, documented for future.

---

## Security Checklist

### Server Hardening
- [x] fail2ban installed and active
- [x] UFW firewall enabled
- [x] SSH restricted by IP (AWS Security Group)
- [x] SSH password auth disabled (key-only)
- [x] Sensitive file permissions fixed

### Network Security
- [x] HTTPS enabled (Cloudflare Full Strict)
- [x] Origin certificate installed
- [x] Rate limiting configured
- [x] Direct port access blocked (3000, 3002)

### Application Security
- [x] JWT RS256 authentication
- [x] Role-based access control
- [x] API rate limiting
- [ ] Credential rotation (deferred)
- [ ] API key auth migration (optional)

---

## Recommendations for Future

1. **Set up monitoring/alerting** - CloudWatch alarms for unusual activity
2. **Regular security updates** - `apt upgrade` monthly
3. **Log review** - Check fail2ban and nginx logs periodically
4. **Backup verification** - Test RDS backup restoration
5. **Credential rotation** - Rotate SendGrid key, consider rotating DB password

---

## Files Modified/Created

### On Server (EC2)
- `/etc/fail2ban/jail.local` - fail2ban configuration
- `/etc/nginx/conf.d/rate-limiting.conf` - rate limit zones
- `/etc/nginx/sites-available/magi-archive` - SSL + rate limiting
- `/etc/nginx/sites-available/mcp-magi-agi` - SSL + rate limiting
- `/etc/ssl/cloudflare/magi-agi.org.pem` - SSL certificate
- `/etc/ssl/cloudflare/magi-agi.org.key` - SSL private key

### In Repository
- `docs/SERVER-ACCESS.md` - Server access documentation
- `docs/SECURITY-AUDIT-2026-01-04.md` - This file
- `docs/GOOGLE-WORKSPACE-SETUP.md` - Email setup instructions (for after approval)

---

## Appendix: Useful Commands

```bash
# Check fail2ban status
sudo fail2ban-client status sshd

# Check UFW status
sudo ufw status verbose

# Check rate limit events
sudo grep "limiting" /var/log/nginx/error.log

# Check SSL certificate
openssl x509 -in /etc/ssl/cloudflare/magi-agi.org.pem -text -noout

# View banned IPs
sudo fail2ban-client status sshd | grep "Banned IP"
```

---

## Session Summary

### Actions Taken (2026-01-04)

1. **Investigated SSH attacks** - Found brute force attempts from multiple foreign IPs
2. **Installed fail2ban** - Configured SSH jail with 3 retries, 1 hour ban; immediately banned 102.88.137.213
3. **Installed SSL certificate** - Cloudflare Origin Certificate valid until 2040
4. **Updated nginx configs** - Added HTTPS (port 443) with SSL for both wiki and MCP subdomains
5. **Enabled UFW firewall** - Restricted to ports 22, 80, 443 only
6. **Added rate limiting** - nginx rate limits for auth (5/s), API (30/s), general (10/s)
7. **Fixed file permissions** - Changed .env and database.yml to 600
8. **Analyzed API usage** - Confirmed rate limits have 6x headroom vs actual usage
9. **Created documentation** - SERVER-ACCESS.md with SSH setup, lockout recovery, team onboarding
10. **Initiated Google Workspace signup** - Application submitted, awaiting approval

### Verification Performed

- ✅ MCP API tools tested after each change - all working
- ✅ SSH connection verified after firewall changes
- ✅ SSL certificate verified with openssl
- ✅ Rate limiting confirmed with log analysis

### Time Investment

- Audit duration: ~2 hours
- Items completed: 6 of 9
- Items deferred: 2 (low priority)
- Items waiting: 1 (external dependency)

### Next Steps

1. **When Google approves:** Follow `docs/GOOGLE-WORKSPACE-SETUP.md` to configure MX records
2. **When convenient:** Rotate SendGrid API key
3. **Monthly:** Run `sudo apt update && sudo apt upgrade`
4. **Periodically:** Review fail2ban logs for attack patterns
