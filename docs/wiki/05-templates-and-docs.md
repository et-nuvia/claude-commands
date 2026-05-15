# Templates and Reference Docs

## Templates (`templates/`)

Per-project contracts and scaffolds:

- **`PROJECT.yaml`** — config every project uses; scripts auto-read it
- **`PROJECT-KNOWLEDGE.md`** — architectural memory file (39 commands read it)
- **`SEQUENCE-TRACKER.template.md`**, **`DOCUMENT-INDEX.template.md`** —
  task lifecycle bookkeeping
- **`task-*.md`** — V4 task document types (TSK, FND, FIX, RCA, DEP, CRV,
  RSK, AUD, VRF, IMP, RSC, LRN, SUM, FRV, REV, RFA, DSN, …)
- **`python-project/`**, **`nextjs-project/`**, **`dockerfiles/`**,
  **`makefiles/`**, **`pipelines/`**, **`architecture/`**,
  **`release-notes/`** — scaffolds stamped out by `/scaffold`,
  `/dockerfile-build`, `/pipeline-create`, `/makefile-init`

## Reference docs (`docs/reference/`)

Linked from commands at runtime — they enforce output and process standards:

- **`ux/`** — output formatting: `commit-confirmation.md`,
  `progress-update.md`, `task-completion.md`, `error-blocker.md`
- **`authoring/`** — `command-guide.md`, `script-guide.md`
- **Tech standards** — `docker.md`, `makefile.md`, `testing.md`,
  `pipelines.md`, `python.md`, `nextjs.md`
- **`secrets-*.md`** — per-backend secrets implementation guides
