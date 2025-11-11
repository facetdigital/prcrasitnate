#!/usr/bin/env ruby
# frozen_string_literal: true

# Minimal-deps Ruby script to export PR review-latency data for Excel.
# Usage:
#   prcrastinate.rb owner/name [SINCE] [UNTIL]
#
# Environment:
#   GITHUB_TOKEN must be set with a GitHub personal access token
#
# Arguments:
#   SINCE defaults to 2008-01-01 if not provided
#   UNTIL defaults to now if not provided
#
# Outputs:
#   - pr_first_review.csv       (one row per PR)
#   - pr_rereview_cycles.csv    (one row per re-review cycle after CHANGES_REQUESTED)
#
# Notes:
# - We consider PRs in state MERGED, ordered by CREATED_AT descending, and stop once createdAt < SINCE.
# - “First review” = earliest PullRequestReview.submittedAt (any state).
# - Clocks exported:
#     created_at -> first_review_submitted_at
#     earliest_review_requested_at -> first_review_submitted_at
#     last_commit_before_first_review_at -> first_review_submitted_at
# - Re-review cycles:
#     For each CHANGES_REQUESTED review, start at the first author commit AFTER that review,
#     end at the next PullRequestReview.submittedAt (from any reviewer) AFTER that commit.
# - You can add your own Excel filters to exclude draft periods, bots, weekends, etc.
#
# Standard library only.

require 'net/http'
require 'json'
require 'csv'
require 'time'

ENDPOINT = URI('https://api.github.com/graphql')

def abort_usage!
  $stderr.puts "Usage: #{File.basename($0)} owner/name [SINCE] [UNTIL]"
  $stderr.puts ""
  $stderr.puts "Arguments:"
  $stderr.puts "  owner/name  GitHub repository (e.g., facebook/react)"
  $stderr.puts "  SINCE       Start date in YYYY-MM-DD format (optional, defaults to 2008-01-01)"
  $stderr.puts "  UNTIL       End date in YYYY-MM-DD format (optional, defaults to now)"
  $stderr.puts ""
  $stderr.puts "Environment:"
  $stderr.puts "  GITHUB_TOKEN must be set with a GitHub personal access token"
  exit 1
end

REPO = ARGV[0] or abort_usage!
SINCE = ARGV[1] ? Time.parse(ARGV[1]) : Time.parse('2008-01-01')
UNTIL_T = ARGV[2] ? Time.parse(ARGV[2]) : Time.now.utc

TOKEN = ENV['GITHUB_TOKEN']
abort("Missing GITHUB_TOKEN env var") unless TOKEN && !TOKEN.empty?

OWNER, NAME = REPO.split('/', 2)
abort("Repo must be 'owner/name'") unless OWNER && NAME

def graphql(query, variables = {})
  req = Net::HTTP::Post.new(ENDPOINT)
  req['Authorization'] = "bearer #{TOKEN}"
  req['Content-Type'] = 'application/json'
  req.body = JSON.dump({ query: query, variables: variables })

  http = Net::HTTP.new(ENDPOINT.host, ENDPOINT.port)
  http.use_ssl = true
  res = http.request(req)

  unless res.is_a?(Net::HTTPSuccess)
    abort("HTTP error #{res.code}: #{res.body}")
  end

  body = JSON.parse(res.body)
  if body['errors']
    abort("GraphQL errors: #{body['errors'].to_json}")
  end
  body['data']
end

LIST_PRS_QUERY = <<~GRAPHQL
  query($owner:String!, $name:String!, $states:[PullRequestState!], $pageSize:Int!, $after:String) {
    repository(owner:$owner, name:$name) {
      pullRequests(states:$states, orderBy:{field:CREATED_AT, direction:DESC}, first:$pageSize, after:$after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          number
          title
          createdAt
          mergedAt
          author { login }
          isDraft
          url
        }
      }
    }
  }
GRAPHQL

TIMELINE_QUERY = <<~GRAPHQL
  query($owner:String!, $name:String!, $number:Int!, $pageSize:Int!, $after:String) {
    repository(owner:$owner, name:$name) {
      pullRequest(number:$number) {
        author { login }
        timelineItems(first:$pageSize, after:$after, itemTypes:[
          PULL_REQUEST_REVIEW,
          REVIEW_REQUESTED_EVENT,
          REVIEW_REQUEST_REMOVED_EVENT,
          PULL_REQUEST_COMMIT,
          READY_FOR_REVIEW_EVENT,
          CONVERT_TO_DRAFT_EVENT,
          REVIEW_DISMISSED_EVENT
        ]) {
          pageInfo { hasNextPage endCursor }
          nodes {
            __typename
            ... on PullRequestReview {
              state
              submittedAt
              author { login }
            }
            ... on ReviewRequestedEvent {
              createdAt
              requestedReviewer {
                __typename
                ... on User { login }
                ... on Team { slug }
              }
            }
            ... on ReviewRequestRemovedEvent {
              createdAt
              requestedReviewer {
                __typename
                ... on User { login }
                ... on Team { slug }
              }
            }
            ... on PullRequestCommit {
              commit { committedDate oid }
              url
            }
            ... on ReadyForReviewEvent { createdAt }
            ... on ConvertToDraftEvent { createdAt }
            ... on ReviewDismissedEvent { createdAt }
          }
        }
      }
    }
  }
GRAPHQL

def list_merged_prs_since(owner, name, since_time, until_time, page_size: 50)
  prs = []
  after = nil
  loop do
    data = graphql(LIST_PRS_QUERY, {
      owner: owner, name: name,
      states: ['MERGED'],
      pageSize: page_size, after: after
    })

    nodes = data.dig('repository', 'pullRequests', 'nodes') || []
    # Stop when PRs are older than SINCE, but keep those within [SINCE, UNTIL]
    nodes.each do |pr|
      created_at = Time.parse(pr['createdAt'])
      break if created_at < since_time
      next if pr['mergedAt'].nil?
      merged_at = Time.parse(pr['mergedAt'])
      next if merged_at < since_time || merged_at > until_time
      prs << pr
    end

    page_info = data.dig('repository', 'pullRequests', 'pageInfo')
    break unless page_info && page_info['hasNextPage']
    # Optimization: if the last PR on this page is older than SINCE, we can stop.
    last_created_at = nodes.last ? Time.parse(nodes.last['createdAt']) : Time.at(0)
    break if last_created_at < since_time
    after = page_info['endCursor']
  end
  prs
end

def fetch_full_timeline(owner, name, number, page_size: 200)
  items = []
  after = nil
  loop do
    data = graphql(TIMELINE_QUERY, {
      owner: owner, name: name, number: number,
      pageSize: page_size, after: after
    })
    pr = data.dig('repository', 'pullRequest')
    break unless pr

    ti = pr.dig('timelineItems')
    nodes = ti['nodes'] || []
    items.concat(nodes)

    pi = ti['pageInfo']
    break unless pi && pi['hasNextPage']
    after = pi['endCursor']
  end
  items
end

def parse_events(items)
  # Normalize into a unified time-ordered stream
  events = []

  items.each do |n|
    type = n['__typename']
    case type
    when 'PullRequestReview'
      next unless n['submittedAt']
      events << {
        type: 'review',
        state: n['state'],                    # APPROVED | CHANGES_REQUESTED | COMMENTED
        at: Time.parse(n['submittedAt']),
        reviewer: n.dig('author', 'login')
      }
    when 'ReviewRequestedEvent'
      rr = n['requestedReviewer']
      who = if rr
        rr['__typename'] == 'Team' ? "team:#{rr['slug']}" : rr['login']
      end
      events << { type: 'review_requested', at: Time.parse(n['createdAt']), requested: who }
    when 'ReviewRequestRemovedEvent'
      rr = n['requestedReviewer']
      who = if rr
        rr['__typename'] == 'Team' ? "team:#{rr['slug']}" : rr['login']
      end
      events << { type: 'review_request_removed', at: Time.parse(n['createdAt']), requested: who }
    when 'PullRequestCommit'
      c = n['commit']
      next unless c && c['committedDate']
      events << { type: 'commit', at: Time.parse(c['committedDate']), oid: c['oid'] }
    when 'ReadyForReviewEvent'
      events << { type: 'ready_for_review', at: Time.parse(n['createdAt']) }
    when 'ConvertToDraftEvent'
      events << { type: 'convert_to_draft', at: Time.parse(n['createdAt']) }
    when 'ReviewDismissedEvent'
      events << { type: 'review_dismissed', at: Time.parse(n['createdAt']) }
    else
      # ignore
    end
  end

  events.sort_by { |e| e[:at] }
end

def compute_first_review_metrics(pr, events)
  created_at = Time.parse(pr['createdAt'])
  first_review = events.find { |e| e[:type] == 'review' }
  first_review_at = first_review && first_review[:at]

  earliest_request = events.select { |e| e[:type] == 'review_requested' }.map { |e| e[:at] }.min

  commits_before_first_review = events.select { |e| e[:type] == 'commit' && first_review_at && e[:at] < first_review_at }
  last_commit_before_first = commits_before_first_review.max_by { |e| e[:at] }
  last_commit_before_first_at = last_commit_before_first && last_commit_before_first[:at]

  {
    created_at: created_at,
    first_review_at: first_review_at,
    created_to_first_review_seconds: (first_review_at && created_at) ? (first_review_at - created_at).to_i : nil,
    earliest_review_requested_at: earliest_request,
    review_requested_to_first_review_seconds: (first_review_at && earliest_request) ? (first_review_at - earliest_request).to_i : nil,
    last_commit_before_first_review_at: last_commit_before_first_at,
    last_commit_to_first_review_seconds: (first_review_at && last_commit_before_first_at) ? (first_review_at - last_commit_before_first_at).to_i : nil
  }
end

def compute_rereview_cycles(pr, events, pr_author_login)
  cycles = []
  # Find each CHANGES_REQUESTED
  cr_reviews = events.select { |e| e[:type] == 'review' && e[:state] == 'CHANGES_REQUESTED' }
  return cycles if cr_reviews.empty?

  commits = events.select { |e| e[:type] == 'commit' }
  reviews = events.select { |e| e[:type] == 'review' }

  cr_reviews.each_with_index do |cr, idx|
    # start = first author commit AFTER this changes requested
    start_commit = commits.find { |c| c[:at] > cr[:at] } # We don't have author on the event; GitHub GraphQL doesn't expose commit author login directly on PR commit node.
    # Fallback: if no commit after, try a later explicit review_requested event as a proxy
    start_time = start_commit ? start_commit[:at] : nil
    if start_time.nil?
      rr = events.find { |e| e[:type] == 'review_requested' && e[:at] > cr[:at] }
      start_time = rr[:at] if rr
      trigger = rr ? 'REVIEW_REQUESTED_AFTER_CR' : 'CHANGES_REQUESTED_NO_FOLLOWUP'
    else
      trigger = 'AUTHOR_COMMIT_AFTER_CR'
    end

    next unless start_time

    # end = next review after start_time
    end_review = reviews.find { |r| r[:at] > start_time }
    next unless end_review

    cycles << {
      index: idx + 1,
      start_at: start_time,
      end_at: end_review[:at],
      seconds: (end_review[:at] - start_time).to_i,
      trigger: trigger,
      end_review_state: end_review[:state],
      end_reviewer: end_review[:reviewer]
    }
  end

  cycles
end

def write_first_review_csv(rows)
  CSV.open('pr_first_review.csv', 'w', write_headers: true, headers: [
    'repo', 'pr_number', 'pr_url', 'pr_title', 'pr_author',
    'created_at', 'merged_at', 'is_draft',
    'first_review_at',
    'created_to_first_review_seconds',
    'earliest_review_requested_at',
    'review_requested_to_first_review_seconds',
    'last_commit_before_first_review_at',
    'last_commit_to_first_review_seconds'
  ]) do |csv|
    rows.each { |r| csv << r }
  end
end

def write_rereview_csv(rows)
  CSV.open('pr_rereview_cycles.csv', 'w', write_headers: true, headers: [
    'repo', 'pr_number', 'pr_url', 'cycle_index',
    'cycle_start_at', 'cycle_end_at', 'cycle_seconds',
    'cycle_trigger', 'end_review_state', 'end_reviewer'
  ]) do |csv|
    rows.each { |r| csv << r }
  end
end

# Main
puts "Fetching merged PRs for #{REPO} between #{SINCE.utc.iso8601} and #{UNTIL_T.utc.iso8601}..."
prs = list_merged_prs_since(OWNER, NAME, SINCE, UNTIL_T)
puts "Found #{prs.size} PRs."

first_review_rows = []
rereview_rows = []

prs.each_with_index do |pr, i|
  num = pr['number']
  puts "[#{i+1}/#{prs.size}] PR ##{num} – fetching timeline..."
  items = fetch_full_timeline(OWNER, NAME, num)
  events = parse_events(items)

  # First-review metrics
  fr = compute_first_review_metrics(pr, events)
  first_review_rows << [
    "#{OWNER}/#{NAME}",
    num,
    pr['url'],
    pr['title'],
    pr.dig('author', 'login'),
    Time.parse(pr['createdAt']).utc.iso8601,
    pr['mergedAt'] ? Time.parse(pr['mergedAt']).utc.iso8601 : nil,
    pr['isDraft'],
    fr[:first_review_at]&.utc&.iso8601,
    fr[:created_to_first_review_seconds],
    fr[:earliest_review_requested_at]&.utc&.iso8601,
    fr[:review_requested_to_first_review_seconds],
    fr[:last_commit_before_first_review_at]&.utc&.iso8601,
    fr[:last_commit_to_first_review_seconds]
  ]

  # Re-review cycles
  cycles = compute_rereview_cycles(pr, events, pr.dig('author', 'login'))
  cycles.each do |c|
    rereview_rows << [
      "#{OWNER}/#{NAME}",
      num,
      pr['url'],
      c[:index],
      c[:start_at].utc.iso8601,
      c[:end_at].utc.iso8601,
      c[:seconds],
      c[:trigger],
      c[:end_review_state],
      c[:end_reviewer]
    ]
  end
end

write_first_review_csv(first_review_rows)
write_rereview_csv(rereview_rows)

# Clean up any temporary files, keeping only the final outputs
desired_files = ['pr_first_review.csv', 'pr_rereview_cycles.csv']
Dir.glob('*.csv').each do |file|
  File.delete(file) unless desired_files.include?(File.basename(file))
end
Dir.glob('*.tmp').each { |f| File.delete(f) }
Dir.glob('*.log').each { |f| File.delete(f) }

puts "Done."
puts "Wrote pr_first_review.csv (#{first_review_rows.size} rows) and pr_rereview_cycles.csv (#{rereview_rows.size} rows)."
puts "Tip: In Excel, build pivot charts by week/month and overlay mean/median/p90."
