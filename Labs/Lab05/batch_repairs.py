"""These functions run, but their decisions need repair. Read SCHEMA_CONTRACT.md."""

STATES = ('ready', 'complete', 'blocked', 'unresolved', 'failed')


def classify_member(context):
    # 1. A running attempt needs attention first, even if an older result exists:
    #    we cannot tell which output is current until that execution is resolved.
    active = context.get('active_attempt')
    if active:
        return {'state': 'unresolved',
                'reason': f"Attempt {active.get('attempt_id', '?')} is still recorded as running; "
                          'establish whether it stopped and reconcile it'}
    # 2. A verified output stays complete even if its inputs later moved or the
    #    budget is used up; the result no longer depends on those inputs.
    result = context.get('verified_result')
    if result:
        return {'state': 'complete',
                'reason': f"Verified output {result.get('artifact_id', '?')} (bytes, grid and request/attempt tags)"}
    # 3. Validation problems are scientific failures and need investigation.
    if context.get('validation_error'):
        return {'state': 'failed', 'reason': 'Input validation failed: ' + str(context['validation_error'])}
    # 4. Missing bytes block the member without consuming an attempt.
    missing = context.get('missing_inputs') or []
    if missing:
        return {'state': 'blocked',
                'reason': 'No available verified copy of input role(s): ' + ', '.join(sorted(missing))}
    # 5. The budget counts non-reused attempts across every batch invocation.
    used, limit = context.get('attempts_used', 0), context.get('max_attempts', 0)
    if used >= limit:
        return {'state': 'failed', 'reason': f'Attempt budget exhausted ({used} of {limit} used)'}
    # 6. An ordinary application failure is not retried blindly. A reconciled
    #    interruption (status 'interrupted') may use the next permitted attempt.
    last = context.get('last_attempt')
    if last and last.get('status') == 'failed':
        return {'state': 'failed',
                'reason': f"Previous application attempt failed ({last.get('error_code') or 'no error code'}); "
                          'investigate before retrying'}
    if last and last.get('status') == 'interrupted':
        return {'state': 'ready',
                'reason': f"Previous attempt was interrupted ({last.get('error_code') or 'stopped'}); "
                          f'retry permitted, {limit - used} attempt(s) left'}
    return {'state': 'ready', 'reason': f'Inputs verified; {limit - used} attempt(s) left in budget'}


def _positive_int(value):
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def verify_result(member, evidence):
    if not isinstance(evidence, dict) or not member.get('request_id'):
        return False
    if evidence.get('request_id') != member['request_id']:
        return False
    for key in ('attempt_id', 'artifact_id'):
        value = evidence.get(key)
        if not isinstance(value, str) or not value.strip():
            return False
    size, actual_size = evidence.get('size_bytes'), evidence.get('actual_size_bytes')
    if not _positive_int(size) or actual_size != size:
        return False
    digest, actual_digest = evidence.get('sha256'), evidence.get('actual_sha256')
    if not isinstance(digest, str) or len(digest) != 64 or not isinstance(actual_digest, str):
        return False
    if digest.lower() != actual_digest.lower():
        return False
    # Flags must be explicitly True; a missing flag never passes.
    return all(evidence.get(flag) is True for flag in
               ('catalogue_link_verified', 'grid_verified', 'provenance_verified'))


def summarize_batch(rows):
    # Keep only the newest observation per member; duplicated join rows collapse.
    latest = {}
    for row in rows:
        member = row['member_id']
        oid = row['observation_id'] if row['observation_id'] is not None else -1
        state = row['state'] if oid != -1 else None
        if member not in latest or oid > latest[member][0]:
            latest[member] = (oid, state)
    counts = {s: 0 for s in (*STATES, 'unobserved')}
    members = {s: [] for s in counts}
    for member, (_, state) in latest.items():
        label = state if state in STATES else 'unobserved'
        counts[label] += 1
        members[label].append(member)
    for label in members:
        members[label].sort()
    return {'expected': len(latest), 'counts': counts, 'members': members}
