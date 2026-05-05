# Runbook: Legal &amp; Compliance

**Audience:** General Counsel, Chief Compliance Officer, External Auditor (SOC 2, PCI DSS)
**Reading time:** 15 minutes
**Last updated:** 2026-05-04
**Owner:** Compliance Officer (delegated to Cloud Migration Steering Committee for the migration window)

---

## How to use this document

You are reading this because (a) you are signing off on the migration, (b) you are auditing it, or (c) something has triggered a regulatory inquiry. Each section answers one question and points you to the evidence. **No section requires you to read code or interpret architecture diagrams.**

If you are short on time, read sections 1, 2, and 9. They contain the legal posture, the residency controls, and the sign-off chain.

---

## 1. Regulatory frameworks in scope

| Framework | Why it applies | Status post-migration |
|---|---|---|
| **SOC 2 Type II** | Customer-facing financial workload; required for B2B contracts | In scope. Controls listed in section 4. AWS provides SOC 2 Type II report covering shared responsibility (`s3://aws-audit-reports/soc2/`). |
| **PCI DSS 4.0** | Payment data flows through reconciliation pipeline | In scope. Cardholder data segregated to a dedicated VPC; tokenization via AWS Payment Cryptography (Phase 2). Phase 1: cardholder data does not leave the transactional database. |
| **GLBA Safeguards Rule** | Contoso is a financial institution under GLBA definition | In scope. Encryption-at-rest, encryption-in-transit, access controls, and incident response — all met by the architecture. Evidence in section 4. |
| **GDPR (Article 28, 32, 44)** | EU customer data subject to GDPR | In scope. Data residency enforced by Aurora region pinning (section 2). DPA executed with AWS as processor; SCCs in place for any cross-border processing. |
| **NYDFS Part 500** | Contoso licensed in NY | In scope. Annual certification supported by the audit trail described in section 5. |
| **State data breach notification laws** (CCPA, etc.) | All 50 US states have breach notification statutes | In scope. Incident response procedure in Ops runbook section 6. |

**Out of scope (explicitly):** HIPAA (no health data), FedRAMP (no federal customers), CMMC (no DoD work).

---

## 2. Data residency — what is enforced and where

The cloud contract was signed in part to obtain residency controls that on-prem could not provide. Those controls are enforced in three places:

| Layer | Control | Evidence location |
|---|---|---|
| **Compute** | ECS/EKS tasks pinned to `us-east-1` (primary) and `us-west-2` (DR, Phase 2) | Terraform: `infra/main.tf` provider region; ECS service definition `aws_ecs_service` |
| **Database** | Aurora PostgreSQL Serverless v2 region pinned to `us-east-1`. Aurora Global DB secondary region `us-west-2` activates only with explicit ADR. EU data partition deferred to Phase 2 with `eu-west-1` Global DB secondary. | Terraform: `infra/modules/rds.tf` |
| **Object storage** | S3 buckets created with explicit region; Object Lock enabled for audit logs (WORM compliance for 7-year retention). | Terraform: `infra/modules/s3.tf` |

**Data exfiltration controls:**
- Aurora and Redshift accept inbound connections only from VPC CIDR `10.0.0.0/8`. Public access disabled. Evidence: `aws_security_group.rds` ingress rule.
- S3 buckets have `BlockPublicAccess` set to true on all four sub-controls. Evidence: `aws_s3_bucket_public_access_block.reports`.
- VPC has no NAT gateway egress to non-AWS endpoints in the production environment without explicit VPC endpoint configuration.

**No customer data may be processed in regions outside the contractually agreed list.** The Terraform configuration prevents accidental drift via `default_tags` and the AWS provider region lock.

---

## 3. Personally Identifiable Information (PII) and PCI

| Data class | Storage | Encryption | Access |
|---|---|---|---|
| Customer name, email | Aurora PostgreSQL `accounts` table | AES-256-KMS at rest; TLS 1.3 in transit | IAM role-based; ECS task role only |
| Account balance, transaction history | Aurora PostgreSQL `transactions` table | AES-256-KMS at rest; TLS 1.3 in transit | IAM role-based; reporting team users on read replica only |
| Reconciliation reports (PDF) | S3 (versioned, KMS-encrypted) | AES-256-KMS via SSE-KMS | Pre-signed URLs only; URL TTL 1 hour |
| Audit logs | CloudTrail → S3 (Object Lock) | AES-256-KMS; immutable for 7 years | Read access for Compliance role only; no delete |
| Application logs | OpenTelemetry → CloudWatch Logs | AES-256-KMS | Engineering on-call role |

**PII redaction in logs:** Application logs pass through a regex filter at the OpenTelemetry collector layer. Patterns redacted: SSN, credit card primary account numbers (PAN), API tokens. Evidence: collector config in `infra/modules/observability.tf` (Phase 2 module).

**PCI DSS scope minimization:** Cardholder data does not flow through the web-app or batch workloads in Phase 1. Phase 2 streaming integration with the payments processor will include cardholder data; that change is gated on a separate PCI DSS scoping memo (not yet drafted).

---

## 4. Control mapping

The following controls are most frequently asked for in audit. Each row is a control ID, the AWS service that satisfies it, and the location of evidence.

| Control | Framework | AWS service | Evidence |
|---|---|---|---|
| Access control — least privilege | SOC 2 CC6.1 | IAM, ECS task roles | `infra/modules/ecs.tf` `aws_iam_role_policy.ecs_task` |
| Multi-factor authentication | SOC 2 CC6.6 | IAM Identity Center (Phase 2), MFA enforced on root | AWS IAM console; CloudTrail event `ConsoleLogin` with `MFAUsed=Yes` |
| Encryption at rest | PCI 3.5, GLBA | KMS, RDS encryption, S3 SSE-KMS | Terraform: `storage_encrypted = true`, `aws_s3_bucket_server_side_encryption_configuration` |
| Encryption in transit | PCI 4.1, GLBA | TLS 1.3 on ALB; in-transit encryption on Aurora | ALB listener config; Aurora cluster parameter group |
| Audit logging | SOC 2 CC7.2, PCI 10 | CloudTrail (org trail), VPC Flow Logs, S3 access logs | CloudTrail S3 bucket: `s3://contoso-audit-logs/` (Object Lock 7-year retention) |
| Vulnerability management | SOC 2 CC7.1, PCI 11 | Amazon Inspector, ECR image scanning | Inspector findings dashboard; ECR scan results in `contoso-web` repo |
| Incident response | SOC 2 CC7.3 | GuardDuty, Security Hub, SNS alerts | Ops runbook section 6 |
| Backup | SOC 2 A1.2, GLBA | RDS automated backups (35-day retention), S3 versioning, AWS Backup | Aurora console; S3 bucket versioning enabled |
| Change management | SOC 2 CC8.1 | Terraform IaC + GitHub PR reviews + CI gates | GitHub branch protection on `main`; CI workflow runs `terraform validate` and security scans |
| Secret management | SOC 2 CC6.1, PCI 8 | Secrets Manager (auto-rotation), PreToolUse hook in CLAUDE.md | ADR-003; `.claude/settings.json` hook |

**Independence of controls:** No single control failure causes data loss or unauthorized access. Defense in depth is documented in ADR-002 (target services) and ADR-004 (5 Rs assessment).

---

## 5. Audit trail — where to find evidence

All actions taken in the AWS environment are logged. The audit trail has three distinct streams, each with its own retention and access policy:

| Stream | What's captured | Retention | Where to query |
|---|---|---|---|
| **CloudTrail (org trail)** | All AWS API calls — who, what, when, from where | 7 years (Object Lock) | Athena over `s3://contoso-audit-logs/CloudTrail/` |
| **VPC Flow Logs** | Network traffic metadata at the VPC level | 90 days hot, 7 years archived | CloudWatch Logs Insights; archive in S3 Glacier Deep Archive |
| **Application audit log** | Business-event audit trail (transactions written, reports generated) | 7 years | Aurora PostgreSQL `audit_log` table → archived nightly to S3 Object Lock |

**Sample audit query — "show me everyone who accessed the reporting database in March 2026":**
```sql
-- run in Athena over CloudTrail
SELECT userIdentity.userName, eventTime, eventName, sourceIPAddress
FROM cloudtrail_logs
WHERE resources['ARN'] LIKE '%contoso-staging%'
  AND eventTime BETWEEN '2026-03-01' AND '2026-04-01'
ORDER BY eventTime;
```

**Chain of custody:** Audit logs are written by AWS service control plane; tampering would require root account compromise. Object Lock prevents deletion or modification within the retention window. The audit log bucket has its own AWS account isolation (planned in Phase 2) for additional separation of duty.

---

## 6. Vendor / third-party risk

AWS is a sub-processor under the GLBA Safeguards Rule and a processor under GDPR Article 28. The following agreements are in place:

| Agreement | Status | Renewal |
|---|---|---|
| AWS Customer Agreement | Executed | Auto-renew |
| AWS Business Associate Addendum (BAA) | N/A — no health data | — |
| AWS Data Processing Addendum (DPA, GDPR) | Executed | Co-terminus with master agreement |
| Standard Contractual Clauses (SCC) | Module Two executed for any cross-border transfer | Co-terminus |
| AWS SOC 2 Type II report | Available on request from AWS Artifact | Quarterly refresh |

**Sub-processor disclosure:** AWS sub-processors are listed at `aws.amazon.com/compliance/sub-processors`. Contoso receives 30-day notice of any new sub-processor per the DPA.

**Egress to non-AWS services:** The architecture currently has no egress to third-party SaaS providers from production. Any future addition (e.g., Datadog, PagerDuty integration) requires Compliance pre-approval and a vendor risk review.

---

## 7. Incident response — what Legal needs to know

In the event of a security incident, the engineering on-call follows the procedure in the Ops runbook (section 6). Legal is notified per the following matrix:

| Severity | Definition | Legal notification |
|---|---|---|
| **SEV1** | Confirmed unauthorized access to PII or transactional data | Within 1 hour, by phone, to General Counsel |
| **SEV2** | Suspected compromise; no confirmed data access | Within 4 hours, by phone, to General Counsel |
| **SEV3** | Service degradation; no security implication | Email to Compliance, within 24 hours |
| **SEV4** | Internal-only, no customer impact | Logged; no Legal notification required |

**State / federal notification:** If a SEV1 confirms unauthorized access to personal information, the 50-state breach notification matrix applies. Contoso's outside counsel (firm: TBD) maintains the current state-by-state timing requirements; default is 30 days from discovery unless a stricter state requires sooner.

**Forensic preservation:** On declaration of SEV1 or SEV2, the on-call engineer triggers an EBS snapshot of the affected resource and a CloudTrail event export for the relevant time window. Snapshots are preserved in a quarantined account (Phase 2: dedicated forensic account) with no automatic deletion.

---

## 8. Data subject requests (GDPR/CCPA)

A customer may request access to, correction of, or deletion of their personal data. The procedure:

1. Request received by `privacy@contoso.com` (monitored inbox).
2. Compliance Officer authenticates the requester within 5 business days.
3. Engineering receives a ticket with the data subject's customer ID.
4. **Access request:** Engineering runs the standard "data export" query against Aurora and packages the output (CSV + audit log slice) for the data subject.
5. **Deletion request:** Engineering runs the "data deletion" query, which:
   - Soft-deletes the customer record in Aurora (sets `deleted_at`, retains for 90 days for regulatory hold).
   - Removes the customer from active queries by application logic.
   - After 90 days, hard-deletes the record from Aurora and propagates deletion to Redshift, S3 reports (object expiration), and CloudTrail (excluded by retention requirements; documented).
6. Compliance Officer confirms completion to data subject within 30 days of request.

**Hard delete exception:** Records under regulatory hold (litigation, investigation) are not deleted. Compliance Officer must approve any exception.

---

## 9. Sign-off checklist for migration go-live

Before production cutover, the following must be confirmed in writing (a green checkbox in the migration tracker, with the named approver and timestamp):

- [ ] **Compliance Officer:** Reviewed control mapping (section 4); satisfied that SOC 2 and PCI DSS controls have demonstrable evidence.
- [ ] **General Counsel:** Reviewed data residency configuration (section 2); satisfied that customer data does not cross unauthorized borders.
- [ ] **Chief Information Security Officer:** Reviewed encryption configuration (section 3); satisfied that PII and PCI data are encrypted at rest and in transit.
- [ ] **DPO (Data Protection Officer):** Reviewed GDPR posture (sections 2, 6, 8); satisfied that DPA, SCCs, and data subject request procedures are operational.
- [ ] **External Auditor (if required pre-go-live):** Reviewed evidence locations (sections 4, 5); satisfied that audit trail is intact.

**Rollback authority:** If any sign-off is withheld, the cutover is paused. Rollback follows the Ops runbook section 7. Rollback within the first 14 days post-cutover is operationally trivial (the on-prem system remains warm). After day 15, rollback requires a re-migration plan.

---

## 10. Phase 2 compliance commitments

The following are documented commitments in ADR-001 and ADR-004:

| Commitment | Deadline | Owner |
|---|---|---|
| EU data residency partition (Aurora Global DB `eu-west-1` secondary) | Within 12 months of go-live | DPO + Platform |
| AWS IAM Identity Center for cloud-native identity (replaces LDAP AD Connector) | Within 24 months of go-live | Security |
| PCI DSS scoping memo for Phase 2 streaming integration with payments | Before any cardholder data flows through MSK | Compliance |
| Forensic account isolation (separate AWS account for snapshots and CloudTrail) | Within 6 months of go-live | Security |
| Annual penetration test | Annual, first one within 6 months of go-live | Security + external vendor |

---

**Questions about this runbook:** Compliance Officer (compliance@contoso.com) is the primary point of contact. Engineering on-call can answer technical questions; legal interpretation goes to General Counsel.
