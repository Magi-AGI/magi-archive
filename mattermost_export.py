#!/usr/bin/env python3
"""
Mattermost Channel Export Tool
Export channels, messages, and attachments from Mattermost to JSON format.

Features:
- Export public, private, group, and direct message channels
- Download file attachments
- Extract code blocks to separate files
- Track thread relationships (replies linked to parent posts)
- Date filtering (export posts within specific date ranges)
- Interactive channel selection
- Auto-detect Firefox authentication tokens
- Persistent configuration

Thread Tracking:
Posts that are replies in threads include 'root_id' and 'is_reply' fields.
The export also includes a 'threads' object mapping root post IDs to their replies.
"""

import os
import json
import sqlite3
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple
import getpass
import argparse

try:
    from mattermostdriver import Driver
except ImportError:
    print("Error: mattermostdriver not installed. Install with: pip install mattermostdriver")
    exit(1)


class MattermostExporter:
    """Main class for exporting Mattermost content."""

    def __init__(self, host: str, token: Optional[str] = None,
                 username: Optional[str] = None, password: Optional[str] = None):
        self.host = host
        self.driver = self._connect(host, token, username, password)
        self.user_cache: Dict[str, str] = {}
        self.my_user_id: str = ""
        self.my_username: str = ""

    def _connect(self, host: str, token: Optional[str],
                 username: Optional[str], password: Optional[str]) -> Driver:
        """Establish connection to Mattermost server."""
        driver = Driver({
            "url": host,
            "port": 443,
            "token": token,
            "username": username,
            "password": password,
            "scheme": "https"
        })
        try:
            driver.login()
            print(f"✓ Connected to {host}")
            return driver
        except Exception as e:
            print(f"✗ Connection failed: {e}")
            raise

    def initialize_user_data(self) -> None:
        """Load current user info and build user cache."""
        my_user = self.driver.users.get_user("me")
        self.my_username = my_user["username"]
        self.my_user_id = my_user["id"]
        print(f"✓ Logged in as {self.my_username} ({self.my_user_id})")

        # Build user cache
        print("Loading users...", end=" ", flush=True)
        page = 0
        while True:
            users = self.driver.users.get_users(params={"per_page": 200, "page": page})
            if not users:
                break
            for user in users:
                self.user_cache[user["id"]] = user["username"]
            page += 1
        print(f"✓ {len(self.user_cache)} users loaded")

    def get_username(self, user_id: str) -> str:
        """Get username for a user ID, fetching if not cached."""
        if user_id not in self.user_cache:
            try:
                user = self.driver.users.get_user(user_id)
                self.user_cache[user_id] = user["username"]
            except:
                self.user_cache[user_id] = f"unknown_user_{user_id[:8]}"
        return self.user_cache[user_id]

    def _organize_threads(self, posts: List[Dict]) -> Dict[str, List[Dict]]:
        """Organize posts into thread structures.

        Returns a dictionary mapping root post IDs to lists of reply posts.
        """
        threads = {}
        for post in posts:
            if post.get("root_id"):
                root_id = post["root_id"]
                if root_id not in threads:
                    threads[root_id] = []
                threads[root_id].append({
                    "id": post["id"],
                    "idx": post["idx"],
                    "username": post["username"],
                    "created": post["created"],
                    "message": post["message"]
                })

        # Sort replies in each thread by creation time
        for root_id in threads:
            threads[root_id].sort(key=lambda x: x["created"])

        return threads

    def list_teams(self) -> List[Dict]:
        """Get all teams for current user."""
        print("Loading teams...", end=" ", flush=True)
        teams = self.driver.teams.get_user_teams(self.my_user_id)
        print(f"✓ {len(teams)} teams found")
        return teams

    def select_team_interactive(self) -> Dict:
        """Interactive team selection."""
        teams = self.list_teams()
        print("\nAvailable Teams:")
        for idx, team in enumerate(teams):
            print(f"  [{idx}] {team['display_name']} ({team['name']})")

        while True:
            try:
                choice = int(input("\nSelect team [number]: "))
                if 0 <= choice < len(teams):
                    selected = teams[choice]
                    print(f"✓ Selected: {selected['display_name']}")
                    return selected
            except (ValueError, IndexError):
                pass
            print("Invalid selection. Try again.")

    def list_channels(self, team_id: str) -> List[Dict]:
        """Get all channels for a team."""
        print("Loading channels...", end=" ", flush=True)
        channels = self.driver.channels.get_channels_for_user(self.my_user_id, team_id)

        # Enhance display names for DMs
        for channel in channels:
            if channel["type"] == "D":
                user_ids = channel["name"].split("__")
                other_id = user_ids[1] if user_ids[0] == self.my_user_id else user_ids[0]
                channel["display_name"] = f"DM: {self.get_username(other_id)}"

        channels.sort(key=lambda x: x["display_name"].lower())
        print(f"✓ {len(channels)} channels found")
        return channels

    def select_channels_interactive(self, team_id: str) -> List[Dict]:
        """Interactive channel selection."""
        channels = self.list_channels(team_id)

        print("\nAvailable Channels:")
        for idx, channel in enumerate(channels):
            type_indicator = {
                "O": "📢", "P": "🔒", "D": "💬", "G": "👥"
            }.get(channel["type"], "❓")
            print(f"  [{idx}] {type_indicator} {channel['display_name']}")

        choice = input("\nSelect channels [comma-separated numbers or 'all']: ").strip()

        if choice.lower() == "all":
            print(f"✓ Selected all {len(channels)} channels")
            return channels

        try:
            indices = [int(x.strip()) for x in choice.split(",")]
            selected = [channels[i] for i in indices if 0 <= i < len(channels)]
            print(f"✓ Selected {len(selected)} channels")
            return selected
        except (ValueError, IndexError):
            print("Invalid selection. No channels selected.")
            return []

    def export_channel(self, channel: Dict, output_dir: Path,
                      download_files: bool = True,
                      after: Optional[datetime] = None,
                      before: Optional[datetime] = None) -> None:
        """Export a single channel to JSON."""
        channel_name = channel["display_name"].replace("/", "_").replace("\\", "_")
        print(f"\n{'='*60}")
        print(f"Exporting: {channel_name}")
        print(f"{'='*60}")

        # Convert datetime to timestamps
        after_ts = after.timestamp() if after else None
        before_ts = before.timestamp() if before else None

        # Fetch all posts
        all_posts = []
        page = 0
        while True:
            print(f"  Fetching page {page}...", end=" ", flush=True)
            response = self.driver.posts.get_posts_for_channel(
                channel["id"],
                params={"per_page": 200, "page": page}
            )

            if not response["posts"]:
                print("done")
                break

            page_posts = [response["posts"][post_id] for post_id in response["order"]]
            all_posts.extend(page_posts)
            print(f"✓ {len(page_posts)} posts")
            page += 1

        print(f"  Total posts: {len(all_posts)}")

        # Create channel directory
        safe_name = "".join(c for c in channel_name if c.isalnum() or c in " _-").strip()
        channel_dir = output_dir / safe_name
        channel_dir.mkdir(parents=True, exist_ok=True)

        # Process posts
        processed_posts = []
        for idx, post in enumerate(reversed(all_posts)):
            created_ts = post["create_at"] / 1000

            # Apply date filters
            if (before_ts and created_ts > before_ts) or (after_ts and created_ts < after_ts):
                continue

            username = self.get_username(post["user_id"])
            created = datetime.utcfromtimestamp(created_ts).isoformat() + "Z"

            post_data = {
                "idx": idx,
                "id": post["id"],
                "created": created,
                "username": username,
                "message": post["message"]
            }

            # Track thread relationships
            if post.get("root_id"):
                post_data["root_id"] = post["root_id"]
                post_data["is_reply"] = True

            # Extract code blocks
            message = post["message"]
            if message.count("```") >= 2:
                start = message.find("```") + 3
                end = message.rfind("```")
                code = message[start:end].strip()
                if code:
                    code_file = channel_dir / f"{idx:04d}_code.txt"
                    code_file.write_text(code, encoding="utf-8")
                    post_data["code_file"] = code_file.name

            # Download attachments
            if "files" in post.get("metadata", {}):
                filenames = []
                for file_info in post["metadata"]["files"]:
                    filename = f"{idx:04d}_{file_info['name']}"
                    filenames.append(file_info['name'])

                    if download_files:
                        try:
                            print(f"  Downloading: {file_info['name']}...", end=" ", flush=True)
                            file_data = self.driver.files.get_file(file_info["id"])

                            file_path = channel_dir / filename
                            if isinstance(file_data, dict):
                                file_path.write_text(json.dumps(file_data, indent=2))
                            else:
                                file_path.write_bytes(file_data.content)
                            print("✓")
                        except Exception as e:
                            print(f"✗ {e}")

                post_data["files"] = filenames

            processed_posts.append(post_data)

        # Get team info
        try:
            team_info = self.driver.teams.get_team(channel["team_id"])
            team_name = team_info["name"]
        except:
            team_name = "unknown"

        # Organize threads
        threads = self._organize_threads(processed_posts)
        thread_count = len([p for p in processed_posts if p.get("is_reply")])

        # Build export data
        export_data = {
            "channel": {
                "id": channel["id"],
                "name": channel["name"],
                "display_name": channel["display_name"],
                "type": channel["type"],
                "team": team_name,
                "team_id": channel["team_id"],
                "header": channel.get("header", ""),
                "purpose": channel.get("purpose", ""),
                "exported_at": datetime.utcnow().isoformat() + "Z",
                "post_count": len(processed_posts),
                "thread_count": thread_count
            },
            "posts": processed_posts,
            "threads": threads
        }

        # Write JSON export
        json_file = channel_dir / f"{safe_name}.json"
        json_file.write_text(
            json.dumps(export_data, indent=2, ensure_ascii=False),
            encoding="utf-8"
        )

        print(f"✓ Exported to: {json_file}")
        print(f"  Posts: {len(processed_posts)}")
        if thread_count > 0:
            print(f"  Thread replies: {thread_count} across {len(threads)} threads")


def find_firefox_token(host: str) -> Optional[str]:
    """Attempt to extract MMAUTHTOKEN from Firefox cookies."""
    try:
        if os.name == "nt":  # Windows
            profile_dir = Path(os.environ["APPDATA"]) / "Mozilla/Firefox/Profiles"
        else:  # Linux/Mac
            profile_dir = Path.home() / ".mozilla/firefox"

        if not profile_dir.exists():
            return None

        for cookie_file in profile_dir.rglob("cookies.sqlite"):
            try:
                conn = sqlite3.connect(str(cookie_file))
                cursor = conn.cursor()
                rows = cursor.execute(
                    "SELECT host, value FROM moz_cookies WHERE name = 'MMAUTHTOKEN'"
                ).fetchall()
                conn.close()

                for cookie_host, token in rows:
                    if host in cookie_host:
                        print(f"✓ Found token in Firefox profile: {cookie_file.parent.name}")
                        return token
            except:
                continue

    except Exception as e:
        print(f"Note: Could not auto-detect Firefox token: {e}")

    return None


def load_config(config_file: Path) -> Dict:
    """Load configuration from JSON file."""
    if config_file.exists():
        try:
            config = json.loads(config_file.read_text())
            print(f"✓ Loaded config from {config_file}")
            return config
        except Exception as e:
            print(f"Warning: Could not load config: {e}")
    return {}


def save_config(config: Dict, config_file: Path) -> None:
    """Save configuration to JSON file."""
    try:
        # Don't save sensitive data
        safe_config = {k: v for k, v in config.items() if k not in ["password", "token"]}
        config_file.write_text(json.dumps(safe_config, indent=2))
        print(f"✓ Config saved to {config_file}")
    except Exception as e:
        print(f"Warning: Could not save config: {e}")


def interactive_config(config_file: Path) -> Dict:
    """Interactive configuration setup."""
    config = load_config(config_file)

    # Host
    if "host" not in config:
        config["host"] = input("Mattermost server (without https://): ").strip()
    else:
        print(f"Using host: {config['host']}")

    # Login mode
    if "login_mode" not in config:
        while True:
            mode = input("Login mode [password/token]: ").strip().lower()
            if mode in ["password", "token"]:
                config["login_mode"] = mode
                break
    else:
        print(f"Using login mode: {config['login_mode']}")

    # Credentials
    if config["login_mode"] == "password":
        if "username" not in config:
            config["username"] = input("Username: ").strip()
        else:
            print(f"Using username: {config['username']}")
        config["password"] = getpass.getpass("Password: ")
    else:
        token = find_firefox_token(config["host"])
        if not token:
            token = input("Login token (MMAUTHTOKEN): ").strip()
        config["token"] = token

    # Download files
    if "download_files" not in config:
        config["download_files"] = input("Download attachments? [y/n]: ").lower() == "y"
    else:
        print(f"Download files: {config['download_files']}")

    # Save config
    save = input("Save config (without password/token)? [y/n]: ").lower() == "y"
    if save:
        save_config(config, config_file)

    return config


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="Export Mattermost channels to JSON",
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--config", type=Path, default=Path("mattermost_config.json"),
                       help="Config file path (default: mattermost_config.json)")
    parser.add_argument("--output", type=Path, default=Path("exports"),
                       help="Output directory (default: exports)")
    parser.add_argument("--after", type=str, help="Export posts after date (YYYY-MM-DD)")
    parser.add_argument("--before", type=str, help="Export posts before date (YYYY-MM-DD)")
    parser.add_argument("--no-files", action="store_true", help="Skip downloading attachments")

    args = parser.parse_args()

    print("\n" + "="*60)
    print(" Mattermost Channel Exporter")
    print("="*60 + "\n")

    # Load/create config
    config = interactive_config(args.config)

    # Parse date filters
    after = datetime.strptime(args.after, "%Y-%m-%d") if args.after else None
    before = datetime.strptime(args.before, "%Y-%m-%d") if args.before else None
    download_files = not args.no_files and config.get("download_files", True)

    # Create output directory
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    output_dir = args.output / timestamp
    output_dir.mkdir(parents=True, exist_ok=True)
    print(f"\nOutput directory: {output_dir.absolute()}\n")

    try:
        # Initialize exporter
        exporter = MattermostExporter(
            host=config["host"],
            token=config.get("token"),
            username=config.get("username"),
            password=config.get("password")
        )
        exporter.initialize_user_data()

        # Select team and channels
        team = exporter.select_team_interactive()
        channels = exporter.select_channels_interactive(team["id"])

        if not channels:
            print("\nNo channels selected. Exiting.")
            return

        # Export channels
        print(f"\nExporting {len(channels)} channel(s)...\n")
        for idx, channel in enumerate(channels, 1):
            print(f"\n[{idx}/{len(channels)}]")
            exporter.export_channel(
                channel,
                output_dir,
                download_files=download_files,
                after=after,
                before=before
            )

        print("\n" + "="*60)
        print("✓ Export complete!")
        print(f"  Output: {output_dir.absolute()}")
        print("="*60 + "\n")

    except KeyboardInterrupt:
        print("\n\n✗ Export cancelled by user")
    except Exception as e:
        print(f"\n✗ Error: {e}")
        import traceback
        traceback.print_exc()


if __name__ == "__main__":
    main()
