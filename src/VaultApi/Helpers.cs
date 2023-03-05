namespace VaultApi;

public static class Helpers
{
    public static string DateWithTimeAndSeconds(this DateTime date, bool showSeconds = true)
    {
        string secondsString = null!;
        if (showSeconds)
        {
            var diff = date - DateTime.Now;
            if (Math.Floor(diff.TotalSeconds) == 0)
            {
                secondsString = " (now)";
            }
            else
            {
                secondsString = " (";
                if (Math.Floor(Math.Abs(diff.TotalDays)) > 0)
                    secondsString += $"{Math.Floor(Math.Abs(diff.TotalDays)):00} days ";
                if (Math.Floor(Math.Abs(diff.TotalHours)) > 0)
                    secondsString += $"{Math.Abs(diff.Hours):00} hours ";
                if (Math.Floor(Math.Abs(diff.TotalMinutes)) > 0)
                    secondsString += $"{Math.Abs(diff.Minutes):00} minutes ";
                secondsString += $"{Math.Abs(diff.Seconds):00} seconds ";
                secondsString = secondsString.Substring(0, secondsString.Length - 1) + ")";
                if (Math.Floor(diff.TotalSeconds) < 0)
                    secondsString += " (ago, from now)";
                else
                    secondsString += " (from now)";
            }
        }
        else
        {
            secondsString = "";
        }

        return $"{date.ToShortDateString()} {date.ToShortTimeString()}:{date.Second:00}{secondsString}";
    }
}