# Runbook: CTO Office

**Audience:** CTO, VP Engineering, Principal Engineers, Platform Architecture team
**Reading time:** 20 minutes
**Last updated:** 2026-05-04
**Owner:** Cloud Architecture Team Lead (delegated from CTO for the migration window)

---

## How to use this document

This is the technical-leadership companion to the migration. It exists because the ADRs are correct but dense, and because someone needs to be able to defend the architecture in a board meeting without re-reading 12 files. Read sections 1, 4, and 6 before any executive review.

**If you disagree with a decision in this runbook, the path is:** raise an objection with the Architecture Team Lead, who will either update the ADR or escalate to a steering committee vote. Do not silently override.

---

## 1. Executive summary — what we built and why

We migrated three on-prem workloads to AWS using a per-workload **5 Rs** disposition (Refactor, Re-platform, Re-Architect, Retire), not a blanket lift-and-shift. The blanket label was inaccurate: Python 2.7 cannot be re-hosted (security non-starter), and several "dependencies" were operational bugs that warranted retirement, not migration.

**Phase 1 outcomes (ship now):**
- Web app: Refactored to FastAPI on Python 3.11, containerized for ECS Fargate with the same image deployable to EKS in Phase 2.
- Batch: Re-platformed to AWS Batch + EventBridge with S3 outputs.
- Reporting DB: Re-platformed to Aurora PostgreSQL Serverless v2 with multi-AZ.
- Six adjacent components retired (warm-ping cron, NFS, pgBouncer, Apache, shared admin user, manual schema migrations).

**Phase 2 commitments (within 18 months):**
- Web app: Re-platform to EKS + Karpenter on Graviton3 for portability and AI workload readiness.
- Batch: Re-architect to Amazon MSK streaming, eliminating the 24-hour information delay.
- Reporting: Re-architect with OLTP/OLAP separation — Redshift Serverless + S3 data lake for the BI team.

**Why this is defensible at audit and at board level:** Each disposition has a documented driver. Each Phase 2 commitment has a named owner and deadline. Each trade-off we accepted is named explicitly. There is no "we'll figure it out later."

---

## 2. ADR index — the decisions you should know cold

| ADR | One-line summary | Read in full when |
|---|---|---|
| [ADR-001](../decisions/ADR-001-migration-pattern.md) | Per-workload 5 Rs (not blanket lift-and-shift) | Anyone questions the migration approach |
| [ADR-002](../decisions/ADR-002-target-cloud-services.md) | EKS, Aurora, Redshift Serverless as Phase 2 target; ECS, Aurora, read replica for Phase 1 | Anyone questions a service choice |
| [ADR-003](../decisions/ADR-003-secrets-hook-vs-prompt.md) | Secrets enforced by deterministic PreToolUse hook, not by prompt guidance | Anyone proposes a "we'll just remind people" control |
| [ADR-004](../decisions/ADR-004-five-rs-workload-assessment.md) | Per-workload 5 Rs disposition with adjacent retirements named | Anyone wants to add a workload to scope |

**ADR review cadence:** Quarterly. Each ADR has a "review date" — if the review date passes without action, the ADR is considered stale and must be re-validated or superseded. Stale ADRs are a code smell, not a soft failure.

---

## 3. Technical risk register

The top risks. Each row has a likelihood × impact rating, the mitigation we built, and the owner who watches it.

| # | Risk | L × I | Mitigation | Owner | Trip-wire |
|---|---|---|---|---|---|
| 1 | EKS migration in Phase 2 takes 2x estimated time | Med × High | Image is identical for ECS and EKS; only deployment manifest changes. Karpenter PoC scheduled for month 6. | Platform | If Karpenter PoC slips past month 9, escalate. |
| 2 | Aurora cost overrun in first 90 days | Med × Med | Aurora Serverless v2 ACU range capped at 0.5–32 initially (raise after observation). CloudWatch alarm on monthly cost > $X. | Platform + Finance | Alarm fires twice in 90 days → re-evaluate ACU range. |
| 3 | BI team resists Redshift cutover | High × Med | Pre-cutover Glue ETL parity validation (BI team validates same query produces same result). 30-day parallel run. | Data Eng | If parity validation < 99% match, delay cutover. |
| 4 | LDAP AD Connector latency degrades login UX | Med × Med | Cached auth tokens at the application layer. Plan B: AD on EC2 in VPC (Phase 1.5). | Security | Login p95 > 2s for 1 hour → escalate. |
| 5 | Secrets Manager auto-rotation breaks application | Med × High | Rotation tested in staging for 30 days before production. App connects via Secrets Manager SDK with retry on rotation. | Platform | One rotation failure in production → freeze further rotations until RCA. |
| 6 | Compliance auditor demands evidence we don't have | Low × High | Pre-cutover audit dry-run with Compliance Officer (mock SOC 2 walk-through). | Compliance | Dry-run identifies > 2 evidence gaps → block go-live. |
| 7 | SRE team cannot operate EKS in Phase 2 | Med × High | EKS training program in months 4–8. Hands-on with non-prod cluster from month 6. Hire one SRE with K8s experience. | VP Eng | Training sign-off < 80% → delay Phase 2 cutover. |
| 8 | Aurora Global DB secondary region cost not budgeted | Med × Med | Year 3 activation only; budget request in Year 2 planning cycle. | Finance + Platform | If activated before Year 3, requires CFO approval. |
| 9 | OpenTelemetry adoption stalls — teams keep using CloudWatch directly | High × Low | OTel is the default in CLAUDE.md; CI lint blocks direct CloudWatch SDK calls in new code. | Platform | If CI lint disabled or bypassed > 3 times → escalate. |
| 10 | A future ADR contradicts a Phase 2 commitment without explicit supersede | Low × High | All ADRs are PR-reviewed; PR template requires "supersedes" field. Quarterly ADR review. | Architecture | Any ADR merged without supersede check → block merge. |

**This list is not exhaustive.** It is the list of risks the team has actually thought about. Risks not on this list either haven't been identified or aren't yet credible. Add new risks via PR to this document; do not maintain a parallel list.

---

## 4. Phase 2 commitment table — what we owe and when

This is the contract with the CTO. Each row is enforceable.

| Phase 2 deliverable | Owner | Deadline | Success criteria | Status |
|---|---|---|---|---|
| EKS + Karpenter migration (web app) | Platform Lead | Month 12 | Production traffic 100% on EKS; ECS service deleted; cost neutral or better than ECS Fargate baseline | Not started |
| Amazon MSK + stream processor (batch) | Data Engineering Lead | Month 18 | Reconciliation latency < 60s p95; AWS Batch job retired; MSK consumer SLO met | Not started |
| OLTP/OLAP split (Redshift Serverless + S3 lake) | Data Engineering Lead | Month 18 | All 5 BI teams cut over to Redshift; Aurora read replica retired; query parity validated at 99%+ | Not started |
| AD Connector → IAM Identity Center | Security Lead | Month 24 | All workforce identities in Identity Center; LDAP AD Connector retired | Not started |
| OpenTelemetry instrumentation across all services | Platform Lead | Month 6 | 100% of new services instrumented; 80% of existing services migrated from CloudWatch SDK | Not started |
| Aurora Global DB secondary region (us-west-2) | Platform Lead | Month 36 | Multi-region active-passive with sub-second RPO; DR runbook validated | Conditional on budget |
| EU data residency partition (Aurora Global DB eu-west-1) | DPO + Platform | Month 12 | EU customer data resident in eu-west-1; compliance sign-off | Conditional on customer demand |
| Forensic account isolation | Security Lead | Month 6 | CloudTrail and EBS snapshots in dedicated AWS account; cross-account read access for forensics | Not started |
| Annual penetration test | Security Lead + external | Month 6, then annual | Pen test executed; findings remediated within 90 days or accepted with risk acceptance | Not started |
| First-pass review of candidate workloads (SMTP, backups, Jenkins, SFTP, wiki, monitoring) | Architecture Lead | Month 3 | 5 Rs disposition documented for each; recommended scope for Phase 2 expansion | Not started |

**Slippage protocol:** A commitment slipping more than 30 days from its deadline triggers a steering committee review. The owner presents (a) why it slipped, (b) the new deadline, (c) what changed. The committee decides: accept the new deadline, reassign ownership, or descope.

---

## 5. 3-year TCO projection (rough order of magnitude)

These are working numbers, not contracts. Real cost depends on actual usage patterns observed post-cutover.

| Year | On-prem (counterfactual) | AWS (actual) | Delta | Notes |
|---|---|---|---|---|
| Year 1 | ~$520K | ~$430K (Phase 1 + ramp) | -17% | Includes ~$80K migration cost; right-sizing window |
| Year 2 | ~$540K (3% inflation) | ~$370K (Phase 2 transitions) | -31% | EKS Karpenter savings; serverless scale-to-zero |
| Year 3 | ~$560K | ~$390K (Global DB secondary on; multi-region) | -30% | Redshift Serverless replaces always-on read replica |

**Assumptions documented in `/decisions/cost-model-assumptions.md`** (placeholder — to be populated with actual sizing parameters from on-prem inventory and CloudWatch usage data over the first 30 days post-cutover).

**Where the savings come from (in priority order):**
1. **Retired components** — Apache, pgBouncer, NFS server, on-prem LDAP-only access path. Five physical servers go offline within 60 days of cutover.
2. **Serverless scale-to-zero** — ElastiCache Serverless and Aurora Serverless v2 cost approximately zero during overnight low-traffic windows.
3. **Graviton3 in Phase 2** — 30–40% better price-performance than equivalent x86 on EKS.
4. **Redshift Serverless** — replaces always-on Aurora read replica (currently sized for peak, idle most hours).
5. **S3 Intelligent-Tiering** — old reconciliation reports auto-move to Infrequent Access after 30 days, Glacier after 90.

**Cost risks (above the line in the risk register):** Aurora cost overrun (#2), Global DB secondary region cost (#8). Watch them.

---

## 6. Architecture review cadence + tech radar

We commit to reviewing architecture decisions on a regular cadence rather than waiting for a crisis to force the conversation.

**Cadence:**
- **Monthly** — Architecture Team Lead reviews CloudWatch usage, cost, and incident summaries. Output: a one-page memo.
- **Quarterly** — Architecture Team Lead + CTO review ADR status, Phase 2 commitments, and risk register changes. Output: an updated commitment table.
- **Annual** — Steering committee reviews the entire architecture against the original criteria (cost, risk, operability, longevity, AI/ML readiness). Output: a "what changed and what should change" memo to the board.

**Tech radar — adoption signals:**
- A service moves from "trial" to "adopted" when (a) two production workloads use it successfully for 90 days, and (b) the SRE team has run an incident game-day against it.
- A service moves from "adopted" to "hold" when (a) two consecutive production incidents have it in the contributing factors, or (b) AWS deprecates a feature we depend on, or (c) cost overruns exceed 25% of forecast for 60 days.
- A service moves to "retire" when there is a credible replacement and a documented migration path.

**Currently on the radar — adopted:** ECS Fargate, Aurora Serverless v2, ElastiCache Serverless, S3, Secrets Manager, GuardDuty, OpenTelemetry, Terraform.

**Currently on the radar — trial (Phase 2 candidates):** EKS + Karpenter, Amazon MSK, Redshift Serverless, AWS Bedrock, OpenTofu, Aurora Global Database.

**Currently on the radar — hold:** None.

**Currently on the radar — retire:** Apache httpd, pgBouncer, NFS, on-prem LDAP (Phase 2), AWS Batch (Phase 2 transition to MSK).

---

## 7. Escalation chain

Disagreement is healthy; silent override is not. The path:

| Level | Who | When |
|---|---|---|
| L1 | Architecture Team Lead | First-line technical disagreement |
| L2 | VP Engineering | Architecture Lead and engineer cannot reach consensus within 5 business days |
| L3 | CTO | VP Eng decision is contested; cross-organization impact |
| L4 | Steering Committee (CTO, CFO, GC, Chief Compliance Officer) | Decision crosses cost, legal, or compliance boundaries |

**For this migration specifically:**
- ADR-blocking decisions go L1 → L2 → CTO if needed.
- Phase 2 commitment changes go to the Steering Committee.
- Any decision affecting Compliance scope (PCI, GDPR, GLBA) goes to the Steering Committee with Compliance Officer present.

---

## 8. The "this is what would worry me at 3am" list

Things the CTO should be aware of, not because they are imminent risks, but because they are non-obvious dependencies:

1. **Karpenter is a single point of cluster intelligence in EKS.** If it misbehaves, pods don't get scheduled. Mitigation: keep a small managed node group as a fallback for system pods (CoreDNS, etc.).

2. **Aurora Serverless v2 cold-start latency at 0.5 ACUs.** First request after a long idle window can see 1–2 second latency while ACUs scale up. We've sized the minimum ACU floor to 1.0 in production for this reason. Documented in `infra/local.tfvars`.

3. **Pre-signed URL expiration coupled to S3 storage class.** When reports tier to Glacier, pre-signed URLs may not work without a restore. Application layer must handle this; currently it doesn't. Mitigation: bias to Infrequent Access (immediate retrieval) over Glacier for reports under 1 year old.

4. **OpenTelemetry collector is itself a single point of observability failure.** If the collector pod crashes, we lose telemetry. Mitigation: DaemonSet (one per node); alerting via CloudWatch as a fallback path.

5. **Terraform state file in S3.** State file corruption is a worst-case scenario. Mitigation: S3 versioning + DynamoDB lock + daily backup to a separate account. Documented in `infra/main.tf` backend block.

6. **The PreToolUse hook is a defense, not a guarantee.** It catches obvious patterns. Determined exfiltration of secrets through, e.g., environment variable injection at runtime is not blocked by the hook. Defense in depth: GuardDuty + IAM role boundaries + Secrets Manager rotation.

7. **The 5 reporting teams have hardcoded credentials in their query tools.** Until they cut over to Redshift Serverless and IAM auth (Phase 2), the migration carries forward a known credential-sprawl risk. Mitigation: rotation at cutover with new credentials; password manager mandate for the teams.

8. **AWS service deprecation timeline is unknowable.** Five years from now, services we currently rely on may be deprecated, repriced, or replaced. The 5 Rs framework gives us a structured way to re-decide; the ADR-driven architecture means re-decisions happen with full context, not through panic.

---

## 9. What good looks like 12 months from now

- All 4 Phase 2 milestones at month 12 are met or have explicit, accepted slip explanations.
- Cost is at or below the 3-year TCO projection.
- No SEV1 incident in the migration window.
- SOC 2 Type II audit completed with no findings traceable to the migration architecture.
- The candidate workload review (SMTP, backups, Jenkins, SFTP, wiki, monitoring) is complete with 5 Rs dispositions.
- The team is ready to defend Phase 3 (whatever that turns out to be) with the same rigor.

**What "ready" means here:** ADRs current, risk register current, commitments current, runbooks current. Nothing is more than one quarter stale.
