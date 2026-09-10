-- Run only on the dedicated simulator seeded by empty-library-quota-fixture.sql.
.bail on
BEGIN IMMEDIATE;
CREATE TEMP TABLE fixture_guard (count INTEGER CHECK(count = 100));
INSERT INTO fixture_guard SELECT COUNT(*) FROM records;
INSERT INTO fixture_guard SELECT COUNT(*) FROM records WHERE id LIKE 'F0620000-0000-4000-8000-%';
INSERT INTO records(id,payload)
SELECT 'F0630000-0000-4000-8000-000000000001',
 CAST(json_set(CAST(payload AS TEXT), '$.id','F0630000-0000-4000-8000-000000000001',
 '$.title','QuotaRestoreFixture','$.deletedAt',800000001,'$.archivedAt',800000000,
 '$.starred',json('true')) AS BLOB)
FROM records WHERE id='F0620000-0000-4000-8000-000000000001';
COMMIT;
SELECT COUNT(*) FROM records;
