### Source and Destination DBs with No Direct Connectivity: ###
1. Separate Scripts for Each Environment:
Source EC2: Only runs export operations

Target EC2: Only runs import operations

No cross-database connections in scripts

2. NFS as Communication Channel:
Dump files written to shared NFS by source

Dump files read from shared NFS by target

Log files and markers for coordination

3. Independent Operations:
Source analysis and export generation on source EC2

Import script generation and execution on target EC2

No assumptions about network connectivity between DBs

4. Coordination via Files:
Completion markers (export_completion_*.marker)

Progress logs in shared directory

File existence checks before import

5. Usage Instructions:
On Source EC2 (11g):


**Run the planning script first**
./oracle_migration_separate.sh

**Then execute export (requires downtime)**
/mnt/shared/oracle_mig/logs/run_source_export_*.sh
On Target EC2 (19c):

**Wait for export to complete, then execute import**
/mnt/shared/oracle_mig/logs/run_target_import_*.sh

**Then run validation**
sqlplus system@ORCL19C @/mnt/shared/oracle_mig/logs/validate_target_*.sql

This approach completely eliminates the need for direct database connectivity between source and target, using the shared NFS as the only communication mechanism.
