-- Keep the question, parameters, expected columns, empty-result interpretation and next check.
-- 1. Which expected members have never reached an application attempt?
-- Parameters: :batch_id
-- Columns: member_id, planned_request_id, request_id
SELECT m.member_id, m.planned_request_id, m.request_id
FROM batch_members m
WHERE m.batch_id = :batch_id
  AND NOT EXISTS (SELECT 1 FROM processing_attempts a
                  WHERE a.request_id = m.planned_request_id AND a.status <> 'reused')
ORDER BY m.member_id;
-- Empty result: every member had at least one real attempt (not necessarily a success).
-- Next check: latest observation of each listed member (blocked vs ready) and its input location checks.


-- 2. Which request failed or stopped and later produced a verified result?
-- Parameters: none
-- Columns: request_id, problem_attempt, problem_status, error_code, problem_started,
--          producing_attempt, produced_started, output_artifact
SELECT bad.request_id,
       bad.attempt_id  AS problem_attempt, bad.status AS problem_status,
       bad.error_code, bad.started_at AS problem_started,
       good.attempt_id AS producing_attempt, good.started_at AS produced_started,
       o.artifact_id   AS output_artifact
FROM processing_attempts bad
JOIN processing_attempts good
  ON good.request_id = bad.request_id AND good.status = 'succeeded'
 AND good.started_at > bad.started_at
JOIN processing_outputs o ON o.attempt_id = good.attempt_id AND o.role = 'ndvi'
WHERE bad.status IN ('failed', 'interrupted')
  AND EXISTS (SELECT 1 FROM batch_observations bo
              WHERE bo.attempt_id = good.attempt_id AND bo.state = 'complete')
ORDER BY bad.started_at;
-- Empty result: no request recovered after a failure; either a clean run or a failure never retried.
-- Next check: failed/interrupted attempts with no later success, and the remaining attempt budget.


-- 3. Which succeeded products have no location recorded as available?
-- Explain why this does not establish present filesystem state.
-- Parameters: none
-- Columns: request_id, attempt_id, artifact_id, recorded_statuses, last_checked_at
SELECT a.request_id, a.attempt_id, o.artifact_id,
       (SELECT group_concat(l.status) FROM processing_artifact_locations l
         WHERE l.artifact_id = o.artifact_id) AS recorded_statuses,
       (SELECT MAX(l.checked_at) FROM processing_artifact_locations l
         WHERE l.artifact_id = o.artifact_id) AS last_checked_at
FROM processing_attempts a
JOIN processing_outputs o ON o.attempt_id = a.attempt_id AND o.role = 'ndvi'
WHERE a.status = 'succeeded'
  AND NOT EXISTS (SELECT 1 FROM processing_artifact_locations l
                  WHERE l.artifact_id = o.artifact_id AND l.status = 'available')
ORDER BY a.started_at;
-- Status is only what the last check wrote at checked_at; files may have changed since.
-- Empty result: every succeeded product had an available copy at its last check.
-- Next check: run lab05_cli.py refresh, then rerun this query.


-- 4. Which members rely on old observations?
-- :before and :batch_id; explain the timestamps used.
-- Parameters: :batch_id, :before (ISO-8601 UTC, e.g. '2026-11-09T09:00:00Z')
-- Columns: member_id, state, observed_at, reason
-- Timestamps: observed_at of the newest observation (when the coordinator checked the member),
-- not attempt or report times. Members with no observation are included.
WITH latest AS (
  SELECT m.member_id, MAX(o.observation_id) AS observation_id
  FROM batch_members m
  LEFT JOIN batch_observations o ON o.batch_id = m.batch_id AND o.member_id = m.member_id
  WHERE m.batch_id = :batch_id
  GROUP BY m.member_id)
SELECT l.member_id, o.state, o.observed_at, o.reason
FROM latest l
LEFT JOIN batch_observations o ON o.observation_id = l.observation_id
WHERE o.observation_id IS NULL OR o.observed_at < :before
ORDER BY o.observed_at, l.member_id;
-- Empty result: every member was observed at or after :before.
-- Next check: refresh the listed members before relying on their state.


-- Case A diagnosis: which input role and location blocked the member?
-- Parameters: none
-- Columns: artifact_id, role, status, local_path, checked_at
SELECT a.artifact_id, json_extract(a.lineage_json, '$.asset_key') AS role,
       l.status, l.local_path, l.checked_at
FROM processing_artifacts a
JOIN processing_artifact_locations l USING (artifact_id)
WHERE a.source_artifact_id IS NOT NULL AND l.status <> 'available';
-- Empty result: every input copy was available at its last check.
-- Next check: locate the file and compare its SHA256 with the catalogue before restoring.
