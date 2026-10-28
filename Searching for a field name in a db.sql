
SELECT 
[View]=sysobjects.name,
column_name=syscolumns.name,
--datatype=systypes.name,
column_type=sys.types.name,
length=syscolumns.length,
isnullable
FROM sysobjects
JOIN syscolumns ON sysobjects.id = syscolumns.id
JOIN sys.sql_modules ON sql_modules.object_id = sysobjects.id 
JOIN sys.types ON syscolumns.xtype = sys.types.system_type_id
WHERE sysobjects.xtype='V'
AND sysobjects.name like '%item%'
ORDER BY sysobjects.name,syscolumns.colid


