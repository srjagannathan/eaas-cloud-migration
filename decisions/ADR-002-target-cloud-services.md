# ADR-002: Target AWS Services Per Workload

**Date:** 2026-05-04 (revised)
**Status:** Accepted
**Deciders:** Cloud Architecture Team

---

## Context

Following ADR-001 (lift-and-shift pattern for Phase 1), we selected specific AWS services for each workload. Initial selection criteria were cut-over speed and operability. After a second pass with a 15-year horizon — accounting for AI/ML workload adoption, financial services regulatory trajectory, and the pace at which the cloud-native ecosystem is evolving — we revised three of our four service decisions. The lift-and-shift pattern for Phase 1 holds; the target architecture for Phase 2 onward changes significantly.

**Revised criteria (weighted for longevity):**

| Criterion | Weight | Rationale |
|---|---|---|
| Migration risk (Phase 1) | High | Still the forcing function for compliance gap closure |
| Ecosystem longevity | High | AWS-proprietary abstractions that have no portable equivalent become liabilities at contract renewal |
| AI/ML readiness | High | Every financial services workload will have AI inference requirements within 5 years |
| OLAP/OLTP separation | High | Conflating analytics and transactional queries on the same engine doesn't scale past moderate growth |
| Cost predictability | Medium | Important but not at the expense of architectural flexibility |
| Portability | Medium | Multi-cloud is not a goal, but vendor lock-in on non-commodity abstractions is a risk |

---

## Service Decisions

### Web App: EKS with Karpenter (not ECS Fargate)

| Option | Migration Risk | Ecosystem Longevity | AI/ML Ready | Portability | 15yr Score |
|---|---|---|---|---|---|
| **EKS + Karpenter** | 3 | 5 | 5 | 5 | **18** |
| ECS Fargate | 5 | 2 | 2 | 1 | 10 |
| EC2 Auto Scaling | 3 | 3 | 3 | 3 | 12 |
| App Runner | 5 | 2 | 1 | 1 | 9 |

**Decision: EKS with Karpenter.**

ECS Fargate was our original pick for its operational simplicity. We reversed that decision on the 15-year horizon for three reasons:

1. **Portability.** ECS has no equivalent on any other cloud or on-prem platform. Kubernetes runs identically on GKE, AKS, EKS, on-prem, and edge. When Contoso's cloud contract comes up for renegotiation in year 7, EKS workloads have options; ECS workloads do not.

2. **AI/ML scheduling.** Within five years, Contoso will need to run inference workloads alongside the web tier — fraud scoring, document processing, real-time anomaly detection. Kubernetes supports GPU node pools, Knative for serverless inference, and KEDA for event-driven autoscaling. ECS supports none of these natively.

3. **Karpenter eliminates the ops overhead argument.** The original objection to EKS was node management complexity. Karpenter provisions right-sized nodes (including Graviton3, which gives 40% better price-performance) just-in-time for actual pod requirements, and terminates them when idle. The operational burden objection no longer holds.

**Graviton3 by default.** All node pools use `arm64` Graviton3 instances. FastAPI + Python 3.11 is fully compatible. 30–40% cost reduction vs. equivalent x86, with higher throughput per dollar.

**Fargate profile retained** for burst-workload pods that don't need persistent node capacity — batch-adjacent jobs, CI runners, low-traffic periods.

---

### Transactional Database: Aurora PostgreSQL Global Database (not RDS Postgres)

| Option | Migration Risk | AI/ML Ready | DR Capability | 15yr Score |
|---|---|---|---|---|
| **Aurora PostgreSQL** | 3 | 5 | 5 | **13** |
| RDS Postgres multi-AZ | 4 | 2 | 2 | 8 |
| Aurora Serverless v2 | 3 | 5 | 4 | 12 |
| Self-managed on EC2 | 2 | 3 | 2 | 7 |

**Decision: Aurora PostgreSQL Serverless v2 with Global Database enabled from day one.**

RDS was our original pick for its simplicity and direct on-prem Postgres equivalence. We upgraded to Aurora for three reasons that compound over time:

1. **pgvector.** Aurora PostgreSQL supports the `pgvector` extension, enabling vector similarity search natively on the transactional database. Within five years, Contoso will want to run embedding-based fraud detection, customer similarity, and document retrieval against the same data. Aurora makes that possible without a separate vector database. RDS does not support pgvector at the same performance tier.

2. **Aurora Global Database.** Financial services companies operating across regions need RPO under one second for their primary database. Aurora Global Database replicates with sub-second lag to up to five read regions — enabling active-passive multi-region DR without a replica re-architecture. Enable it now at near-zero cost; activate a second region when the risk profile demands it.

3. **Serverless v2 ACU scaling.** Aurora Serverless v2 scales from 0.5 ACUs to 128 ACUs in fine-grained increments, within seconds. The web app + batch job combination produces spiky load patterns. RDS requires manual right-sizing and causes either over-provisioning (cost) or under-provisioning (incident). Serverless v2 removes the sizing decision entirely.

**Secrets Manager with auto-rotation** replaces SSM Parameter Store for DB credentials. At the scale and sensitivity of a financial services database, manual rotation windows are a compliance risk.

---

### Analytics / BI Workload: Redshift Serverless + S3 Data Lake (replaces read replica)

**This is the most significant architectural departure from the original plan.** Routing the BI team's 6-hour analytics queries to a Postgres read replica treats OLAP as a minor variant of OLTP. It is not.

**Decision: Redshift Serverless for the BI team. S3 data lake as the canonical analytics store.**

- Aurora CDC (Change Data Capture) → Amazon Kinesis Data Streams → S3 (raw) → AWS Glue ETL → Redshift Serverless
- BI team queries Redshift, not Postgres. Redshift Serverless costs zero when idle; the BI team's usage pattern (daily batch queries from five teams) is the textbook serverless use case.
- Athena for ad-hoc SQL directly on S3 — no warehouse needed for exploratory queries.
- This separation means the BI team's 6-hour queries can never degrade the transactional database, regardless of how large those queries grow.

The S3 data lake also becomes the foundation for all AI/ML work: SageMaker reads from S3, Bedrock fine-tuning jobs read from S3, reconciliation audit trails are queryable via Athena without touching the transactional database.

---

### Batch Reconciliation: AWS Batch (Phase 1) → Amazon MSK (Phase 2)

**Phase 1 decision holds: AWS Batch + EventBridge.** The nightly reconciliation job runs up to 45 minutes and requires job queuing, retry logic, and CloudWatch integration. Lambda is excluded by its 15-minute limit. AWS Batch is the right lift-and-shift target.

**Phase 2 target (within 18 months): Amazon MSK (Managed Kafka).** A nightly reconciliation job is an artifact of on-prem I/O constraints, not a sound financial services architecture. In the cloud, transactions become events the moment they are committed. The reconciliation logic belongs in a stream processor — reading from an MSK topic, writing to S3, updating Redshift in near real-time. This eliminates the 24-hour information delay that currently prevents intraday dashboards and real-time fraud detection.

The AWS Batch job we are building is explicitly designed to be decomposable: each logical step is a function, not a monolithic script. When the team moves to MSK, those functions become Lambda consumers or EKS-based Flink operators without a rewrite.

---

### Cache: ElastiCache Serverless Redis (not provisioned cluster)

**Decision:** ElastiCache Serverless — no cluster sizing, no node count decisions, scale-to-zero when not needed. The web app session cache has low baseline traffic with moderate peaks. Provisioned Redis clusters require sizing decisions that become wrong within 18 months. Serverless is the appropriate choice for unpredictable cache usage.

---

### Object Storage: S3 with Intelligent-Tiering (same decision, enhanced)

S3 versioned bucket with server-side encryption holds. Add S3 Intelligent-Tiering from day one: reconciliation reports older than 30 days move to Infrequent Access automatically. Over a 15-year archive, this reduces storage costs by 40–60% with no application changes.

---

### Added: AI Integration Layer

**Amazon Bedrock + Claude.** Financial services AI use cases that Contoso will encounter within the 15-year window include: transaction anomaly detection, document processing (reconciliation reports, audit trails), customer risk scoring, and regulatory change summarization. The architecture includes a Bedrock integration point from day one — even if the first use case is simply AI-assisted operations (DevOps Guru, Amazon Q for cost optimization). Bedrock APIs are invoked from EKS pods using IAM task roles — no API keys, no additional infrastructure.

---

### Added: Observability Platform — OpenTelemetry + Amazon Managed Grafana

**Decision: OpenTelemetry collector as a DaemonSet on EKS, exporting to Amazon Managed Prometheus and Amazon Managed Grafana.**

CloudWatch-only observability creates vendor lock-in at the observability layer. If Contoso adds a third-party APM tool in year 5 (DataDog, Honeycomb, New Relic), CloudWatch metrics and traces cannot be exported without a re-instrumentation effort. OpenTelemetry instruments once and exports to any backend. The Amazon Managed Grafana + Prometheus stack is the open-source standard managed by AWS — no operational overhead, no proprietary format.

---

## Full Target Architecture (Phase 2 onward)

```
Internet
  └─→ CloudFront (WAF, edge caching)
        └─→ ALB
              └─→ EKS / Karpenter (contoso-web, Graviton3)
                    ├─→ Aurora PostgreSQL Serverless v2 (writes + pgvector)
                    ├─→ ElastiCache Serverless Redis (sessions)
                    ├─→ S3 (report PDFs, pre-signed URLs, Intelligent-Tiering)
                    └─→ Amazon Bedrock (fraud/anomaly detection, doc intelligence)

Aurora CDC
  └─→ Kinesis Data Streams
        └─→ Lambda / Flink on EKS
              └─→ S3 Data Lake
                    ├─→ AWS Glue ETL → Redshift Serverless (BI team)
                    └─→ Athena (ad-hoc SQL)

EventBridge (Phase 1 only) → AWS Batch → reconcile.py
[Phase 2: replaced by MSK topic + stream processor]

Aurora Global Database
  └─→ Read region (us-west-2, active in Year 3)

Observability: OpenTelemetry → Amazon Managed Prometheus → Amazon Managed Grafana
Security: GuardDuty · Security Hub · Macie · Secrets Manager auto-rotation
```

**Phase 1 local stand-ins (docker-compose) unchanged:**
- MinIO → S3, Postgres 15 → Aurora, Redis 7 → ElastiCache Serverless

---

## IaC: Terraform + OpenTofu migration path

HashiCorp changed Terraform's license to BSL 1.1 in 2023. For a 15-year infrastructure commitment, the CNCF-governed OpenTofu fork (MIT license) is the safer long-term choice. Current Terraform modules are 100% compatible with OpenTofu; migration is a binary swap. We document this risk now and plan the switch at the next major provider version upgrade.

---

## Consequences

- EKS initial migration takes 1–2 weeks longer than ECS Fargate; this is accepted in exchange for a 15-year portable foundation
- Aurora Global Database adds ~15% cost vs. RDS multi-AZ; accepted given the RPO guarantee and pgvector capability
- Redshift Serverless requires a Glue ETL pipeline before the BI team can cut over; this is a 2–3 week pre-cutover deliverable
- All five reporting teams move to Redshift endpoints — larger change management effort than a read replica endpoint swap
- OpenTelemetry instrumentation adds ~1 week of engineering work; accepted as the correct investment for vendor-neutral observability
