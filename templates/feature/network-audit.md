# Network Audit: [Page/Feature Name]

**Created**: [YYYYMMDDHHMM]
**Type**: Network Analysis
**Author**: Claude
**Status**: Final

---

## 1. Audit Overview
[Summary of the network performance and API call behavior observed.]

**Target URL**: [URL audited]
**Total Requests**: [Count]
**Total Data Transferred**: [Size in MB]
**Audit Duration**: [Seconds]

---

## 2. API Call Analysis
[Breakdown of backend communication.]

### Top Most Frequent Calls
| Endpoint | Method | Count | Avg Size | Status |
|----------|--------|-------|----------|--------|
| `[api-path]` | [GET/POST] | [N] | [KB] | [200] |

### Potentially Excessive/Redundant Requests
- **[Endpoint]**: [Reason: e.g., called 15 times in 2 seconds, suggesting a missing cache or a loop.]
- **[Endpoint]**: [Reason: e.g., large payload retrieved multiple times.]

---

## 3. Performance Metrics
- **DOMContentLoaded**: [ms]
- **Largest Contentful Paint**: [ms]
- **Total Blocking Time**: [ms]

---

## 4. Discovery & Issues
[Specific findings from the network trace.]

- **⚠️ [Issue 1]**: [e.g., Waterfall shows serial requests that could be parallelized.]
- **⚠️ [Issue 2]**: [e.g., Large JSON payloads containing unused fields.]
- **⚠️ [Issue 3]**: [e.g., Lack of `Cache-Control` headers on static assets.]

---

## 5. Optimization Recommendations
1. **[Recommendation 1]**: [Actionable fix]
2. **[Recommendation 2]**: [Actionable fix]

---

**Audit Completed**: [YYYYMMDDHHMM]
