# Strapi CMS API Reference (Showcase Site)

## Connection Details

- **URL**: `https://admin.eric-turner.com`
- **Admin email**: `razzam21@gmail.com`
- **Admin password**: stored in `~/.strapi-showcase`
- **API Token** (for automation): stored in `~/.strapi-showcase`
- **Site**: `https://eric-turner.com` (Hugo frontend)

## Authentication

### Admin JWT (expires in 30 days)

```bash
TOKEN=$(curl -s -X POST https://admin.eric-turner.com/admin/login \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$(sed -n 's/^EMAIL=//p' ~/.strapi-showcase)\",\"password\":\"$(sed -n 's/^PASSWORD=//p' ~/.strapi-showcase)\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['token'])")
```

### API Token (permanent, for automation scripts)

```bash
API_TOKEN=$(sed -n 's/^API_TOKEN=//p' ~/.strapi-showcase)
```

The API token uses the public REST API (`/api/*`), while the JWT uses the Content-Manager admin API (`/content-manager/*`). **Use the Content-Manager API** — it has full CRUD access; the REST API requires per-endpoint permission configuration.

## Content-Manager API (Admin)

Base: `https://admin.eric-turner.com/content-manager`
Auth: `Authorization: Bearer <JWT>`

### Content Types

| Type | API UID | Kind | Key Fields |
|------|---------|------|------------|
| Author Profile | `api::author-profile.author-profile` | singleType | name, nickname, greeting (json), summary (json), contactInfo (component[]) |
| Site Configuration | `api::site-configuration.site-configuration` | singleType | copyright, disclaimer, description, customMenus (component[]) |
| About Section | `api::about-section.about-section` | singleType | designation, companyName, companyUrl, summary (richtext), socialLinks (component[]), skills (relation) |
| Skill | `api::skill.skill` | collection | name, summary, categories (json), proficiencyLevel (1-100), sortOrder, showOnHomepage |
| Education | `api::education.education` | collection | degreeType, icon, timeframe, institutionName, institutionUrl, description, sortOrder |
| Experience | `api::experience.experience` | collection | companyName, companyUrl, location, overview, positions (component[]), sortOrder |
| Project | `api::project.project` | collection | name, role, timeline, summary (richtext), tags (json), technologies (json), url, repository, sortOrder |
| Blog Post | `api::blog-post.blog-post` | collection | title, content (richtext), slug (uid), publishedDate, visibility (enum), excerpt |
| Page | `api::page.page` | collection | title, content (richtext), slug (uid), menuWeight, showInMenu |

### Components (embedded in content types)

| Component | Fields | Used In |
|-----------|--------|---------|
| shared.social-link | name, icon, url | Author Profile (contactInfo), About Section (socialLinks) |
| shared.menu-item | name, url, hideFromNavbar, showOnFooter | Site Configuration (customMenus) |
| shared.position | designation, startDate (date), endDate (date), responsibilities (json[]) | Experience (positions) |
| shared.section-config | name, sectionId, enable, weight, showOnNavbar, template | About Section (sectionMeta) |
| shared.resource-link | title, url | (available) |

### CRUD Operations

#### Collection Types

```bash
# LIST (paginated, sortable, filterable)
curl -s -H "Authorization: Bearer $TOKEN" \
  "$BASE/content-manager/collection-types/{api_uid}?page=1&pageSize=25&sort=sortOrder:asc"

# Response: { "results": [...], "pagination": { "page": 1, "pageSize": 25, "pageCount": 3, "total": 57 } }

# GET ONE
curl -s -H "Authorization: Bearer $TOKEN" \
  "$BASE/content-manager/collection-types/{api_uid}/{documentId}"

# CREATE
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "$BASE/content-manager/collection-types/{api_uid}" \
  -d '{"name": "New Skill", "summary": "Description", "categories": ["test"], "proficiencyLevel": 50, "sortOrder": 1}'

# Response: { "data": { "id": 1, "documentId": "abc123", ... } }

# UPDATE
curl -s -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "$BASE/content-manager/collection-types/{api_uid}/{documentId}" \
  -d '{"name": "Updated Name"}'

# DELETE
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" \
  "$BASE/content-manager/collection-types/{api_uid}/{documentId}"

# Response: {} (empty on success)
```

#### Single Types

```bash
# GET
curl -s -H "Authorization: Bearer $TOKEN" \
  "$BASE/content-manager/single-types/{api_uid}"

# UPDATE (PUT, not POST)
curl -s -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "$BASE/content-manager/single-types/{api_uid}" \
  -d '{"name": "Eric Turner", "nickname": "Eric"}'
```

#### Publish / Unpublish

Entries are created as **drafts** by default. They must be explicitly published to appear on the site.

```bash
# PUBLISH
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "$BASE/content-manager/collection-types/{api_uid}/{documentId}/actions/publish" \
  -d '{"documentId": "{documentId}"}'

# UNPUBLISH
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "$BASE/content-manager/collection-types/{api_uid}/{documentId}/actions/unpublish" \
  -d '{"documentId": "{documentId}"}'

# For single types, replace collection-types with single-types (no documentId in URL)
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "$BASE/content-manager/single-types/{api_uid}/actions/publish" \
  -d '{"documentId": "{documentId}"}'
```

### Filtering & Sorting

```bash
# Sort by field (asc/desc)
?sort=sortOrder:asc
?sort=createdAt:desc

# Filter by status
?status=draft
?status=published

# Filter by field value (URL-encoded)
?filters[$and][0][name][$eq]=Python
?filters[$and][0][categories][$contains]=ai-ml

# Pagination
?page=1&pageSize=100

# Combine
?page=1&pageSize=50&sort=sortOrder:asc&status=published
```

### Components in Create/Update

Components are nested objects in the payload. Do NOT include `id` when creating.

```bash
# Experience with positions component
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "$BASE/content-manager/collection-types/api::experience.experience" \
  -d '{
    "companyName": "Acme Corp",
    "companyUrl": "https://acme.com",
    "location": "Remote",
    "overview": "Built things.",
    "sortOrder": 1,
    "positions": [
      {
        "designation": "Senior Engineer",
        "startDate": "2024-01-01",
        "endDate": null,
        "responsibilities": [
          "Did this",
          "Did that"
        ]
      }
    ]
  }'

# Author profile with contactInfo component
curl -s -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "$BASE/content-manager/single-types/api::author-profile.author-profile" \
  -d '{
    "name": "Eric Turner",
    "contactInfo": [
      {"name": "github", "icon": "fab fa-github", "url": "https://github.com/razzam21"},
      {"name": "linkedin", "icon": "fab fa-linkedin", "url": "https://linkedin.com/in/ericturner"}
    ]
  }'
```

## Skill Categories

Current category slugs used in the skills JSON array:

| Category | Skills |
|----------|--------|
| `programming-languages` | Python, PHP, Rust, C#, ASP .NET, GoLang, Node.js, JavaScript, TypeScript |
| `cloud-infrastructure` | GCP, OCI, AWS, Kubernetes, Docker, Terraform, Ansible, Open vSwitch, OpenFlow, SDN, VMware, Proxmox |
| `devops-sre` | DevOps, CI/CD, GitLab CI/CD, Zabbix, Automated Testing, Microservices, Scalable Systems, Capacity Planning, Latency/Throughput Optimization |
| `ai-ml` | AI/ML Pipelines, LLMs, LangChain, MLOps |
| `databases` | SQL, PostgreSQL, MySQL, MongoDB, Qdrant |
| `web-api-development` | Web API Development (REST, SOAP), Laravel, React, Express.js, Next.js, PHP, Node.js, JavaScript, TypeScript, ASP .NET |
| `leadership` | Agile/Scrum, Team Management, Mentoring, High-EQ Communication, Stakeholder Collaboration, Remote Workforces, Global Team Partnerships |
| `soft-skills` | Problem-Solving, Strategic Thinking, Emotional Intelligence, Adaptability |
| `testing` | End-to-End Testing, Workflow Testing |

## Rate Limiting

Strapi applies rate limiting (~100 requests/minute). For bulk operations:
- Add `time.sleep(0.15)` between requests in Python
- If you get HTTP 429, wait 2 seconds and retry once

## Hugo Data Flow

The Hugo site fetches data from Strapi and caches it as JSON:

```
Strapi API → data/strapi/*.json → Hugo builds site from JSON
```

- Data source config: `data/data-source.json` (controls which content types to fetch)
- Fallback: Hugo reads from `data/en/sections/*.yaml` if Strapi is unavailable
- Cache files: `data/strapi/{author,site,about,education,experiences,projects,skills,blog-posts,pages}.json`
- Fetch summary: `data/strapi/fetch-summary.json` (timestamp + record counts)

After updating Strapi content, the Hugo container needs to re-fetch data (or restart) for changes to appear on the site.

## Common Automation Patterns

### Add a new project

```bash
# 1. Create
RESULT=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "$BASE/content-manager/collection-types/api::project.project" \
  -d '{
    "name": "My New Project",
    "role": "Lead Developer",
    "timeline": "2026",
    "summary": "Built a cool thing.",
    "tags": ["professional"],
    "technologies": ["Python", "Docker"],
    "url": "https://example.com",
    "repository": "https://git.example.com/products/project",
    "sortOrder": 1
  }')
DOC_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['documentId'])")

# 2. Publish
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "$BASE/content-manager/collection-types/api::project.project/$DOC_ID/actions/publish" \
  -d "{\"documentId\": \"$DOC_ID\"}"
```

### Add a new experience

```bash
RESULT=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "$BASE/content-manager/collection-types/api::experience.experience" \
  -d '{
    "companyName": "New Company",
    "companyUrl": "https://newco.com",
    "location": "Remote",
    "overview": "What I did there.",
    "sortOrder": 0,
    "positions": [
      {
        "designation": "Senior Engineer",
        "startDate": "2026-01-01",
        "endDate": null,
        "responsibilities": ["Responsibility 1", "Responsibility 2"]
      }
    ]
  }')
DOC_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['documentId'])")
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "$BASE/content-manager/collection-types/api::experience.experience/$DOC_ID/actions/publish" \
  -d "{\"documentId\": \"$DOC_ID\"}"
```

### Add a new skill

```bash
RESULT=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "$BASE/content-manager/collection-types/api::skill.skill" \
  -d '{
    "name": "New Tech",
    "summary": "Experience with New Tech for X.",
    "categories": ["programming-languages"],
    "proficiencyLevel": 50,
    "sortOrder": 99,
    "showOnHomepage": false
  }')
DOC_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['documentId'])")
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "$BASE/content-manager/collection-types/api::skill.skill/$DOC_ID/actions/publish" \
  -d "{\"documentId\": \"$DOC_ID\"}"
```

## Seed Script

Located at `/tmp/seed-strapi.py` — reads from `/tmp/strapi-cache/*.json` and populates all content types. Can be adapted if the database needs to be rebuilt.
