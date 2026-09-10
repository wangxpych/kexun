-- Dedicated simulator only, with the app terminated. Does not change existing records.
-- After testing: DROP TRIGGER kexun_processing_pause_fixture;
.bail on
BEGIN IMMEDIATE;
INSERT INTO records(id, payload) VALUES (
 'F0980000-0000-4000-8000-000000000001',
 CAST(json_object('id','F0980000-0000-4000-8000-000000000001',
 'createdAt',900000000,'updatedAt',900000000,'version',1,'kind','link',
 'title','ProcessingPauseUI-98','body','暂停期间原始正文仍然可读',
 'originalURL','http://127.0.0.1/processing-pause-fixture',
 'source','验收资料','note','','starred',json('false'),'titleEdited',json('true'),
 'attachments',json('[]'),'extractedText','','processingState','pending') AS BLOB)
);
CREATE TRIGGER kexun_processing_pause_fixture BEFORE INSERT ON records
WHEN NEW.id = 'F0980000-0000-4000-8000-000000000001'
BEGIN SELECT RAISE(ABORT, 'ProcessingPauseUI-98 injected write failure'); END;
COMMIT;
