# Reference: RDS Database Provisioning

**Type**: Reference
**Created**: 2026-02-18
**Status**: Current
**Applies To**: AWS RDS (MySQL), AWS Secrets Manager

---

## Overview

The `create-rds-database.sh` script is a utility for provisioning MySQL databases on existing AWS RDS instances. It automates the creation of the database, the generation of strong passwords for application and migration users, and the storage of these credentials in AWS Secrets Manager.

**Audience**: DevOps Engineers, Backend Developers
**Prerequisites**:
- AWS CLI configured with appropriate permissions (RDS and Secrets Manager)
- `mysql` client installed on the host
- `jq` installed on the host
- Network access to the RDS instance (VPN or Security Group)

---

## Usage

The script supports two ways to provide administrative credentials for the RDS instance.

### 1. Direct Admin Credentials
Provide the admin username and password directly via flags.

```bash
~/.claude/scripts/create-rds-database.sh 
  --database analytics 
  --host mydb.us-west-1.rds.amazonaws.com 
  --admin-user admin 
  --admin-password 'your-secret-pass' 
  --target-secret myapp/production/analytics-db
```

### 2. Credentials from AWS Secrets Manager
Fetch the admin credentials from an existing secret. This is recommended for production environments.

```bash
~/.claude/scripts/create-rds-database.sh 
  --database analytics 
  --admin-secret myapp/production/master-db-creds 
  --admin-key-host DB_HOST 
  --admin-key-user DB_USER 
  --admin-key-password DB_PASSWORD 
  --target-secret myapp/production/analytics-db
```

---

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `--database` | Yes | Name of the MySQL database to create. |
| `--target-secret` | Yes | Name for the new secret in AWS Secrets Manager. |
| `--host` | Cond. | RDS endpoint (Required if `--admin-secret` is not used). |
| `--admin-user` | Cond. | Admin username (Required if `--admin-secret` is not used). |
| `--admin-password`| Cond. | Admin password (Required if `--admin-secret` is not used). |
| `--admin-secret` | Cond. | Name of the secret containing admin credentials. |
| `--app-user` | No | App username (Default: `{database}_app`). |
| `--migrations-user`| No | Migrations username (Default: `{database}_migrations`). |
| `--region` | No | AWS region (Default: `us-west-1` or `$AWS_REGION`). |
| `--dry-run` | No | Show SQL and Secret JSON without executing. |

---

## Security Model

The script creates two distinct users for the new database to follow the principle of least privilege:

1.  **Application User (`_app`)**:
    *   **Privileges**: `SELECT`, `INSERT`, `UPDATE`, `DELETE` (DML only).
    *   **Purpose**: Used by the application during normal runtime.
2.  **Migrations User (`_migrations`)**:
    *   **Privileges**: `SELECT`, `INSERT`, `UPDATE`, `DELETE`, `CREATE`, `ALTER`, `DROP`, `INDEX`, `REFERENCES`.
    *   **Purpose**: Used by CI/CD or initialization scripts to manage schema changes.

**Generated Secret Structure**:
```json
{
  "host": "...",
  "port": "3306",
  "database": "...",
  "username": "..._app",
  "password": "...",
  "ssl": "rds",
  "migrations_user": "..._migrations",
  "migrations_password": "..."
}
```

---

## Verification

After execution, the script automatically attempts to connect using both the new `app` and `migrations` users to verify the setup.

```bash
# Manual verification example
mysql -h <host> -u <user> -p <database> --execute="SELECT 1"
```

---

## Troubleshooting

### Connection Failures
- **Symptom**: `MySQL commands failed. Check admin credentials and network access.`
- **Cause**: Usually either incorrect admin password or the RDS security group doesn't allow traffic from your current IP.
- **Solution**: Verify VPN connection or add your IP to the RDS Security Group inbound rules for port 3306.

### Secrets Manager Errors
- **Symptom**: `Failed to fetch admin secret` or `Failed to create secret`.
- **Cause**: Missing IAM permissions or incorrect secret name/region.
- **Solution**: Ensure your AWS identity has `secretsmanager:GetSecretValue`, `secretsmanager:CreateSecret`, and `secretsmanager:PutSecretValue`.

---

**Last Updated**: 2026-02-18
