using Company.Function;

namespace RegExAzFunc.Tests;

public class DownloadCapTests
{
    private static async IAsyncEnumerable<BlobEntry> Entries(int count, long each)
    {
        await Task.CompletedTask;
        for (int i = 0; i < count; i++) { yield return new BlobEntry($"f{i}.eml", each); }
    }

    private static async IAsyncEnumerable<BlobEntry> One(string name, long size)
    {
        await Task.CompletedTask;
        yield return new BlobEntry(name, size);
    }

    [Fact]
    public async Task Measure_totals_a_small_folder()
    {
        CapResult result = await DownloadCap.MeasureAsync(Entries(3, 100));

        Assert.Equal(3, result.Files);
        Assert.Equal(300, result.Bytes);
        Assert.True(result.WithinLimit);
    }

    [Fact]
    public async Task Measure_allows_exactly_the_file_limit()
    {
        CapResult result = await DownloadCap.MeasureAsync(Entries(DownloadCap.MaxFiles, 1));

        Assert.Equal(DownloadCap.MaxFiles, result.Files);
        Assert.True(result.WithinLimit);
    }

    [Fact]
    public async Task Measure_refuses_one_file_past_the_limit()
    {
        CapResult result = await DownloadCap.MeasureAsync(Entries(DownloadCap.MaxFiles + 1, 1));

        Assert.Equal(DownloadCap.MaxFiles + 1, result.Files);
        Assert.False(result.WithinLimit);
    }

    [Fact]
    public async Task Measure_refuses_on_bytes_even_when_the_file_count_is_tiny()
    {
        CapResult result = await DownloadCap.MeasureAsync(One("huge.pst", DownloadCap.MaxBytes + 1));

        Assert.Equal(1, result.Files);
        Assert.False(result.WithinLimit);
    }

    [Fact]
    public async Task Measure_allows_exactly_the_byte_limit()
    {
        CapResult result = await DownloadCap.MeasureAsync(One("big.zip", DownloadCap.MaxBytes));
        Assert.True(result.WithinLimit);
    }

    [Fact]
    public async Task Measure_stops_enumerating_once_it_is_over()
    {
        // UnsortedMatterCommunication holds 201,356 entries. If MeasureAsync ever enumerates
        // past the cap, this test hangs rather than fails - which is the failure we want
        // to be impossible in production.
        int yielded = 0;
        async IAsyncEnumerable<BlobEntry> endless()
        {
            await Task.CompletedTask;
            while (true) { yielded++; yield return new BlobEntry($"f{yielded}.eml", 1); }
        }

        CapResult result = await DownloadCap.MeasureAsync(endless());

        Assert.False(result.WithinLimit);
        Assert.Equal(DownloadCap.MaxFiles + 1, yielded);
    }
}
