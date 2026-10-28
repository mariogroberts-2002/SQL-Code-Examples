/*
    Purpose: Lists every user table in the current database with its row count
             and disk space usage, sorted by name or by size.
             Same figures as sp_spaceused, but returned as numbers from DMVs
             in a single set-based query (no undocumented procs, no temp table).
*/

DECLARE @Sort bit = 0;  -- 0 = alphabetical by table name, 1 = by reserved size, largest first

-- Aggregate page counts per table across all of its partitions and indexes
WITH TableSpace AS
(
    SELECT
        t.object_id,
        s.name AS Schema_Name,
        t.name AS Table_Name,

        -- Row count: only count the heap (index_id 0) or clustered index (index_id 1),
        -- otherwise rows would be double-counted once per nonclustered index
        SUM(CASE WHEN ps.index_id < 2 THEN ps.row_count ELSE 0 END) AS Row_Count,

        -- Total pages allocated to the table (all indexes, LOB, row-overflow)
        SUM(ps.reserved_page_count) AS Reserved_Pages,

        -- Pages actually in use
        SUM(ps.used_page_count) AS Used_Pages,

        -- Data pages: in-row data for the heap/clustered index, plus LOB and
        -- row-overflow pages for every index (same logic sp_spaceused uses)
        SUM(CASE
                WHEN ps.index_id < 2
                    THEN ps.in_row_data_page_count + ps.lob_used_page_count + ps.row_overflow_used_page_count
                ELSE ps.lob_used_page_count + ps.row_overflow_used_page_count
            END) AS Data_Pages
    FROM sys.tables AS t
    JOIN sys.schemas AS s
        ON s.schema_id = t.schema_id
    JOIN sys.dm_db_partition_stats AS ps      -- one row per partition of each index/heap
        ON ps.object_id = t.object_id
    WHERE t.is_ms_shipped = 0                 -- user tables only
    GROUP BY t.object_id, s.name, t.name
)
SELECT
    Schema_Name,
    Table_Name,
    Row_Count,
    -- Pages are 8 KB each; convert page counts to KB and MB
    Reserved_Pages * 8                              AS Reserved_KB,
    CAST(Reserved_Pages * 8 / 1024.0 AS decimal(18,2)) AS Reserved_MB,
    Data_Pages * 8                                  AS Data_KB,
    (Used_Pages - Data_Pages) * 8                   AS Index_KB,   -- used space that isn't data
    (Reserved_Pages - Used_Pages) * 8               AS Unused_KB   -- allocated but empty
FROM TableSpace
ORDER BY
    -- Sort numerically by size when @Sort = 1 (NULL otherwise, so it has no effect)
    CASE WHEN @Sort = 1 THEN Reserved_Pages END DESC,
    -- Then by name (primary sort when @Sort = 0, tie-breaker when @Sort = 1)
    Schema_Name,
    Table_Name;