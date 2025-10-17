#!/bin/bash
#
# Oracle 32TB Migration: 11g to 19c using Data Pump Only
# MODIFIED for NO DIRECT DB CONNECTIVITY between source and target
#

set -e

# Configuration - SOURCE Environment (EC2 with 11g)
SOURCE_DB="ORCL11G"
SOURCE_USER="system"

# Configuration - TARGET Environment (EC2 with 19c)  
TARGET_DB="ORCL19C"
TARGET_USER="system"

# Shared NFS Configuration
NFS_BASE="/mnt/shared/oracle_mig"
LOG_DIR="${NFS_BASE}/logs"
DATA_DIR="${NFS_BASE}/datapump"
BACKUP_DIR="${NFS_BASE}/backups"
DATE_STAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="migration_no_direct_connect_${DATE_STAMP}.log"

# Data Pump Configuration
PARALLEL_JOBS=8
COMPRESSION_ALGORITHM="ALL"

# File Definitions
TABLESPACE_FILE="${LOG_DIR}/tablespaces_${DATE_STAMP}.lst"
DBLINKS_FILE="${LOG_DIR}/dblinks_${DATE_STAMP}.lst"
SYNONYMS_FILE="${LOG_DIR}/synonyms_${DATE_STAMP}.lst"
MIGRATION_PLAN="${LOG_DIR}/migration_plan_${DATE_STAMP}.txt"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Logging Functions
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "${LOG_DIR}/${LOG_FILE}"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1" | tee -a "${LOG_DIR}/${LOG_FILE}"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" | tee -a "${LOG_DIR}/${LOG_FILE}"
    exit 1
}

# Initialize Environment
initialize_environment() {
    log "Initializing Migration Environment for SEPARATE databases..."
    
    # Create directories on shared NFS
    mkdir -p "${LOG_DIR}" "${DATA_DIR}" "${BACKUP_DIR}"
    chmod 755 "${NFS_BASE}" "${LOG_DIR}" "${DATA_DIR}" "${BACKUP_DIR}"
    
    # Verify NFS mount
    if ! mountpoint -q /mnt/shared; then
        error "NFS not mounted at /mnt/shared"
    fi
    
    # Check available space
    local available_gb=$(df -BG /mnt/shared | awk 'NR==2 {print $4}' | sed 's/G//')
    if [ "$available_gb" -lt 40000 ]; then
        warn "Low disk space: ${available_gb}GB available, recommended 40000GB"
        read -p "Continue anyway? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            error "Insufficient disk space"
        fi
    else
        log "Disk space available: ${available_gb}GB"
    fi
}

# Phase 1: Source Database Analysis (Run on SOURCE EC2)
phase1_source_analysis() {
    log "=== PHASE 1: SOURCE DATABASE ANALYSIS ==="
    
    # Get source DB password
    echo -n "Enter SOURCE DB (${SOURCE_USER}) password: "
    read -s SOURCE_PASSWORD
    echo
    
    # Verify source DB connectivity
    if ! sqlplus -s "${SOURCE_USER}/\"${SOURCE_PASSWORD}\"@${SOURCE_DB}" <<EOF >/dev/null
    WHENEVER SQLERROR EXIT SQL.SQLCODE;
    SELECT 'Source DB Connected' FROM DUAL;
    EXIT;
EOF
    then
        error "Cannot connect to source database ${SOURCE_DB}"
    fi
    log "Source database connection: SUCCESS"
    
    # Extract tablespaces
    log "Extracting tablespace information..."
    sqlplus -s "${SOURCE_USER}/\"${SOURCE_PASSWORD}\"@${SOURCE_DB}" <<EOF > "${TABLESPACE_FILE}"
    SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
    SELECT tablespace_name 
    FROM dba_tablespaces 
    WHERE contents = 'PERMANENT' 
    AND tablespace_name NOT IN ('SYSTEM','SYSAUX','TEMP','UNDOTBS1')
    ORDER BY tablespace_name;
    EXIT;
EOF

    # Extract database links
    log "Extracting database links..."
    sqlplus -s "${SOURCE_USER}/\"${SOURCE_PASSWORD}\"@${SOURCE_DB}" <<EOF > "${DBLINKS_FILE}"
    SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF LINESIZE 200
    SELECT owner || '|' || db_link || '|' || username || '|' || host || '|' || created
    FROM dba_db_links
    ORDER BY owner, db_link;
    EXIT;
EOF

    # Extract synonyms
    log "Extracting synonyms..."
    sqlplus -s "${SOURCE_USER}/\"${SOURCE_PASSWORD}\"@${SOURCE_DB}" <<EOF > "${SYNONYMS_FILE}"
    SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF LINESIZE 200
    SELECT owner || '|' || synonym_name || '|' || table_owner || '|' || table_name || '|' || NVL(db_link, 'NONE')
    FROM dba_synonyms
    WHERE owner NOT IN ('SYS','SYSTEM')
    AND table_owner IS NOT NULL
    ORDER BY owner, synonym_name;
    EXIT;
EOF

    # Create Data Pump directory in source DB
    log "Creating Data Pump directory in source database..."
    sqlplus -s "${SOURCE_USER}/\"${SOURCE_PASSWORD}\"@${SOURCE_DB}" <<EOF | tee -a "${LOG_DIR}/source_setup_${DATE_STAMP}.log"
    CREATE OR REPLACE DIRECTORY MIG_DIR AS '${DATA_DIR}';
    GRANT READ, WRITE ON DIRECTORY MIG_DIR TO PUBLIC;
    
    -- Verify directory
    SELECT directory_name, directory_path FROM dba_directories 
    WHERE directory_name = 'MIG_DIR';
EOF

    # Generate source analysis report
    sqlplus -s "${SOURCE_USER}/\"${SOURCE_PASSWORD}\"@${SOURCE_DB}" <<EOF | tee -a "${LOG_DIR}/source_analysis_${DATE_STAMP}.log"
    SET PAGESIZE 1000 LINESIZE 200
    
    PROMPT === SOURCE DATABASE SIZE SUMMARY ===
    SELECT 'Total Data Size: ' || 
           ROUND(SUM(bytes)/1024/1024/1024,2) || ' GB' as database_size
    FROM dba_segments;
    
    PROMPT === LARGEST TABLESPACES ===
    SELECT tablespace_name, ROUND(SUM(bytes)/1024/1024/1024,2) as SIZE_GB
    FROM dba_data_files 
    WHERE tablespace_name NOT IN ('SYSTEM','SYSAUX','TEMP','UNDOTBS1')
    GROUP BY tablespace_name
    ORDER BY SIZE_GB DESC;
    
    PROMPT === SPATIAL DATA SUMMARY ===
    SELECT COUNT(*) as spatial_tables,
           ROUND(SUM(s.bytes)/1024/1024/1024,2) as total_size_gb
    FROM dba_tables t
    JOIN dba_segments s ON (t.owner = s.owner AND t.table_name = s.segment_name)
    WHERE EXISTS (
        SELECT 1 FROM dba_tab_columns c 
        WHERE c.owner = t.owner 
        AND c.table_name = t.table_name 
        AND c.data_type = 'SDO_GEOMETRY'
    );
EOF
}

# Phase 2: Generate Source Export Script (Run on SOURCE EC2)
phase2_generate_source_export() {
    log "=== PHASE 2: GENERATING SOURCE EXPORT SCRIPTS ==="
    
    # Main export script for source
    cat > "${LOG_DIR}/run_source_export_${DATE_STAMP}.sh" << 'EOEXPORT'
#!/bin/bash
#
# Data Pump Export Script - RUN ON SOURCE EC2
#

set -e

SOURCE_DB="${SOURCE_DB}"
SOURCE_USER="${SOURCE_USER}"
DATA_DIR="${DATA_DIR}"
LOG_DIR="${LOG_DIR}"
DATE_STAMP="${DATE_STAMP}"
PARALLEL_JOBS=${PARALLEL_JOBS}

echo "=== SOURCE DATABASE EXPORT ==="
echo "Started: $(date)"

# Get password
echo -n "Enter source DB password: "
read -s SOURCE_PASSWORD
echo

# Verify NFS is accessible
if [ ! -w "${DATA_DIR}" ]; then
    echo "ERROR: Cannot write to DATA_DIR: ${DATA_DIR}"
    exit 1
fi

# Full database export
echo "Starting Data Pump export at $(date)..."
echo "This will take approximately 5-7 days for 32TB database..."

expdp ${SOURCE_USER}/\"${SOURCE_PASSWORD}\"@${SOURCE_DB} \
    DIRECTORY=MIG_DIR \
    DUMPFILE=full_export_%U_${DATE_STAMP}.dmp \
    LOGFILE=full_export_${DATE_STAMP}.log \
    FULL=YES \
    PARALLEL=${PARALLEL_JOBS} \
    COMPRESSION=ALL \
    COMPRESSION_ALGORITHM=HIGH \
    FILESIZE=32G \
    EXCLUDE=STATISTICS \
    FLASHBACK_TIME=SYSTIMESTAMP

export_exit_code=$?

if [ $export_exit_code -eq 0 ]; then
    echo "Export completed successfully at $(date)"
    # List created files
    echo "=== EXPORTED FILES ==="
    ls -lh ${DATA_DIR}/*.dmp | tee "${LOG_DIR}/exported_files_${DATE_STAMP}.log"
    
    # Create completion marker
    echo "EXPORT_COMPLETED: $(date)" > "${LOG_DIR}/export_completion_${DATE_STAMP}.marker"
else
    echo "Export failed with exit code: $export_exit_code"
    exit $export_exit_code
fi
EOEXPORT

    # Metadata-only export for validation
    cat > "${LOG_DIR}/run_source_metadata_export_${DATE_STAMP}.sh" << 'EOMETADATA'
#!/bin/bash
#
# Data Pump Metadata Export - RUN ON SOURCE EC2
#

set -e

SOURCE_DB="${SOURCE_DB}"
SOURCE_USER="${SOURCE_USER}"
DATA_DIR="${DATA_DIR}"
LOG_DIR="${LOG_DIR}"
DATE_STAMP="${DATE_STAMP}"

echo "=== METADATA EXPORT ==="

echo -n "Enter source DB password: "
read -s SOURCE_PASSWORD
echo

# Metadata-only export (much faster)
expdp ${SOURCE_USER}/\"${SOURCE_PASSWORD}\"@${SOURCE_DB} \
    DIRECTORY=MIG_DIR \
    DUMPFILE=metadata_only_${DATE_STAMP}.dmp \
    LOGFILE=metadata_export_${DATE_STAMP}.log \
    FULL=YES \
    CONTENT=METADATA_ONLY

echo "Metadata export completed"
EOMETADATA

    chmod +x "${LOG_DIR}/run_source_export_${DATE_STAMP}.sh" "${LOG_DIR}/run_source_metadata_export_${DATE_STAMP}.sh"
    log "Source export scripts generated"
}

# Phase 3: Generate Target Import Script (Run on TARGET EC2)
phase3_generate_target_import() {
    log "=== PHASE 3: GENERATING TARGET IMPORT SCRIPTS ==="
    
    # Main import script for target
    cat > "${LOG_DIR}/run_target_import_${DATE_STAMP}.sh" << 'EOIMPORT'
#!/bin/bash
#
# Data Pump Import Script - RUN ON TARGET EC2
#

set -e

TARGET_DB="${TARGET_DB}"
TARGET_USER="${TARGET_USER}"
DATA_DIR="${DATA_DIR}"
LOG_DIR="${LOG_DIR}"
DATE_STAMP="${DATE_STAMP}"
PARALLEL_JOBS=${PARALLEL_JOBS}

echo "=== TARGET DATABASE IMPORT ==="
echo "Started: $(date)"

# Get password
echo -n "Enter target DB password: "
read -s TARGET_PASSWORD
echo

# Verify dump files exist
if ! ls ${DATA_DIR}/full_export_*_${DATE_STAMP}.dmp 1> /dev/null 2>&1; then
    echo "ERROR: No dump files found for import!"
    echo "Expected pattern: ${DATA_DIR}/full_export_*_${DATE_STAMP}.dmp"
    exit 1
fi

# Create Data Pump directory in target DB
sqlplus -s ${TARGET_USER}/\"${TARGET_PASSWORD}\"@${TARGET_DB} <<EOF
CREATE OR REPLACE DIRECTORY MIG_DIR AS '${DATA_DIR}';
GRANT READ, WRITE ON DIRECTORY MIG_DIR TO PUBLIC;
EOF

echo "Starting Data Pump import at $(date)..."
echo "This will take approximately 5-7 days for 32TB database..."

# Full database import
impdp ${TARGET_USER}/\"${TARGET_PASSWORD}\"@${TARGET_DB} \
    DIRECTORY=MIG_DIR \
    DUMPFILE=full_export_%U_${DATE_STAMP}.dmp \
    LOGFILE=full_import_${DATE_STAMP}.log \
    FULL=YES \
    PARALLEL=${PARALLEL_JOBS} \
    TRANSFORM=DISABLE_ARCHIVE_LOGGING:Y \
    REMAP_TABLESPACE=USERS:USERS \
    EXCLUDE=SCHEMA:"IN ('ANONYMOUS','APEX_030200','CTXSYS','DBSNMP','DIP','EXFSYS','MDDATA','MDSYS','MGMT_VIEW','OLAPSYS','ORACLE_OCM','ORDDATA','ORDPLUGINS','ORDSYS','OUTLN','SI_INFORMTN_SCHEMA','SYS','SYSMAN','SYSTEM','TSMSYS','WMSYS','XDB','XS\$NULL')" \
    TABLE_EXISTS_ACTION=REPLACE

import_exit_code=$?

if [ $import_exit_code -eq 0 ]; then
    echo "Import completed successfully at $(date)"
    echo "IMPORT_COMPLETED: $(date)" > "${LOG_DIR}/import_completion_${DATE_STAMP}.marker"
else
    echo "Import completed with exit code: $import_exit_code"
    # Continue anyway for partial success
fi
EOIMPORT

    # Spatial optimization import
    cat > "${LOG_DIR}/run_target_spatial_import_${DATE_STAMP}.sh" << 'EOSPATIAL'
#!/bin/bash
#
# Spatial Data Import - RUN ON TARGET EC2
#

set -e

TARGET_DB="${TARGET_DB}"
TARGET_USER="${TARGET_USER}"
DATA_DIR="${DATA_DIR}"
LOG_DIR="${LOG_DIR}"
DATE_STAMP="${DATE_STAMP}"

echo "=== SPATIAL DATA OPTIMIZATION ==="

echo -n "Enter target DB password: "
read -s TARGET_PASSWORD
echo

# Import without spatial indexes first (faster)
impdp ${TARGET_USER}/\"${TARGET_PASSWORD}\"@${TARGET_DB} \
    DIRECTORY=MIG_DIR \
    DUMPFILE=full_export_%U_${DATE_STAMP}.dmp \
    LOGFILE=spatial_import_phase1_${DATE_STAMP}.log \
    FULL=YES \
    PARALLEL=8 \
    EXCLUDE=INDEX:"LIKE '%SDO_%'" \
    TRANSFORM=DISABLE_ARCHIVE_LOGGING:Y \
    TABLE_EXISTS_ACTION=REPLACE

echo "Data imported without spatial indexes, now creating spatial indexes..."

# Create spatial indexes
sqlplus -s ${TARGET_USER}/\"${TARGET_PASSWORD}\"@${TARGET_DB} <<EOF > "${LOG_DIR}/spatial_indexes_${DATE_STAMP}.log"
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    CURSOR c_spatial_indexes IS
        SELECT owner, index_name, table_owner, table_name, column_name
        FROM all_ind_columns ic
        JOIN all_indexes i ON (ic.index_owner = i.owner AND ic.index_name = i.index_name)
        WHERE i.ityp_name = 'SPATIAL_INDEX'
        AND i.owner NOT IN ('SYS','MDSYS','SYSTEM');
    
    v_sql VARCHAR2(4000);
BEGIN
    FOR rec IN c_spatial_indexes LOOP
        v_sql := 'CREATE INDEX ' || rec.owner || '.' || rec.index_name || 
                 ' ON ' || rec.table_owner || '.' || rec.table_name || 
                 '(' || rec.column_name || ') ' ||
                 'INDEXTYPE IS MDSYS.SPATIAL_INDEX ' ||
                 'PARAMETERS (''TABLESPACE=USERS'')';
        
        DBMS_OUTPUT.PUT_LINE('Creating: ' || rec.index_name);
        BEGIN
            EXECUTE IMMEDIATE v_sql;
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('Error creating ' || rec.index_name || ': ' || SQLERRM);
        END;
    END LOOP;
END;
/
EOF

echo "Spatial optimization completed"
EOSPATIAL

    chmod +x "${LOG_DIR}/run_target_import_${DATE_STAMP}.sh" "${LOG_DIR}/run_target_spatial_import_${DATE_STAMP}.sh"
    log "Target import scripts generated"
}

# Phase 4: Generate Object Recreation Scripts
phase4_generate_recreation_scripts() {
    log "=== PHASE 4: GENERATING OBJECT RECREATION SCRIPTS ==="
    
    # Database links recreation (run on TARGET)
    cat > "${LOG_DIR}/recreate_dblinks_${DATE_STAMP}.sql" << 'EODBLINKS'
-- Database Links Recreation - RUN ON TARGET DATABASE
-- Passwords need to be manually updated!

PROMPT === RECREATING DATABASE LINKS ===

EODBLINKS

    # Add DB links DDL from source analysis
    if [ -f "${DBLINKS_FILE}" ] && [ -s "${DBLINKS_FILE}" ]; then
        while IFS='|' read -r owner db_link username host created; do
            if [ -n "$owner" ] && [ "$owner" != "owner" ]; then
                cat >> "${LOG_DIR}/recreate_dblinks_${DATE_STAMP}.sql" << EOF
-- DB Link: $db_link (Owner: $owner)
CREATE $([ "$owner" = "PUBLIC" ] && echo "PUBLIC ")DATABASE LINK $([ "$owner" != "PUBLIC" ] && echo "${owner}.")${db_link}
CONNECT TO $username IDENTIFIED BY "<PASSWORD>" 
USING '$host';

EOF
            fi
        done < "${DBLINKS_FILE}"
    fi

    # Validation script for target
    cat > "${LOG_DIR}/validate_target_${DATE_STAMP}.sql" << 'EOVALIDATE'
-- Validation Script - RUN ON TARGET DATABASE

SET PAGESIZE 1000 LINESIZE 200
PROMPT === TARGET DATABASE VALIDATION ===

PROMPT 1. Database Status
SELECT name, dbid, created, log_mode FROM v\$database;

PROMPT 2. Tablespace Status  
SELECT tablespace_name, status, contents FROM dba_tablespaces ORDER BY 1;

PROMPT 3. Object Counts by Schema
SELECT owner, COUNT(*) FROM dba_objects 
WHERE owner NOT IN ('SYS','SYSTEM') GROUP BY owner ORDER BY 2 DESC;

PROMPT 4. Spatial Data Check
SELECT owner, table_name, column_name FROM all_sdo_geom_metadata ORDER BY 1,2;

PROMPT 5. Invalid Objects
SELECT owner, object_type, COUNT(*) FROM dba_objects 
WHERE status = 'INVALID' GROUP BY owner, object_type ORDER BY 1,2;

PROMPT === VALIDATION COMPLETE ===
EOVALIDATE

    log "Object recreation scripts generated"
}

# Phase 5: Generate Migration Plan
phase5_generate_migration_plan() {
    log "=== PHASE 5: GENERATING MIGRATION PLAN ==="
    
    cat > "${MIGRATION_PLAN}" << EOF
ORACLE 32TB MIGRATION PLAN - SEPARATE ENVIRONMENTS
==================================================

SOURCE: ${SOURCE_DB} (11g) on EC2 -> TARGET: ${TARGET_DB} (19c) on EC2
NO DIRECT DATABASE CONNECTIVITY BETWEEN SOURCE AND TARGET

MIGRATION STRATEGY: Data Pump via Shared NFS
=============================================

PHASE 1: PREPARATION (Run on SOURCE EC2)
-----------------------------------------
1. Source database analysis
2. Create Data Pump directory
3. Generate export scripts
4. Schedule application downtime

SCRIPTS:
- Analysis: Already completed
- Export: ${LOG_DIR}/run_source_export_${DATE_STAMP}.sh

PHASE 2: EXPORT (Run on SOURCE EC2) - 5-7 DAYS
-----------------------------------------------
1. Stop applications on source
2. Run: ${LOG_DIR}/run_source_export_${DATE_STAMP}.sh
3. Monitor progress in ${LOG_DIR}/
4. Verify dump files in ${DATA_DIR}/

PHASE 3: TRANSFER (Automatic via NFS)
--------------------------------------
1. Dump files automatically available on target via NFS
2. No manual transfer needed

PHASE 4: IMPORT (Run on TARGET EC2) - 5-7 DAYS  
-----------------------------------------------
1. Verify dump files exist in ${DATA_DIR}/
2. Run: ${LOG_DIR}/run_target_import_${DATE_STAMP}.sh
3. For spatial optimization: ${LOG_DIR}/run_target_spatial_import_${DATE_STAMP}.sh
4. Monitor progress in ${LOG_DIR}/

PHASE 5: POST-MIGRATION (Run on TARGET EC2)
--------------------------------------------
1. Recreate database links: ${LOG_DIR}/recreate_dblinks_${DATE_STAMP}.sql
2. Validate migration: ${LOG_DIR}/validate_target_${DATE_STAMP}.sql
3. Update application connection strings
4. Performance testing

CRITICAL NOTES:
===============
- TOTAL DOWNTIME: 7-10 days required
- NO direct database connectivity between source and target
- All communication via shared NFS
- Monitor disk space on NFS continuously
- Test with metadata export first if possible

GENERATED SCRIPTS:
==================
SOURCE EC2 (11g):
  - Export: ${LOG_DIR}/run_source_export_${DATE_STAMP}.sh

TARGET EC2 (19c):  
  - Import: ${LOG_DIR}/run_target_import_${DATE_STAMP}.sh
  - Spatial: ${LOG_DIR}/run_target_spatial_import_${DATE_STAMP}.sh
  - DB Links: ${LOG_DIR}/recreate_dblinks_${DATE_STAMP}.sql
  - Validation: ${LOG_DIR}/validate_target_${DATE_STAMP}.sql

VERIFICATION:
=============
- Check export completion: ${LOG_DIR}/export_completion_${DATE_STAMP}.marker
- Check import completion: ${LOG_DIR}/import_completion_${DATE_STAMP}.marker
- Review logs in: ${LOG_DIR}/

EOF

    log "Migration plan generated: ${MIGRATION_PLAN}"
}

# Main Execution
main() {
    echo
    info "=================================================================="
    info "ORACLE 32TB MIGRATION - SEPARATE SOURCE/TARGET ENVIRONMENTS"
    info "=================================================================="
    echo
    info "ASSUMPTION: No direct database connectivity between source and target"
    info "COMMUNICATION: Via shared NFS mount only"
    echo
    
    initialize_environment
    
    # Execute phases
    phase1_source_analysis
    phase2_generate_source_export
    phase3_generate_target_import  
    phase4_generate_recreation_scripts
    phase5_generate_migration_plan
    
    # Final instructions
    log ""
    info "=================================================================="
    info "MIGRATION PLANNING COMPLETE FOR SEPARATE ENVIRONMENTS"
    info "=================================================================="
    log ""
    warn "*** IMPORTANT: MIGRATION STEPS ***"
    info "1. ON SOURCE EC2: Run ${LOG_DIR}/run_source_export_${DATE_STAMP}.sh"
    info "2. WAIT for export to complete (5-7 days)"
    info "3. ON TARGET EC2: Run ${LOG_DIR}/run_target_import_${DATE_STAMP}.sh" 
    info "4. WAIT for import to complete (5-7 days)"
    info "5. ON TARGET: Run validation and recreation scripts"
    log ""
    warn "*** NO DIRECT DB CONNECTIVITY BETWEEN SOURCE AND TARGET ***"
    info "All coordination happens via shared NFS: ${NFS_BASE}"
    info "Monitor progress through log files and completion markers"
    log ""
}

# Execute
main "$@"
