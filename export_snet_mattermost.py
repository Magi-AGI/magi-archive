#!/usr/bin/env python3
"""
Non-interactive script to export all SingularityNET Mattermost channels.
Run this from command line where you can enter your password.
"""

import os
import sys
import json
import getpass
from pathlib import Path
from datetime import datetime

# Add current directory to path
sys.path.insert(0, str(Path(__file__).parent))

from mattermost_export import MattermostExporter


def main():
    print("\n" + "="*60)
    print(" SingularityNET Mattermost Exporter")
    print("="*60 + "\n")

    # Configuration
    config = {
        "host": "chat.singularitynet.io",
        "username": "lake.watkins@gmail.com",  # Use email for login
        "download_files": True
    }

    # Get password
    print(f"Host: {config['host']}")
    print(f"Username: {config['username']}")
    password = getpass.getpass("Password: ")

    if not password:
        print("Error: Password required")
        sys.exit(1)

    # Create output directory
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    output_dir = Path("mattermost_exports") / f"singularitynet_{timestamp}"
    output_dir.mkdir(parents=True, exist_ok=True)
    print(f"\nOutput directory: {output_dir.absolute()}\n")

    try:
        # Initialize exporter
        print("Connecting to Mattermost...")
        exporter = MattermostExporter(
            host=config["host"],
            username=config["username"],
            password=password
        )
        exporter.initialize_user_data()

        # Get all teams
        teams = exporter.list_teams()

        print(f"\nFound {len(teams)} teams:")
        for idx, team in enumerate(teams):
            print(f"  [{idx}] {team['display_name']}")

        # Process each team
        for team_idx, team in enumerate(teams):
            print(f"\n{'='*60}")
            print(f"Processing Team {team_idx + 1}/{len(teams)}: {team['display_name']}")
            print(f"{'='*60}")

            # Get all channels for this team
            channels = exporter.list_channels(team["id"])

            if not channels:
                print("  No channels found")
                continue

            # Export each channel
            for channel_idx, channel in enumerate(channels):
                print(f"\n[Channel {channel_idx + 1}/{len(channels)}]")
                try:
                    exporter.export_channel(
                        channel,
                        output_dir,
                        download_files=config["download_files"]
                    )
                except Exception as e:
                    print(f"✗ Error exporting {channel['display_name']}: {e}")
                    continue

        # Create summary
        summary = {
            "host": config["host"],
            "username": config["username"],
            "exported_at": datetime.utcnow().isoformat() + "Z",
            "teams_count": len(teams),
            "teams": [
                {
                    "name": team["name"],
                    "display_name": team["display_name"],
                    "id": team["id"]
                }
                for team in teams
            ]
        }

        summary_file = output_dir / "export_summary.json"
        summary_file.write_text(json.dumps(summary, indent=2), encoding="utf-8")

        print("\n" + "="*60)
        print("✓ Export Complete!")
        print(f"  Output: {output_dir.absolute()}")
        print(f"  Summary: {summary_file}")
        print("="*60 + "\n")

    except KeyboardInterrupt:
        print("\n\n✗ Export cancelled by user")
        sys.exit(1)
    except Exception as e:
        print(f"\n✗ Error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
