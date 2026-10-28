select distinct name,text
 from sysobjects o, syscomments s
where o.id = s.id
and text like '%%'
and o.xtype = 'P'
 
 
SELECT definition
FROM sys.sql_modules
where definition like '%create view%'


