# Atlas Bug: CockroachDB TTL Storage Parameters Double-Escaped

Atlas `v1.1.0` mis-renders CockroachDB TTL storage parameters whose values are
intervals or SQL expressions. The resulting SQL is invalid, even though the
original SQL is accepted by CockroachDB directly.

This affects both:

- `ttl_expire_after`
- `ttl_expiration_expression` when the expression contains nested quotes, such as
  `INTERVAL '24 hours'`

It does not affect simple scalar storage parameters such as booleans.

## Conclusion

This is a high-confidence Atlas bug, not a CockroachDB parser bug.

The important distinction is:

1. CockroachDB accepts the original DDL directly.
2. Atlas normalizes the value through the dev database.
3. Atlas re-emits the normalized value as a doubly-quoted string.
4. CockroachDB correctly rejects the malformed SQL Atlas produced.

For example, Atlas takes a valid declaration like:

```sql
WITH (ttl_expire_after = '24 hours')
```

and emits:

```sql
WITH (ttl_expire_after = '''24:00:00'':::INTERVAL')
```

CockroachDB then rejects that with:

```text
pq: value of "ttl_expire_after" must be an interval: could not parse "'24:00:00':::INTERVAL" as type interval
```

## Environment

- Atlas: `v1.1.0`
- CockroachDB: `v26.1.1`
- Atlas driver: `crdb://`
- Atlas config: SQL schema source plus separate dev database for normalization

`atlas.hcl`:

```hcl
env "local" {
  src = "file://schema"
  url = getenv("DATABASE_URL")
  dev = getenv("DEV_URL")
}
```

`mise.toml`:

```toml
[tools]
atlas = "latest"

[env]
DATABASE_URL = "crdb://root@localhost:26260/atlasbugs?sslmode=disable"
DEV_URL = "crdb://root@localhost:26260/atlas_dev?sslmode=disable"
```

## Reproduce

Prerequisites: [mise](https://mise.jdx.dev/) and Docker.

```bash
git clone git@github.com:crewlinker/atlasbugs.git
cd atlasbugs
mise trust
mise run reproduce
```

The repro schema is intentionally minimal:

```sql
CREATE TABLE "public"."events" (
  "id" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  "payload" JSONB NOT NULL,
  "created_at" TIMESTAMPTZ NOT NULL DEFAULT now()
)
WITH (
  ttl_expire_after = '24 hours'
);
```

Atlas plans:

```sql
CREATE TABLE "public"."events" (
  "id" uuid NOT NULL DEFAULT gen_random_uuid(),
  "payload" jsonb NOT NULL,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "crdb_internal_expiration" timestamptz NOT NULL DEFAULT current_timestamp() + '24:00:00',
  PRIMARY KEY ("id")
) WITH (ttl = 'on', ttl_expire_after = '''24:00:00'':::INTERVAL', schema_locked = 'true');
```

That SQL is invalid because the interval literal has been turned into a string
containing the text of an interval cast, instead of an interval value.

## What CockroachDB Does Directly

CockroachDB accepts all of the following forms directly:

```sql
WITH (ttl_expire_after = '24 hours')
WITH (ttl_expire_after = '24:00:00':::INTERVAL)
WITH (ttl_expire_after = INTERVAL '24 hours')
WITH (ttl_expire_after = CAST('24 hours' AS INTERVAL))
WITH (ttl_expiration_expression = 'created_at + INTERVAL ''24 hours''')
WITH (ttl_expiration_expression = $$ ( created_at + INTERVAL '24 hours' ) $$)
```

CockroachDB then normalizes them in `SHOW CREATE TABLE` output, for example:

```sql
) WITH (ttl = 'on', ttl_expire_after = '24:00:00':::INTERVAL, schema_locked = true);
```

and:

```sql
) WITH (ttl = 'on', ttl_expiration_expression = e'created_at + INTERVAL \'24 hours\'', schema_locked = true);
```

Those normalized forms are valid CockroachDB SQL.

## Investigation Matrix

The table below summarizes what was tested.

| Case | Example input | Direct CockroachDB | Atlas declarative apply | Notes |
| --- | --- | --- | --- | --- |
| `ttl_expire_after` plain string | `ttl_expire_after = '24 hours'` | Works | Fails | Atlas emits `'''24:00:00'':::INTERVAL'` |
| `ttl_expire_after` normalized interval | `ttl_expire_after = '24:00:00':::INTERVAL` | Works | Fails | Same broken Atlas output |
| `ttl_expire_after` interval keyword | `ttl_expire_after = INTERVAL '24 hours'` | Works | Fails | Same broken Atlas output |
| `ttl_expire_after` cast | `ttl_expire_after = CAST('24 hours' AS INTERVAL)` | Works | Fails | Same broken Atlas output |
| `ttl_expiration_expression` quoted interval expression | `ttl_expiration_expression = 'created_at + INTERVAL ''24 hours'''` | Works | Fails | Atlas emits a quoted `e'...'` string |
| `ttl_expiration_expression` dollar-quoted expression | `ttl_expiration_expression = $$ ( created_at + INTERVAL '24 hours' ) $$` | Works | Fails | Same failure after normalization |
| `ttl_expiration_expression` column reference | `ttl_expiration_expression = 'expires_at'` | Works | Works | Best declarative workaround |
| `ttl_expiration_expression` quote-free expression | `ttl_expiration_expression = 'to_timestamp(extract(epoch from created_at) + 86400)'` | Works | Works | Works because there are no nested quotes |

## Atlas Inspect Output Is Not Round-Trippable

Another strong signal that this is an Atlas bug is that Atlas's own inspected
schema is not always re-applicable.

For a table created directly in CockroachDB with `ttl_expire_after`,
`atlas schema inspect` produced storage params like:

```hcl
storage_params {
  ttl              = "'on'"
  ttl_expire_after = "'24:00:00':::INTERVAL"
  schema_locked    = true
}
```

Re-applying that HCL fails with the same interval parse error.

For a table created directly with a quoted expression, `atlas schema inspect`
produced:

```hcl
storage_params {
  ttl                       = "'on'"
  ttl_expiration_expression = "e'created_at + INTERVAL \\'24 hours\\''"
  schema_locked             = true
}
```

Re-applying that also fails.

So this is not just a bug in hand-authored SQL input. Atlas does not round-trip
its own inspected representation for these values.

## Attempts That Did Not Work

These approaches were tested and did not help:

- Using different valid SQL spellings for `ttl_expire_after`
- Using a normalized Cockroach interval literal directly
- Using `INTERVAL '24 hours'`
- Using `CAST('24 hours' AS INTERVAL)`
- Using dollar-quoted expressions for `ttl_expiration_expression`
- Re-applying Atlas's own `schema inspect` output

An HCL raw-expression escape hatch was also attempted:

```hcl
storage_params {
  ttl_expire_after = sql("'24:00:00':::INTERVAL")
}
```

Atlas rejected that form during spec conversion with:

```text
unexpected type cty.Type for attribute 'ttl_expire_after'
```

So `storage_params` does not currently accept `sql(...)` raw values as a user
workaround.

## Working Declarative Workarounds

### 1. Preferred: explicit expiration column

Use a dedicated `TIMESTAMPTZ` column whose default contains the interval logic,
then point `ttl_expiration_expression` at the column name.

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

This works because the storage parameter value is just the plain identifier
string `'expires_at'`, which Atlas round-trips correctly.

This is also close to CockroachDB's own recommended pattern, since
`ttl_expiration_expression` is generally preferable to `ttl_expire_after`.

### 2. Secondary: quote-free expressions

If an explicit expiration column is undesirable, Atlas can handle a
`ttl_expiration_expression` string so long as the string itself does not contain
nested quotes.

This worked and round-tripped successfully:

```sql
WITH (
  ttl_expiration_expression = 'to_timestamp(extract(epoch from created_at) + 86400)'
)
```

This is useful for fixed second-based durations, but is less attractive than the
explicit `expires_at` column and is not a good replacement for calendar-style
intervals like `3 months`.

### 3. Non-declarative fallback

If exact Cockroach TTL syntax must be preserved and a declarative workaround is
not acceptable, the remaining option is to manage these TTL clauses outside the
declarative Atlas schema workflow, for example in hand-written SQL migrations.

## Why This Is Cockroach-Specific in Practice

CockroachDB is wire-compatible with PostgreSQL, but this bug is not about the
wire protocol. It is about how Atlas round-trips Cockroach-specific TTL storage
parameters.

A comparison with PostgreSQL 16 showed that Atlas handles normal PostgreSQL
storage parameters such as:

- `fillfactor = 80`
- `autovacuum_enabled = false`
- `vacuum_index_cleanup = auto`

without issue.

That makes sense because normal PostgreSQL storage parameters are scalar values,
not SQL-ish strings such as:

- `'24:00:00':::INTERVAL`
- `e'created_at + INTERVAL \'24 hours\''`

The failure appears when Atlas treats a Cockroach-normalized SQL literal or
expression as an ordinary string and then quotes it again.

## What Atlas Likely Needs To Fix

At a high level, Atlas needs to treat these TTL storage parameters as raw SQL
expressions or typed values during round-trip, rather than as plain strings.

In practice that likely means at least one of:

- preserve interval/expression values without quoting them again during emit
- add proper raw-expression support for `storage_params`
- special-case CockroachDB TTL parameters so that normalized values like
  `'24:00:00':::INTERVAL` and `e'...'` survive inspection and re-apply intact

## Summary

This repository demonstrates that:

1. CockroachDB accepts the original TTL syntax directly.
2. Atlas normalizes or inspects the value into a string-like representation.
3. Atlas re-emits that representation as an ordinary quoted string.
4. CockroachDB then rejects the invalid SQL.

The most robust workaround today is:

```sql
expires_at TIMESTAMPTZ NOT NULL DEFAULT now() + INTERVAL '24 hours'
WITH (ttl_expiration_expression = 'expires_at')
```
