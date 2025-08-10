# jira-ai

Ever wanted to grab a bunch of info from Jira, run some heuristics on it and make it available as markdown for AI? I did.

## To do

Update output to always include last comment, staleness
- Show bounces to/from QA for tickets that are not done or open

Test that `file` and `register` outputs work
Test developer stats command

## **Features**

- **Current Sprint Overview**
  - List all tickets in the current sprint, grouped by assignee.
  - Highlight tickets not assigned to any epic.
  - Show per-developer workload and story points.
  - Display sprint progress (tickets/points completed vs. total).
- **Epics Overview**
  - List all active epics and their progress.
  - Show tickets in each epic, including those spanning multiple sprints.
- **Attention & Action Items**
  - Identify stale tickets (no updates in X days).
  - Highlight tickets stuck in QA or with excessive QA bounces.
  - Mark blocked/flagged tickets and show blockers.
  - Identify sprint carryover tickets (not completed in previous sprint).
  - Show unassigned or neglected tickets.
- **Developer Insights**
  - Per-developer statistics: assigned/completed tickets and points per sprint.
  - Average velocity per developer over recent sprints.
- **Comments & Activity**
  - Show latest comment for each ticket.
  - Highlight tickets with recent activity or mentions.
- **Markdown Export**
  - Generate markdown summaries for easy AI prompt integration.
  - Export to file, register, or a new buffer
- **Flexible File Browsing**
  - Built-in file browsing with vim.ui.select
  - Optional Telescope extension for enhanced picker experience
  - Modular picker system - integrate with any picker you prefer
  - Browse snapshots, attention items, epics, and user stats

---

**Roadmap**

- [x] Basic sprint and epic summaries
- [x] Markdown output for AI consumption
- [x] Replace Jira CLI with direct API/JQL queries
- [x] Stale ticket detection and highlighting
- [ ] Sprint carryover ticket identification
- [x] QA bounce/stuck ticket detection
- [x] Per-developer workload and velocity stats
- [x] Blocked/flagged ticket reporting
- [x] Recent comments and mentions summary
- [x] Configurable thresholds (e.g., stale days, QA bounce count)
- [ ] Batch API calls for performance
- [ ] (Future) Sprint forecasting and advanced analytics (AI-powered)
- [ ] (Future) Considering github activity as part of staleness/activity considerations
- [x] (Future, only if needed) Use a local sqlite DB or an in-memory cache to store Jira data for faster access and reduced API calls.
  - Introduced json caching to speed up repeated queries
