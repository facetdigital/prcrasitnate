# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Ruby-based tool that analyzes GitHub PR review latency metrics using the GitHub GraphQL API. It exports data to CSV files for analysis in Excel or other tools.

### File Structure

- `lib/prcrastinate.rb`: Main Ruby script containing all analysis logic
- `run`: Bash wrapper script that executes the Ruby script in a Docker container
- `README.md`: User-facing documentation
- `CLAUDE.md`: This file - guidance for Claude Code

## Running the Script

**Recommended (using Docker):**
```bash
GITHUB_TOKEN=xxxxx ./run owner/repo [YYYY-MM-DD] [YYYY-MM-DD]
```

**Direct (requires Ruby installed):**
```bash
GITHUB_TOKEN=xxxxx ruby lib/prcrastinate.rb owner/repo [YYYY-MM-DD] [YYYY-MM-DD]
```

Arguments:
- `owner/repo`: GitHub repository in owner/name format (required)
- First date: SINCE date (optional) - start of analysis period, defaults to 2008-01-01
- Second date: UNTIL date (optional) - end of analysis period, defaults to now

Environment:
- `GITHUB_TOKEN`: Required GitHub personal access token with repo access

Examples:
- `./run owner/repo` - Analyzes all merged PRs from 2008-01-01 until now
- `./run owner/repo 2025-08-01` - Analyzes from August 1st until now
- `./run owner/repo 2025-08-01 2025-11-30` - Analyzes specific date range

The `run` script:
- Uses `docker run` with `ruby:3.3` base image
- Mounts current directory to `/app` in container
- Passes through `GITHUB_TOKEN` environment variable
- Outputs CSV files to current directory

## Output Files

The script generates two CSV files in the current directory:

1. `pr_first_review.csv`: One row per PR with metrics about the first review
2. `pr_rereview_cycles.csv`: One row per re-review cycle after CHANGES_REQUESTED reviews

The script automatically cleans up any temporary files (`.tmp`, `.log`, or unwanted `.csv` files) after generating the desired outputs.

## Architecture

All line numbers below refer to `lib/prcrastinate.rb`.

### Data Flow

1. **PR Discovery** (lib/prcrastinate.rb:140-169): Uses GraphQL to fetch all merged PRs in descending creation order, filtering by date range
2. **Timeline Extraction** (lib/prcrastinate.rb:171-191): For each PR, fetches complete timeline with pagination
3. **Event Parsing** (lib/prcrastinate.rb:193-236): Normalizes different timeline event types into a unified time-ordered stream
4. **Metrics Computation**:
   - First review metrics (lib/prcrastinate.rb:238-258): Calculates latency from PR creation, review request, and last commit to first review
   - Re-review cycles (lib/prcrastinate.rb:260-300): Tracks time from author changes after CHANGES_REQUESTED to next review
5. **Output & Cleanup** (lib/prcrastinate.rb:378-391): Writes CSV files and cleans up temporary files

### Key Event Types

The script tracks these GitHub timeline events:
- `PullRequestReview`: Submitted reviews (APPROVED, CHANGES_REQUESTED, COMMENTED)
- `ReviewRequestedEvent`/`ReviewRequestRemovedEvent`: Review request lifecycle
- `PullRequestCommit`: Commit activity
- `ReadyForReviewEvent`/`ConvertToDraftEvent`: Draft status changes
- `ReviewDismissedEvent`: Review dismissals

### Latency Metrics

**First Review Metrics:**
- Created → First Review: Total time from PR creation to first review submission
- Review Requested → First Review: Time from earliest review request to first review
- Last Commit → First Review: Time from last commit before review to first review

**Re-Review Cycles:**
- Triggered after each CHANGES_REQUESTED review
- Start: First author commit after changes requested (or review re-request if no commit)
- End: Next review submission from any reviewer
- Tracks trigger type and outcome

### GraphQL Queries

Two main queries:
- `LIST_PRS_QUERY` (lib/prcrastinate.rb:69-86): Paginated PR list with basic metadata
- `TIMELINE_QUERY` (lib/prcrastinate.rb:88-138): Detailed timeline with all relevant event types

### Pagination Strategy

- PRs fetched in descending creation order (newest first)
- Stops when `createdAt < SINCE` for optimization
- Timeline items paginated with default 200 items per page
- Uses cursor-based pagination with `after` parameter
