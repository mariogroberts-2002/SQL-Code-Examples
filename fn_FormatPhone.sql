CREATE OR ALTER FUNCTION dbo.fn_FormatPhone
(
    @PhoneNumber nvarchar(100)
)
RETURNS nvarchar(100)
AS
BEGIN
    DECLARE @Digits  nvarchar(100) = N'';
    DECLARE @Counter int = 1;
    DECLARE @Len     int = LEN(@PhoneNumber);

    IF @PhoneNumber IS NULL RETURN NULL;

    -- Keep only the characters 0-9.
    -- LIKE '[0-9]' replaces ISNUMERIC, which also accepts - + $ . , \
    -- (that's why the original needed the REPLACE chain afterward).
    WHILE @Counter <= @Len
    BEGIN
        IF SUBSTRING(@PhoneNumber, @Counter, 1) LIKE N'[0-9]'
            SET @Digits += SUBSTRING(@PhoneNumber, @Counter, 1);
        SET @Counter += 1;
    END;

    -- Format as (XXX) XXX-XXXX, plus " xNNN" for any digits beyond 10
    RETURN N'(' + LEFT(@Digits, 3) + N') '
         + SUBSTRING(@Digits, 4, 3) + N'-'
         + SUBSTRING(@Digits, 7, 4)
         + CASE WHEN LEN(@Digits) > 10
                THEN N' x' + SUBSTRING(@Digits, 11, 100)
                ELSE N'' END;
END;