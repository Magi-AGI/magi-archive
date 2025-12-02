#!/usr/bin/env python3
"""
Non-interactive script to export all SingularityNET Mattermost channels using token auth.

To get your token:
1. Log into https://chat.singularitynet.io/ in your browser
2. Open Developer Tools (F12)
3. Go to Application/Storage → Cookies → https://chat.singularitynet.io
4. Find the cookie named 'MMAUTHTOKEN'
5. Copy its value
"""

import os
import sys
import json
from pathlib import Path
from datetime import datetime

# Add current directory to path
sys.path.insert(0, str(Path(__file__).parent))

from mattermost_export import MattermostExporter


def main():
    print("\n" + "="*60)
    print(" SingularityNET Mattermost Exporter (Token Auth)")
    print("="*60 + "\n")

    # Configuration
    config = {
        "host": "chat.singularitynet.io",
        "download_files": True
    }

    # Get token
    print(f"Host: {config['host']}")
    print("\nTo get your MMAUTHTOKEN:")
    print("1. Log into https://chat.singularitynet.io/ in your browser")
    print("2. Open Developer Tools (F12)")
    print("3. Go to Application/Storage → Cookies")
    print("4. Find 'MMAUTHTOKEN' and copy its value\n")

    token = input("Enter your MMAUTHTOKEN: ").strip()

    if not token:
        print("Error: Token required")
        sys.exit(1)

    # Create output directory
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    output_dir = Path("mattermost_exports") / f"singularitynet_{timestamp}"
    output_dir.mkdir(parents=True, exist_ok=True)
    print(f"\nOutput directory: {output_dir.absolute()}\n")

    try:
        # Initialize exporter with token
        print("Connecting to Mattermost...")
        exporter = MattermostExporter(
            host=config["host"],
            token=token
        )
        exporter.initialize_user_data()

        # Get all teams
        teams = exporter.list_teams()

        print(f"\nFound {len(teams)} teams:")
        for idx, team in enumerate(teams):
            print(f"  [{idx}] {team['display_name']}")

        # Ask which teams to export
        print("\nExport options:")
        print("  'all' - Export all teams")
        print("  '0,1,2' - Export specific teams by number")
        choice = input("\nEnter your choice: ").strip().lower()

        if choice == 'all':
            teams_to_export = teams
        else:
            try:
                indices = [int(x.strip()) for x in choice.split(",")]
                teams_to_export = [teams[i] for i in indices if 0 <= i < len(teams)]
            except (ValueError, IndexError):
                print("Invalid selection. Exporting all teams.")
                teams_to_export = teams

        # Process each team
        total_channels = 0
        for team_idx, team in enumerate(teams_to_export):
            print(f"\n{'='*60}")
            print(f"Processing Team {team_idx + 1}/{len(teams_to_export)}: {team['display_name']}")
            print(f"{'='*60}")

            # Get all channels for this team
            channels = exporter.list_channels(team["id"])

            if not channels:
                print("  No channels found")
                continue

            total_channels += len(channels)

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
                    import traceback
                    traceback.print_exc()
                    continue

        # Create summary
        summary = {
            "host": config["host"],
            "exported_at": datetime.utcnow().isoformat() + "Z",
            "teams_count": len(teams_to_export),
            "total_channels": total_channels,
            "teams": [
                {
                    "name": team["name"],
                    "display_name": team["display_name"],
                    "id": team["id"]
                }
                for team in teams_to_export
            ]
        }

        summary_file = output_dir / "export_summary.json"
        summary_file.write_text(json.dumps(summary, indent=2), encoding="utf-8")

        print("\n" + "="*60)
        print("✓ Export Complete!")
        print(f"  Output: {output_dir.absolute()}")
        print(f"  Teams: {len(teams_to_export)}")
        print(f"  Channels: {total_channels}")
        print(f"  Summary: {summary_file.name}")
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
