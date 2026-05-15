# Service: [Service Name]

**Document ID**: [TASK_ID]
**Folder**: [FOLDER]
**Created**: [YYYY-MM-DD]
**Last Updated**: [YYYY-MM-DD]
**Type**: Service Documentation
**Status**: [Active/Deprecated/Planned]

---

## Service Overview

**Name**: [Full service name]
**Purpose**: [What this service does in one sentence]
**Owner**: [Team/Person]
**Status**: [Production/Staging/Development]

**Quick Links**:
- Repository: [URL]
- CI/CD Pipeline: [URL]
- Monitoring Dashboard: [URL]
- Logs: [URL]
- Alerts: [URL]

---

## What This Service Does

**Primary Function**:
[Detailed description of what the service does]

**Key Capabilities**:
- [Capability 1]
- [Capability 2]
- [Capability 3]

**Business Value**:
[Why this service exists and what business need it fulfills]

---

## Architecture

**Type**: [API/Worker/Web App/Microservice/Database/etc.]
**Language/Framework**: [e.g., Python/FastAPI, Node.js/Express, Go, etc.]
**Runtime**: [e.g., Docker, Kubernetes, Lambda]

**Dependencies**:
- [Service/Database 1] - [Why needed]
- [Service/Database 2] - [Why needed]
- [External API 1] - [Why needed]

**Dependents** (Who depends on this service):
- [Service 1] - [How they use it]
- [Service 2] - [How they use it]

**Architecture Diagram**:
```
[Text description or ASCII diagram]

Client -> Load Balancer -> [This Service] -> Database
                                          -> External API
```

---

## API Documentation

### Endpoints

#### GET /api/v1/[resource]
**Purpose**: [What this endpoint does]
**Authentication**: [Required/Optional/None]
**Rate Limit**: [Requests per minute]

**Request**:
```json
{
  "param1": "value",
  "param2": "value"
}
```

**Response** (200 OK):
```json
{
  "data": [...],
  "meta": {...}
}
```

**Errors**:
- 400: [When this occurs]
- 401: [When this occurs]
- 500: [When this occurs]

#### POST /api/v1/[resource]
[Same structure for each endpoint]

---

## Configuration

**Environment Variables**:
| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `DATABASE_URL` | Yes | N/A | Database connection string |
| `API_KEY` | Yes | N/A | External API authentication |
| `LOG_LEVEL` | No | `info` | Logging verbosity |
| `PORT` | No | `8000` | HTTP port |

**Feature Flags**:
| Flag | Default | Description |
|------|---------|-------------|
| `enable_new_feature` | `false` | Enables new feature X |
| `use_cache` | `true` | Enable caching layer |

**Configuration Files**:
- `config/production.yaml` - Production settings
- `config/staging.yaml` - Staging settings

---

## Data Models

### Model: [Entity Name]
**Table/Collection**: `[table_name]`

**Fields**:
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | UUID | Yes | Primary key |
| `name` | String | Yes | Entity name |
| `created_at` | Timestamp | Yes | Creation timestamp |
| `status` | Enum | Yes | active/inactive/deleted |

**Indexes**:
- `idx_name` - Index on `name` field
- `idx_created_at` - Index on `created_at` field

**Relationships**:
- Has many: [Related entity]
- Belongs to: [Parent entity]

---

## Deployment

**Deployment Method**: [Docker/Kubernetes/Serverless/etc.]

**Environments**:
- **Development**: [URL/Details]
- **Staging**: [URL/Details]
- **Production**: [URL/Details]

**Deployment Process**:
1. [Step 1]
2. [Step 2]
3. [Step 3]

**Deployment Frequency**: [How often deployed]

**Infrastructure**:
- Compute: [Type and size]
- Memory: [Amount]
- Storage: [Type and size]
- Network: [Details]

---

## Monitoring & Alerting

**Health Check Endpoint**: `/health`
**Expected Response**: 200 OK with `{"status": "healthy"}`

**Key Metrics**:
| Metric | Normal Range | Alert Threshold |
|--------|-------------|-----------------|
| Response time | < 200ms | > 500ms |
| Error rate | < 0.1% | > 1% |
| CPU usage | < 70% | > 85% |
| Memory usage | < 80% | > 90% |
| Request rate | 100-1000/min | > 2000/min |

**Dashboards**:
- [Dashboard name] - [URL]
- [Dashboard name] - [URL]

**Alerts**:
- **High error rate** - Triggers when error rate > 1%
- **High latency** - Triggers when p99 > 1s
- **Service down** - Triggers when health check fails

**On-Call**: [Team/Rotation info]

---

## Logging

**Log Level**: [INFO/DEBUG/ERROR]
**Log Format**: [JSON/Plain text]
**Log Location**: [Where logs are stored]

**Key Log Events**:
- `request_started` - HTTP request received
- `request_completed` - HTTP request completed
- `database_query` - Database query executed
- `error_occurred` - Error encountered

**Log Retention**: [Duration]

---

## Performance

**Expected Load**:
- Requests per second: [Number]
- Concurrent users: [Number]
- Data volume: [Size]

**Performance Benchmarks**:
| Operation | Average | p95 | p99 |
|-----------|---------|-----|-----|
| GET request | [ms] | [ms] | [ms] |
| POST request | [ms] | [ms] | [ms] |
| Database query | [ms] | [ms] | [ms] |

**Scaling**:
- Horizontal: [Can it scale horizontally?]
- Vertical: [Resource limits]
- Auto-scaling: [Yes/No - rules]

---

## Security

**Authentication**: [OAuth/JWT/API Key/etc.]
**Authorization**: [RBAC/ACL/etc.]
**Data Encryption**:
- At rest: [Yes/No - method]
- In transit: [Yes/No - TLS version]

**Security Measures**:
- [ ] Input validation
- [ ] SQL injection protection
- [ ] XSS protection
- [ ] CSRF protection
- [ ] Rate limiting
- [ ] IP whitelisting

**Secrets Management**: [Where secrets are stored]

**Compliance**: [GDPR/HIPAA/SOC2/etc.]

---

## Testing

**Test Coverage**: [Percentage]

**Test Types**:
- Unit tests: `make test-unit`
- Integration tests: `make test-integration`
- E2E tests: `make test-e2e`

**Test Environments**:
- Local: `docker-compose up`
- CI/CD: [Pipeline info]

**Load Testing**:
- Tool: [k6/Locust/etc.]
- Target: [RPS/Users]
- Results: [Summary]

---

## Operations

### Starting the Service
```bash
# Development
make dev

# Production
docker-compose up -d
```

### Stopping the Service
```bash
docker-compose down
```

### Viewing Logs
```bash
docker-compose logs -f [service-name]
```

### Common Operations
```bash
# Clear cache
make cache-clear

# Run migrations
make migrate

# Backup database
make db-backup
```

---

## Troubleshooting

### Issue: Service won't start
**Symptoms**: [Description]
**Causes**:
- [Cause 1]
- [Cause 2]
**Resolution**:
1. [Step 1]
2. [Step 2]

### Issue: High memory usage
**Symptoms**: [Description]
**Causes**: [Causes]
**Resolution**: [Steps]

### Issue: Database connection errors
**Symptoms**: [Description]
**Causes**: [Causes]
**Resolution**: [Steps]

---

## Runbook

### Incident: Service Down
1. Check health endpoint
2. Check logs for errors
3. Check dependencies (database, APIs)
4. Restart service if needed
5. Escalate if not resolved in 15 minutes

### Incident: High Error Rate
1. Check recent deployments
2. Review error logs
3. Check external dependencies
4. Roll back if recent deployment
5. Apply fixes and monitor

### Maintenance: Updating Dependencies
1. Review dependency changes
2. Test in development
3. Deploy to staging
4. Run full test suite
5. Deploy to production during low-traffic window

---

## Development

**Local Setup**:
```bash
# Clone repository
git clone [repo-url]

# Install dependencies
make install

# Set up environment
cp .env.example .env

# Start services
make dev
```

**Development Workflow**:
1. Create feature branch
2. Make changes
3. Run tests locally
4. Create pull request
5. Deploy to staging after approval
6. Deploy to production

**Code Style**: [Style guide reference]
**Linting**: `make lint`
**Formatting**: `make format`

---

## Change History

| Date | Version | Changes | Author |
|------|---------|---------|--------|
| [YYYY-MM-DD] | 1.0.0 | Initial release | [Name] |
| [YYYY-MM-DD] | 1.1.0 | Added feature X | [Name] |
| [YYYY-MM-DD] | 1.2.0 | Performance improvements | [Name] |

---

## Related Documentation

- Architecture Decision Records: [Link]
- API Changelog: [Link]
- Database Schema: [Link]
- Deployment Guide: [Link]

---

## Contact

**Owner Team**: [Team name]
**Slack Channel**: #[channel]
**Email**: [team-email@company.com]
**On-Call**: [PagerDuty link or rotation info]

**Key Contacts**:
- Technical Lead: [Name]
- Product Owner: [Name]
- On-Call Rotation: [Link]

---

## Future Roadmap

**Planned Improvements**:
- [ ] [Improvement 1] - Target: [Quarter/Date]
- [ ] [Improvement 2] - Target: [Quarter/Date]

**Known Limitations**:
- [Limitation 1]
- [Limitation 2]

**Deprecation Plans**:
[If service is being deprecated, describe timeline and migration path]
