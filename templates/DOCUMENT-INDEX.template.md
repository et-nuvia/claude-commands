# Document Index - Master Reference

**Last Updated**: {{LAST_UPDATED}}
**Total Documents**: {{TOTAL_DOCS}} files
**Total Work Items**: {{TOTAL_WORK_ITEMS}} (task IDs {{FIRST_SEQ}}-{{LAST_SEQ}})
**Next Available Task ID**: {{NEXT_SEQ}}

---

## Key Concept

**One task ID = one work item** (can have multiple document types)

---

## Quick Stats

| Status | Documents | Work Items |
|--------|-----------|------------|
| Active | {{ACTIVE_DOCS}} docs | {{ACTIVE_WORK_ITEMS}} work items |
| On Hold | {{ON_HOLD_DOCS}} docs | {{ON_HOLD_WORK_ITEMS}} work items |
| Completed | {{COMPLETED_DOCS}} docs | {{COMPLETED_WORK_ITEMS}} work items |
| **Total** | **{{TOTAL_DOCS}} docs** | **{{TOTAL_WORK_ITEMS}} work items** |

---

## Work Items (Most Recent First)

{{WORK_ITEMS}}

---

## Maintenance

**Last Generated**: {{TIMESTAMP}}
**Generator**: ~/.claude/scripts/update-docs.sh
**Method**: Automated scan of docs/ structure

To regenerate: `~/.claude/scripts/update-docs.sh`
