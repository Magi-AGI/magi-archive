#!/usr/bin/env python3
"""
Helper script to find your MMAUTHTOKEN from Firefox or Chrome.
"""

import sqlite3
import json
from pathlib import Path
import sys
import os


def find_firefox_token(host="chat.singularitynet.io"):
    """Try to extract MMAUTHTOKEN from Firefox cookies."""
    print("🔍 Searching Firefox profiles...")

    if os.name == "nt":  # Windows
        profile_dir = Path(os.environ.get("APPDATA", "")) / "Mozilla/Firefox/Profiles"
    else:  # Linux/Mac
        profile_dir = Path.home() / ".mozilla/firefox"

    if not profile_dir.exists():
        print("  ✗ Firefox profile directory not found")
        return None

    found_tokens = []

    for cookie_file in profile_dir.rglob("cookies.sqlite"):
        try:
            # Copy to temp file to avoid lock issues
            import tempfile
            import shutil

            with tempfile.NamedTemporaryFile(delete=False, suffix='.sqlite') as tmp:
                tmp_path = tmp.name

            shutil.copy2(str(cookie_file), tmp_path)

            conn = sqlite3.connect(tmp_path)
            cursor = conn.cursor()

            # Try to find MMAUTHTOKEN
            query = """
                SELECT host, name, value
                FROM moz_cookies
                WHERE name = 'MMAUTHTOKEN'
                AND host LIKE ?
            """
            rows = cursor.execute(query, (f"%{host}%",)).fetchall()
            conn.close()

            # Clean up temp file
            os.unlink(tmp_path)

            if rows:
                profile_name = cookie_file.parent.name
                print(f"  ✓ Found in profile: {profile_name}")
                for cookie_host, name, value in rows:
                    found_tokens.append({
                        "host": cookie_host,
                        "value": value,
                        "profile": profile_name
                    })

        except Exception as e:
            print(f"  ⚠ Error reading {cookie_file.parent.name}: {e}")
            continue

    return found_tokens if found_tokens else None


def find_chrome_token(host="chat.singularitynet.io"):
    """Try to extract MMAUTHTOKEN from Chrome cookies."""
    print("🔍 Searching Chrome profiles...")

    if os.name == "nt":  # Windows
        cookie_paths = [
            Path(os.environ.get("LOCALAPPDATA", "")) / "Google/Chrome/User Data/Default/Network/Cookies",
            Path(os.environ.get("LOCALAPPDATA", "")) / "Google/Chrome/User Data/Default/Cookies",
        ]
    else:  # Linux/Mac
        cookie_paths = [
            Path.home() / ".config/google-chrome/Default/Cookies",
            Path.home() / "Library/Application Support/Google/Chrome/Default/Cookies",
        ]

    for cookie_file in cookie_paths:
        if not cookie_file.exists():
            continue

        try:
            import tempfile
            import shutil

            # Copy to temp to avoid lock
            with tempfile.NamedTemporaryFile(delete=False, suffix='.sqlite') as tmp:
                tmp_path = tmp.name

            shutil.copy2(str(cookie_file), tmp_path)

            conn = sqlite3.connect(tmp_path)
            cursor = conn.cursor()

            # Chrome uses 'cookies' table
            query = """
                SELECT host_key, name, value, encrypted_value
                FROM cookies
                WHERE name = 'MMAUTHTOKEN'
                AND host_key LIKE ?
            """
            rows = cursor.execute(query, (f"%{host}%",)).fetchall()
            conn.close()

            # Clean up
            os.unlink(tmp_path)

            if rows:
                print(f"  ✓ Found in Chrome")
                # Note: Chrome encrypts cookie values, might need decryption
                tokens = []
                for cookie_host, name, value, encrypted in rows:
                    if value:
                        tokens.append({
                            "host": cookie_host,
                            "value": value,
                            "source": "chrome"
                        })
                return tokens if tokens else None

        except Exception as e:
            print(f"  ⚠ Error reading Chrome cookies: {e}")
            continue

    print("  ✗ Chrome cookies not found")
    return None


def main():
    print("\n" + "="*60)
    print(" MMAUTHTOKEN Finder for SingularityNET Mattermost")
    print("="*60 + "\n")

    print("Attempting to automatically find your auth token...")
    print("Make sure you're logged into chat.singularitynet.io in your browser!\n")

    # Try Firefox first
    tokens = find_firefox_token()

    # Try Chrome if Firefox didn't work
    if not tokens:
        tokens = find_chrome_token()

    if tokens:
        print(f"\n✓ Found {len(tokens)} token(s)!\n")
        for idx, token in enumerate(tokens):
            print(f"Token #{idx + 1}:")
            print(f"  Host: {token['host']}")
            print(f"  Value: {token['value']}")
            if 'profile' in token:
                print(f"  Profile: {token['profile']}")
            print()

        print("="*60)
        print("Copy the token value above and use it in the export script!")
        print("="*60 + "\n")
    else:
        print("\n✗ No token found automatically.\n")
        print("Please find it manually:")
        print("\n1. Log into https://chat.singularitynet.io/")
        print("2. Complete MFA authentication")
        print("3. Press F12 to open Developer Tools")
        print("\nFor Firefox:")
        print("  - Go to Storage tab")
        print("  - Expand Cookies → https://chat.singularitynet.io")
        print("  - Find MMAUTHTOKEN and copy the value")
        print("\nFor Chrome:")
        print("  - Go to Application tab")
        print("  - Expand Cookies → https://chat.singularitynet.io")
        print("  - Find MMAUTHTOKEN and copy the value")
        print()


if __name__ == "__main__":
    main()
