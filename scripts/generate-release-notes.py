#!/usr/bin/env python3
"""
generate-release-notes.py - Generate multi-audience release notes from commits

Parses conventional commits and PR bodies, renders templates, optionally polishes with AI
"""

import argparse
import json
import os
import subprocess
import sys
from datetime import date
from pathlib import Path
from typing import Dict, List, Optional
import re

try:
    import requests
except ImportError:
    requests = None  # Optional for polished mode

# Colors for output
class Colors:
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    BLUE = '\033[0;34m'
    BOLD = '\033[1m'
    NC = '\033[0m'  # No Color

def log(msg: str, quiet: bool = False):
    if not quiet:
        print(f"{Colors.BLUE}[release-notes]{Colors.NC} {msg}", file=sys.stderr)

def warn(msg: str):
    print(f"{Colors.YELLOW}[release-notes] WARNING:{Colors.NC} {msg}", file=sys.stderr)

def error(msg: str):
    print(f"{Colors.RED}[release-notes] ERROR:{Colors.NC} {msg}", file=sys.stderr)
    sys.exit(1)

def run_cmd(cmd: List[str], check: bool = True) -> subprocess.CompletedProcess:
    """Run a shell command and return result"""
    try:
        return subprocess.run(cmd, capture_output=True, text=True, check=check)
    except subprocess.CalledProcessError as e:
        if check:
            error(f"Command failed: {' '.join(cmd)}\n{e.stderr}")
        return e

def get_latest_tag() -> str:
    """Get the most recent git tag"""
    result = run_cmd(['git', 'describe', '--tags', '--abbrev=0'], check=False)
    if result.returncode == 0:
        return result.stdout.strip()
    return "v0.0.0"

def calculate_next_version() -> str:
    """Calculate next version using version.sh"""
    script_dir = Path(__file__).parent
    version_script = script_dir / "version.sh"

    if not version_script.exists():
        error(f"version.sh not found at {version_script}")

    result = run_cmd([str(version_script)])
    # Output format: "1.0.0 (calculated from...)" - extract just the version
    version_line = result.stdout.strip().split('\n')[0]
    return version_line.split()[0]  # Get first word (the version)

def get_commits(commit_range: str) -> List[Dict]:
    """Get all commits in range as structured data"""
    # Use custom format with null separator
    format_str = '%H%x1F%s%x1F%b%x1F%an%x1F%ad%x1E'

    result = run_cmd([
        'git', 'log', commit_range,
        '--no-merges',
        f'--format={format_str}',
        '--date=short'
    ], check=False)

    if result.returncode != 0 or not result.stdout:
        return []

    commits = []
    for entry in result.stdout.split('\x1E'):
        entry = entry.strip()
        if not entry:
            continue

        parts = entry.split('\x1F')
        if len(parts) >= 5:
            commits.append({
                'hash': parts[0],
                'subject': parts[1],
                'body': parts[2],
                'author': parts[3],
                'date': parts[4]
            })

    return commits

def parse_commits(commits: List[Dict]) -> Dict:
    """Categorize commits by type"""
    features = []
    fixes = []
    breaking = []
    other = []

    for commit in commits:
        subject = commit['subject']
        body = commit['body']

        # Check for breaking changes
        if re.match(r'^[a-z]+(\(.+\))?!:', subject) or \
           re.search(r'^BREAKING CHANGE:', body, re.MULTILINE | re.IGNORECASE):
            breaking.append(commit)

        # Categorize by type
        if re.match(r'^feat(\(.+\))?!?:', subject, re.IGNORECASE):
            features.append(commit)
        elif re.match(r'^fix(\(.+\))?!?:', subject, re.IGNORECASE):
            fixes.append(commit)
        elif re.match(r'^(docs|chore|refactor|test|perf|build|ci|style)(\(.+\))?!?:', subject, re.IGNORECASE):
            other.append(commit)

    return {
        'features': features,
        'fixes': fixes,
        'breaking': breaking,
        'other': other
    }

def get_project_name() -> str:
    """Get project name from PROJECT.yaml or directory name"""
    if Path('PROJECT.yaml').exists():
        result = run_cmd(['yq', 'eval', '.app.name', 'PROJECT.yaml'], check=False)
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()

    return Path.cwd().name

def build_template_data(version: str, commits: List[Dict], parsed: Dict) -> Dict:
    """Build data dictionary for template rendering"""
    return {
        'VERSION': version,
        'DATE': date.today().isoformat(),
        'PRODUCT_NAME': get_project_name(),
        'COMMIT_COUNT': len(commits),
        'FEATURE_COUNT': len(parsed['features']),
        'FIX_COUNT': len(parsed['fixes']),
        'COMMITS': commits,
        'FEATURES': parsed['features'],
        'FIXES': parsed['fixes'],
        'BREAKING_CHANGES': parsed['breaking'],
        'OTHER': parsed['other'],
        # Template helpers
        'NEW_FEATURES': parsed['features'],  # Alias for external template
        'BUG_FIXES': parsed['fixes'],  # Alias for external template
    }

def render_template(audience: str, data: Dict, templates_dir: Path) -> str:
    """Render release notes for specific audience"""
    # Simple programmatic generation without external template dependencies

    if audience == 'technical':
        return render_technical(data)
    elif audience == 'operations':
        return render_operations(data)
    elif audience == 'business':
        return render_business(data)
    elif audience == 'external':
        return render_external(data)
    elif audience == 'support':
        return render_support(data)
    else:
        error(f"Unknown audience: {audience}")

def render_technical(data: Dict) -> str:
    """Render technical release notes"""
    lines = [
        "# Release Notes - Technical",
        "",
        f"**Version**: {data['VERSION']}",
        f"**Released**: {data['DATE']}",
        f"**Target Audience**: Engineers, Developers",
        "",
        "---",
        "",
        "## Breaking Changes",
        ""
    ]

    if data['BREAKING_CHANGES']:
        for change in data['BREAKING_CHANGES']:
            lines.extend([
                f"### {change['subject']}",
                "",
                change['body'],
                ""
            ])
    else:
        lines.append("_No breaking changes in this release._")

    lines.extend(["", "---", "", "## New Features", ""])

    if data['FEATURES']:
        for feat in data['FEATURES']:
            lines.extend([
                f"### {feat['subject']}",
                "",
                feat['body'] if feat['body'] else "_No description provided_",
                ""
            ])
    else:
        lines.append("_No new features in this release._")

    lines.extend(["", "---", "", "## Bug Fixes", ""])

    if data['FIXES']:
        for fix in data['FIXES']:
            lines.extend([
                f"### {fix['subject']}",
                "",
                fix['body'] if fix['body'] else "_No description provided_",
                ""
            ])
    else:
        lines.append("_No bug fixes in this release._")

    lines.extend(["", "---", "", "## Other Changes", ""])

    if data['OTHER']:
        for change in data['OTHER']:
            lines.append(f"- {change['subject']}")
    else:
        lines.append("_No other changes in this release._")

    lines.extend([
        "",
        "---",
        "",
        "## Migration Guide",
        ""
    ])

    if data['BREAKING_CHANGES']:
        lines.append("This release includes breaking changes. Follow these steps to migrate:")
        lines.append("")
        for i, change in enumerate(data['BREAKING_CHANGES'], 1):
            lines.append(f"{i}. **{change['subject']}**: Review commit {change['hash'][:7]} for details")
    else:
        lines.append("No migration required for this release.")

    lines.extend([
        "",
        "---",
        "",
        "## Internal Notes",
        "",
        f"- Total commits: {data['COMMIT_COUNT']}",
        f"- Features: {data['FEATURE_COUNT']}",
        f"- Fixes: {data['FIX_COUNT']}",
        ""
    ])

    return "\n".join(lines)

def render_operations(data: Dict) -> str:
    """Render operations release notes"""
    lines = [
        "# Release Notes - Operations",
        "",
        f"**Version**: {data['VERSION']}",
        f"**Released**: {data['DATE']}",
        "**Target Audience**: DevOps, SRE",
        "",
        "---",
        "",
        "## Deployment Steps",
        "",
        "Standard deployment procedure. No special steps required.",
        "",
        "---",
        "",
        "## Configuration Changes",
        "",
        "_No configuration changes in this release._" if not data['BREAKING_CHANGES'] else "Review breaking changes section below.",
        "",
        "---",
        "",
        "## Breaking Changes",
        ""
    ]

    if data['BREAKING_CHANGES']:
        for change in data['BREAKING_CHANGES']:
            lines.extend([
                f"### {change['subject']}",
                "",
                change['body'],
                ""
            ])
    else:
        lines.append("_No breaking changes in this release._")

    lines.extend([
        "",
        "---",
        "",
        "## Commits",
        "",
        f"- Total: {data['COMMIT_COUNT']}",
        f"- Features: {data['FEATURE_COUNT']}",
        f"- Fixes: {data['FIX_COUNT']}",
        ""
    ])

    return "\n".join(lines)

def render_business(data: Dict) -> str:
    """Render business release notes"""
    lines = [
        "# Release Notes - Business Impact",
        "",
        f"**Version**: {data['VERSION']}",
        f"**Released**: {data['DATE']}",
        "**Target Audience**: Product, Leadership",
        "",
        "---",
        "",
        "## Summary",
        "",
        f"This release contains {data['FEATURE_COUNT']} new feature(s) and {data['FIX_COUNT']} bug fix(es).",
        "",
        "---",
        "",
        "## New Capabilities",
        ""
    ]

    if data['FEATURES']:
        for feat in data['FEATURES']:
            lines.append(f"- {feat['subject']}")
    else:
        lines.append("_No new features in this release._")

    lines.extend([
        "",
        "---",
        "",
        "## Improvements",
        ""
    ])

    if data['FIXES']:
        for fix in data['FIXES']:
            lines.append(f"- {fix['subject']}")
    else:
        lines.append("_No improvements in this release._")

    lines.extend([
        "",
        "---",
        "",
        "## Business Value",
        "",
        "This release improves system stability and adds new functionality to support business goals.",
        ""
    ])

    return "\n".join(lines)

def render_external(data: Dict) -> str:
    """Render external/customer release notes"""
    lines = [
        "# Release Notes",
        "",
        f"**Version**: {data['VERSION']}",
        f"**Released**: {data['DATE']}",
        "",
        f"Welcome to version {data['VERSION']}! This release brings {data['FEATURE_COUNT']} new features and {data['FIX_COUNT']} bug fixes.",
        "",
        "---",
        "",
        "## What's New",
        ""
    ]

    if data['FEATURES']:
        for feat in data['FEATURES']:
            lines.extend([
                f"### {feat['subject']}",
                "",
                feat['body'] or "New feature added.",
                ""
            ])
    else:
        lines.append("_This release focuses on performance and stability improvements._")

    lines.extend([
        "",
        "---",
        "",
        "## Bug Fixes",
        ""
    ])

    if data['FIXES']:
        for fix in data['FIXES']:
            lines.append(f"- {fix['subject']}")
    else:
        lines.append("_No major bug fixes in this release._")

    lines.extend([
        "",
        "---",
        "",
        "## Action Required",
        ""
    ])

    if not data['BREAKING_CHANGES']:
        lines.append("_No action required - just update and you're good to go!_")
    else:
        lines.append("**Important**: This release includes breaking changes. Please review the migration guide.")

    lines.extend([
        "",
        "---",
        "",
        f"Thank you for using {data['PRODUCT_NAME']}!",
        ""
    ])

    return "\n".join(lines)

def render_support(data: Dict) -> str:
    """Render customer support release notes"""
    lines = [
        "# Release Notes - Customer Support Guide",
        "",
        f"**Version**: {data['VERSION']}",
        f"**Released**: {data['DATE']}",
        "**Target Audience**: Customer Support, Success Teams",
        "",
        "---",
        "",
        "## Quick Reference",
        "",
        "| Change Type | Count |",
        "|-------------|-------|",
        f"| New Features | {data['FEATURE_COUNT']} |",
        f"| Bug Fixes | {data['FIX_COUNT']} |",
        f"| Breaking Changes | {len(data['BREAKING_CHANGES'])} |",
        "",
        "---",
        "",
        "## New Features Support",
        ""
    ]

    if data['FEATURES']:
        for feat in data['FEATURES']:
            lines.extend([
                f"### {feat['subject']}",
                "",
                f"**What it does**: {feat['body'] or 'New feature added.'}",
                ""
            ])
    else:
        lines.append("_No new features in this release._")

    lines.extend([
        "",
        "---",
        "",
        "## Bug Fixes",
        ""
    ])

    if data['FIXES']:
        for fix in data['FIXES']:
            lines.extend([
                f"### {fix['subject']}",
                "",
                f"**Fixed**: {fix['body'] or 'Issue resolved.'}",
                ""
            ])
    else:
        lines.append("_No bug fixes in this release._")

    lines.extend([
        "",
        "---",
        "",
        "## Breaking Changes",
        ""
    ])

    if data['BREAKING_CHANGES']:
        lines.append("⚠️ **Important**: This release includes breaking changes")
        lines.append("")
        for change in data['BREAKING_CHANGES']:
            lines.extend([
                f"### {change['subject']}",
                "",
                change['body'],
                ""
            ])
    else:
        lines.append("_No breaking changes in this release._")

    lines.append("")
    return "\n".join(lines)

def polish_with_ai(audience: str, raw_content: str, model: str, api_key: str, quiet: bool) -> str:
    """Polish release notes with Claude API"""
    if requests is None:
        warn("requests library not available, using raw version")
        return raw_content

    log(f"Polishing {audience} notes with AI (model: {model})...", quiet)

    # Audience-specific system prompts
    system_prompts = {
        'technical': "You are writing release notes for engineers and developers. Focus on technical accuracy, API changes, breaking changes, migration guides, and code examples. Use technical terminology. Be precise and comprehensive.",
        'operations': "You are writing release notes for DevOps and SRE teams. Focus on deployment steps, configuration changes, infrastructure impacts, performance, monitoring, and rollback procedures. Be operational and action-oriented.",
        'business': "You are writing release notes for product managers and leadership. Focus on business value, customer impact, revenue opportunities, strategic alignment, and success metrics. Use business language, not technical jargon.",
        'external': "You are writing release notes for external customers and end users. Focus on user-facing features, improvements, and benefits. Use simple, friendly language. Avoid technical details. Be concise and welcoming.",
        'support': "You are writing release notes for customer support teams. Focus on common questions, troubleshooting steps, workarounds, escalation paths, and customer communication templates. Be practical and support-focused."
    }

    system_prompt = system_prompts.get(audience, system_prompts['technical'])

    user_message = f"""Polish these release notes while maintaining the existing structure and sections. Improve clarity, grammar, and tone for the {audience} audience.

Original notes:
{raw_content}

Rules:
- Keep all existing sections and structure
- Improve language clarity and professionalism
- Maintain factual accuracy (don't add features that aren't listed)
- Use appropriate tone for {audience} audience
- Output ONLY the polished markdown, no commentary"""

    payload = {
        'model': model,
        'max_tokens': 4096,
        'temperature': 0.3,
        'system': system_prompt,
        'messages': [
            {'role': 'user', 'content': user_message}
        ]
    }

    try:
        response = requests.post(
            'https://api.anthropic.com/v1/messages',
            headers={
                'x-api-key': api_key,
                'anthropic-version': '2023-06-01',
                'Content-Type': 'application/json'
            },
            json=payload,
            timeout=60
        )

        if response.status_code != 200:
            warn(f"API returned HTTP {response.status_code} for {audience}, using raw version")
            return raw_content

        data = response.json()
        content = data.get('content', [{}])[0].get('text', '')

        if not content:
            warn(f"API returned empty content for {audience}, using raw version")
            return raw_content

        return content

    except Exception as e:
        warn(f"API request failed for {audience}: {e}, using raw version")
        return raw_content

def generate_changelog(release_notes: Dict, changelog_file: Path) -> str:
    """Generate cumulative CHANGELOG.md"""
    # Use technical notes as base
    new_entry = release_notes.get('technical', '')

    # Prepend to existing changelog
    if changelog_file.exists():
        existing = changelog_file.read_text()
        return f"{new_entry}\n\n---\n\n{existing}"
    else:
        header = "# Changelog\n\nAll notable changes to this project will be documented in this file.\n\n---\n\n"
        return f"{header}{new_entry}"

def main():
    parser = argparse.ArgumentParser(
        description='Generate multi-audience release notes from conventional commits'
    )
    parser.add_argument('-v', '--version', help='Override version (default: auto-calculate)')
    parser.add_argument('-a', '--audiences', default='technical,operations,business,external,support',
                        help='Comma-separated list of audiences')
    parser.add_argument('-m', '--mode', choices=['raw', 'polished'], default='polished',
                        help='Generation mode')
    parser.add_argument('-o', '--output-dir', default='docs/releases',
                        help='Output directory')
    parser.add_argument('--changelog', action='store_true',
                        help='Generate cumulative CHANGELOG.md')
    parser.add_argument('--changelog-file', default='docs/CHANGELOG.md',
                        help='CHANGELOG.md path')
    parser.add_argument('--tag', action='store_true',
                        help='Create git tag after committing')
    parser.add_argument('--push', action='store_true',
                        help='Push commit and tag to remote')
    parser.add_argument('--force', action='store_true',
                        help='Overwrite existing release notes')
    parser.add_argument('--dry-run', action='store_true',
                        help='Print to stdout, don\'t write files')
    parser.add_argument('-q', '--quiet', action='store_true',
                        help='Suppress progress output')

    args = parser.parse_args()

    # Validate we're in a git repository
    if run_cmd(['git', 'rev-parse', '--git-dir'], check=False).returncode != 0:
        error("Not a git repository")

    # Validate audiences
    valid_audiences = {'technical', 'operations', 'business', 'external', 'support'}
    audience_list = [a.strip() for a in args.audiences.split(',')]
    for aud in audience_list:
        if aud not in valid_audiences:
            error(f"Invalid audience: {aud}")

    # Get API key for polished mode
    api_key = os.getenv('ANTHROPIC_API_KEY', '')
    model = os.getenv('ANTHROPIC_MODEL', 'claude-sonnet-4-20250514')

    if args.mode == 'polished' and not api_key:
        warn("ANTHROPIC_API_KEY not set, falling back to raw mode")
        args.mode = 'raw'

    # Get templates directory
    script_dir = Path(__file__).parent
    templates_dir = script_dir.parent / 'templates' / 'release-notes'

    if not templates_dir.exists():
        error(f"Templates directory not found: {templates_dir}")

    # Determine version
    last_tag = get_latest_tag()
    current_version = last_tag.lstrip('v')

    if args.version:
        version = args.version
        log(f"Using override version: {version}", args.quiet)
    else:
        version = calculate_next_version()
        log(f"Auto-calculated version: {version} (from {current_version})", args.quiet)

    # Check for no new commits
    if version == current_version and last_tag != "v0.0.0":
        log(f"No new commits since {last_tag}, nothing to do", args.quiet)
        return 0

    # Get commit range
    commit_range = "HEAD" if last_tag == "v0.0.0" else f"{last_tag}..HEAD"

    # Collect commits
    log(f"Collecting commits since {last_tag}...", args.quiet)
    commits = get_commits(commit_range)

    if not commits:
        log("No commits found in range, nothing to do", args.quiet)
        return 0

    # Parse commits
    parsed = parse_commits(commits)
    log(f"Found {len(commits)} commits: {len(parsed['features'])} features, " +
        f"{len(parsed['fixes'])} fixes, {len(parsed['breaking'])} breaking", args.quiet)

    # Build template data
    template_data = build_template_data(version, commits, parsed)

    # Generate release notes for each audience
    release_notes = {}
    for audience in audience_list:
        log(f"Generating {audience} release notes...", args.quiet)

        # Render template
        raw_notes = render_template(audience, template_data, templates_dir)

        # Polish if requested
        if args.mode == 'polished':
            polished_notes = polish_with_ai(audience, raw_notes, model, api_key, args.quiet)
            release_notes[audience] = polished_notes
        else:
            release_notes[audience] = raw_notes

    # Dry run - print to stdout
    if args.dry_run:
        for audience in audience_list:
            print("=" * 45)
            print(f"Audience: {audience}")
            print("=" * 45)
            print(release_notes[audience])
            print()

        if args.changelog:
            print("=" * 45)
            print("CHANGELOG.md (preview)")
            print("=" * 45)
            changelog_content = generate_changelog(release_notes, Path(args.changelog_file))
            print(changelog_content)
            print()

        log("(dry run - no files written)", args.quiet)
        return 0

    # Check if output files exist
    if not args.force:
        for audience in audience_list:
            output_file = Path(args.output_dir) / f"v{version}-{audience}.md"
            if output_file.exists():
                error(f"Release notes already exist: {output_file} (use --force to overwrite)")

    # Check if tag exists
    if args.tag:
        if run_cmd(['git', 'rev-parse', f'v{version}'], check=False).returncode == 0:
            error(f"Tag v{version} already exists")

    # Write files
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    files_written = []

    for audience in audience_list:
        output_file = output_dir / f"v{version}-{audience}.md"
        output_file.write_text(release_notes[audience])
        files_written.append(str(output_file))
        log(f"Wrote {output_file}", args.quiet)

    # Write changelog
    if args.changelog:
        changelog_path = Path(args.changelog_file)
        changelog_path.parent.mkdir(parents=True, exist_ok=True)
        changelog_content = generate_changelog(release_notes, changelog_path)
        changelog_path.write_text(changelog_content)
        files_written.append(str(changelog_path))
        log(f"Updated {changelog_path}", args.quiet)

    # Commit
    commit_message = f"""docs(release): add release notes for v{version}

Generated for audiences: {args.audiences}
Commit count: {len(commits)}
Features: {len(parsed['features'])}
Fixes: {len(parsed['fixes'])}
Breaking changes: {len(parsed['breaking'])}"""

    run_cmd(['git', 'add'] + files_written)
    run_cmd(['git', 'commit', '-m', commit_message])
    log("Committed release notes", args.quiet)

    # Tag
    if args.tag:
        run_cmd(['git', 'tag', '-a', f'v{version}', '-m', f'Release {version}'])
        log(f"Created tag v{version}", args.quiet)

    # Push
    if args.push:
        run_cmd(['git', 'push', 'origin', 'HEAD'])
        log("Pushed commit", args.quiet)

        if args.tag:
            run_cmd(['git', 'push', 'origin', f'v{version}'])
            log(f"Pushed tag v{version}", args.quiet)

    # Summary
    if not args.quiet:
        print()
        print(f"{Colors.BOLD}┌────────────────────────────────────────────┐{Colors.NC}")
        print(f"{Colors.BOLD}│       Release Notes Generated              │{Colors.NC}")
        print(f"{Colors.BOLD}├────────────────────────────────────────────┤{Colors.NC}")
        print(f"{Colors.BOLD}│{Colors.NC} Version:    {Colors.GREEN}v{version}{Colors.NC}")
        print(f"{Colors.BOLD}│{Colors.NC} Audiences:  {args.audiences}")
        print(f"{Colors.BOLD}│{Colors.NC} Mode:       {args.mode}")
        print(f"{Colors.BOLD}│{Colors.NC} Changelog:  {args.changelog}")
        print(f"{Colors.BOLD}│{Colors.NC} Tagged:     {args.tag}")
        print(f"{Colors.BOLD}│{Colors.NC} Pushed:     {args.push}")
        print(f"{Colors.BOLD}│{Colors.NC} Files:      {len(files_written)}")
        print(f"{Colors.BOLD}└────────────────────────────────────────────┘{Colors.NC}")
        print()
        print("Generated files:")
        for file in files_written:
            print(f"  - {file}")

    return 0

if __name__ == '__main__':
    sys.exit(main())
