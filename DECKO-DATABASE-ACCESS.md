# Accessing Decko Database via Console

**Created**: 2025-10-25
**Server**: EC2 at <REDACTED_EC2_IP>
**Application**: /home/<user>/<app-dir>

---

## Problem

When trying to run Decko commands via SSH, you'll encounter several issues:
1. **rbenv not in PATH** - Ruby isn't found by default in non-interactive shells
2. **Environment variables not loaded** - `.env.production` isn't sourced automatically
3. **Database connection fails** - Without the environment, Rails can't connect to PostgreSQL

---

## Solution: Complete Command Template

```bash
ssh -i ~/.ssh/<REDACTED_KEY>.pem ubuntu@<REDACTED_EC2_IP> 'cd /home/<user>/<app-dir> && set -a && source .env.production && set +a && PATH="/home/ubuntu/.rbenv/shims:$PATH" script/card runner '\''YOUR_RUBY_CODE_HERE'\'' '
```

### Breaking Down the Command

1. **SSH into server**:
   ```bash
   ssh -i ~/.ssh/<REDACTED_KEY>.pem ubuntu@<REDACTED_EC2_IP>
   ```

2. **Navigate to app directory**:
   ```bash
   cd /home/<user>/<app-dir>
   ```

3. **Load environment variables** (critical!):
   ```bash
   set -a                    # Export all variables set from now on
   source .env.production    # Load DATABASE_PASSWORD and other vars
   set +a                    # Stop exporting variables
   ```

4. **Add rbenv to PATH**:
   ```bash
   PATH="/home/ubuntu/.rbenv/shims:$PATH"
   ```

5. **Run Decko command**:
   ```bash
   script/card runner 'Ruby code here'
   ```

---

## Example Commands

### List All Cards (with limit)

```bash
ssh -i ~/.ssh/<REDACTED_KEY>.pem ubuntu@<REDACTED_EC2_IP> 'cd /home/<user>/<app-dir> && set -a && source .env.production && set +a && PATH="/home/ubuntu/.rbenv/shims:$PATH" script/card runner '\''Card.all.limit(20).each { |c| puts "#{c.id}: #{c.name} (#{c.type_name})" }'\'' '
```

### Count Total Cards

```bash
ssh -i ~/.ssh/<REDACTED_KEY>.pem ubuntu@<REDACTED_EC2_IP> 'cd /home/<user>/<app-dir> && set -a && source .env.production && set +a && PATH="/home/ubuntu/.rbenv/shims:$PATH" script/card runner '\''puts "Total cards: #{Card.count}"'\'' '
```

### Show Recent Cards

```bash
ssh -i ~/.ssh/<REDACTED_KEY>.pem ubuntu@<REDACTED_EC2_IP> 'cd /home/<user>/<app-dir> && set -a && source .env.production && set +a && PATH="/home/ubuntu/.rbenv/shims:$PATH" script/card runner '\''Card.order(created_at: :desc).limit(20).each { |c| puts "#{c.id}: #{c.name} (#{c.type_name})" }'\'' '
```

### Find Specific Card by Name

```bash
ssh -i ~/.ssh/<REDACTED_KEY>.pem ubuntu@<REDACTED_EC2_IP> 'cd /home/<user>/<app-dir> && set -a && source .env.production && set +a && PATH="/home/ubuntu/.rbenv/shims:$PATH" script/card runner '\''card = Card.fetch("Neoterics"); puts "#{card.id}: #{card.name} - #{card.content[0..100]}"'\'' '
```

### Search Cards by Pattern

```bash
ssh -i ~/.ssh/<REDACTED_KEY>.pem ubuntu@<REDACTED_EC2_IP> 'cd /home/<user>/<app-dir> && set -a && source .env.production && set +a && PATH="/home/ubuntu/.rbenv/shims:$PATH" script/card runner '\''Card.where("name LIKE ?", "Neoterics%").each { |c| puts "#{c.id}: #{c.name}" }'\'' '
```

### Get Top-Level Cards (no + in name)

```bash
ssh -i ~/.ssh/<REDACTED_KEY>.pem ubuntu@<REDACTED_EC2_IP> 'cd /home/<user>/<app-dir> && set -a && source .env.production && set +a && PATH="/home/ubuntu/.rbenv/shims:$PATH" script/card runner '\''Card.where.not("name LIKE ?", "%+%").order(id: :desc).limit(15).each { |c| puts "#{c.id}: #{c.name} (#{c.type_name})" }'\'' '
```

---

## Important Notes

### Quote Escaping

When running Ruby code remotely, you need **triple-level quoting**:

1. **Outer single quotes** `'...'` - For the SSH command
2. **Escaped single quotes** `'\''...'\'` - For the script/card runner argument
3. **Inner double quotes** `"..."` - For Ruby string interpolation

Example:
```bash
script/card runner '\''puts "Hello #{name}"'\''
```

### Multi-line Commands

For complex queries, you can use:

```bash
ssh -i ~/.ssh/<REDACTED_KEY>.pem ubuntu@<REDACTED_EC2_IP> 'cd /home/<user>/<app-dir> && set -a && source .env.production && set +a && PATH="/home/ubuntu/.rbenv/shims:$PATH" script/card runner '\''
  puts "=== Analysis ==="
  total = Card.count
  recent = Card.where("created_at > ?", 1.day.ago).count
  puts "Total: #{total}"
  puts "Last 24h: #{recent}"
'\'' '
```

---

## Alternative: Using Decko Console Interactively

For longer sessions, use the interactive console:

```bash
ssh -i ~/.ssh/<REDACTED_KEY>.pem ubuntu@<REDACTED_EC2_IP>

# Once logged in:
cd /home/<user>/<app-dir>
set -a && source .env.production && set +a
PATH="/home/ubuntu/.rbenv/shims:$PATH" script/card console

# Now you're in an interactive Rails console:
> Card.count
> Card.fetch("Neoterics")
> exit
```

---

## Common Errors & Solutions

### Error: `/usr/bin/env: 'ruby': No such file or directory`

**Cause**: rbenv shims not in PATH
**Solution**: Add `PATH="/home/ubuntu/.rbenv/shims:$PATH"` before command

### Error: `connection to server at "172.31.21.37", port 5432 failed: fe_sendauth: no password supplied`

**Cause**: `.env.production` not loaded, so `DATABASE_PASSWORD` is missing
**Solution**: Use `set -a && source .env.production && set +a` before command

### Error: `cat: .env.production: No such file or directory`

**Cause**: Not in the correct directory
**Solution**: Always `cd /home/<user>/<app-dir>` first

### Error: Syntax errors with quotes

**Cause**: Improper quote escaping
**Solution**: Use pattern `'\''Ruby code here'\''` for the script/card runner argument

---

## Systemd Service Configuration

The production server runs Decko via systemd, which handles environment loading automatically:

**Service file**: `/etc/systemd/system/magi-archive.service`

```ini
[Service]
EnvironmentFile=/home/<user>/<app-dir>/.env.production
ExecStart=/home/ubuntu/.rbenv/shims/decko server -b 0.0.0.0 -p 3000
```

This is why the running application works fine - systemd loads the environment file automatically.

---

## Database Backup

The cards are stored in PostgreSQL RDS. To back up the database:

```bash
ssh -i ~/.ssh/<REDACTED_KEY>.pem ubuntu@<REDACTED_EC2_IP> "cd /home/<user>/<app-dir> && set -a && source .env.production && set +a && pg_dump -h <REDACTED_RDS_ENDPOINT> -U <REDACTED_DB_USER> -d magi_archive_production > backup-\$(date +%Y%m%d-%H%M%S).sql"
```

Then download the backup:

```bash
scp -i ~/.ssh/<REDACTED_KEY>.pem ubuntu@<REDACTED_EC2_IP>:/home/<user>/<app-dir>/backup-*.sql ./
```

---

## Quick Reference

**SSH Key Location**: `~/.ssh/<REDACTED_KEY>.pem`
**Server IP**: `<REDACTED_EC2_IP>`
**App Directory**: `/home/<user>/<app-dir>`
**Environment File**: `/home/<user>/<app-dir>/.env.production`
**Database Host**: `<REDACTED_RDS_ENDPOINT>`
**Ruby Path**: `/home/ubuntu/.rbenv/shims/`
**Decko Command**: `script/card runner 'Ruby code'`

---

**Last Updated**: 2025-10-25
**Tested**: Successfully retrieved 641 cards including Neoterics knowledge structure
