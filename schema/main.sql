-- Bug: ttl_expire_after with an interval value gets double-escaped by Atlas.
-- Atlas normalizes '24 hours' to '24:00:00':::INTERVAL via the dev database,
-- then double-quotes it on output as '''24:00:00'':::INTERVAL', which CockroachDB rejects.
CREATE TABLE "public"."events" (
  "id" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  "payload" JSONB NOT NULL,
  "created_at" TIMESTAMPTZ NOT NULL DEFAULT now()
)
WITH
  (
    ttl_expire_after = '24 hours'
  );
