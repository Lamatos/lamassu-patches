#!/usr/bin/env bash
set -euo pipefail

TS="$(date +%Y%m%d_%H%M%S)"
OUT="/tmp/cash_out_timings_eth_${TS}.csv"

cd /tmp

if [ "$(whoami)" = "postgres" ]; then
  PSQL_CMD="psql -d lamassu"
else
  PSQL_CMD="sudo -u postgres psql -d lamassu"
fi

$PSQL_CMD <<SQL
COPY (
  SELECT
    t.id AS tx_id,
    t.crypto_code AS coin,
    provision_address.created AS provision_address_time,
    published.created AS published_time,
    confirmed.created AS confirmed_time,
    dispense.created AS dispense_time,
    published.created - provision_address.created AS provision_to_published,
    confirmed.created - provision_address.created AS provision_to_confirmed,
    dispense.created - provision_address.created AS provision_to_dispense
  FROM cash_out_txs t
  JOIN cash_out_actions provision_address
    ON t.id = provision_address.tx_id
   AND provision_address.action = 'provisionAddress'
  JOIN cash_out_actions published
    ON t.id = published.tx_id
   AND published.action = 'published'
  JOIN cash_out_actions confirmed
    ON t.id = confirmed.tx_id
   AND confirmed.action = 'confirmed'
  JOIN cash_out_actions dispense
    ON t.id = dispense.tx_id
   AND dispense.action = 'dispense'
  WHERE t.crypto_code = 'ETH'
  ORDER BY t.created DESC
) TO '$OUT' WITH CSV HEADER;
SQL

echo "✅ Done. CSV saved to: $OUT"
ls -lh "$OUT"
