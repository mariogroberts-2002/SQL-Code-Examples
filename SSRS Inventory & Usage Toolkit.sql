/*=============================================================================================
    SSRS Inventory & Usage Toolkit  —  ISIGHT folder
    ---------------------------------------------------------------------------------------------
    Queries the SSRS catalog database ([ReportServer]) to document and monitor everything under
    the /ISIGHT folder:

        1. Currently running jobs
        2. Subscriptions (parsed from XML) and the reports they deliver
        3. Folder structure, split into one column per folder level
        4. Shared data sources
        5. Shared datasets
        6. Report execution log (detail)
        7. Report schedules
        8. Top N most-run reports, by week
        9. Activity by week and 30-minute time slot

    HOW TO RUN
        This is a collection of independent sections, NOT a single batch. Highlight and run one
        section at a time. Running the whole file at once fails because @localhost, @pStartDate,
        @pEndDate and @path are DECLAREd more than once in the same batch.
        Section 3 uses @localhost declared in Section 2 — run them together, or re-declare it.

    REFERENCE — [Catalog].[Type] values used below
        1 = Folder       2 = Report          3 = Resource       4 = Linked report
        5 = Data source  6 = Report model    7 = Report part    8 = Shared dataset

    REFERENCE — [ExecutionLog].[RequestType]
        0 = Interactive (user)   1 = Subscription   2 = Cache refresh (SSRS 2008 R2+)
=============================================================================================*/


--===========================================================================================
-- SECTION 1: Currently running jobs
--   Shows report executions/jobs in progress at this moment (empty if nothing is running).
--   Note: SELECT * already includes [JobStatus]; listing it again just repeats the column.
--===========================================================================================
SELECT *
,[JobStatus]
FROM [ReportServer].[dbo].[RunningJobs]


--===========================================================================================
-- SECTION 2: Subscriptions and their delivery settings
--===========================================================================================

-- Drop the temp table if it is left over from a previous run in this session,
-- so the SELECT ... INTO below doesn't fail with "object already exists"
IF OBJECT_ID('tempdb..#Subscriptions_Parsed') IS NOT NULL
Begin DROP TABLE #Subscriptions_Parsed
End

-------------------------------------------------------------------------------------------
-- Step 2a: Parse subscription settings out of XML
--   Subscriptions.ExtensionSettings is stored as text containing XML like:
--     <ParameterValues>
--       <ParameterValue><Name>TO</Name><Value>someone@company.com</Value></ParameterValue>
--       <ParameterValue><Name>RenderFormat</Name><Value>EXCEL</Value></ParameterValue>
--       ...
--     </ParameterValues>
--   This converts it into one row per (SubscriptionID, setting Name, setting Value).
-------------------------------------------------------------------------------------------

-- Base URL of the Report Manager page; a report's catalog path is appended to build a link.
-- Also used by Section 3.
Declare @localhost varchar(600)
SET @localhost = 'http://ussd-prd-msdb05/Reports/Pages/Report.aspx?ItemPath=%2f'

-- Table variable holding each subscription with its settings cast to the XML data type
declare @T table
(
  SubscriptionID varchar(50) ,
  Report_OID varchar(50),       -- ItemID of the report in [Catalog]
  XMLCol xml
)

-- Load every subscription, converting the text column to XML so it can be shredded
INSERT INTO @T (SubscriptionID,Report_OID,XMLCol)
SELECT SubscriptionID
,Report_OID
,CAST(ExtensionSettings AS XML) XMLCol
FROM [ReportServer].dbo.Subscriptions

-- Shred the XML: CROSS APPLY .nodes() returns one row per <ParameterValue> element;
-- .value() pulls the <Name> and <Value> text out of each one.
-- Note: varchar(200) will silently truncate long TO/CC recipient lists.
SELECT SubscriptionID,
Report_OID,
X.N.value('Name[1]', 'varchar(200)') as [Name],
X.N.value('Value[1]', 'varchar(200)') as [Value]
INTO #Subscriptions_Parsed
FROM @T as T
cross apply T.XMLCol.nodes('/ParameterValues/ParameterValue') as X(N)

-- Inspect the raw parsed settings (one row per subscription setting)
SELECT * FROM #Subscriptions_Parsed

-------------------------------------------------------------------------------------------
-- Step 2b: One row per ISIGHT report/subscription with delivery settings as columns
--   Each LEFT JOIN to #Subscriptions_Parsed pivots one setting (TO, CC, etc.) into its own
--   column. LEFT JOINs keep reports that have no subscription (subscription columns = NULL).
-------------------------------------------------------------------------------------------
SELECT DISTINCT
		Cat.Name AS Report_Name,
		Cat.[Description],
		Cat.Path,
		--@localhost + replace(replace(right(Cat.Path,LEN(Cat.Path)-1),'/','%2f'),' ','+') As [URL],
		-- Classify the report's environment by keywords in its folder path
		CASE WHEN Cat.Path like '%BizApps%' THEN 'BizApps'
		WHEN Cat.Path like '%xDevelopment%' THEN 'xDevelopment'
		ELSE 'Production' END AS [Environment],
		LastRunTime,                    -- from Subscriptions: last time this subscription fired
		LastStatus,                     -- from Subscriptions: result message of that run
		subTo.Value As Emailed_To,      -- email recipients
		subCC.Value As Emailed_CC,      -- CC recipients
		subIR.Value As IncludeReport,   -- True = report attached to the email
		subRF.Value As RenderFormat,    -- attachment format (PDF, EXCEL, MHTML, ...)
		subIL.Value As IncludeLink     ,-- True = email includes a link to the report
		Cat.Type

FROM [ReportServer].[dbo].[Catalog] Cat
LEFT JOIN [ReportServer].dbo.Subscriptions sub ON sub.Report_OID = Cat.ItemID
LEFT JOIN #Subscriptions_Parsed subTo ON subTo.SubscriptionID = sub.SubscriptionID And subTo.Name = 'TO'
LEFT JOIN #Subscriptions_Parsed subCC ON subCC.SubscriptionID = sub.SubscriptionID And subCC.Name = 'CC'
LEFT JOIN #Subscriptions_Parsed subIR ON subIR.SubscriptionID = sub.SubscriptionID And subIR.Name = 'IncludeReport'
LEFT JOIN #Subscriptions_Parsed subRF ON subRF.SubscriptionID = sub.SubscriptionID And subRF.Name = 'RenderFormat'
LEFT JOIN #Subscriptions_Parsed subIL ON subIL.SubscriptionID = sub.SubscriptionID And subIL.Name = 'IncludeLink'
WHERE
Cat.Path like '/ISIGHT%'            -- ISIGHT folder (also matches e.g. '/ISIGHT_Archive')
--Cat.Path not like '%/Data Sources/%'
--AND Cat.Name ='Data Feed'
AND Cat.Type = 2                    -- reports only (linked reports, Type 4, are excluded)
AND Cat.Hidden = 0                  -- skip items hidden in Report Manager
ORDER BY 3                          -- column 3 = Path

-- Clean up the temp table used in this section
DROP TABLE #Subscriptions_Parsed


--===========================================================================================
-- SECTION 3: Folder structure
--   Lists every folder under /ISIGHT and splits its path into Folder 1 … Folder 8 columns,
--   plus a clickable Report Manager URL.
--   Requires @localhost from Section 2 (run together, or re-declare it).
--
--   How it works:
--     Inner query: Folders_Cnt = number of '/' in the path (= folder depth), and
--                  [1]…[8] = character position of the 1st…8th '/' (0 if not present),
--                  found by chaining CHARINDEX, each search starting just past the previous '/'.
--     Outer query: Folder N = text between slash N and slash N+1; for the last level,
--                  text from slash N to the end of the path.
--     Each folder value keeps its leading '/'.
--
--   KNOWN BUG: the [7] and [8] expressions are malformed — one inner CHARINDEX searches
--   inside an integer instead of Cat.Path, returns 0, and restarts the chain. As a result
--   [7] equals [6], so Folder 6 comes back empty for paths deeper than 6 levels, and
--   Folders 7–8 are wrong. Only matters if ISIGHT has folders 7+ levels deep.
--===========================================================================================
SELECT A.Name,[Description],Folders_Cnt,
-- Level 1: whole path if only one level deep, else up to (not including) the 2nd '/'
CASE WHEN Folders_Cnt = 1 THEN [Path]
	 ELSE SUBSTRING(A.Path,[1],[2]-1)
End [Folder 1],
-- Levels 2–7: if this is the last level, take from this '/' to end of path;
--             if deeper levels exist, take from this '/' up to the next one;
--             otherwise NULL (path isn't this deep)
CASE WHEN Folders_Cnt = 2 THEN SUBSTRING(A.Path,[2],LEN(path)-[2]+1)
	 WHEN Folders_Cnt > 2 THEN SUBSTRING(A.Path,[2],[3]-[2])
	 ELSE Null
End [Folder 2],
CASE WHEN Folders_Cnt = 3 THEN SUBSTRING(A.Path,[3],LEN(path)-[3]+1)
	 WHEN Folders_Cnt > 3 THEN SUBSTRING(A.Path,[3],[4]-[3])
	 ELSE Null
End [Folder 3],
CASE WHEN Folders_Cnt = 4 THEN SUBSTRING(A.Path,[4],LEN(path)-[4]+1)
	 WHEN Folders_Cnt > 4 THEN SUBSTRING(A.Path,[4],[5]-[4])
	 ELSE Null
End [Folder 4],
CASE WHEN Folders_Cnt = 5 THEN SUBSTRING(A.Path,[5],LEN(path)-[5]+1)
	 WHEN Folders_Cnt > 5 THEN SUBSTRING(A.Path,[5],[6]-[5])
	 ELSE Null
End [Folder 5],
CASE WHEN Folders_Cnt = 6 THEN SUBSTRING(A.Path,[6],LEN(path)-[6]+1)
	 WHEN Folders_Cnt > 6 THEN SUBSTRING(A.Path,[6],[7]-[6])
	 ELSE Null
End [Folder 6],
CASE WHEN Folders_Cnt = 7 THEN SUBSTRING(A.Path,[7],LEN(path)-[7]+1)
	 WHEN Folders_Cnt > 7 THEN SUBSTRING(A.Path,[7],[8]-[7])
	 ELSE Null
End [Folder 7],
-- Level 8: catch-all — everything from the 8th '/' to the end, however deep
CASE WHEN Folders_Cnt = 8 THEN SUBSTRING(A.Path,[8],LEN(path)-[8]+1)
	 WHEN Folders_Cnt > 8 THEN SUBSTRING(A.Path,[8],len(path)-[8]+1)
	 ELSE Null
End [Folder 8],
[Path],
-- Report Manager link: drop the leading '/', encode '/' as %2f and spaces as '+'
-- (only these two characters are encoded; &, #, % etc. in names would break the link)
@localhost + replace(replace(right([Path],LEN([Path])-1),'/','%2f'),' ','+') As [URL]
FROM (
		SELECT Name,[Description]
		-- Folder depth = number of '/' characters in the path
		,LEN(Cat.Path)-LEN(replace(Cat.Path,'/','')) Folders_Cnt
		-- Positions of the 1st through 8th '/' (0 = not found)
		,CHARINDEX('/',Cat.Path,1) [1]
		,CHARINDEX('/',Cat.Path,CHARINDEX('/',Cat.Path,1)+1) [2]
		,CHARINDEX('/',Cat.Path,CHARINDEX('/',Cat.Path,CHARINDEX('/',Cat.Path,1)+1)+1) [3]
		,CHARINDEX('/',Cat.Path,CHARINDEX('/',Cat.Path,CHARINDEX('/',Cat.Path,CHARINDEX('/',Cat.Path,1)+1)+1)+1) [4]
		,CHARINDEX('/',Cat.Path,CHARINDEX('/',Cat.Path,CHARINDEX('/',Cat.Path,CHARINDEX('/',Cat.Path,CHARINDEX('/',Cat.Path,1)+1)+1)+1)+1) [5]
		,CHARINDEX('/',Cat.Path,CHARINDEX('/',Cat.Path,CHARINDEX('/',Cat.Path,CHARINDEX('/',Cat.Path,CHARINDEX('/',Cat.Path,CHARINDEX('/',Cat.Path,1)+1)+1)+1)+1)+1) [6]
		-- [7] and [8] are malformed — see KNOWN BUG in the section header
		,CHARINDEX('/',Cat.Path,CHARINDEX('/',Cat.Path,CHARINDEX('/',Cat.Path,CHARINDEX('/',Cat.Path,CHARINDEX('/',Cat.Path,CHARINDEX('/',CHARINDEX('/',Cat.Path,1)+1,1)+1)+1)+1)+1)+1) [7]
		,CHARINDEX('/',Cat.Path,CHARINDEX('/',Cat.Path,CHARINDEX('/',Cat.Path,CHARINDEX('/',Cat.Path,CHARINDEX('/',Cat.Path,CHARINDEX('/',CHARINDEX('/',CHARINDEX('/',Cat.Path,1)+1,1)+1,1)+1)+1)+1)+1)+1) [8]
		,Cat.Path
		FROM [ReportServer].[dbo].[Catalog] Cat
		WHERE Cat.Type = 1               -- folders only
		AND Cat.Path like '/ISIGHT%'
		) A
Order by [Path]


--===========================================================================================
-- SECTION 4: Shared data sources under /ISIGHT
--   Connection definitions (server/database/credentials) that reports reference.
--===========================================================================================
SELECT Name,[Description],Cat.Path
FROM [ReportServer].[dbo].[Catalog] Cat
WHERE Cat.Type = 5                       -- shared data sources
AND Cat.Path like '/ISIGHT%'


--===========================================================================================
-- SECTION 5: Shared datasets under /ISIGHT
--   Reusable queries published separately from reports.
--===========================================================================================
SELECT Name,[Description],Cat.Path
FROM [ReportServer].[dbo].[Catalog] Cat
WHERE Cat.Type = 8                       -- shared datasets
AND Cat.Path like '/ISIGHT%'


--===========================================================================================
-- SECTION 6: Report execution log (detail)
--   One row per report execution in the date range, with time buckets for trending,
--   who ran it, output format, parameters, and performance timings.
--   Note: SSRS only retains ExecutionLog history for a limited period (default 60 days,
--   set by the ExecutionLogDaysKept server property), so an old start date returns
--   only what is still retained.
--===========================================================================================

-- Parameters
DECLARE @pStartDate datetime
DECLARE @pEndDate datetime
DECLARE @localhost varchar(300)
SET @pStartDate = '9/1/2012'
SET @pEndDate = GETDATE()+1              -- tomorrow, so everything up to now is included
SET @localhost = ''                      -- blank: URL column returns only the encoded path
DECLARE @path varchar(300)
SET @path = '/ISIGHT%'                   -- LIKE pattern for the folder to report on

SELECT
	RSCatalog.Path,
	RSCatalog.Name AS Report,
	ExecutionLog.TimeStart,
	-- [Week]: date (time stripped) of the Friday in the Sunday–Saturday week containing TimeStart.
	--   TimeStart - weekday# + 6 lands on that Friday when DATEFIRST = 7 (US default).
	--   CAST to varchar(12) drops the time portion; CONVERT turns it back into a datetime.
	--   Results shift if the server/session DATEFIRST setting differs.
	CONVERT(Datetime, CAST(DATEADD(day, -DATEPART(weekday,ExecutionLog.TimeStart), ExecutionLog.TimeStart)+6 as varchar(12)),108) As [Week],
	-- [Month]: first day of the month containing TimeStart (time stripped the same way)
	CONVERT(Datetime, CAST(DATEADD(DAY,-DATEPART(day,ExecutionLog.TimeStart)+1,ExecutionLog.TimeStart) as varchar(12)),108) As [Month],
	-- [Time]: TimeStart rounded down to the 30-minute slot (e.g. 14:47 -> 14:30), as a TIME value
	DATEADD(MINUTE,
	CASE WHEN DATEPART(MINUTE,ExecutionLog.TimeStart) >= 30 THEN 30 ELSE 0 END,
	cast(cast(DATEPART(Hour,ExecutionLog.TimeStart) as varchar(2))+':00:00.000' as time))
	As [Time],
	-- Strip the 'rs' prefix from the status code (e.g. 'rsSuccess' -> 'Success')
	right(ExecutionLog.STATUS,len(ExecutionLog.STATUS)-2) As [STATUS],
	-- RequestType 1 = subscription; everything else labeled 'User'
	-- (this also lumps cache refreshes, RequestType 2, in with users)
	CASE WHEN ExecutionLog.RequestType = 1 Then 'Subscription' Else 'User' END As RunType,
	CASE WHEN ExecutionLog.RequestType = 1 Then 'Subscription' Else ExecutionLog.UserName END As [Report User],
	ExecutionLog.Format,                 -- render format (HTML4.0, PDF, EXCEL, ...)
	ExecutionLog.Parameters	,            -- parameter values used for this run
	@localhost + replace(replace(right([Path],LEN([Path])-1),'/','%2f'),' ','+') As [URL],
	ExecutionLog.[TimeDataRetrieval],    -- ms spent running the dataset queries
	ExecutionLog.[TimeProcessing],       -- ms spent processing the report
	ExecutionLog.[TimeRendering],        -- ms spent rendering the output
	ExecutionLog.[ByteCount],            -- size of the rendered output
	ExecutionLog.[RowCount]              -- rows returned by the queries


FROM
	[ReportServer].[dbo].[Catalog] RSCatalog
	INNER JOIN [ReportServer].[dbo].[ExecutionLog] ExecutionLog
	ON ExecutionLog.ReportID = RSCatalog.ItemID
where RSCatalog.Path like @path
and (ExecutionLog.TimeStart between @pStartDate and @pEndDate)
and RSCatalog.Name <>'Data Feed' --Remove Later
AND RSCatalog.Type = 2                   -- reports only
order by  3 desc                         -- column 3 = TimeStart, newest first
--16768
--141464
-- (row counts from earlier runs, kept for reference)


--===========================================================================================
-- SECTION 7: Report schedules
--   Schedule definitions attached to reports (includes subscription schedules and
--   snapshot/cache schedules). Not filtered to /ISIGHT — returns the first 100 for the
--   whole server, ordered by report name.
--   Original note: "not sure how useful this is."
--
--   RecurrenceType: 1 = Once, 2 = Minute, 3 = Daily, 4 = Weekly,
--                   5 = Monthly (by day of month), 6 = Monthly (by week of month)
--   DaysOfWeek / DaysOfMonth are bitmasks, not readable day names.
--   Note: DaysInterval is selected twice.
--===========================================================================================
SELECT TOP 100 cat.Name,
 cat.[Path],
 LastRunTime,
 RecurrenceType,
 MinutesInterval,
 DaysInterval,
 DaysInterval,
 WeeksInterval,
 DaysOfWeek,
 DaysOfMonth,
 [Month],
 MonthlyWeek

FROM [ReportServer].dbo.Schedule sch
INNER JOIN [ReportServer].dbo.ReportSchedule rsch ON rsch.ScheduleID = sch.ScheduleID   -- links schedules to reports
INNER JOIN [ReportServer].dbo.Catalog cat On cat.ItemID = rsch.ReportID
Order by 1                               -- column 1 = report name


--===========================================================================================
-- SECTION 8: Top N most-run reports, broken out by week
--   Ranks reports by total runs over the whole date range, keeps the top @pTop,
--   then shows each one's run count per week.
--   Note: the original heading said "Top 20", but @pTop is set to 10.
--===========================================================================================

-- Parameters
DECLARE @pStartDate datetime
DECLARE @pEndDate datetime
DECLARE @localhost varchar(300)
SET @pStartDate = '9/1/2012'
SET @pEndDate = GETDATE()+1
SET @localhost = ''
DECLARE @path varchar(300)
SET @path = '/ISIGHT%'
DECLARE @pTop int
SET @pTop = 10                           -- number of reports to return

SELECT
	RSCatalog.Path,
	RSCatalog.Name AS Report,
	-- Week bucket (same logic as Section 6)
	CONVERT(Datetime, CAST(DATEADD(day, -DATEPART(weekday,ExecutionLog.TimeStart), ExecutionLog.TimeStart)+6 as varchar(12)),108) As [Week],
	@localhost + replace(replace(right([Path],LEN([Path])-1),'/','%2f'),' ','+') As [URL],
	count(*) Reports_Run,                -- runs of this report in this week
	Report_Rank                          -- overall rank across the full date range

FROM
	[ReportServer].[dbo].[Catalog] RSCatalog
	INNER JOIN [ReportServer].[dbo].[ExecutionLog] ExecutionLog
	ON ExecutionLog.ReportID = RSCatalog.ItemID
	-- TopReports: total runs per report over the full date range, ranked highest first
	-- (ties broken alphabetically by name). Same filters as the outer query.
	INNER JOIN (SELECT ReportID,COUNT(*) Report_Run,RSCatalog.Name
				,Row_number() Over (Order by COUNT(*) desc,RSCatalog.Name ) As Report_Rank
				FROM [ReportServer].[dbo].[ExecutionLog] ExecutionLog
				INNER JOIN [ReportServer].[dbo].[Catalog] RSCatalog ON ExecutionLog.ReportID = RSCatalog.ItemID
				WHERE RSCatalog.Path like @path
				AND TimeStart between @pStartDate and @pEndDate
				and RSCatalog.Name <>'Data Feed' --Remove Later
				AND RSCatalog.Type = 2
				GROUP BY ReportID,RSCatalog.Name
				) as TopReports ON TopReports.ReportID = RSCatalog.ItemID
where RSCatalog.Path like @path
and (ExecutionLog.TimeStart between @pStartDate and @pEndDate)
and RSCatalog.Name <>'Data Feed' --Remove Later
AND RSCatalog.Type = 2
AND Report_Rank <= @pTop                 -- keep only the top N reports

-- Group by report + week to get weekly run counts
-- (expressions are repeated because SELECT aliases can't be used in GROUP BY)
GROUP BY
	RSCatalog.Path,
	RSCatalog.Name,
	CONVERT(Datetime, CAST(DATEADD(day, -DATEPART(weekday,ExecutionLog.TimeStart), ExecutionLog.TimeStart)+6 as varchar(12)),108),
	@localhost + replace(replace(right([Path],LEN([Path])-1),'/','%2f'),' ','+') ,
	Report_Rank
order by Report_Rank,Reports_Run desc


--===========================================================================================
-- SECTION 9: Activity by week and time of day
--   Count of report runs per week, per 30-minute slot, split into Subscription vs User.
--   Useful for spotting peak load times and when subscriptions pile up.
--===========================================================================================

-- Parameters
DECLARE @pStartDate datetime
DECLARE @pEndDate datetime
DECLARE @localhost varchar(300)
SET @pStartDate = '9/1/2012'
SET @pEndDate = GETDATE()+1
SET @localhost = ''                      -- declared but not used in this section
DECLARE @path varchar(300)
SET @path = '/ISIGHT%'

SELECT
	-- Week bucket (same logic as Section 6)
	CONVERT(Datetime, CAST(DATEADD(day, -DATEPART(weekday,ExecutionLog.TimeStart), ExecutionLog.TimeStart)+6 as varchar(12)),108) As [Week],
	-- 30-minute time slot (same logic as Section 6)
	DATEADD(MINUTE,
	CASE WHEN DATEPART(MINUTE,ExecutionLog.TimeStart) >= 30 THEN 30 ELSE 0 END,
	cast(cast(DATEPART(Hour,ExecutionLog.TimeStart) as varchar(2))+':00:00.000' as time))
	As [Time],
	CASE WHEN ExecutionLog.RequestType = 1 Then 'Subscription' Else 'User' END As RunType,
	COUNT(*) Reports_Run

FROM
	[ReportServer].[dbo].[Catalog] RSCatalog
	INNER JOIN [ReportServer].[dbo].[ExecutionLog] ExecutionLog
	ON ExecutionLog.ReportID = RSCatalog.ItemID
where RSCatalog.Path like @path
and (ExecutionLog.TimeStart between @pStartDate and @pEndDate)
and RSCatalog.Name <>'Data Feed' --Remove Later
AND RSCatalog.Type = 2
-- Group by the same three expressions as the SELECT (week, time slot, run type)
GROUP BY
	CONVERT(Datetime, CAST(DATEADD(day, -DATEPART(weekday,ExecutionLog.TimeStart), ExecutionLog.TimeStart)+6 as varchar(12)),108),
	DATEADD(MINUTE,
	CASE WHEN DATEPART(MINUTE,ExecutionLog.TimeStart) >= 30 THEN 30 ELSE 0 END,
	cast(cast(DATEPART(Hour,ExecutionLog.TimeStart) as varchar(2))+':00:00.000' as time)),
	CASE WHEN ExecutionLog.RequestType = 1 Then 'Subscription' Else 'User' END