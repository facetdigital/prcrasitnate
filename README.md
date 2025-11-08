# PRcrastinate

A Ruby script to analyze GitHub Pull Request review latency metrics and export the data to CSV files for analysis in Excel or other tools.

## Quickstart

```bash
# Get a GitHub token from https://github.com/settings/tokens (needs 'repo' scope)
export GITHUB_TOKEN=ghp_xxxxxxxxxxxx

# Run the analysis (analyzes PRs merged from August 1st until now)
./run myorg/myrepo 2025-08-01

# Or with a specific date range
./run myorg/myrepo 2025-11-01 2025-11-30
```

This will generate two CSV files: `pr_first_review.csv` and `pr_rereview_cycles.csv`

## Overview

PRcrastinate helps you understand how long it takes for PRs to get reviewed in your repository by tracking:
- Time from PR creation to first review
- Time from review request to first review
- Time from last commit to first review
- Re-review cycles after changes are requested

## Prerequisites

- Docker
- A GitHub Personal Access Token

## Getting a GitHub Token

1. Go to GitHub Settings: https://github.com/settings/tokens
2. Click **"Generate new token"** → **"Generate new token (classic)"**
3. Give your token a descriptive name (e.g., "PR Review Latency Analysis")
4. Set an expiration date (recommended: 90 days or custom)
5. Select the following scopes:
   - `repo` (Full control of private repositories)
     - This includes `repo:status`, `repo_deployment`, `public_repo`, `repo:invite`, and `security_events`
   - Alternatively, if analyzing only public repositories, you can use just:
     - `public_repo` (Access public repositories)

6. Click **"Generate token"**
7. **Copy the token immediately** - you won't be able to see it again!

### Required Token Scopes

- **For private repositories**: `repo` scope
- **For public repositories only**: `public_repo` scope

The script needs read access to pull requests, reviews, and timeline events.

## Usage

The `./run` script runs the analysis in a Docker container, so you don't need Ruby installed locally.

### Basic Usage

```bash
GITHUB_TOKEN=your_token_here ./run owner/repo YYYY-MM-DD
```

### With End Date

```bash
GITHUB_TOKEN=your_token_here ./run owner/repo YYYY-MM-DD YYYY-MM-DD
```

### Arguments

1. **Repository** (required): GitHub repository in `owner/name` format (e.g., `facebook/react`)
2. **SINCE date** (required): Start date for analysis in `YYYY-MM-DD` format
3. **UNTIL date** (optional): End date for analysis in `YYYY-MM-DD` format (defaults to current time)

The script analyzes PRs that were **merged** between the SINCE and UNTIL dates.

### Setting the Token

You can set the `GITHUB_TOKEN` environment variable in several ways:

**Option 1: Inline (recommended for one-time use)**
```bash
GITHUB_TOKEN=ghp_xxxxxxxxxxxx ./run owner/repo 2025-08-01
```

**Option 2: Export in your shell session**
```bash
export GITHUB_TOKEN=ghp_xxxxxxxxxxxx
./run owner/repo 2025-08-01
```

**Option 3: In your shell profile (for repeated use)**

Add to `~/.bashrc`, `~/.zshrc`, or equivalent:
```bash
export GITHUB_TOKEN=ghp_xxxxxxxxxxxx
```

Then reload your shell or run `source ~/.bashrc`

⚠️ **Security Note**: Never commit your token to version control. Consider using a `.env` file (and add it to `.gitignore`) or a secrets manager.

## Examples

**Analyze PRs merged in November 2025:**
```bash
GITHUB_TOKEN=ghp_xxxxxxxxxxxx ./run myorg/myrepo 2025-11-01 2025-11-30
```

**Analyze PRs merged from August 1st until now:**
```bash
GITHUB_TOKEN=ghp_xxxxxxxxxxxx ./run myorg/myrepo 2025-08-01
```

**Running without Docker (if you have Ruby installed):**
```bash
GITHUB_TOKEN=ghp_xxxxxxxxxxxx ruby lib/prcrastinate.rb myorg/myrepo 2025-08-01
```

## Output

The script generates two CSV files:

### `pr_first_review.csv`

One row per PR with columns:
- `repo`: Repository name
- `pr_number`: PR number
- `pr_url`: Link to the PR
- `pr_title`: PR title
- `pr_author`: GitHub username of PR author
- `created_at`: When the PR was created
- `merged_at`: When the PR was merged
- `is_draft`: Whether the PR was a draft
- `first_review_at`: When the first review was submitted
- `created_to_first_review_seconds`: Latency from creation to first review
- `earliest_review_requested_at`: When the first review was requested
- `review_requested_to_first_review_seconds`: Latency from review request to first review
- `last_commit_before_first_review_at`: Last commit before the first review
- `last_commit_to_first_review_seconds`: Latency from last commit to first review

### `pr_rereview_cycles.csv`

One row per re-review cycle (after `CHANGES_REQUESTED`) with columns:
- `repo`: Repository name
- `pr_number`: PR number
- `pr_url`: Link to the PR
- `cycle_index`: Which re-review cycle this is (1, 2, 3...)
- `cycle_start_at`: When the cycle started (first commit after changes requested)
- `cycle_end_at`: When the cycle ended (next review submission)
- `cycle_seconds`: Duration of the re-review cycle
- `cycle_trigger`: What triggered the cycle (e.g., `AUTHOR_COMMIT_AFTER_CR`)
- `end_review_state`: State of the review that ended the cycle
- `end_reviewer`: Who submitted the review that ended the cycle

## Analyzing the Data

The CSV files can be imported into Excel, Google Sheets, or any data analysis tool.

**Suggested analyses:**
- Create pivot tables grouping by week or month
- Calculate mean, median, and p90 (90th percentile) review latencies
- Filter out draft periods or bot activity
- Identify trends over time
- Compare latencies across different time periods

## Troubleshooting

**"Missing GITHUB_TOKEN env var"**
- Make sure you've set the `GITHUB_TOKEN` environment variable

**"HTTP error 401"** or **"Bad credentials"**
- Your token is invalid or expired - generate a new one

**"HTTP error 403"** or **"Resource not accessible"**
- Your token doesn't have the required scopes
- For private repos, ensure the `repo` scope is enabled
- The repository might not exist or you don't have access

**"GraphQL errors"**
- Check that the repository name is in the correct format: `owner/name`
- Verify the dates are in `YYYY-MM-DD` format
