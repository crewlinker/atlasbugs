# Atlas Bug: CockroachDB TTL Storage Parameters Double-Escaped

Atlas (v1.1, including Pro) double-escapes interval/string-valued CockroachDB TTL
storage parameters during SQL generation, producing invalid SQL that CockroachDB rejects.

## The Bug

When a schema uses `ttl_expire_after = '24 hours'`, Atlas normalizes the interval
via the dev database to `'24:00:00':::INTERVAL`, then double-quotes it on output as
`'''24:00:00'':::INTERVAL'` — which CockroachDB cannot parse.

The same issue affects `ttl_expiration_expression` when its value contains intervals
(e.g. `'created_at + INTERVAL ''24 hours'''`).

Boolean storage parameters like `exclude_data_from_backup = true` work fine, confirming
the bug is specific to interval/string-valued TTL parameters.

## Reproduce

Prerequisites: [mise](https://mise.jdx.dev/) and Docker.

```bash
git clone git@github.com:crewlinker/atlasbugs.git
cd atlasbugs
mise run reproduce
```

## Workaround

Use a dedicated column with the interval in its `DEFAULT` and point
`ttl_expiration_expression` at just the column name (a plain identifier string):

```sql
CREATE TABLE "public"."events" (
  "id" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  "payload" JSONB NOT NULL,
  "created_at" TIMESTAMPTZ NOT NULL DEFAULT now(),
  "expires_at" TIMESTAMPTZ NOT NULL DEFAULT now() + INTERVAL '24 hours'
)
WITH (
  ttl_expiration_expression = 'expires_at',
  ttl_job_cron = '@hourly'
);
```

Atlas handles plain column names correctly since they don't contain intervals.
