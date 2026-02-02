# RAG PostgreSQL Connection Details (for Ingestion)

This document summarizes the **Mobius RAG** PostgreSQL database details so the MOBIUS-DBT ingestion job (or BigQuery Data Transfer / Datastream) can connect and read `rag_published_embeddings`. Source: **Mobius RAG** repo (`Mobius RAG/`).

---

## Summary

| Item | Value |
|------|--------|
| **Project (GCP)** | `mobiusos-new` |
| **Cloud SQL instance** | `mobius-platform-db` |
| **Region** | `us-central1` |
| **Database name** | `mobius_rag` |
| **Table to read** | `rag_published_embeddings` |
| **User** | `postgres` |
| **Port** | `5432` (standard PostgreSQL) |
| **Connection name** | `mobiusos-new:us-central1:mobius-platform-db` |

---

## Values to use in the form

Use these **exact values** when filling a connection form (BigQuery Data Transfer, Datastream, or any PostgreSQL source):

| Form field | Value to enter |
|------------|----------------|
| **Host** (or **Server** / **IP**) | Private IP of Cloud SQL (see below), or `localhost` if using Auth Proxy on the same machine. Get private IP: `gcloud sql instances describe mobius-platform-db --format='value(ipAddresses[0].ipAddress)' --project=mobiusos-new` |
| **Port** | `5432` |
| **Database** (or **Database name**) | `mobius_rag` |
| **Username** (or **User**) | `postgres` |
| **Password** | The postgres user password you set on Cloud SQL (not in repo; use your chosen value or Secret Manager). |
| **Schema** (if asked) | `public` (PostgreSQL default; table is in `public.rag_published_embeddings`). |
| **Table** (if asked for source table) | `rag_published_embeddings` |

**If the form asks for “Cloud SQL instance” instead of Host:**

| Form field | Value to enter |
|------------|----------------|
| **GCP Project** | `mobiusos-new` |
| **Region** | `us-central1` |
| **Cloud SQL instance** (or **Connection name**) | `mobius-platform-db` or full `mobiusos-new:us-central1:mobius-platform-db` |
| **Database** | `mobius_rag` |
| **Username** | `postgres` |
| **Password** | Your Cloud SQL postgres password |

**BigQuery destination (for Transfer / landing):**

| Form field | Value to enter |
|------------|----------------|
| **Project** | `mobiusos-new` |
| **Dataset** | `landing_rag` |
| **Table** | `rag_published_embeddings` |

---

## Connection strings

### Local / dev (RAG app default)

- **Format:** `postgresql://postgres:postgres@localhost:5432/mobius_rag`
- **When:** RAG runs against local PostgreSQL or Cloud SQL Auth Proxy on `localhost:5432`.

### Cloud SQL — private IP (VM / same VPC)

- **Format:** `postgresql://postgres:PASSWORD@PRIVATE_IP:5432/mobius_rag`
- **Get private IP:**  
  `gcloud sql instances describe mobius-platform-db --format='value(ipAddresses[0].ipAddress)' --project=mobiusos-new`
- **When:** Ingestion runs in the same GCP project/VPC (e.g. VM, Cloud Run with VPC connector, Composer in same VPC). Replace `PASSWORD` with the postgres user password.

### Cloud SQL — Auth Proxy (local or no private IP)

- **Start proxy:**  
  `./cloud-sql-proxy mobiusos-new:us-central1:mobius-platform-db --port 5433`
- **Format:** `postgresql://postgres:PASSWORD@127.0.0.1:5433/mobius_rag`
- **When:** Running ingestion from your laptop or a host that uses the proxy to reach Cloud SQL.

### Cloud SQL — Cloud Run (Unix socket)

- **Format:** `postgresql://postgres:PASSWORD@/mobius_rag?host=/cloudsql/mobiusos-new:us-central1:mobius-platform-db`
- **When:** Service runs on Cloud Run with Cloud SQL connection; connector provides the socket.

---

## Password

- The **postgres** user password is set on the Cloud SQL instance. RAG does not store it in the repo.
- **Set or reset password:**  
  `gcloud sql users set-password postgres --instance=mobius-platform-db --password=YOUR_PASSWORD --project=mobiusos-new`
- For ingestion, use the same password (or a dedicated read-only user if you create one). Store it in Secret Manager or env (e.g. `DATABASE_PASSWORD`) and do not commit it.

---

## Table: `rag_published_embeddings`

- **Schema:** Mobius RAG repo `docs/CONTRACT_DBT_RAG.md`, **Section 3** (authoritative).
- **Primary key:** `id` (UUID).
- **Special column:** `embedding` is **pgvector(1536)**. For BigQuery landing, map to **ARRAY<FLOAT64>** (1536 elements). In Python with `psycopg2`/asyncpg, typically convert with `list(embedding)` or the driver’s vector-to-list API.
- **Grain:** One row per published chunk/fact embedding. Full replace per `document_id` on each Publish/Republish in RAG.

---

## References (in Mobius RAG repo)

| Doc / file | Content |
|------------|--------|
| `docs/CONTRACT_DBT_RAG.md` | Contract table schema (Section 3), publish semantics, change handling. |
| `docs/GCP_DEPLOYMENT.md` | Cloud SQL instance creation, databases, postgres user, private IP, Auth Proxy. |
| `docs/MIGRATE_TO_GCP.md` | `DATABASE_URL` examples for local vs Cloud SQL. |
| `.env.example` | Example `DATABASE_URL=postgresql+asyncpg://postgres:postgres@localhost:5432/mobius_rag`. |
| `deploy/deploy_cloudrun.sh` | Cloud SQL connection name, `DATABASE_URL` for Cloud Run (Unix socket). |
| `app/config.py` | Reads `DATABASE_URL` from env; dev default `localhost:5432/mobius_rag`. |

---

## For BigQuery Data Transfer Service / Datastream

- **Host:** Use the Cloud SQL **public IP** (if enabled) or **Private IP** from the same VPC. For Datastream/Transfer Service, create a connection profile pointing at:
  - **Instance:** `mobius-platform-db` (project `mobiusos-new`, region `us-central1`), or
  - **Host:port:** `<private-ip>:5432` and database `mobius_rag`, user `postgres`.
- **pgvector:** If the connector does not support the `vector` type, use a **custom ETL** (e.g. Python script or Dataflow) that reads from Postgres and writes to BigQuery, converting `embedding` to ARRAY<FLOAT64> explicitly.

---

## Troubleshooting: "The connection attempt failed" (BigQuery Data Transfer)

If the transfer log shows **"Error in executing PrepareQuery request for table rag_published_embeddings | Cause: The connection attempt failed"**, the BigQuery Data Transfer Service cannot reach your PostgreSQL (Cloud SQL). Fix by network and/or credentials.

### 1. Use Cloud SQL **public IP** and **authorized networks**

BigQuery Data Transfer runs in Google’s infrastructure. It can reach Cloud SQL only if:

- The instance has **public IP** enabled, and  
- The **authorized networks** for the instance include the IPs the connector uses.

**Steps:**

1. **Enable public IP** (if it’s off):  
   Cloud Console → **SQL** → select `mobius-platform-db` → **Connections** → enable **Public IP**.
2. **Add an authorized network** so the connector can connect:
   - In the same **Connections** tab, under **Authorized networks**, click **Add network**.
   - For a quick test you can use **Name** `bq-transfer-test`, **Network** `0.0.0.0/0` (allows any IP; use only for testing).
   - For production, try restricting to Google’s egress ranges if documented, or use VPC peering (see below).
3. **Use the instance’s public IP in the transfer config**:  
   In the BigQuery Data Transfer PostgreSQL source, set **Host** to the **Public IP address** of `mobius-platform-db` (shown on the instance’s **Overview** in Cloud Console).  
   **Port** `5432`, **Database** `mobius_rag`, **User** `postgres`, **Password** = your Cloud SQL postgres password.

### 2. Check credentials

- **Password:** Must match the `postgres` user on Cloud SQL. Reset if needed:  
  `gcloud sql users set-password postgres --instance=mobius-platform-db --password=YOUR_PASSWORD --project=mobiusos-new`
- In the transfer config, re-enter **Username** `postgres` and the **Password** (no typos, no extra spaces).

### 3. If Cloud SQL has **private IP only** (no public IP)

BigQuery Data Transfer cannot reach a private IP unless you use **VPC peering** between the BigQuery Data Transfer connector project and the project/VPC where Cloud SQL lives, plus a **network attachment** in the connector project.  
Details: [Configure Cloud SQL instance access (BigQuery)](https://cloud.google.com/bigquery/docs/cloud-sql-instance-access).

**Simpler option:** Run a **custom ingestion job** (e.g. Python on Cloud Run, Composer, or a VM) in the **same VPC** as Cloud SQL, so it can use the **private IP** to read from `rag_published_embeddings` and load into BigQuery `landing_rag.rag_published_embeddings`. That avoids opening public IP or setting up peering for the transfer service.

### 4. "Server's certificate is not trusted" (SSL / PKIX path building failed)

If the transfer log shows **"SSL connection failed: Server's certificate is not trusted"** or **"PKIX path building failed"**, the connector is using TLS and does not trust Cloud SQL's server certificate.

**Option A – Disable SSL verification (quickest):**  
In the BigQuery Data Transfer config for the PostgreSQL source, look for **SSL/TLS** or **Encryption**:
- Set to **"Do not use SSL"**, **"Allow unencrypted"**, or **"No verification"** if available.  
Then run the transfer again. (Traffic is still on the network; for stricter security use Option B.)

**Option B – Provide the CA certificate:**  
1. In Cloud Console go to **SQL** → **mobius-platform-db** → **Connections**.  
2. Under **SSL**, use **"Download server CA certificate"** (or the instance’s CA cert from [Manage SSL/TLS certificates](https://cloud.google.com/sql/docs/postgres/manage-ssl-instance)).  
3. In the transfer config, find **CA certificate** / **SSL root certificate** and paste the **entire PEM content** (including `-----BEGIN CERTIFICATE-----` and `-----END CERTIFICATE-----`).  
4. Keep SSL/TLS set to **"Encrypt and verify CA"** (or equivalent) and run the transfer again.

---

### 5. If connection is OK but transfer still fails: **pgvector**

The table `rag_published_embeddings` has an **`embedding`** column of type **pgvector(1536)**. The BigQuery Data Transfer Service PostgreSQL connector **does not support** the `vector` type. It may report "The connection attempt failed" or "Error in executing PrepareQuery" when it actually connected but failed on schema discovery or a test query.

**Fix:** Use a **custom ETL** that reads from PostgreSQL (e.g. with `psycopg2` or `asyncpg`), converts `embedding` to a Python list of floats, and loads into BigQuery `landing_rag.rag_published_embeddings` (column type `ARRAY<FLOAT64>`). Run this on a schedule (Cloud Run, Composer, or Cloud Scheduler + script) instead of the built-in PostgreSQL transfer.
