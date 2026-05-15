---
name: make-it-pretty
description: Improve code readability, formatting, and visual presentation
user_invocable: true
---

## Tracking

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "make-it-pretty" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "make-it-pretty" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```
# Make It Pretty

I'll improve code readability while preserving exact functionality.

## Strategic Thinking Process

<think>
Before making any changes, I need to consider:

1. **Code Analysis**
   - What makes this code "ugly" or hard to read?
   - Are there complex nested structures that need simplification?
   - Is the naming unclear or inconsistent?
   - Are there repeated patterns that could be abstracted?

2. **Safety Considerations**
   - Which changes are purely cosmetic (safe)?
   - Which might affect behavior (risky)?
   - Are there implicit dependencies on current structure?
   - Could renaming break external references?

3. **Improvement Strategy**
   - Priority 1: Clear naming (variables, functions, files)
   - Priority 2: Reduce complexity (extract functions, simplify logic)
   - Priority 3: Remove redundancy (DRY principle)
   - Priority 4: Improve type safety (if applicable)

4. **Validation Approach**
   - How can I ensure functionality remains identical?
   - What tests exist to verify behavior?
   - Should I add temporary logging to verify flow?
</think>

Based on this analysis, I'll proceed safely:

**Safety First:**
- Create git checkpoint before changes
- Use **Write** tool to create backups
- Track all modifications systematically

I'll identify files to beautify based on:
- Files you specify, or if none specified, analyze the entire application
- Recently modified code
- Our conversation context

**Improvements I'll Make:**
- Variable and function names for clarity
- Code organization and structure
- Remove unused code and clutter
- Simplify complex expressions
- Group related functionality
- Fix loose or generic type declarations
- Add missing type annotations where supported
- Make types more specific based on usage

**My Approach:**
1. Analyze current code patterns and type usage
2. Apply consistent naming conventions
3. Improve type safety where applicable
4. Reorganize for better readability
5. Remove redundancy without changing logic

**Quality Assurance:**
- All functionality remains identical
- Tests continue to pass (if available)
- No behavior changes occur
- Clear commit messages for changes

**Important**: I will NEVER:
- Add "Co-authored-by" or any Claude signatures
- Include "Generated with Claude Code" or similar messages
- Modify git config or user credentials
- Add any AI/assistant attribution to the commit

This helps transform working code into maintainable code without risk.

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "make-it-pretty" --event complete \
  --model "MODEL_ID" \
  --complexity COMPLEXITY \
  --tokens TOKENS_ESTIMATED \
  --cost COST_ESTIMATED
```

Replace values before calling:
- `MODEL_ID` — the model currently in use (from system context, e.g., `claude-sonnet-4-6`)
- `COMPLEXITY` — 1-5 based on: 1=read-only analysis, 2=single-file/simple git, 3=multi-file feature,
  4=cross-system/staging deploy, 5=production/infrastructure/security
- `TOKENS_ESTIMATED` — rough estimate of context used (input + output tokens combined)
- `COST_ESTIMATED` — approximate cost in USD based on model pricing
