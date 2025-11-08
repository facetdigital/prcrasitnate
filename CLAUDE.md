# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a single-file Ruby script (`prcrastinate.rb`) that analyzes GitHub PR review latency metrics using the GitHub GraphQL API. It exports data to CSV files for analysis in Excel or other tools.

## Running the Script

```bash
GITHUB_TOKEN=xxxxx ruby prcrastinate.rb owner/repo YYYY-MM-DD [YYYY-MM-DD]
```

Arguments:
- `owner/repo`: GitHub repository in owner/name format
- First date: SINCE date (required) - start of analysis period
- Second date: UNTIL date (optional) - end of analysis period, defaults to now

Environment:
- `GITHUB_TOKEN`: Required GitHub personal access token with repo access

## Output Files

The script generates two CSV files:

1. `pr_first_review.csv`: One row per PR with metrics about the first review
2. `pr_rereview_cycles.csv`: One row per re-review cycle after CHANGES_REQUESTED reviews

## Architecture

### Data Flow

1. **PR Discovery** (lines 140-169): Uses GraphQL to fetch all merged PRs in descending creation order, filtering by date range
2. **Timeline Extraction** (lines 171-191): For each PR, fetches complete timeline with pagination
3. **Event Parsing** (lines 193-236): Normalizes different timeline event types into a unified time-ordered stream
4. **Metrics Computation**:
   - First review metrics (lines 238-258): Calculates latency from PR creation, review request, and last commit to first review
   - Re-review cycles (lines 260-300): Tracks time from author changes after CHANGES_REQUESTED to next review

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
- `LIST_PRS_QUERY` (lines 69-86): Paginated PR list with basic metadata
- `TIMELINE_QUERY` (lines 88-138): Detailed timeline with all relevant event types

### Pagination Strategy

- PRs fetched in descending creation order (newest first)
- Stops when `createdAt < SINCE` for optimization
- Timeline items paginated with default 200 items per page
- Uses cursor-based pagination with `after` parameter
