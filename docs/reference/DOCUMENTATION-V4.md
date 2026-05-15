# Documentation V4 Naming Convention - Complete Reference

**Version**: V4 (Final)
**Date**: 2026-02-03
**Status**: ✅ Production Ready

---

## Quick Reference

### V4 Naming Format
```
<TASK_ID>-<DATETIME>-<TYPE>-<description>.md
```

**Example**: `A3F2B9-2602031430-INC-webservices-queue-not-clearing.md`

### Components
| Component | Format | Example | Description |
|-----------|--------|---------|-------------|
| `TASK_ID` | 6 uppercase hex | `A3F2B9` | Deterministic hash of datetime+description (SHA256 first 6 hex chars) |
| `DATETIME` | 10 digits | `2602031430` | Creation timestamp (YYMMDDHHMM) |
| `TYPE` | 3 letters | `INC` | Document type code |
| `description` | kebab-case | `webservices-queue` | Brief description |

### Task ID Computation
```bash
TASK_ID=$(printf '%s%s' "$DATETIME" "$DESCRIPTION_SLUG" | sha256sum | head -c 6 | tr 'a-f' 'A-F')
```
- **Deterministic**: same datetime + slug always produces the same hash
- **Collision-resistant**: 16^6 = 16.7M combinations; ~0.003% collision at 1000 tasks
- **No coordination needed**: multiple users can create tasks simultaneously

### Folder Structure
```
docs/
├── active/                  # Work in progress
│   └── 2026-02/            # Date-based folders (YYYY-MM, auto-created)
├── completed/               # Finished work
│   └── 2026-02/            # Same date structure
├── reference/               # Timeless reference docs
└── SEQUENCE-TRACKER.md      # Auto-generated work item index
```

### Document Front Matter Fields
```markdown
**Work Item**: A3F2B9
**Folder**: docs/active/2026-02
**Created**: 2026-02-14 09:22
```
The `Folder` field is set once (from TSK doc's creation date) and shared by all related docs.

---

## Why V4 Format?

### Perfect Grouping + Perfect Chronology

```bash
ls docs/active/0000-0099/

0042-2602031400-INC-webservices-queue-not-clearing.md       # 2:00 PM - Incident
0042-2602031430-PLN-webservices-investigation-plan.md       # 2:30 PM - Plan
0042-2602031600-FND-webservices-investigation-findings.md   # 4:00 PM - Findings
0042-2602031700-FIX-webservices-queue-fix.md                # 5:00 PM - Fix
0042-2602101000-RCA-webservices-queue-rca.md                # Week later - RCA
0043-2602031800-TSK-upload-processor-database-error.md      # Next work item
```

**Benefits**:
1. ✅ **Task ID first** - All docs for work item A3F2B9 grouped together
2. ✅ **Time second** - Perfect chronological order within work item
3. ✅ **Type third** - Easy to identify document types
4. ✅ **Natural timeline** - File listings show progression automatically
5. ✅ **Metrics-friendly** - Calculate time-to-resolution easily
6. ✅ **Team-safe** - No coordination needed; hashes computed locally

---

## Document Type Codes

| Code | Type | When to Use | Primary? |
|------|------|-------------|----------|
| INC | Incident | Production issue, outage | Yes |
| TSK | Task | Work item, bug, feature | Yes |
| PLN | Plan | Investigation or implementation plan | No |
| FND | Findings | Investigation results | No |
| FIX | Fix | Solution implemented | No |
| DEP | Deployment | Infrastructure change, rollout | No |
| CRV | Code Review | Code quality/security assessment | No |
| RSK | Risk Analysis | Deployment/change risk assessment | No |
| RCA | Root Cause Analysis | Post-mortem analysis | No |
| RSP | Response | Customer/stakeholder communication (outgoing) | No |
| UPD | Update | External input received (email, SMS, Cliq, etc.) | No |
| SUM | Summary | Non-technical summary | No |
| SVC | Service | Service documentation | Standalone |
| RUN | Execution Run | Log of script/process execution | No |
| SCR | Script | Executable script file (php/bash/python) | No |
| AUD | Audit | Task progress and quality assessment | No |
| VRF | Verification | Implementation vs plan validation with scoring | No |
| IMP | Implementation Guide | Step-by-step implementation instructions | No |
| RSC | Research | Comparative analysis and recommendations | No |
| LRN | Lessons Learned | Retrospective and knowledge capture | No |
| REF | Reference | Standalone knowledge base article, how-to guide | Standalone |
| FRV | Feature Review | Completeness review - goal vs implementation, gaps, wiring | No |
| REV | Review | Code or feature review (general) | No |
| RFA | Refactor Analysis | Refactoring opportunities and recommendations | No |
| PERF | Performance | Performance analysis and bottleneck identification | No |
| DEAD | Dead Code | Dead code removal analysis | Standalone |
| AUDIT | Coverage Audit | Unified test coverage audit | Standalone |
| NET | Network Audit | Network activity and API call analysis | Standalone |

**Primary types** (INC, TSK) should be the first document created for a work item.

**Special Notes**:
- **RSK**: Comprehensive risk analysis for deployments or significant changes. Multiple RSK documents may exist for the same work item (e.g., staging risk, production risk, pre-deployment, post-mitigation)
- **RUN**: Documents a single execution of a script or process. Multiple RUN documents may exist for the same work item (e.g., backfill run #1, run #2, etc.)
- **SCR**: The actual executable script file. Extension matches the language (.php, .sh, .py, etc.) instead of .md

---

## Multi-File Work Items

One Task ID can have multiple documents for the same work item:

```
A3F2B9-2602031200-TSK-upload-processor-database-error.md     # Task
D84C12-2602031205-FND-database-connection-findings.md         # Findings (5 min later)
91E7A3-2602031210-FIX-connection-pool-configuration.md        # Fix (10 min later)
B6F204-2602101000-RCA-upload-processor-post-mortem.md         # RCA (week later)
```

Note: Each document has its own hash (from its own datetime+slug). Related documents are linked via the `--seq TASKID` flag, which stores the same `Folder:` path in each doc.

All documents for Task ID A3F2B9 will:
- Share the same `docs/active/YYYY-MM/` folder (set from the TSK doc's creation date)
- Sort together naturally within that folder
- Show chronological progression
- Move together when task is closed

---

## Creating Documents

### Global Creation Script

Located at: `~/.claude/scripts/new-doc.sh`

#### Create New Work Item
```bash
~/.claude/scripts/new-doc.sh --type INC --description webservices-down --new

# Computes: TASK_ID = sha256("2602031445webservices-down")[:6].upper() = "A3F2B9"
# Creates: A3F2B9-2602031445-INC-webservices-down.md
# Placed in: docs/active/2026-02/
```

#### Add to Existing Work Item
```bash
~/.claude/scripts/new-doc.sh --type FND --description webservices-investigation --id A3F2B9

# Creates: <new_hash>-2602031600-FND-webservices-investigation.md
# Placed in same folder as TSK: docs/active/2026-02/
```

#### Parameters
- `--type TYPE`: 3-letter document type (INC, TSK, FND, etc.)
- `--description DESC`: Kebab-case description
- `--new`: Create new work item (computes hash Task ID)
- `--id TASKID`: Add to existing work item (6-char hex Task ID)
- `--status active|completed`: Set initial status (default: active)

---

## Finding Documents

### By Task ID (Primary Method)
```bash
# All documents for work item A3F2B9
find docs -name "A3F2B9-*"

# Result: Perfect grouping + chronological order
A3F2B9-2602031400-INC-webservices-queue-not-clearing.md
D84C12-2602031430-PLN-webservices-investigation-plan.md
91E7A3-2602031600-FND-webservices-investigation-findings.md
B6F204-2602031700-FIX-webservices-queue-fix.md
```

### By Date/Time
```bash
# All documents from Feb 3, 2026
find docs -name "*-260203*"

# All documents from Feb 3, 2pm hour
find docs -name "*-26020314*"

# All documents from February 2026
find docs -name "*-2602*"
```

### By Type
```bash
# All incidents
find docs -name "*-INC-*"

# All RCAs
find docs -name "*-RCA-*"

# Incident for work item 0042
find docs -name "0042-*-INC-*"
```

---

## Utility Functions

Located at: `~/.claude/scripts/doc-utils.sh`

### Source in Scripts
```bash
source ~/.claude/scripts/doc-utils.sh
```

### Key Functions

#### Find by Task ID
```bash
find_by_sequence A3F2B9
# Returns all documents for Task ID A3F2B9 in chronological order
```

#### Find Primary Document
```bash
find_primary 0023
# Returns the main task document (TSK or INC type)
```

#### Get Sequence from Filename
```bash
filename="0042-2602031430-INC-description.md"
seq=$(get_sequence "$filename")
# Returns: 0042
```

#### Get Type from Filename
```bash
type=$(get_type "$filename")
# Returns: INC
```

#### Parse DateTime
```bash
datetime=$(get_datetime "$filename")
# Returns: 2602031430

human_time=$(parse_datetime "$datetime")
# Returns: 2026-02-03 14:30
```

#### Get Work Item Status
```bash
status=$(get_status 0023)
# Returns: "active" or "completed"
```

#### Show Task Info
```bash
show_task_info 0023
# Displays:
# Work Item: 0023
# Status: active
# Documents: 3
# Files:
#   - 2026-02-03 12:00 TSK 0023-2602031200-TSK-upload-processor-database-error.md
#   - 2026-02-03 12:05 FND 0023-2602031205-FND-database-connection-findings.md
#   - 2026-02-03 12:10 FIX 0023-2602031210-FIX-connection-pool-configuration.md
```

---

## Task Commands

All task commands now support V4 format and finding by task ID.

### task-capture - Create Task from External Source

**Usage**:
```bash
/task-capture
```

**Creates**: `docs/active/0000-0099/<NEXT_SEQ>-<DATETIME>-TSK-<description>.md`

**Features**:
- Uses `new-doc.sh` script internally
- Assigns next available task ID from SEQUENCE-TRACKER.md
- Places in active/ folder
- Shows task ID in output
- Supports capture from: Asana, GitHub, GitLab, Email, SMS, Voice, Direct input

---

### task-start - Start Working on Task

**Usage by Sequence**:
```bash
/task-start 23          # Simple number
/task-start 0023        # 4-digit format
```

**Usage by Path** (legacy):
```bash
/task-start docs/active/0000-0099/0023-2602031200-TSK-*.md
```

**Features**:
- Finds task by sequence using `find_primary()`
- Creates git branch from sequence and description
- Shows all related documents for the work item
- Sets up development environment

**Example**:
```bash
/task-start 23
# Finds: 0023-2602031200-TSK-upload-processor-database-error.md
# Creates branch: fix/23-upload-processor-database-error
# Shows all docs for work item 0023
```

---

### task-close - Complete or Defer Task

**Usage by Sequence**:
```bash
/task-close 23          # Simple number
/task-close 0023        # 4-digit format
```

**Features**:
- Finds ALL documents for sequence using `find_by_sequence()`
- Moves ALL related documents together
- Preserves range folder (active/0000-0099/ → completed/0000-0099/)
- Commits all documents in one commit
- Updates external tracking systems

**Example**:
```bash
/task-close 23
# Finds ALL docs: 0023-*-TSK-*.md, 0023-*-FND-*.md, 0023-*-FIX-*.md
# Moves all from: docs/active/0000-0099/
#           to: docs/completed/0000-0099/
# Commits: "docs: close work item 0023 - upload processor database error"
```

---

### task-create - Create Task in External System

**Usage**:
```bash
/task-create
```

**Features**:
- Creates task in Asana (work) or GitLab (home)
- Optionally auto-captures using V4 format
- References V4 structure in output

---

## Parsing Filenames

### Script-Friendly Parsing

```bash
FILENAME="0042-2602031430-INC-webservices-queue-not-clearing.md"

# Extract components
SEQ=$(echo $FILENAME | cut -d'-' -f1)                # 0042
DATETIME=$(echo $FILENAME | cut -d'-' -f2)           # 2602031430
TYPE=$(echo $FILENAME | cut -d'-' -f3)               # INC
DESC=$(echo $FILENAME | cut -d'-' -f4- | sed 's/.md$//')  # webservices-queue-not-clearing

# Parse datetime
YEAR="20${DATETIME:0:2}"     # 2026
MONTH="${DATETIME:2:2}"       # 02
DAY="${DATETIME:4:2}"         # 03
HOUR="${DATETIME:6:2}"        # 14
MIN="${DATETIME:8:2}"         # 30

echo "Work Item $SEQ on $YEAR-$MONTH-$DAY at $HOUR:$MIN"
# Output: Work Item 0042 on 2026-02-03 at 14:30
```

### Human-Readable

```
0042-2602031430-INC-webservices-queue-not-clearing.md

Decoded:
- Work item: 0042
- Date: February 3, 2026
- Time: 2:30 PM (14:30)
- Type: INC (Incident)
- Description: webservices queue not clearing
```

---

## Migration Summary

**Date**: 2026-02-03
**Status**: ✅ Complete

### What Was Migrated

- **25 documents** migrated from old structure
- **Sequences 0001-0025** assigned chronologically (oldest first)
- **6 active documents** in `docs/active/0000-0099/`
- **19 completed documents** in `docs/completed/0000-0099/`
- **Next sequence**: 0026
- **Backup**: `docs-backup-20260203-201059/`

### Old → New Format

| Old Structure | New Structure |
|--------------|---------------|
| `docs/incidents/INC-0001-20251126-caddy...md` | `docs/completed/0000-0099/0001-2511261200-INC-caddy-certificate-abuse-crash.md` |
| `docs/tasks/2026-02-03-bug-upload...md` | `docs/active/0000-0099/0023-2602031200-TSK-upload-processor-database-error.md` |
| `docs/findings/2026-02-03-upload-findings.md` | `docs/active/0000-0099/0015-2602031200-FND-processor-database-error-findings.md` |

**Note**: Migration used default time of 1200 (noon) for documents without recorded creation time.

---

## Real-World Workflow Example

### Incident Response Timeline

```bash
# 2:15 PM - Production alert fires
~/.claude/scripts/new-doc.sh --type INC --description database-timeout --new
→ Creates: 0050-2602031415-INC-database-timeout.md

# 2:30 PM - Start investigating
~/.claude/scripts/new-doc.sh --type PLN --description database-timeout-investigation --id 0050
→ Creates: 0050-2602031430-PLN-database-timeout-investigation.md

# 4:00 PM - Found root cause
~/.claude/scripts/new-doc.sh --type FND --description database-timeout-findings --id 0050
→ Creates: 0050-2602031600-FND-database-timeout-findings.md

# 4:30 PM - Fix deployed
~/.claude/scripts/new-doc.sh --type FIX --description database-timeout-fix --id 0050
→ Creates: 0050-2602031630-FIX-database-timeout-fix.md

# Next week - Write RCA
~/.claude/scripts/new-doc.sh --type RCA --description database-timeout-rca --id 0050
→ Creates: 0050-2602101000-RCA-database-timeout-rca.md

# View timeline
ls docs/active/0000-0099/0050-*

# Results:
0050-2602031415-INC-database-timeout.md               # 2:15 PM (Start)
0050-2602031430-PLN-database-timeout-investigation.md # 2:30 PM (+15 min)
0050-2602031600-FND-database-timeout-findings.md      # 4:00 PM (+1h 30m)
0050-2602031630-FIX-database-timeout-fix.md           # 4:30 PM (+30 min)
0050-2602101000-RCA-database-timeout-rca.md           # Week later

# Metrics visible in timeline:
# - Time to investigate: 15 minutes
# - Time to root cause: 1h 45m
# - Time to fix: 30 minutes
# - Total resolution: 2h 15m ✅
```

---

## Benefits Summary

### 1. Perfect Grouping
All documents for one work item grouped together (sequence first)

### 2. Chronological Order
Documents sort by creation time automatically (datetime second)

### 3. Natural Timeline
File listings show progression of work - no separate tools needed

### 4. Metrics-Friendly
Calculate time-to-resolution, response times directly from filenames

### 5. Human-Readable
Easy to parse: `260203` = Feb 3, 2026, `1430` = 2:30 PM

### 6. Script-Friendly
Simple field extraction with cut/sed/awk

### 7. Future-Proof
Handles 100 years (2000-2099) and 24-hour timestamps

### 8. Scalable
Range folders prevent filesystem overload (100 docs per folder max recommended)

### 9. Status Visibility
Clear active/ vs completed/ separation

### 10. Multi-Document Support
One work item can have many related documents, all moving together

---

## Command Quick Reference

| Action | Command |
|--------|---------|
| Create new work item | `~/.claude/scripts/new-doc.sh --type INC --description description --new` |
| Add to work item | `~/.claude/scripts/new-doc.sh --type FND --description description --id 0042` |
| Find by sequence | `find docs -name "0042-*"` |
| Find by date | `find docs -name "*-260203*"` |
| Find by type | `find docs -name "*-INC-*"` |
| View timeline | `ls docs/**/0042-*` |
| Show work item info | `source ~/.claude/scripts/doc-utils.sh && show_task_info 0042` |
| Capture task | `/task-capture` |
| Start task | `/task-start 0042` |
| Close task | `/task-close 0042` |
| Create external task | `/task-create` |

---

## Format Specification

```
Filename: <TASK_ID>-<DATETIME>-<TYPE>-<description>.md

<TASK_ID>:    6 uppercase hex chars (000000-FFFFFF)
              Hash-based identifier
              Global across all document types

<DATETIME>:   10 digits (YYMMDDHHMM)
  YY:         Year (00-99) → 2000-2099
  MM:         Month (01-12)
  DD:         Day (01-31)
  HH:         Hour (00-23, 24-hour format)
  MM:         Minute (00-59)

<TYPE>:       3 uppercase letters
              INC, RCA, TSK, FND, FIX, DEP, CRV, RSK, AUD, VRF, IMP, RSC, LRN, PLN, RSP, UPD, SUM, SVC, RUN, SCR, REF, FRV, REV, RFA, PERF, DEAD, AUDIT, NET

<description>: lowercase-kebab-case
              No spaces, use hyphens
              Brief, descriptive

Extension:    .md (Markdown)

Example: 0042-2602031430-INC-webservices-queue-not-clearing.md
```

---

## Tools and Scripts

### Global Scripts (Available Everywhere)

**Location**: `~/.claude/scripts/`

1. **new-doc.sh** - Create new documents
   - Auto-detects project docs directory
   - Manages task ID generation
   - Creates range folders automatically

2. **doc-utils.sh** - Utility functions
   - Find by task ID
   - Parse filenames
   - Get work item status
   - Show task information

### Project Script (Project-Specific)

**Location**: `<project>/scripts/migrate-to-v4.sh`

- One-time migration script
- Converts old structure to V4
- Assigns sequences chronologically
- Creates backups

### Command Integration

**Location**: `~/.claude/commands/`

All task commands updated to use V4:
- task-capture.md
- task-start.md
- task-close.md
- task-create.md

---

## Troubleshooting

### Can't Find Document by Sequence

```bash
# Check if sequence exists
source ~/.claude/scripts/doc-utils.sh
find_by_sequence 0042

# If empty, sequence doesn't exist
# Check SEQUENCE-TRACKER.md for next available
cat docs/SEQUENCE-TRACKER.md
```

### Multiple Projects

Each project has its own `docs/` folder with its own sequences. The global scripts auto-detect the project based on current directory.

```bash
# Project A
cd /path/to/projectA
~/.claude/scripts/new-doc.sh --type INC --description issue --new
# Creates in: projectA/docs/active/2026-02/

# Project B
cd /path/to/projectB
~/.claude/scripts/new-doc.sh --type INC --description issue --new
# Creates in: projectB/docs/active/2026-02/
```

### Range Folder Overflow

When sequence exceeds 99, next range folder is created automatically:

```
docs/active/
├── 0000-0099/  # Sequences 0-99
└── 0100-0199/  # Sequences 100-199 (auto-created)
```

---

## Version History

- **V1**: Type-first format (INC-0042-260203-description.md) - Abandoned
- **V2**: Sequence-first, no time (0042-INC-260203-description.md) - Abandoned
- **V3**: Sequence-first, date-second (0042-260203-INC-description.md) - Abandoned
- **V4**: Sequence-first, datetime-second (0042-2602031430-INC-description.md) - **FINAL** ✅

---

**Format**: `<TASK_ID>-<DATETIME>-<TYPE>-<description>.md`
**Example**: `0042-2602031430-INC-webservices-queue-not-clearing.md`
**Status**: ✅ Production Ready
**Documentation**: Complete
**Migration**: Complete
**Commands**: Updated
**Testing**: Recommended before full adoption
