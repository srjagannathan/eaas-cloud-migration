# Runbook: Operations / SRE — The 4am Runbook

**Audience:** SRE on-call, Engineering on-call, Incident Commander
**Reading time:** 25 minutes (read it cold once; you may not have time when it matters)
**Last updated:** 2026-05-04
**Owner:** SRE Lead

---

## How to use this document

If you are reading this at 4am because something is on fire, **go straight to section 6 (Incident Response)**. Use the severity matrix to decide who to wake up. Don't read this from the top.

If you are reading this in advance of a cutover, read sections 2, 3, 4, and 5 in order. Practice section 4 (rollback) on staging before you trust it in production.

If you are new to the on-call rotation, read everything once. Then re-read section 6.

**Conventions in this document:**
- Commands shown are exact and executable. Substitute `<placeholder>` values from the environment.
- All AWS CLI commands assume the `contoso-prod` profile is configured and active.
- All Terraform commands run from `infra/`.

---

## 1. Quick reference

| What | Where |
|---|---|
| Web app health check | `https://app.contoso.com/health` (returns 200 + JSON) |
| ALB DNS | Output of `terraform output alb_dns_name` |
| Aurora primary endpoint | Secrets Manager: `contoso/production/db` → `host` field |
| MinIO console (local dev) | http://localhost:9001 |
| GuardDuty findings | AWS Console → GuardDuty → Findings |
| CloudWatch dashboards | AWS Console → CloudWatch → Dashboards → `contoso-prod` |
| PagerDuty escalation policy | `Contoso-Production` schedule |
| Status page | https://status.contoso.com |

**Escalation contacts** (the order to wake people up; respect business hours when severity allows):

| Role | Primary on-call | Secondary | When to escalate |
|---|---|---|---|
| SRE | PagerDuty `Contoso-SRE` | Backup rotation | First responder for anything user-facing |
| Engineering | PagerDuty `Contoso-Eng` | Tech lead per workload | When SRE confirms it's an application bug |
| Database | DBA on-call | Architecture Lead | Aurora-specific incidents, replication lag |
| Security | CISO on-call | Compliance Officer | Suspected unauthorized access |
| Legal | General Counsel | Outside counsel | SEV1 with confirmed data exposure |

---

## 2. Cutover sequence — the 4-week run-up

Cutover is staged. Do not skip stages; do not run them out of order.

### T-7 days (one week before go-live)

**Goal:** Final validation in staging.

```bash
# 1. Validate IaC
cd infra && terraform plan -var-file=staging.tfvars
# Expected: zero changes if staging is current

# 2. Bring up the local stand-in stack (smoke check)
cd ../  # back to repo root
docker compose up -d
docker compose ps    # all services healthy
docker compose run --rm batch    # batch job runs successfully

# 3. Run validation suite
cd tests && uv run pytest -v
# Expected: all green

# 4. Pre-flight Compliance walk-through
# Compliance Officer reviews Legal runbook section 9 sign-off checklist
```

**Sign-offs collected:** Compliance, Security, DPO. See Legal runbook section 9.

### T-3 days

**Goal:** Production environment provisioned. No traffic yet.

```bash
# 1. Apply production Terraform (this creates the AWS resources)
cd infra && terraform apply -var-file=production.tfvars
# Expected: ~80 resources created in 12-15 minutes

# 2. Verify resources
aws ecs describe-services --cluster contoso-production --services contoso-web-production
aws rds describe-db-instances --db-instance-identifier contoso-production
aws s3 ls s3://contoso-reports-prod/

# 3. Seed reference data (idempotent)
docker compose -f docker-compose.prod-seed.yml run --rm seed
```

### T-1 day

**Goal:** Communications sent. Final go/no-go.

- Send cutover notice to: 5 reporting teams, customer support, partner integrations.
- Status page maintenance window scheduled.
- On-call rotation confirmed for cutover window (Engineering Lead + SRE on-call + DBA on-call).

### T-0 (cutover day)

**Cutover window: 2-hour scheduled window, 0200-0400 UTC.**

```bash
# Step 1 (T+0:00): Drain on-prem traffic
# Update Route 53 weighted routing: on-prem 100% → AWS 100%
aws route53 change-resource-record-sets --hosted-zone-id Z123 \
  --change-batch file://cutover/route53-aws-100.json

# Step 2 (T+0:05): Validate health endpoint serving from AWS
curl -fsS https://app.contoso.com/health | jq .
# Expected: {"status":"ok","timestamp":"2026-..."}

# Step 3 (T+0:10): Run smoke tests against production
cd tests && WEB_APP_URL=https://app.contoso.com uv run pytest smoke/ -v

# Step 4 (T+0:15): Disable on-prem cron (warm-ping cron retired)
ssh batch01.contoso.local "sudo crontab -r"

# Step 5 (T+0:20): Run first reconciliation in AWS Batch
aws batch submit-job --job-name cutover-validation \
  --job-queue contoso-reconciliation-production \
  --job-definition contoso-reconciliation-production:1
# Wait for completion (~5-10 min); validate output in s3://contoso-reports-prod/

# Step 6 (T+0:30): Notify reporting teams to switch endpoints
# Email + Slack: read replica endpoint, new IAM credentials per team

# Step 7 (T+1:00): Monitor — see section 5
```

### T+1 to T+14 (warm rollback window)

The on-prem environment remains warm for 14 days. Rollback within this window is operationally trivial (see section 4).

### T+15

On-prem decommission begins:
- Day 15: stop on-prem services
- Day 30: archive on-prem data (encrypted backup to S3 Glacier Deep Archive)
- Day 45: decommission hardware

---

## 3. Pre-flight checklist (before any production change)

Run through this before any production deploy, not just go-live:

- [ ] Latest CI green on `main` branch
- [ ] `terraform plan` shows only the changes intended (no unexplained drift)
- [ ] PR reviewed and approved by at least one peer
- [ ] On-call notified in #incidents
- [ ] Rollback command identified and tested (see section 4)
- [ ] CloudWatch dashboards open in a browser tab
- [ ] PagerDuty schedule confirmed
- [ ] Status page maintenance window opened (if user-facing)
- [ ] Validation queries ready to run post-deploy

---

## 4. Rollback procedures — the most-important section

**Rollback is faster than fixing forward in 95% of incidents.** Default to rollback when uncertain.

### 4.1 Web app rollback (ECS Fargate)

**Symptom:** Web app returning 5xx, latency spike, OOM, or any user-visible degradation after a deploy.

**Rollback (3 minutes):**
```bash
# 1. Identify the previous task definition
PREV=$(aws ecs describe-services \
  --cluster contoso-production --services contoso-web-production \
  --query 'services[0].deployments[?status==`PRIMARY`].taskDefinition' \
  --output text | sed 's/:[0-9]*$//' | xargs -I{} aws ecs list-task-definitions \
  --family-prefix {} --status ACTIVE --sort DESC --max-items 2 \
  --query 'taskDefinitionArns[1]' --output text)

# 2. Update the service to the previous task definition
aws ecs update-service \
  --cluster contoso-production \
  --service contoso-web-production \
  --task-definition $PREV \
  --force-new-deployment

# 3. Wait for stable
aws ecs wait services-stable \
  --cluster contoso-production --services contoso-web-production
```

**Validation:**
```bash
curl -fsS https://app.contoso.com/health
# Should return 200 within 30s of rollback completion
```

### 4.2 Database rollback (Aurora)

**Symptom:** Schema migration broke an application; replication lag growing without bound; data corruption.

**This is the highest-risk rollback. Wake the DBA on-call before proceeding.**

**Schema rollback (only if migration was applied within the last 24 hours):**
```bash
# 1. Confirm we have a backup snapshot from before the migration
aws rds describe-db-cluster-snapshots \
  --db-cluster-identifier contoso-production \
  --snapshot-type automated \
  --query 'DBClusterSnapshots[?SnapshotCreateTime>`2026-05-04`]'

# 2. Restore to a NEW cluster (do not overwrite the production cluster)
aws rds restore-db-cluster-from-snapshot \
  --db-cluster-identifier contoso-production-rollback \
  --snapshot-identifier <snapshot-id> \
  --engine aurora-postgresql

# 3. Wait for the rollback cluster to come up
aws rds wait db-cluster-available --db-cluster-identifier contoso-production-rollback

# 4. Validate data
psql -h contoso-production-rollback.cluster-... \
  -U contoso_admin -d contoso \
  -c "SELECT COUNT(*) FROM transactions WHERE created_at > NOW() - INTERVAL '1 day';"

# 5. Switch traffic by updating Secrets Manager + restarting ECS service
# (DBA + Architecture Lead approval required)
```

**Replica catch-up:** Aurora replicas are continuous; if replication lag is the symptom, the resolution is usually to scale up the primary or kill long-running queries on the read replica.

### 4.3 IaC rollback (Terraform)

**Symptom:** A `terraform apply` resulted in unintended resource changes or destruction.

**Stop immediately. Do not run another apply until rollback is decided.**

```bash
# 1. View the most recent state changes
cd infra
terraform state list | head -30

# 2. Identify the change to roll back
git log --oneline -10 main.tf modules/

# 3. Revert the offending commit
git revert <commit-sha>
git push

# 4. Apply the reverted state
terraform plan -var-file=production.tfvars
# READ THE PLAN. Confirm it's reversing the unintended change.
terraform apply -var-file=production.tfvars
```

**If the resource is destroyed and Terraform cannot recreate it identically** (e.g., RDS with deletion protection bypassed), restore from the most recent snapshot per section 4.2.

### 4.4 Full migration rollback (cutover failure)

**Symptom:** Within 14 days of cutover, AWS environment cannot serve production traffic.

**Decision authority:** VP Engineering + General Counsel + CTO. Document the decision in a postmortem before, not after, the rollback.

```bash
# 1. Reverse Route 53 weights — back to on-prem
aws route53 change-resource-record-sets --hosted-zone-id Z123 \
  --change-batch file://cutover/route53-onprem-100.json

# 2. Re-enable on-prem cron
ssh batch01.contoso.local "sudo crontab /home/ops/cron-backup-2026-05-04"

# 3. Re-point reporting teams back to on-prem connection strings
# Send communication to 5 teams with reverted endpoints

# 4. AWS environment remains live for forensic analysis
# Do NOT terraform destroy until the postmortem identifies the root cause
```

**After day 14:** Rollback requires a re-migration plan because on-prem is decommissioned. At that point, "rollback" is "build a different cloud environment." Avoid this.

---

## 5. Monitoring during cutover and steady state

### Cutover window (T+0 to T+2 hours)

Watch these in dedicated browser tabs:

1. **CloudWatch dashboard `contoso-prod`** — ALB request count, ECS task health, Aurora connections, error rates
2. **Route 53 health check** — `app.contoso.com` health status
3. **AWS Batch console** — first reconciliation job status
4. **CloudTrail Insights** — anomalous API call volume
5. **GuardDuty** — any new findings

**Trip-wires (call SEV during cutover if any of these fire):**
- Web app 5xx rate > 1% for 5 minutes
- Aurora connection count > 80% of max
- ALB target health < 100% for 5 minutes
- CloudWatch alarm `contoso-prod-error-rate` triggers

### Steady state (post-cutover)

| SLO | Target | Alert |
|---|---|---|
| Web app availability | 99.95% monthly | PagerDuty SEV3 if < 99.9% over 1 hour |
| Web app p95 latency | < 250ms | PagerDuty SEV3 if > 500ms for 10 min |
| Aurora replication lag | < 100ms | PagerDuty SEV3 if > 1s for 5 min |
| Reconciliation completion | by 06:00 UTC daily | PagerDuty SEV2 if not complete by 07:00 UTC |
| Health check uptime | 99.99% | PagerDuty SEV2 if down for 2+ minutes |

---

## 6. Incident response

### 6.1 Severity matrix

| Severity | Definition | Response time | Who's on the call |
|---|---|---|---|
| **SEV1** | Complete outage; confirmed data exposure; payment processing down | < 15 min | SRE on-call, Eng on-call, Incident Commander, CTO, GC, Compliance |
| **SEV2** | Major degradation; suspected security event; one workload down | < 30 min | SRE on-call, Eng on-call, Incident Commander |
| **SEV3** | Partial degradation; SLO breach without outage | < 1 hour during business; next morning otherwise | SRE on-call |
| **SEV4** | Minor; no user impact | Best effort | Logged only |

### 6.2 First responder steps (any severity)

1. **Acknowledge the page** (PagerDuty: ack within 5 minutes).
2. **Open `#incident-XXXX` channel** in Slack. Update channel topic with status.
3. **Assess scope** — section 6.3 below.
4. **Decide severity** — section 6.1.
5. **Page additional responders** if SEV2 or higher.
6. **Communicate externally** if user-facing (status page) — within 15 min for SEV1, 30 min for SEV2.
7. **Document everything** in the channel; the channel becomes the postmortem timeline.

### 6.3 Triage decision tree

```
Is the health endpoint returning 200?
├── No  → Web app is down. Check ECS task status, ALB target health.
│         If tasks are unhealthy: rollback (section 4.1).
│         If ALB target health is failing: check security groups, networking.
│
└── Yes → Is application returning correct data?
          ├── No  → Check Aurora connection from web app. Check Aurora primary status.
          │         If Aurora is degraded: see section 6.4.
          │
          └── Yes → Is latency elevated?
                    ├── Yes → Check ECS CPU/memory. Check Aurora connection count.
                    │         If both healthy: check downstream (S3, ElastiCache).
                    │
                    └── No  → SEV4 false alarm OR alert configuration issue.
                              Validate alert thresholds; close incident.
```

### 6.4 Common failure modes — playbooks

**Aurora connection storm:**
- Symptom: web app errors with "too many connections"; Aurora connection count > 90% max.
- Root cause: usually a connection pool misconfiguration or a runaway query.
- Action: identify the offending session: `SELECT pid, query, state FROM pg_stat_activity ORDER BY query_start;`
- Mitigation: kill the long-running query; restart the offending ECS task; consider scaling Aurora ACU range.

**S3 access denied:**
- Symptom: web app 500s on `/reports`; logs show `AccessDenied` from boto3.
- Root cause: usually a recent IAM policy change.
- Action: verify ECS task role has `s3:GetObject`, `s3:PutObject`, `s3:ListBucket` on the report bucket.
- Validation: `aws s3 ls s3://contoso-reports-prod/ --profile <task-role-assumed>`

**Reconciliation job failing:**
- Symptom: AWS Batch job state is `FAILED`; CloudWatch logs show error.
- Root cause: most commonly Aurora connection failure, S3 access, or a data integrity check.
- Action: check the duplicate transaction ID detection in `reconcile.py`. If it's a data issue, escalate to DBA.
- Mitigation: AWS Batch retries automatically up to 3 times. After 3 failures, manual intervention required.

**Secret rotation broke the app:**
- Symptom: web app errors after a Secrets Manager rotation event.
- Root cause: app didn't re-read the secret after rotation.
- Action: redeploy the ECS service to pick up the new secret value.
- Long-term: app should use Secrets Manager SDK with automatic refresh, not bake-in at startup.

### 6.5 Postmortem requirements

Every SEV1 and SEV2 requires a written postmortem within 5 business days. Template lives in `runbooks/templates/postmortem.md` (to be created).

Postmortems are blameless. The goal is the system, not the person.

---

## 7. Backup and restore

| What | Mechanism | Retention | Restore procedure |
|---|---|---|---|
| Aurora database | Automated daily backup | 35 days | Section 4.2 |
| Aurora point-in-time | Continuous (5 min RPO) | 35 days | `aws rds restore-db-cluster-to-point-in-time` |
| S3 reports | Versioning + Object Lock | 7 years | `aws s3api list-object-versions` then `get-object` with version-id |
| CloudTrail audit logs | Object Lock | 7 years | Athena query (read-only; logs cannot be modified) |
| ECS task definitions | Terraform state + Git | Forever | `terraform apply` with the previous commit checked out |

**Test the restore process every quarter.** A backup that hasn't been restored is a hope, not a backup.

---

## 8. Contact escalation tree

```
[Page 1] PagerDuty Contoso-SRE
   ↓ (15 min no ack)
[Page 2] PagerDuty Contoso-Eng
   ↓ (15 min no ack)
[Page 3] SRE Lead direct phone
   ↓ (15 min no ack)
[Page 4] CTO direct phone
```

For SEV1: skip the wait — page 1 and 4 simultaneously.

For security incidents: include CISO direct phone in the parallel page.

---

## 9. What good looks like

- The cutover happened during the scheduled window without invoking rollback.
- No SEV1 or SEV2 incidents in the first 30 days post-cutover.
- All SLOs in section 5 met for 90 consecutive days.
- The first reconciliation job runs automatically every night without paging anyone.
- The on-call rotation rotates through the team without anyone refusing the page.

If we get all five, the migration is operationally sound. If we don't, there's a specific named gap to fix; address it before adding scope.

---

## 10. Stakeholder review — additions from Ops review

Sections 10.1–10.4 were added in response to a roundtable review by Priya Krishnan (SRE Lead). They close operational gaps identified before go-live sign-off.

### 10.1 Capacity sizing — the math behind the task counts

Discovery surfaced 800 req/min peak, 120 req/min average. The Terraform sets `desired_count = 2`. Here is the math:

| Variable | Value | Source |
|---|---|---|
| Peak RPS | 13.3 req/sec (800 / 60) | Discovery interview with SRE |
| Per-task safe RPS at p95 < 250ms | ~25 req/sec | FastAPI + uvicorn benchmark on 0.5 vCPU / 1 GB Fargate (validated locally; production benchmark scheduled for week 1 post-cutover) |
| Tasks needed at peak (no headroom) | 1 | 13.3 / 25 |
| Tasks needed with N-1 fault tolerance | 2 | One can fail and capacity holds |
| Tasks needed with 3x burst headroom | 3 | 800 × 3 / 60 / 25 = 1.6 → round up |

**Decision: `desired_count = 3`, not 2.** Updated in `infra/modules/ecs.tf`. The original 2 was correct for steady-state but did not absorb a deploy-time task drain (rolling deploy reduces capacity to 1 momentarily) plus a 3x spike scenario.

**Auto-scaling:**
- Target tracking on ECS service: 70% CPU utilization, scale to maximum 8 tasks
- Trigger: `aws_appautoscaling_policy` (Phase 2 — adding to IaC after baseline metrics collected)
- Cooldown: 60 seconds scale-out, 300 seconds scale-in (be cautious about scale-in during sustained load)

**Validation post-cutover:** Run a synthetic load test against staging at 3x peak (40 req/sec sustained for 10 minutes). Capture p95 latency, task CPU, ALB queue depth. Adjust `desired_count` and auto-scaling policy based on observed performance. Target: complete by end of week 2 post-cutover.

### 10.2 Aurora cold-start observability

Aurora Serverless v2 at min ACU = 0.5 has 1–2s cold-start latency on first request after long idle. This is a customer-visible event.

**Mitigation in production:** `min_capacity = 1.0` (not 0.5) in `infra/modules/rds.tf`. Trade-off: ~$80/mo additional baseline cost vs. eliminating the cold-start customer impact.

**Observability:**
- New CloudWatch metric: `Contoso/Aurora/ColdStartLatency` published by web app on first DB query after process start
- Alarm: `contoso-prod-aurora-cold-start` fires if cold-start latency > 1.5s, P95 over 5-minute window
- Dashboard: `contoso-prod` includes cold-start as a separate panel from normal latency

**P95 SLO interpretation:** Cold-start excluded from the customer-facing p95 SLO if it occurs < 0.1% of requests (engineering definition; customer-visible SLO measured at the ALB without exclusion).

### 10.3 Game-day schedule — practiced, not theoretical

A runbook is theatre until someone has executed it. Game-day cadence:

| Frequency | Scenario | Target time | Owner |
|---|---|---|---|
| Pre-cutover (T-21d) | Full rollback drill (Ops runbook 4.1, 4.2, 4.3, 4.4) in staging | 90 min total | SRE Lead + Eng |
| Pre-cutover (T-7d) | Cutover dress rehearsal in staging — every step from section 2.4 | 2 hours | All on-call |
| Month 1 | Web app rollback (4.1) | < 5 min | SRE on-call rotation |
| Month 2 | Aurora connection storm playbook (6.4) | < 15 min | DBA + SRE |
| Month 3 | Full Aurora rollback from snapshot (4.2) in staging | < 60 min | DBA |
| Month 4 | Backup restoration test (section 7) | < 90 min | DBA |
| Month 6 | Multi-failure scenario (web app + Aurora replica failure simultaneously) | Variable | All on-call |
| Quarterly thereafter | Rotating scenario from playbook library | Variable | SRE Lead |

**Recording:** Each game-day produces a one-page report — what worked, what didn't, what to update in the runbook. Reports archived in `runbooks/game-day-logs/`.

**Rotation:** Game-day participation rotates so every on-call engineer executes every major rollback at least once per year.

**Skipping a scheduled game-day requires explicit sign-off from VP Engineering with a documented reason. Skipping is a leading indicator of operational decay.**

### 10.4 Cutover communications — five reporting teams, one window

The migration requires 5 reporting teams to update their connection strings on cutover day. The communications artifact:

**T-30 days:** Initial notification email
- To: 5 reporting team leads + Tableau admin + PowerBI admin + Excel power-user community
- Content: cutover date, what changes (connection string + new credentials), training resources, FAQ
- Sender: VP Engineering + Compliance Officer

**T-14 days:** Technical instructions
- Per-team document: "How to update your Tableau workbooks for the new connection string" / "How to update PowerBI" / "How to update your custom Python scripts"
- Each team's IT lead validates instructions on a sandbox copy

**T-7 days:** Office hours (drop-in support)
- 1-hour sessions, two per day, with Engineering on standby
- Captures any question we hadn't anticipated; updates the per-team docs

**T-1 day:** Final reminder
- Cutover window time, on-call contact, escalation path
- Status page link

**T+0 (cutover):** Comms during cutover
- Slack channel `#cutover-2026-05` — engineering posts each major step
- Reporting teams confirm each one has cut over within their window (T+30 to T+60)

**T+1 day:** Post-cutover check-in
- Email survey to all 5 teams: did your reports run? Any failures? Any anomalies?
- Engineering responds to issues within 2 business hours

**T+7 days:** Closeout
- Retrospective with the 5 teams; lessons learned captured in `runbooks/post-cutover-retro.md`

**Templates and contact list:** `runbooks/templates/` (placeholder — to be populated with actual email drafts, FAQ, per-team instructions). Contact list maintained by Engineering Operations Manager (access-controlled to Engineering, Account Mgmt, Executive — not in public repo).

### 10.5 Time-zone coverage during cutover

Cutover window 02:00–04:00 UTC. Coverage map:

| Role | Engineer | Time zone | Local time at cutover start (02:00 UTC) | Awake? |
|---|---|---|---|---|
| Incident Commander | TBD | Eastern (US) | 21:00 prior day | Yes — primary on-call |
| Web app eng | Raymond | Eastern | 21:00 prior day | Yes — staying late |
| Database eng | Saurabh | Pacific | 18:00 prior day | Yes — earlier shift |
| Platform eng | Venkat | Central (US) | 20:00 prior day | Yes |
| SRE on-call | TBD | India | 07:30 (cutover day) | Yes — early start |
| Backup SRE | TBD | London | 02:00 (cutover day) | On standby; 1-hour response |

**No-single-time-zone rule:** No cutover may proceed with all responders in a single time zone. The redundancy is the point.

**Communication backup:** Slack + Zoom + PagerDuty + cell phone numbers (not Slack DM only). Multi-channel ensures one outage doesn't drop a responder.
