--DATES

--Returns the beginning of the Current Year
SELECT CONVERT(datetime,CAST(GETDATE() as varchar(12)),101)-DATEPART(DAYOFYEAR,getdate()-1) As [First day of Current Year]

--Returns the End of the Current Year
SELECT dateadd(year,1,CONVERT(datetime,CAST(GETDATE() as varchar(12)),101)-DATEPART(DAYOFYEAR,getdate())) As [Last day of Current Year]

--Returns the weekending (Friday) for a particular day
SELECT DATEADD(day, -DATEPART(weekday,GETDATE()), GETDATE())+6 As [Week Ending]
SELECT DATEADD(day,6,DATEADD(day, -DATEPART(weekday,GETDATE()), GETDATE())) As [Week Ending]

--Returns the week commencing (Monday) for a particular day
SELECT DATEADD(day, -DATEPART(weekday,GETDATE())+2, GETDATE()) As [Week Commencing]

--Returns the start of a month based on Todays date
SELECT CONVERT(Datetime, CAST(DATEADD(DAY,-DATEPART(day,GETDATE())+1,GETDATE()) as varchar(12)),108) As [Month]

--Returns the start of a month going back 3 months from Todays date
SELECT dateadd(dd,-day(CONVERT(datetime,CAST(GETDATE() as varchar(12)),101))+1,CONVERT(datetime,CAST(dateadd(month,-3,GETDATE()) as varchar(12)),101)) as [Start of a month going back 3 months from Todays date]

--Returns the end of a month based on Todays date
SELECT dateadd(dd,-day(CONVERT(datetime,CAST(GETDATE() as varchar(12)),101)),CONVERT(datetime,CAST(dateadd(month,1,GETDATE()) as varchar(12)),101)) As [End of a month based on Todays date]

--Returns the end of a month going foward 3 months based on Todays date
SELECT dateadd(dd,-day(CONVERT(datetime,CAST(GETDATE() as varchar(12)),101)),CONVERT(datetime,CAST(dateadd(month,4,GETDATE()) as varchar(12)),101)) As [End of a month going foward 3 months based on Todays date]

--Returns Time Only
SELECT CAST(GETDATE() As time) [Time Only]

--Rounds up to the nearest 30 minutes 
	SELECT
	DATEADD(MINUTE,
	CASE WHEN DATEPART(MINUTE,GETDATE()) >= 30 THEN 30 ELSE 0 END, 
	cast(cast(DATEPART(Hour,GETDATE()) as varchar(2))+':00:00.000' as time))
	As [Time to the nearest 30 mins]
	
--Selects the hour only and keeps it in a datetime format
SELECT cast(cast(DATEPART(Hour,GETDATE()) as varchar(2))+':00:00.000' as time) [Time rounded up to Hour]