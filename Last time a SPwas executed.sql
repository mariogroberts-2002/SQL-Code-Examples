SELECT TOP 10 'GetHPCSNCarePacks_Canada' AS [SP Name], qs.last_execution_time
      FROM sys.dm_exec_query_stats AS qs
      CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS qt
      WHERE qt.dbid = db_id() -- Filter by current database
      AND qt.text LIKE '%GetHPCSNCarePacks_Canada%'
      ORDER BY qs.last_execution_time desc