-- Only for an empty, dedicated simulator database. Never run against user data.
.bail on
BEGIN IMMEDIATE;
CREATE TEMP TABLE fixture_guard (count INTEGER CHECK(count = 0));
INSERT INTO fixture_guard SELECT COUNT(*) FROM records;
WITH RECURSIVE numbers(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM numbers WHERE n<100)
INSERT INTO records(id, payload)
SELECT printf('F0620000-0000-4000-8000-%012d', n),
CAST(json_object('id', printf('F0620000-0000-4000-8000-%012d', n),
 'createdAt',800000000,'updatedAt',800000000,'version',1,'kind','text',
 'title',printf('QuotaFixture-%03d',n),'body','Dedicated quota UI fixture',
 'source','验收资料','note','','starred',json('false'),'titleEdited',json('false'),
 'attachments',json('[]'),'extractedText','','processingState','complete') AS BLOB)
FROM numbers;
COMMIT;
SELECT COUNT(*) FROM records;
