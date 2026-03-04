An automated log lifecycle management system. The system consists of two coordinated Bash scripts designed to manage historical logs in a controlled, secure, and auditable manner. The objective of this process is to reduce local storage usage, preserve historical logs in compressed format, ensure secure offloading to Object Storage Service (OSS), and maintain operational reliability through error handling and isolation mechanisms.
The log lifecycle is structured in three major phases:
1.	Compression of logs older than two calendar months.
2.	Upload of original logs older than two calendar months to an OSS bucket.
3.	Deletion of original logs only after successful upload, with quarantine handling for failed uploads.
This design ensures no data loss, controlled storage utilization, and traceable operational behavior.
