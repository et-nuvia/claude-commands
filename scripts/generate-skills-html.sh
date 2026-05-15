#!/usr/bin/env bash
# Generate comprehensive skills-documentation.html with interactive workflow examples
# Usage: ./scripts/generate-skills-html.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(dirname "$SCRIPT_DIR")"
COMMANDS_DIR="${CLAUDE_DIR}/commands"
OUTPUT_FILE="${CLAUDE_DIR}/docs/skills-documentation.html"

echo "🔨 Generating Skills HTML from command files..."

# Extract command data
declare -A commands
declare -A descriptions
declare -A categories

while IFS= read -r cmd_file; do
    cmd_name=$(basename "$cmd_file" .md)
    description=$(grep "^description:" "$cmd_file" | head -1 | sed 's/description: //' | sed 's/"//g' | sed "s/'//g" || echo "")
    if [[ -z "$description" ]]; then
        description=$(grep "^# " "$cmd_file" | head -1 | sed 's/^# //' || echo "$cmd_name")
    fi

    # Categorize commands
    category="Other"
    if [[ "$cmd_name" =~ ^task- ]]; then category="Task Management"
    elif [[ "$cmd_name" =~ ^rca- ]]; then category="Incident Response"
    elif [[ "$cmd_name" =~ ^deploy- ]]; then category="Deployment"
    elif [[ "$cmd_name" =~ ^test- || "$cmd_name" == "test" ]]; then category="Testing"
    elif [[ "$cmd_name" =~ ^git- ]]; then category="Git Operations"
    elif [[ "$cmd_name" =~ ^review ]]; then category="Code Review"
    elif [[ "$cmd_name" =~ ^security- ]]; then category="Security"
    elif [[ "$cmd_name" =~ ^db- ]]; then category="Database"
    elif [[ "$cmd_name" =~ ^pipeline- ]]; then category="CI/CD"
    elif [[ "$cmd_name" =~ ^infra- ]]; then category="Infrastructure"
    elif [[ "$cmd_name" =~ ^ops- ]]; then category="Operations"
    elif [[ "$cmd_name" =~ ^docker- || "$cmd_name" == "dockerfile-build" ]]; then category="Docker"
    elif [[ "$cmd_name" =~ ^docs || "$cmd_name" == "document-api" ]]; then category="Documentation"
    elif [[ "$cmd_name" =~ ^plan- ]]; then category="Planning"
    fi

    commands["$cmd_name"]="$description"
    categories["$cmd_name"]="$category"
done < <(find "$COMMANDS_DIR" -name "*.md" -type f | sort)

TOTAL_COMMANDS=${#commands[@]}
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

echo "✓ Found $TOTAL_COMMANDS commands"
echo "📝 Generating HTML..."

cat > "$OUTPUT_FILE" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Claude Workflows & Skills - Complete Reference</title>
    <style>
        :root {
            --bg-primary: #0f172a;
            --bg-secondary: #1e293b;
            --bg-tertiary: #334155;
            --bg-code: #1e1e1e;
            --text-primary: #f1f5f9;
            --text-secondary: #cbd5e1;
            --text-muted: #94a3b8;
            --accent-primary: #3b82f6;
            --accent-hover: #2563eb;
            --accent-light: #60a5fa;
            --success: #10b981;
            --warning: #f59e0b;
            --danger: #ef4444;
            --border: #475569;
            --sidebar-width: 280px;
        }

        body.light-mode {
            --bg-primary: #ffffff;
            --bg-secondary: #f8fafc;
            --bg-tertiary: #e2e8f0;
            --bg-code: #f5f5f5;
            --text-primary: #0f172a;
            --text-secondary: #475569;
            --text-muted: #64748b;
            --accent-primary: #2563eb;
            --accent-hover: #1d4ed8;
            --accent-light: #3b82f6;
            --border: #cbd5e1;
        }

        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
            line-height: 1.6;
            color: var(--text-primary);
            background: var(--bg-primary);
            transition: background 0.3s, color 0.3s;
        }

        .container {
            max-width: 1400px;
            margin: 0 auto;
            padding: 40px 20px;
        }

        .header {
            text-align: center;
            margin-bottom: 60px;
            padding: 40px 20px;
            background: var(--bg-secondary);
            border-radius: 16px;
            border: 1px solid var(--border);
        }

        .header h1 {
            font-size: 3em;
            margin-bottom: 15px;
            background: linear-gradient(135deg, var(--accent-primary), var(--accent-light));
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }

        .header-meta {
            color: var(--text-muted);
            font-size: 0.9em;
        }

        .theme-toggle {
            position: fixed;
            top: 20px;
            right: 20px;
            padding: 12px 20px;
            background: var(--bg-secondary);
            border: 1px solid var(--border);
            border-radius: 8px;
            cursor: pointer;
            color: var(--text-primary);
            font-size: 1.1em;
            z-index: 1000;
            transition: all 0.3s;
        }

        .theme-toggle:hover {
            background: var(--bg-tertiary);
            border-color: var(--accent-primary);
        }

        .nav-tabs {
            display: flex;
            gap: 15px;
            margin-bottom: 40px;
            border-bottom: 2px solid var(--border);
            flex-wrap: wrap;
        }

        .nav-tab {
            padding: 15px 30px;
            background: transparent;
            border: none;
            color: var(--text-secondary);
            cursor: pointer;
            font-size: 1.1em;
            font-weight: 500;
            border-bottom: 3px solid transparent;
            transition: all 0.3s;
            position: relative;
            bottom: -2px;
        }

        .nav-tab:hover {
            color: var(--accent-light);
        }

        .nav-tab.active {
            color: var(--accent-primary);
            border-bottom-color: var(--accent-primary);
        }

        .tab-content {
            display: none;
        }

        .tab-content.active {
            display: block;
        }

        .workflow-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(350px, 1fr));
            gap: 25px;
            margin: 30px 0;
        }

        .workflow-card {
            background: var(--bg-secondary);
            border-radius: 12px;
            padding: 25px;
            border: 1px solid var(--border);
            cursor: pointer;
            transition: all 0.3s;
            position: relative;
            overflow: hidden;
        }

        .workflow-card::before {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            width: 4px;
            height: 100%;
            background: var(--accent-primary);
            transform: scaleY(0);
            transition: transform 0.3s;
        }

        .workflow-card:hover {
            border-color: var(--accent-primary);
            box-shadow: 0 8px 24px rgba(59, 130, 246, 0.2);
            transform: translateY(-2px);
        }

        .workflow-card:hover::before {
            transform: scaleY(1);
        }

        .workflow-icon {
            font-size: 2.5em;
            margin-bottom: 15px;
        }

        .workflow-title {
            font-size: 1.4em;
            font-weight: 600;
            color: var(--text-primary);
            margin-bottom: 10px;
        }

        .workflow-summary {
            color: var(--text-secondary);
            font-size: 0.95em;
            margin-bottom: 20px;
        }

        .workflow-badge {
            display: inline-block;
            padding: 4px 10px;
            background: var(--bg-tertiary);
            border-radius: 4px;
            font-size: 0.85em;
            color: var(--text-secondary);
            margin-right: 8px;
            margin-bottom: 8px;
        }

        .workflow-badge.high {
            background: rgba(59, 130, 246, 0.2);
            color: var(--accent-light);
        }

        .workflow-detail {
            display: none;
            margin-top: 40px;
            padding: 40px;
            background: var(--bg-secondary);
            border-radius: 16px;
            border: 1px solid var(--border);
        }

        .workflow-detail.active {
            display: block;
            animation: slideIn 0.3s ease;
        }

        @keyframes slideIn {
            from {
                opacity: 0;
                transform: translateY(20px);
            }
            to {
                opacity: 1;
                transform: translateY(0);
            }
        }

        .workflow-detail-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 30px;
            padding-bottom: 20px;
            border-bottom: 2px solid var(--border);
        }

        .workflow-detail-title {
            font-size: 2em;
            font-weight: 600;
        }

        .close-btn {
            padding: 10px 20px;
            background: var(--bg-tertiary);
            border: 1px solid var(--border);
            border-radius: 8px;
            color: var(--text-primary);
            cursor: pointer;
            transition: all 0.3s;
        }

        .close-btn:hover {
            background: var(--danger);
            border-color: var(--danger);
        }

        .workflow-step {
            margin: 30px 0;
            padding: 25px;
            background: var(--bg-tertiary);
            border-radius: 12px;
            border-left: 4px solid var(--accent-primary);
        }

        .step-number {
            display: inline-block;
            width: 32px;
            height: 32px;
            background: var(--accent-primary);
            color: white;
            border-radius: 50%;
            text-align: center;
            line-height: 32px;
            font-weight: 600;
            margin-right: 15px;
        }

        .step-title {
            font-size: 1.3em;
            font-weight: 600;
            margin-bottom: 15px;
            display: flex;
            align-items: center;
        }

        .step-description {
            color: var(--text-secondary);
            margin-bottom: 20px;
        }

        .code-example {
            background: var(--bg-code);
            padding: 20px;
            border-radius: 8px;
            font-family: 'Courier New', monospace;
            font-size: 0.9em;
            overflow-x: auto;
            margin: 15px 0;
            border: 1px solid var(--border);
        }

        .code-example pre {
            margin: 0;
            color: var(--accent-light);
        }

        .code-comment {
            color: var(--text-muted);
        }

        .expandable {
            margin: 20px 0;
        }

        .expandable-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 15px 20px;
            background: var(--bg-primary);
            border-radius: 8px;
            cursor: pointer;
            transition: all 0.3s;
            border: 1px solid var(--border);
        }

        .expandable-header:hover {
            background: var(--bg-tertiary);
            border-color: var(--accent-primary);
        }

        .expandable-title {
            font-weight: 600;
            font-size: 1.1em;
        }

        .expandable-icon {
            transition: transform 0.3s;
        }

        .expandable.open .expandable-icon {
            transform: rotate(180deg);
        }

        .expandable-content {
            display: none;
            padding: 20px;
            background: var(--bg-primary);
            border-radius: 0 0 8px 8px;
            border: 1px solid var(--border);
            border-top: none;
            margin-top: -8px;
        }

        .expandable.open .expandable-content {
            display: block;
        }

        .variation-box {
            background: rgba(16, 185, 129, 0.1);
            border-left: 4px solid var(--success);
            padding: 20px;
            border-radius: 8px;
            margin: 15px 0;
        }

        .variation-title {
            font-weight: 600;
            color: var(--success);
            margin-bottom: 10px;
        }

        .output-box {
            background: rgba(59, 130, 246, 0.1);
            border-left: 4px solid var(--accent-primary);
            padding: 20px;
            border-radius: 8px;
            margin: 15px 0;
        }

        .output-title {
            font-weight: 600;
            color: var(--accent-primary);
            margin-bottom: 10px;
        }

        .commands-section {
            margin-top: 40px;
        }

        .category-group {
            margin: 30px 0;
        }

        .category-title {
            font-size: 1.5em;
            font-weight: 600;
            color: var(--accent-primary);
            margin-bottom: 20px;
            padding-left: 15px;
            border-left: 4px solid var(--accent-primary);
        }

        .command-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
            gap: 15px;
        }

        .command-item {
            background: var(--bg-tertiary);
            padding: 15px 20px;
            border-radius: 8px;
            border: 1px solid var(--border);
            transition: all 0.2s;
        }

        .command-item:hover {
            border-color: var(--accent-primary);
            box-shadow: 0 4px 12px rgba(59, 130, 246, 0.15);
        }

        .command-name {
            font-family: 'Courier New', monospace;
            font-size: 1.05em;
            color: var(--accent-light);
            font-weight: 600;
            margin-bottom: 8px;
        }

        .command-desc {
            color: var(--text-secondary);
            font-size: 0.9em;
        }

        .search-box {
            width: 100%;
            padding: 15px 20px;
            background: var(--bg-secondary);
            border: 2px solid var(--border);
            border-radius: 8px;
            color: var(--text-primary);
            font-size: 1em;
            margin-bottom: 30px;
            transition: all 0.3s;
        }

        .search-box:focus {
            outline: none;
            border-color: var(--accent-primary);
            box-shadow: 0 0 0 4px rgba(59, 130, 246, 0.2);
        }

        .info-badge {
            display: inline-block;
            padding: 6px 12px;
            background: var(--bg-tertiary);
            border-radius: 6px;
            font-size: 0.85em;
            color: var(--text-secondary);
            margin: 5px 5px 5px 0;
        }

        .info-badge.priority {
            background: rgba(239, 68, 68, 0.2);
            color: var(--danger);
        }

        .info-badge.flexible {
            background: rgba(245, 158, 11, 0.2);
            color: var(--warning);
        }

        .back-to-top {
            position: fixed;
            bottom: 30px;
            right: 30px;
            padding: 15px 20px;
            background: var(--accent-primary);
            color: white;
            border-radius: 50%;
            cursor: pointer;
            box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
            transition: all 0.3s;
            display: none;
            z-index: 999;
        }

        .back-to-top.visible {
            display: block;
        }

        .back-to-top:hover {
            background: var(--accent-hover);
            transform: translateY(-3px);
        }
    </style>
</head>
<body>
    <div class="theme-toggle" onclick="toggleTheme()">🌓</div>
    <div class="back-to-top" onclick="scrollToTop()">↑</div>

    <div class="container">
        <div class="header">
            <h1>🚀 Claude Workflows & Skills</h1>
            <div class="header-meta">
                Complete Reference • COMMAND_COUNT Commands • Generated: TIMESTAMP
            </div>
        </div>

        <div class="nav-tabs">
            <button class="nav-tab active" onclick="showTab('workflows')">Workflows</button>
            <button class="nav-tab" onclick="showTab('commands')">All Commands</button>
        </div>

        <div id="workflows-tab" class="tab-content active">
            <h2 style="font-size: 2em; margin-bottom: 30px;">Interactive Workflow Examples</h2>

            <div class="workflow-grid">
                <!-- Task Management Workflow -->
                <div class="workflow-card" onclick="showWorkflowDetail('task-workflow')">
                    <div class="workflow-icon">📋</div>
                    <div class="workflow-title">Task Management</div>
                    <div class="workflow-summary">Complete task lifecycle from capture to deployment</div>
                    <span class="workflow-badge high">High Detail</span>
                    <span class="workflow-badge flexible">Highly Flexible</span>
                </div>

                <!-- RCA/Incident Response -->
                <div class="workflow-card" onclick="showWorkflowDetail('rca-workflow')">
                    <div class="workflow-icon">🔥</div>
                    <div class="workflow-title">RCA/Incident Response</div>
                    <div class="workflow-summary">Systematic root cause analysis for production incidents</div>
                    <span class="workflow-badge high">High Detail</span>
                    <span class="workflow-badge priority">Critical</span>
                </div>

                <!-- Deployment Workflow -->
                <div class="workflow-card" onclick="showWorkflowDetail('deployment-workflow')">
                    <div class="workflow-icon">🚢</div>
                    <div class="workflow-title">Safe Deployment</div>
                    <div class="workflow-summary">Staging and production deployment with risk analysis</div>
                    <span class="workflow-badge high">High Detail</span>
                    <span class="workflow-badge flexible">Flexible</span>
                </div>

                <!-- Code Review - Medium Detail -->
                <div class="workflow-card" onclick="showWorkflowDetail('review-workflow')">
                    <div class="workflow-icon">👀</div>
                    <div class="workflow-title">Code Review</div>
                    <div class="workflow-summary">Comprehensive PR/MR review process</div>
                    <span class="workflow-badge">Medium Detail</span>
                </div>

                <!-- Testing - Medium Detail -->
                <div class="workflow-card" onclick="showWorkflowDetail('testing-workflow')">
                    <div class="workflow-icon">🧪</div>
                    <div class="workflow-title">Testing Workflow</div>
                    <div class="workflow-summary">TDD, unit, integration, and E2E testing</div>
                    <span class="workflow-badge">Medium Detail</span>
                </div>

                <!-- Git Operations - Medium Detail -->
                <div class="workflow-card" onclick="showWorkflowDetail('git-workflow')">
                    <div class="workflow-icon">🌿</div>
                    <div class="workflow-title">Git Operations</div>
                    <div class="workflow-summary">Commits, branches, PRs, and rebasing</div>
                    <span class="workflow-badge">Medium Detail</span>
                </div>

                <!-- Security - Medium Detail -->
                <div class="workflow-card" onclick="showWorkflowDetail('security-workflow')">
                    <div class="workflow-icon">🔒</div>
                    <div class="workflow-title">Security Audit</div>
                    <div class="workflow-summary">Vulnerability scanning and compliance</div>
                    <span class="workflow-badge">Medium Detail</span>
                </div>

                <!-- Additional workflows with lower detail -->
                <div class="workflow-card" onclick="showWorkflowDetail('db-workflow')">
                    <div class="workflow-icon">🗄️</div>
                    <div class="workflow-title">Database Operations</div>
                    <div class="workflow-summary">Performance, backup, and recovery</div>
                </div>

                <div class="workflow-card" onclick="showWorkflowDetail('infra-workflow')">
                    <div class="workflow-icon">☁️</div>
                    <div class="workflow-title">Infrastructure</div>
                    <div class="workflow-summary">Terraform infrastructure management</div>
                </div>

                <div class="workflow-card" onclick="showWorkflowDetail('docker-workflow')">
                    <div class="workflow-icon">🐳</div>
                    <div class="workflow-title">Docker Development</div>
                    <div class="workflow-summary">Container build and hardening</div>
                </div>

                <div class="workflow-card" onclick="showWorkflowDetail('pipeline-workflow')">
                    <div class="workflow-icon">⚙️</div>
                    <div class="workflow-title">CI/CD Pipelines</div>
                    <div class="workflow-summary">Pipeline setup and optimization</div>
                </div>

                <div class="workflow-card" onclick="showWorkflowDetail('ops-workflow')">
                    <div class="workflow-icon">📊</div>
                    <div class="workflow-title">Operations</div>
                    <div class="workflow-summary">Monitoring, scaling, and cost optimization</div>
                </div>
            </div>
HTMLEOF

# Now add the detailed workflow sections
# I'll add the three high-detail workflows inline here

cat >> "$OUTPUT_FILE" << 'WORKFLOWSEOF'

            <!-- TASK MANAGEMENT WORKFLOW - HIGH DETAIL -->
            <div id="task-workflow" class="workflow-detail">
                <div class="workflow-detail-header">
                    <h2 class="workflow-detail-title">📋 Task Management Workflow</h2>
                    <button class="close-btn" onclick="hideWorkflowDetail()">✕ Close</button>
                </div>

                <p style="font-size: 1.1em; color: var(--text-secondary); margin-bottom: 30px;">
                    Complete lifecycle: <strong>Capture → Plan → Start → Work → [Hold] → Close</strong>
                </p>

                <!-- Step 1: Capture Task -->
                <div class="workflow-step">
                    <div class="step-title">
                        <span class="step-number">1</span>
                        Capture Task
                    </div>
                    <div class="step-description">
                        Capture tasks from any source into structured format
                    </div>

                    <div class="code-example">
                        <pre><span class="code-comment"># From GitHub/GitLab issue</span>
/task-capture #123
/task-capture https://github.com/owner/repo/issues/123

<span class="code-comment"># From Asana</span>
/task-capture https://app.asana.com/0/PROJECT/TASK

<span class="code-comment"># Direct input</span>
/task-capture Add user authentication to API

<span class="code-comment"># From email (paste content)</span>
/task-capture
From: boss@company.com
Subject: Fix production bug
...</pre>
                    </div>

                    <div class="expandable">
                        <div class="expandable-header" onclick="toggleExpandable(this)">
                            <span class="expandable-title">💡 What You Can Change</span>
                            <span class="expandable-icon">▼</span>
                        </div>
                        <div class="expandable-content">
                            <div class="variation-box">
                                <div class="variation-title">Source Type</div>
                                <strong>Options:</strong> GitHub, GitLab, Jira, Asana, Email, SMS, Direct input<br>
                                <strong>Effect:</strong> Determines parsing strategy and metadata extraction<br>
                                <strong>Example:</strong> GitHub issues preserve labels/milestones, Asana includes subtasks
                            </div>

                            <div class="variation-box">
                                <div class="variation-title">Task Complexity</div>
                                <strong>Effect:</strong> Simple descriptions → quick capture, Complex → AI parsing with Opus<br>
                                <strong>When to use detailed input:</strong> Complex requirements, ambiguous scope, multiple stakeholders
                            </div>
                        </div>
                    </div>

                    <div class="expandable">
                        <div class="expandable-header" onclick="toggleExpandable(this)">
                            <span class="expandable-title">📤 Expected Output</span>
                            <span class="expandable-icon">▼</span>
                        </div>
                        <div class="expandable-content">
                            <div class="output-box">
                                <div class="output-title">Output: Task Document</div>
                                <pre>Created: docs/active/0000-0099/0042-2602101830-TSK-add-user-auth.md

Task Summary: Add JWT-based authentication to API
Priority: High
Type: Feature
Complexity: Medium (M)

✓ 3 acceptance criteria identified
⚠ 1 ambiguity to clarify: Session timeout duration?</pre>
                            </div>
                        </div>
                    </div>
                </div>

                <!-- Step 2: Start Task -->
                <div class="workflow-step">
                    <div class="step-title">
                        <span class="step-number">2</span>
                        Start Task
                    </div>
                    <div class="step-description">
                        Create branch, set up environment, prepare for implementation
                    </div>

                    <div class="code-example">
                        <pre><span class="code-comment"># Start with task ID</span>
/task-start 42

<span class="code-comment"># Or let it auto-detect from .current-task</span>
/task-start</pre>
                    </div>

                    <div class="expandable">
                        <div class="expandable-header" onclick="toggleExpandable(this)">
                            <span class="expandable-title">💡 What You Can Change</span>
                            <span class="expandable-icon">▼</span>
                        </div>
                        <div class="expandable-content">
                            <div class="variation-box">
                                <div class="variation-title">Branch Naming</div>
                                <strong>Default:</strong> feature/42-add-user-auth<br>
                                <strong>Options:</strong> bugfix/, hotfix/, refactor/, feature/<br>
                                <strong>Effect:</strong> Affects CI/CD pipeline behavior and PR routing
                            </div>

                            <div class="variation-box">
                                <div class="variation-title">Environment Setup</div>
                                <strong>What it does:</strong>
                                • Starts Docker services (docker compose up -d)
                                • Runs database migrations
                                • Seeds test data (if configured)
                                <strong>Skip option:</strong> Use --no-setup flag to skip Docker/DB setup
                            </div>
                        </div>
                    </div>

                    <div class="expandable">
                        <div class="expandable-header" onclick="toggleExpandable(this)">
                            <span class="expandable-title">📤 Expected Output</span>
                            <span class="expandable-icon">▼</span>
                        </div>
                        <div class="expandable-content">
                            <div class="output-box">
                                <div class="output-title">Output: Environment Ready</div>
                                <pre>✓ Pulled latest from main
✓ Created branch: feature/42-add-user-auth
✓ Docker services started (5/5)
✓ Database migrations applied (3 pending)
✓ Created .current-task tracker

Ready to code! 🚀</pre>
                            </div>
                        </div>
                    </div>
                </div>

                <!-- Step 3: Work on Task -->
                <div class="workflow-step">
                    <div class="step-title">
                        <span class="step-number">3</span>
                        Work & Update Progress
                    </div>
                    <div class="step-description">
                        Implement with TDD, run tests, update task progress
                    </div>

                    <div class="code-example">
                        <pre><span class="code-comment"># Generate failing test (TDD - RED phase)</span>
/test-tdd "User can authenticate with JWT token"

<span class="code-comment"># Implement code (GREEN phase)</span>
<span class="code-comment"># ... write implementation ...</span>

<span class="code-comment"># Run tests</span>
/test-run --coverage

<span class="code-comment"># Update task plan with progress</span>
/task-update

<span class="code-comment"># Continue work (ensures tests, validates, updates plan, commits)</span>
/task-continue</pre>
                    </div>

                    <div class="expandable">
                        <div class="expandable-header" onclick="toggleExpandable(this)">
                            <span class="expandable-title">💡 What You Can Change</span>
                            <span class="expandable-icon">▼</span>
                        </div>
                        <div class="expandable-content">
                            <div class="variation-box">
                                <div class="variation-title">Test Coverage Threshold</div>
                                <strong>Default:</strong> 80% (configured in PROJECT.yaml)<br>
                                <strong>Effect:</strong> Blocks commit if below threshold<br>
                                <strong>Override:</strong> Update PROJECT.yaml testing.coverage_threshold
                            </div>

                            <div class="variation-box">
                                <div class="variation-title">Update Frequency</div>
                                <strong>Recommended:</strong> Update task plan after completing each major subtask<br>
                                <strong>Effect:</strong> Keeps progress visible, helps with interruptions/context switches
                            </div>
                        </div>
                    </div>
                </div>

                <!-- Step 4: Hold (Optional) -->
                <div class="workflow-step" style="border-left-color: var(--warning);">
                    <div class="step-title">
                        <span class="step-number" style="background: var(--warning);">4</span>
                        Hold Task (Optional)
                    </div>
                    <div class="step-description">
                        Pause work while waiting for external dependencies or clarifications
                    </div>

                    <div class="code-example">
                        <pre><span class="code-comment"># Put task on hold</span>
/task-hold

<span class="code-comment"># Prompts for reason (e.g., "Waiting for API design approval")</span>
<span class="code-comment"># Preserves branch, commits WIP, updates status</span></pre>
                    </div>

                    <div class="expandable">
                        <div class="expandable-header" onclick="toggleExpandable(this)">
                            <span class="expandable-title">💡 What Happens</span>
                            <span class="expandable-icon">▼</span>
                        </div>
                        <div class="expandable-content">
                            <div class="output-box">
                                <div class="output-title">Preserves Your Work</div>
                                <pre>✓ Committed WIP with [HOLD] marker
✓ Updated task status to "On Hold"
✓ Branch preserved: feature/42-add-user-auth
✓ Can switch to other tasks

Resume later with: /task-start 42</pre>
                            </div>
                        </div>
                    </div>
                </div>

                <!-- Step 5: Audit Progress -->
                <div class="workflow-step">
                    <div class="step-title">
                        <span class="step-number">5</span>
                        Audit Progress
                    </div>
                    <div class="step-description">
                        Check task status, test coverage, and project-wide impact
                    </div>

                    <div class="code-example">
                        <pre><span class="code-comment"># Comprehensive audit of task progress</span>
/task-audit</pre>
                    </div>

                    <div class="expandable">
                        <div class="expandable-header" onclick="toggleExpandable(this)">
                            <span class="expandable-title">📤 Expected Output</span>
                            <span class="expandable-icon">▼</span>
                        </div>
                        <div class="expandable-content">
                            <div class="output-box">
                                <div class="output-title">Audit Report</div>
                                <pre>Task Audit Report - Task #42

Status: ✅ In Progress
Tests: ✅ 15 tests written, all passing
Coverage: ✅ 87% (threshold: 80%)
Files Changed: 8 files
  • src/auth.py (new)
  • tests/test_auth.py (new)
  • src/api.py (modified)
  • ...

⚠ Recommendations:
  • Add error handling for expired tokens
  • Document JWT configuration in README

Ready for review: Yes ✓</pre>
                            </div>
                        </div>
                    </div>
                </div>

                <!-- Step 6: Close Task -->
                <div class="workflow-step" style="border-left-color: var(--success);">
                    <div class="step-title">
                        <span class="step-number" style="background: var(--success);">6</span>
                        Close Task
                    </div>
                    <div class="step-description">
                        Complete task, update external systems, cleanup
                    </div>

                    <div class="code-example">
                        <pre><span class="code-comment"># Close completed task</span>
/task-close</pre>
                    </div>

                    <div class="expandable">
                        <div class="expandable-header" onclick="toggleExpandable(this)">
                            <span class="expandable-title">💡 What You Can Change</span>
                            <span class="expandable-icon">▼</span>
                        </div>
                        <div class="expandable-content">
                            <div class="variation-box">
                                <div class="variation-title">Completion Type</div>
                                <strong>Complete:</strong> Task finished successfully<br>
                                <strong>Defer:</strong> Task postponed/cancelled<br>
                                <strong>Effect:</strong> Updates status differently in external systems
                            </div>

                            <div class="variation-box">
                                <div class="variation-title">Cleanup Options</div>
                                <strong>Branch deletion:</strong> Optional (default: yes if PR merged)<br>
                                <strong>Docker cleanup:</strong> Optional (default: no)<br>
                                <strong>External updates:</strong> Updates GitHub/GitLab/Asana/Jira
                            </div>
                        </div>
                    </div>

                    <div class="expandable">
                        <div class="expandable-header" onclick="toggleExpandable(this)">
                            <span class="expandable-title">📤 Expected Output</span>
                            <span class="expandable-icon">▼</span>
                        </div>
                        <div class="expandable-content">
                            <div class="output-box">
                                <div class="output-title">Task Closed Successfully</div>
                                <pre>✓ Verified all acceptance criteria met
✓ Updated GitHub issue #123 → Closed
✓ Posted completion summary with PR link
✓ Moved task doc to docs/completed/
✓ Deleted branch feature/42-add-user-auth
✓ Cleaned up .current-task tracker

Task #42 complete! 🎉</pre>
                            </div>
                        </div>
                    </div>
                </div>

                <div style="margin-top: 40px; padding: 20px; background: rgba(59, 130, 246, 0.1); border-radius: 8px; border-left: 4px solid var(--accent-primary);">
                    <h3 style="margin-bottom: 15px;">🔗 Related Commands</h3>
                    <div style="display: flex; flex-wrap: wrap; gap: 10px;">
                        <span class="info-badge">/task-create</span>
                        <span class="info-badge">/task-summary</span>
                        <span class="info-badge">/task-code-review</span>
                        <span class="info-badge">/task-risk</span>
                        <span class="info-badge">/task-plan</span>
                    </div>
                </div>
            </div>

            <!-- RCA WORKFLOW - HIGH DETAIL -->
            <div id="rca-workflow" class="workflow-detail">
                <div class="workflow-detail-header">
                    <h2 class="workflow-detail-title">🔥 RCA/Incident Response Workflow</h2>
                    <button class="close-btn" onclick="hideWorkflowDetail()">✕ Close</button>
                </div>

                <p style="font-size: 1.1em; color: var(--text-secondary); margin-bottom: 30px;">
                    Systematic approach: <strong>Triage → Timeline → Analyze → Review → Learn</strong>
                </p>

                <!-- RCA Step 1: Triage -->
                <div class="workflow-step">
                    <div class="step-title">
                        <span class="step-number">1</span>
                        Triage Incident
                    </div>
                    <div class="step-description">
                        Initial assessment, severity classification, and immediate mitigation
                    </div>

                    <div class="code-example">
                        <pre><span class="code-comment"># Start incident triage</span>
/rca-triage</pre>
                    </div>

                    <div class="expandable">
                        <div class="expandable-header" onclick="toggleExpandable(this)">
                            <span class="expandable-title">💡 What You Can Customize</span>
                            <span class="expandable-icon">▼</span>
                        </div>
                        <div class="expandable-content">
                            <div class="variation-box">
                                <div class="variation-title">Severity Levels</div>
                                <strong>SEV-1 (Critical):</strong> Complete outage, data loss, security breach<br>
                                <strong>SEV-2 (High):</strong> Major functionality impaired<br>
                                <strong>SEV-3 (Medium):</strong> Minor functionality affected<br>
                                <strong>SEV-4 (Low):</strong> Cosmetic issues<br>
                                <strong>Effect:</strong> Determines escalation path and response team
                            </div>

                            <div class="variation-box">
                                <div class="variation-title">Incident Type</div>
                                <strong>Options:</strong> Outage, Performance, Security, Data, Deployment<br>
                                <strong>Effect:</strong> Changes checklist items and required artifacts
                            </div>
                        </div>
                    </div>

                    <div class="expandable">
                        <div class="expandable-header" onclick="toggleExpandable(this)">
                            <span class="expandable-title">📤 Triage Output</span>
                            <span class="expandable-icon">▼</span>
                        </div>
                        <div class="expandable-content">
                            <div class="output-box">
                                <div class="output-title">Triage Assessment</div>
                                <pre>Created: docs/active/0000-0099/0043-2602101915-INC-api-outage.md

Incident: API Gateway Outage
Severity: SEV-1 (Critical)
Detected: 2026-02-10 19:15 PST
Impact: 100% of API requests failing
Status: INVESTIGATING

Immediate Actions:
  □ Notify on-call team
  □ Check infrastructure health
  □ Review recent deployments
  □ Enable status page updates

Incident Commander: Assigned</pre>
                            </div>
                        </div>
                    </div>
                </div>

                <!-- RCA Step 2: Timeline -->
                <div class="workflow-step">
                    <div class="step-title">
                        <span class="step-number">2</span>
                        Create Timeline
                    </div>
                    <div class="step-description">
                        Build detailed incident timeline from logs, metrics, and events
                    </div>

                    <div class="code-example">
                        <pre><span class="code-comment"># Generate timeline from logs and events</span>
/rca-timeline

<span class="code-comment"># Specify time range</span>
/rca-timeline --start "2026-02-10 19:00" --end "2026-02-10 20:00"</pre>
                    </div>

                    <div class="expandable">
                        <div class="expandable-header" onclick="toggleExpandable(this)">
                            <span class="expandable-title">💡 Timeline Customization</span>
                            <span class="expandable-icon">▼</span>
                        </div>
                        <div class="expandable-content">
                            <div class="variation-box">
                                <div class="variation-title">Data Sources</div>
                                <strong>Auto-collected:</strong>
                                • Application logs (last 2 hours)
                                • System metrics (CPU, memory, disk)
                                • Deployment events
                                • Database slow queries
                                • External API errors

                                <strong>Custom:</strong> Specify log paths or metrics
                                <strong>Effect:</strong> More data sources = more complete timeline but slower generation
                            </div>

                            <div class="variation-box">
                                <div class="variation-title">Time Window</div>
                                <strong>Default:</strong> 2 hours before incident detection<br>
                                <strong>Adjust for:</strong> Slow-developing issues (expand window), Known trigger (narrow window)<br>
                                <strong>Effect:</strong> Wider windows show context, narrower focus on immediate cause
                            </div>
                        </div>
                    </div>

                    <div class="expandable">
                        <div class="expandable-header" onclick="toggleExpandable(this)">
                            <span class="expandable-title">📤 Timeline Output</span>
                            <span class="expandable-icon">▼</span>
                        </div>
                        <div class="expandable-content">
                            <div class="output-box">
                                <div class="output-title">Incident Timeline</div>
                                <pre>19:00:00 - ✓ Deployment v1.2.3 started
19:02:15 - ✓ Database migrations completed (3 applied)
19:02:45 - ✓ Application restart successful
19:03:12 - ⚠ First elevated error rate (5xx: 2%)
19:05:30 - ⚠ Error rate climbing (5xx: 15%)
19:08:45 - 🔥 Error rate critical (5xx: 98%)
19:10:00 - 📢 PagerDuty alert triggered
19:15:00 - 👤 Incident declared (SEV-1)
19:17:30 - 🔍 Root cause identified: Connection pool exhausted
19:20:00 - 🛠️ Mitigation: Increased pool size
19:22:15 - ✅ Error rate normalizing (5xx: 5%)
19:25:00 - ✅ Incident resolved

Duration: 22 minutes
Impact: ~15,000 failed requests</pre>
                            </div>
                        </div>
                    </div>
                </div>

                <!-- RCA Step 3: Root Cause Analysis -->
                <div class="workflow-step">
                    <div class="step-title">
                        <span class="step-number">3</span>
                        Analyze Root Cause
                    </div>
                    <div class="step-description">
                        Use 5 Whys and fishbone analysis to identify root cause
                    </div>

                    <div class="code-example">
                        <pre><span class="code-comment"># Conduct root cause analysis</span>
/rca-analyze</pre>
                    </div>

                    <div class="expandable">
                        <div class="expandable-header" onclick="toggleExpandable(this)">
                            <span class="expandable-title">💡 Analysis Methods</span>
                            <span class="expandable-icon">▼</span>
                        </div>
                        <div class="expandable-content">
                            <div class="variation-box">
                                <div class="variation-title">5 Whys Method</div>
                                <strong>What:</strong> Ask "why" 5 times to drill down to root cause<br>
                                <strong>Example:</strong>
                                1. Why did API fail? → Connection pool exhausted
                                2. Why was pool exhausted? → Too many concurrent connections
                                3. Why too many connections? → Load spike after deployment
                                4. Why spike after deployment? → New feature increased DB queries
                                5. Why not detected in testing? → Load tests didn't simulate real traffic

                                <strong>Root Cause:</strong> Insufficient load testing for new feature
                            </div>

                            <div class="variation-box">
                                <div class="variation-title">Fishbone Diagram</div>
                                <strong>Categories:</strong> People, Process, Technology, Environment<br>
                                <strong>Effect:</strong> Visual representation showing contributing factors<br>
                                <strong>Use when:</strong> Multiple contributing causes suspected
                            </div>
                        </div>
                    </div>

                    <div class="expandable">
                        <div class="expandable-header" onclick="toggleExpandable(this)">
                            <span class="expandable-title">📤 Analysis Output</span>
                            <span class="expandable-icon">▼</span>
                        </div>
                        <div class="expandable-content">
                            <div class="output-box">
                                <div class="output-title">Root Cause Analysis</div>
                                <pre>Created: docs/active/0000-0099/0043-2602101945-RCA-api-outage.md

Root Cause: Database connection pool undersized for post-deployment load

Contributing Factors:
  • New feature increased queries per request (3x)
  • Load tests didn't simulate production traffic patterns
  • No connection pool metrics in monitoring
  • Default pool size (10) too small for scale

Immediate Fix: Increased pool size to 50
Permanent Fix Required: Yes

Action Items:
  □ Implement connection pool monitoring
  □ Update load test scenarios
  □ Review all default configurations
  □ Add capacity planning to deployment checklist</pre>
                            </div>
                        </div>
                    </div>
                </div>

                <!-- RCA Step 4: Post-Incident Review -->
                <div class="workflow-step">
                    <div class="step-title">
                        <span class="step-number">4</span>
                        Post-Incident Review
                    </div>
                    <div class="step-description">
                        Document findings, action items, and preventive measures
                    </div>

                    <div class="code-example">
                        <pre><span class="code-comment"># Generate post-incident review document</span>
/rca-pir</pre>
                    </div>

                    <div class="expandable">
                        <div class="expandable-header" onclick="toggleExpandable(this)">
                            <span class="expandable-title">💡 PIR Customization</span>
                            <span class="expandable-icon">▼</span>
                        </div>
                        <div class="expandable-content">
                            <div class="variation-box">
                                <div class="variation-title">Blameless Culture</div>
                                <strong>Focus:</strong> System failures, not people<br>
                                <strong>Language:</strong> "The system lacked..." not "They didn't..."<br>
                                <strong>Effect:</strong> Encourages honest discussion and learning
                            </div>

                            <div class="variation-box">
                                <div class="variation-title">Action Item Priority</div>
                                <strong>P0 (Immediate):</strong> Prevent recurrence<br>
                                <strong>P1 (This Sprint):</strong> Improve detection<br>
                                <strong>P2 (Next Quarter):</strong> Long-term improvements<br>
                                <strong>Effect:</strong> Ensures critical items get addressed first
                            </div>
                        </div>
                    </div>
                </div>

                <div style="margin-top: 40px; padding: 20px; background: rgba(239, 68, 68, 0.1); border-radius: 8px; border-left: 4px solid var(--danger);">
                    <h3 style="margin-bottom: 15px;">⚠️ Critical Best Practices</h3>
                    <ul style="list-style: none; padding-left: 0;">
                        <li style="margin: 10px 0;">✓ Declare incidents early - false alarms are OK</li>
                        <li style="margin: 10px 0;">✓ Focus on mitigation first, root cause later</li>
                        <li style="margin: 10px 0;">✓ Keep stakeholders updated every 15-30 minutes</li>
                        <li style="margin: 10px 0;">✓ Document everything in real-time</li>
                        <li style="margin: 10px 0;">✓ Blameless PIRs - focus on systems, not people</li>
                    </ul>
                </div>

                <div style="margin-top: 20px; padding: 20px; background: rgba(59, 130, 246, 0.1); border-radius: 8px; border-left: 4px solid var(--accent-primary);">
                    <h3 style="margin-bottom: 15px;">🔗 Related Commands</h3>
                    <div style="display: flex; flex-wrap: wrap; gap: 10px;">
                        <span class="info-badge">/ops-monitoring</span>
                        <span class="info-badge">/db-performance</span>
                        <span class="info-badge">/deploy-risk</span>
                        <span class="info-badge">/task-create</span>
                    </div>
                </div>
            </div>

            <!-- DEPLOYMENT WORKFLOW - HIGH DETAIL -->
            <div id="deployment-workflow" class="workflow-detail">
                <div class="workflow-detail-header">
                    <h2 class="workflow-detail-title">🚢 Safe Deployment Workflow</h2>
                    <button class="close-btn" onclick="hideWorkflowDetail()">✕ Close</button>
                </div>

                <p style="font-size: 1.1em; color: var(--text-secondary); margin-bottom: 30px;">
                    Progressive deployment: <strong>Config → Risk → Stage → Verify → Prod → Monitor</strong>
                </p>

                <!-- Deploy Step 1: Configuration -->
                <div class="workflow-step">
                    <div class="step-title">
                        <span class="step-number">1</span>
                        Configure Deployment
                    </div>
                    <div class="step-description">
                        Set up deployment targets and verification procedures
                    </div>

                    <div class="code-example">
                        <pre><span class="code-comment"># Configure deployment for project</span>
/deployment-config</pre>
                    </div>

                    <div class="expandable">
                        <div class="expandable-header" onclick="toggleExpandable(this)">
                            <span class="expandable-title">💡 Configuration Options</span>
                            <span class="expandable-icon">▼</span>
                        </div>
                        <div class="expandable-content">
                            <div class="variation-box">
                                <div class="variation-title">Environment Settings</div>
                                <strong>Staging:</strong>
                                • Target: staging.example.com
                                • Health check: /health
                                • Smoke tests: Critical paths only
                                • E2E tests: Full suite

                                <strong>Production:</strong>
                                • Target: api.example.com
                                • Health check: /health
                                • Smoke tests: Critical + extended
                                • Auto-rollback: Enabled
                            </div>

                            <div class="variation-box">
                                <div class="variation-title">Deployment Method</div>
                                <strong>Work (macOS):</strong> AWS SSM (Systems Manager)<br>
                                <strong>Home (WSL):</strong> SSH to Unraid/Proxmox<br>
                                <strong>Effect:</strong> Auto-detected from environment, affects deployment commands
                            </div>
                        </div>
                    </div>
                </div>

                <!-- Deploy Step 2: Risk Analysis -->
                <div class="workflow-step">
                    <div class="step-title">
                        <span class="step-number">2</span>
                        Analyze Deployment Risk
                    </div>
                    <div class="step-description">
                        Comprehensive risk analysis before deployment
                    </div>

                    <div class="code-example">
                        <pre><span class="code-comment"># Analyze risks for staging</span>
/deploy-risk staging

<span class="code-comment"># Analyze risks for production</span>
/deploy-risk production

<span class="code-comment"># Or use task-specific risk analysis</span>
/task-risk</pre>
                    </div>

                    <div class="expandable">
                        <div class="expandable-header" onclick="toggleExpandable(this)">
                            <span class="expandable-title">💡 Risk Scoring</span>
                            <span class="expandable-icon">▼</span>
                        </div>
                        <div class="expandable-content">
                            <div class="variation-box">
                                <div class="variation-title">Risk Categories (10 total)</div>
                                1. Security (25%) - Vulnerabilities, exposed secrets<br>
                                2. Data Integrity (20%) - Migrations, data changes<br>
                                3. Breaking Changes (15%) - API compatibility<br>
                                4. Dependencies (10%) - New packages, versions<br>
                                5. Infrastructure (10%) - Resource changes<br>
                                6. Testing (5%) - Coverage, test quality<br>
                                7. Rollback (5%) - Can we undo this?<br>
                                8. Timing (5%) - Deployment window (Friday = bad!)<br>
                                9. Complexity (3%) - Lines changed, files touched<br>
                                10. History (2%) - Recent incidents<br>

                                <strong>Total Score:</strong> 0-10 (weighted average)
                            </div>

                            <div class="variation-box">
                                <div class="variation-title">Risk Levels</div>
                                <strong>0-3 (SAFE):</strong> ✅ Deploy confidently<br>
                                <strong>4-6 (READY):</strong> 🟢 Deploy with monitoring<br>
                                <strong>7-8 (CAUTION):</strong> 🟡 Mitigate first<br>
                                <strong>9-10 (BLOCK):</strong> 🔴 Do not deploy
                            </div>
                        </div>
                    </div>

                    <div class="expandable">
                        <div class="expandable-header" onclick="toggleExpandable(this)">
                            <span class="expandable-title">📤 Risk Analysis Output</span>
                            <span class="expandable-icon">▼</span>
                        </div>
                        <div class="expandable-content">
                            <div class="output-box">
                                <div class="output-title">Risk Assessment</div>
                                <pre>Created: docs/active/0000-0099/0044-2602102000-RSK-production-v1.2.4.md

Deployment Risk Analysis - Production v1.2.4

Overall Score: 4.8/10 🟢 READY
Recommendation: Deploy with monitoring

Risk Breakdown:
  Security:        2/10 ✅ (No vulnerabilities found)
  Data Integrity:  6/10 ⚠️ (3 migrations, tested)
  Breaking Changes: 0/10 ✅ (Backward compatible)
  Dependencies:    3/10 ✅ (2 minor updates)
  Infrastructure:  0/10 ✅ (No changes)
  Testing:         2/10 ✅ (Coverage: 87%)
  Rollback:        0/10 ✅ (Migrations reversible)
  Timing:          5/10 ⚠️ (Tuesday 8PM - good)
  Complexity:      4/10 ✅ (142 lines, 8 files)
  History:         0/10 ✅ (No recent incidents)

Deployment Window: Tuesday 8:00 PM PST
On-Call: Available ✓
Rollback Plan: Automated ✓

Proceed: YES ✅</pre>
                            </div>
                        </div>
                    </div>
                </div>

                <!-- Deploy Step 3: Deploy to Staging -->
                <div class="workflow-step">
                    <div class="step-title">
                        <span class="step-number">3</span>
                        Deploy to Staging
                    </div>
                    <div class="step-description">
                        Deploy to staging with E2E test verification
                    </div>

                    <div class="code-example">
                        <pre><span class="code-comment"># Deploy to staging (full automation)</span>
/deploy-to-stage</pre>
                    </div>

                    <div class="expandable">
                        <div class="expandable-header" onclick="toggleExpandable(this)">
                            <span class="expandable-title">💡 Staging Deployment Steps</span>
                            <span class="expandable-icon">▼</span>
                        </div>
                        <div class="expandable-content">
                            <div class="variation-box">
                                <div class="variation-title">Automated Process</div>
                                1. Risk analysis (if not done)<br>
                                2. Squash merge to staging branch<br>
                                3. Trigger CI/CD pipeline<br>
                                4. Monitor pipeline progress<br>
                                5. Wait for deployment completion<br>
                                6. Run smoke tests<br>
                                7. Run E2E test suite<br>
                                8. Report results<br>

                                <strong>Duration:</strong> Typically 10-15 minutes<br>
                                <strong>Failure:</strong> Automatic rollback, notification sent
                            </div>

                            <div class="variation-box">
                                <div class="variation-title">Customization</div>
                                <strong>Skip E2E:</strong> Use --skip-e2e flag (not recommended)<br>
                                <strong>Manual approval:</strong> Add --wait-for-approval<br>
                                <strong>Effect:</strong> Faster deployment vs thorough verification trade-off
                            </div>
                        </div>
                    </div>

                    <div class="expandable">
                        <div class="expandable-header" onclick="toggleExpandable(this)">
                            <span class="expandable-title">📤 Staging Deployment Output</span>
                            <span class="expandable-icon">▼</span>
                        </div>
                        <div class="expandable-content">
                            <div class="output-box">
                                <div class="output-title">Staging Deployment Complete</div>
                                <pre>✓ Risk analysis: 4.8/10 (READY)
✓ Squash merged to staging branch
✓ Pipeline triggered: #1234
✓ Build completed (3m 45s)
✓ Deployed to staging environment
✓ Health check: PASSING
✓ Smoke tests: 12/12 PASSED
✓ E2E tests: 48/48 PASSED (8m 12s)

Staging URL: https://staging.example.com
Version deployed: v1.2.4

Ready for production: YES ✅</pre>
                            </div>
                        </div>
                    </div>
                </div>

                <!-- Deploy Step 4: Deploy to Production -->
                <div class="workflow-step" style="border-left-color: var(--danger);">
                    <div class="step-title">
                        <span class="step-number" style="background: var(--danger);">4</span>
                        Deploy to Production
                    </div>
                    <div class="step-description">
                        Production deployment with strict checks and auto-rollback
                    </div>

                    <div class="code-example">
                        <pre><span class="code-comment"># Deploy to production</span>
/deploy-to-prod

<span class="code-comment"># Production deployment includes:</span>
<span class="code-comment"># - Final risk check</span>
<span class="code-comment"># - Merge to production branch</span>
<span class="code-comment"># - Deployment with health monitoring</span>
<span class="code-comment"># - Smoke tests</span>
<span class="code-comment"># - Auto-rollback if failures detected</span>
<span class="code-comment"># - Git tag creation</span>
<span class="code-comment"># - Release notes</span></pre>
                    </div>

                    <div class="expandable">
                        <div class="expandable-header" onclick="toggleExpandable(this)">
                            <span class="expandable-title">💡 Production Safety Measures</span>
                            <span class="expandable-icon">▼</span>
                        </div>
                        <div class="expandable-content">
                            <div class="variation-box">
                                <div class="variation-title">Auto-Rollback Triggers</div>
                                • Health check fails after deployment<br>
                                • Smoke tests fail (critical paths)<br>
                                • Error rate spike (>5% increase)<br>
                                • Response time degradation (>2x baseline)<br>
                                • Manual trigger by on-call<br>

                                <strong>Rollback method:</strong> Git revert + automatic deployment of previous version<br>
                                <strong>Notification:</strong> Alerts sent to on-call and team channel
                            </div>

                            <div class="variation-box">
                                <div class="variation-title">Deployment Window</div>
                                <strong>Preferred:</strong> Tuesday-Thursday, 8-10 PM (low traffic)<br>
                                <strong>Avoid:</strong> Friday (limited support), Monday AM (high traffic)<br>
                                <strong>Override:</strong> Emergency deployments bypass window check
                            </div>
                        </div>
                    </div>

                    <div class="expandable">
                        <div class="expandable-header" onclick="toggleExpandable(this)">
                            <span class="expandable-title">📤 Production Deployment Output</span>
                            <span class="expandable-icon">▼</span>
                        </div>
                        <div class="expandable-content">
                            <div class="output-box">
                                <div class="output-title">Production Deployment Success</div>
                                <pre>✓ Risk re-check: 4.8/10 (READY)
✓ Staging verification: PASSED
✓ Merged to production branch
✓ Pipeline triggered: #1235
✓ Build completed (3m 52s)
✓ Deployed to production
✓ Health check: PASSING
✓ Smoke tests: 15/15 PASSED
✓ Error rate: Normal (0.2%)
✓ Response time: Normal (p95: 180ms)
✓ Created git tag: v1.2.4
✓ Generated release notes

Production URL: https://api.example.com
Version deployed: v1.2.4
Rollback available: YES (previous: v1.2.3)

Deployment complete! 🎉
Monitoring for 30 minutes...</pre>
                            </div>
                        </div>
                    </div>
                </div>

                <div style="margin-top: 40px; padding: 20px; background: rgba(239, 68, 68, 0.1); border-radius: 8px; border-left: 4px solid var(--danger);">
                    <h3 style="margin-bottom: 15px;">⚠️ Production Deployment Checklist</h3>
                    <ul style="list-style: none; padding-left: 0;">
                        <li style="margin: 10px 0;">□ All tests passing in staging</li>
                        <li style="margin: 10px 0;">□ Risk score acceptable (&lt;7/10)</li>
                        <li style="margin: 10px 0;">□ Deployment window appropriate</li>
                        <li style="margin: 10px 0;">□ On-call engineer available</li>
                        <li style="margin: 10px 0;">□ Rollback plan tested</li>
                        <li style="margin: 10px 0;">□ Stakeholders notified</li>
                    </ul>
                </div>

                <div style="margin-top: 20px; padding: 20px; background: rgba(59, 130, 246, 0.1); border-radius: 8px; border-left: 4px solid var(--accent-primary);">
                    <h3 style="margin-bottom: 15px;">🔗 Related Commands</h3>
                    <div style="display: flex; flex-wrap: wrap; gap: 10px;">
                        <span class="info-badge">/deployment-config</span>
                        <span class="info-badge">/test-smoke</span>
                        <span class="info-badge">/test-e2e</span>
                        <span class="info-badge">/ops-monitoring</span>
                        <span class="info-badge">/release</span>
                    </div>
                </div>
            </div>

            <!-- Placeholder workflows for other categories (will render with JS based on showWorkflowDetail) -->
            <div id="review-workflow" class="workflow-detail"></div>
            <div id="testing-workflow" class="workflow-detail"></div>
            <div id="git-workflow" class="workflow-detail"></div>
            <div id="security-workflow" class="workflow-detail"></div>
            <div id="db-workflow" class="workflow-detail"></div>
            <div id="infra-workflow" class="workflow-detail"></div>
            <div id="docker-workflow" class="workflow-detail"></div>
            <div id="pipeline-workflow" class="workflow-detail"></div>
            <div id="ops-workflow" class="workflow-detail"></div>

        </div>

        <div id="commands-tab" class="tab-content">
            <h2 style="font-size: 2em; margin-bottom: 20px;">All Commands</h2>
            <input type="text" class="search-box" id="commandSearch" placeholder="🔍 Search commands..." onkeyup="filterCommands()">

            <div class="commands-section" id="commands-container">
                <!-- Commands will be generated here -->
WORKFLOWSEOF

# Generate commands section
for category in "Task Management" "Incident Response" "Deployment" "Testing" "Git Operations" "Code Review" "Security" "Database" "CI/CD" "Infrastructure" "Operations" "Docker" "Documentation" "Planning" "Other"; do
    echo "                <div class=\"category-group\">" >> "$OUTPUT_FILE"
    echo "                    <h3 class=\"category-title\">$category</h3>" >> "$OUTPUT_FILE"
    echo "                    <div class=\"command-grid\">" >> "$OUTPUT_FILE"

    for cmd_name in $(echo "${!categories[@]}" | tr ' ' '\n' | sort); do
        if [[ "${categories[$cmd_name]}" == "$category" ]]; then
            desc="${commands[$cmd_name]}"
            echo "                        <div class=\"command-item\">" >> "$OUTPUT_FILE"
            echo "                            <div class=\"command-name\">/$cmd_name</div>" >> "$OUTPUT_FILE"
            echo "                            <div class=\"command-desc\">$desc</div>" >> "$OUTPUT_FILE"
            echo "                        </div>" >> "$OUTPUT_FILE"
        fi
    done

    echo "                    </div>" >> "$OUTPUT_FILE"
    echo "                </div>" >> "$OUTPUT_FILE"
done

# Add JavaScript and closing tags
cat >> "$OUTPUT_FILE" << 'JSEOF'
            </div>
        </div>
    </div>

    <script>
        // Theme toggle
        function toggleTheme() {
            document.body.classList.toggle('light-mode');
            localStorage.setItem('theme', document.body.classList.contains('light-mode') ? 'light' : 'dark');
        }

        // Load saved theme
        if (localStorage.getItem('theme') === 'light') {
            document.body.classList.add('light-mode');
        }

        // Tab switching
        function showTab(tabName) {
            document.querySelectorAll('.tab-content').forEach(tab => tab.classList.remove('active'));
            document.querySelectorAll('.nav-tab').forEach(btn => btn.classList.remove('active'));

            document.getElementById(tabName + '-tab').classList.add('active');
            event.target.classList.add('active');
        }

        // Workflow detail display
        function showWorkflowDetail(workflowId) {
            // Hide all workflow details
            document.querySelectorAll('.workflow-detail').forEach(detail => {
                detail.classList.remove('active');
            });

            // Show selected workflow
            const workflow = document.getElementById(workflowId);
            workflow.classList.add('active');

            // Scroll to workflow
            workflow.scrollIntoView({ behavior: 'smooth', block: 'start' });
        }

        function hideWorkflowDetail() {
            document.querySelectorAll('.workflow-detail').forEach(detail => {
                detail.classList.remove('active');
            });

            // Scroll back to workflows grid
            document.querySelector('.workflow-grid').scrollIntoView({ behavior: 'smooth', block: 'start' });
        }

        // Expandable sections
        function toggleExpandable(header) {
            const expandable = header.parentElement;
            expandable.classList.toggle('open');
        }

        // Command search
        function filterCommands() {
            const searchTerm = document.getElementById('commandSearch').value.toLowerCase();
            const commandItems = document.querySelectorAll('.command-item');

            commandItems.forEach(item => {
                const name = item.querySelector('.command-name').textContent.toLowerCase();
                const desc = item.querySelector('.command-desc').textContent.toLowerCase();

                if (name.includes(searchTerm) || desc.includes(searchTerm)) {
                    item.style.display = 'block';
                } else {
                    item.style.display = 'none';
                }
            });
        }

        // Back to top
        window.addEventListener('scroll', () => {
            const backToTop = document.querySelector('.back-to-top');
            if (window.scrollY > 300) {
                backToTop.classList.add('visible');
            } else {
                backToTop.classList.remove('visible');
            }
        });

        function scrollToTop() {
            window.scrollTo({ top: 0, behavior: 'smooth' });
        }

        // Auto-close workflow details when clicking outside
        document.addEventListener('click', (e) => {
            if (e.target.classList.contains('workflow-detail') && e.target.classList.contains('active')) {
                if (e.target === e.currentTarget) {
                    hideWorkflowDetail();
                }
            }
        });
    </script>
</body>
</html>
JSEOF

# Update timestamp and count
sed -i.bak "s/TIMESTAMP/$TIMESTAMP/" "$OUTPUT_FILE"
sed -i.bak "s/COMMAND_COUNT/$TOTAL_COMMANDS/" "$OUTPUT_FILE"
rm "${OUTPUT_FILE}.bak"

echo ""
echo "✅ Generated: $OUTPUT_FILE"
echo "   📊 Total commands: $TOTAL_COMMANDS"
echo "   🕒 Generated at: $TIMESTAMP"
echo "   🎨 Features: Dark/light mode, search, interactive workflows"
echo ""
echo "🌐 Open in browser: file://$OUTPUT_FILE"
