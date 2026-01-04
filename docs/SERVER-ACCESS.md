# Server Access Guide

**Last Updated:** 2026-01-04

## SSH Connection

```bash
ssh magi-archive
```

Or explicitly:
```bash
ssh -i ~/.ssh/magi-archive-key.pem ubuntu@54.219.9.17
```

### SSH Config (~/.ssh/config)

```
Host magi-archive
    HostName 54.219.9.17
    User ubuntu
    IdentityFile ~/.ssh/magi-archive-key.pem
    IdentitiesOnly yes
```

---

## AWS Security Group - SSH Access

SSH access is restricted by IP address in AWS Security Groups.

### If Locked Out (IP Changed)

1. Go to **AWS Console** → EC2 → Security Groups
   - https://console.aws.amazon.com/ec2/
2. Find the security group for your EC2 instance
3. Click **Inbound rules** tab → **Edit inbound rules**
4. Find the SSH rule (port 22) and update the **Source** to your new IP
   - Format: `YOUR.IP.ADDRESS/32` (e.g., `24.6.158.138/32`)
5. Click **Save rules**

### Adding Team Member SSH Access

1. Go to AWS Console → EC2 → Security Groups
2. Edit Inbound rules → **Add rule**:
   - Type: `SSH`
   - Port: `22`
   - Source: `THEIR.IP.ADDRESS/32`
   - Description: "Team member name"
3. Save rules
4. Share the SSH key (`magi-archive-key.pem`) securely with the team member

---

## Server Details

| Item | Value |
|------|-------|
| **IP Address** | 54.219.9.17 |
| **User** | ubuntu |
| **SSH Key** | ~/.ssh/magi-archive-key.pem |
| **OS** | Ubuntu 22.04 LTS |
| **Region** | us-west-1 |

---

## Services Running

| Service | Port | Access |
|---------|------|--------|
| SSH | 22 | Restricted by IP (AWS Security Group) |
| HTTP | 80 | Public (redirects to HTTPS) |
| HTTPS | 443 | Public (Cloudflare proxy) |
| Decko (Rails) | 3000 | Internal only (via nginx) |
| MCP Server | 3002 | Internal only (via nginx) |

---

## Security Features Enabled

- [x] **fail2ban** - Auto-bans IPs after failed SSH attempts
- [x] **UFW Firewall** - Only ports 22, 80, 443 allowed
- [x] **Cloudflare SSL** - Full (Strict) mode with Origin Certificate
- [x] **SSH Key Auth** - Password authentication disabled

---

## Useful Commands

```bash
# Check service status
sudo systemctl status magi-archive
sudo systemctl status nginx

# View logs
sudo journalctl -u magi-archive -f
tail -f /home/ubuntu/magi-archive/log/production.log

# Restart services
sudo systemctl restart magi-archive
sudo systemctl restart nginx

# Check firewall status
sudo ufw status verbose

# Check fail2ban status
sudo fail2ban-client status sshd
```

---

## Pending Security Tasks

### Credential Rotation (TODO)

The following credentials were potentially exposed and should be rotated:

1. **SendGrid API Key**
   - Location: `/home/ubuntu/magi-archive/.env.production`
   - Action: Generate new API key in SendGrid dashboard, update `.env.production`
   - SendGrid Dashboard: https://app.sendgrid.com/settings/api_keys

2. **Database Password** (if exposed)
   - Location: `/home/ubuntu/magi-archive/.env.production`
   - Action: Update in AWS RDS console, then update `.env.production`

After rotating credentials:
```bash
# Restart the application to pick up new credentials
sudo systemctl restart magi-archive
```

### API Key Authentication (Future Enhancement)

The MCP API supports API key authentication as an alternative to username/password.
This is a lower priority improvement that could be implemented later:

**Benefits:**
- No plaintext passwords in `.env` files
- Per-user rate limits and usage tracking
- Can revoke access without changing passwords

**To implement:**
1. Generate API keys via Rails console or admin API
2. Update MCP client `.env` to use `MCP_API_KEY` instead of `MCP_USERNAME`/`MCP_PASSWORD`
3. See `mod/mcp_api/lib/mcp/api_key_manager.rb` for implementation details
