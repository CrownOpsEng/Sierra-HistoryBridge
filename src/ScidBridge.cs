// SPDX-License-Identifier: MPL-2.0
using System;
using System.Collections.Generic;
using System.IO;

namespace SierraHistoryBridge
{
    public sealed class ScidMeta
    {
        public long Records;
        public long FirstDateTime;
        public long LastDateTime;
        public long Length;
    }

    public sealed class ScaleInference
    {
        public double Factor;
        public double MedianRatio;
        public int Samples;
    }

    public sealed class ConvertResult
    {
        public long SourceRecords;
        public long TailRecords;
        public long OutputRecords;
        public double ElapsedSeconds;
    }

    public static class ScidBridge
    {
        public const int HeaderSize = 56;
        public const int RecordSize = 40;

        private static readonly double[] CandidateScales =
            new double[] { 0.0001, 0.001, 0.01, 0.1, 1.0, 10.0, 100.0, 1000.0, 10000.0 };

        [System.Runtime.InteropServices.StructLayout(
            System.Runtime.InteropServices.LayoutKind.Explicit)]
        private struct FloatIntBits
        {
            [System.Runtime.InteropServices.FieldOffset(0)]
            public float FloatValue;

            [System.Runtime.InteropServices.FieldOffset(0)]
            public int IntValue;
        }

        private static void WriteSingleLittleEndian(
            byte[] buffer,
            int offset,
            float value)
        {
            var bits = new FloatIntBits { FloatValue = value };
            int raw = bits.IntValue;

            buffer[offset] = (byte)raw;
            buffer[offset + 1] = (byte)(raw >> 8);
            buffer[offset + 2] = (byte)(raw >> 16);
            buffer[offset + 3] = (byte)(raw >> 24);
        }

        private static void ValidateHeader(FileStream stream, string path)
        {
            if (stream.Length < HeaderSize)
                throw new IOException(Path.GetFileName(path) + ": file is too small to be SCID data.");

            byte[] header = new byte[HeaderSize];
            stream.Position = 0;
            ReadExact(stream, header, HeaderSize);

            if (header[0] != (byte)'S' || header[1] != (byte)'C' ||
                header[2] != (byte)'I' || header[3] != (byte)'D')
                throw new IOException(Path.GetFileName(path) + ": SCID header was not found.");

            int headerSize = BitConverter.ToInt32(header, 4);
            int recordSize = BitConverter.ToInt32(header, 8);

            if (headerSize != HeaderSize || recordSize != RecordSize)
                throw new IOException(
                    Path.GetFileName(path) + ": unsupported SCID layout. Expected 56-byte header and 40-byte records.");

            if ((stream.Length - HeaderSize) % RecordSize != 0)
                throw new IOException(Path.GetFileName(path) + ": file length is not aligned to SCID records.");
        }

        private static void ReadExact(FileStream stream, byte[] buffer, int count)
        {
            int offset = 0;
            while (offset < count)
            {
                int read = stream.Read(buffer, offset, count - offset);
                if (read <= 0)
                    throw new EndOfStreamException();
                offset += read;
            }
        }

        private static long ReadDateTimeAt(FileStream stream, long recordIndex)
        {
            byte[] buffer = new byte[8];
            stream.Position = HeaderSize + recordIndex * RecordSize;
            ReadExact(stream, buffer, 8);
            return BitConverter.ToInt64(buffer, 0);
        }

        private static float ReadCloseAt(FileStream stream, long recordIndex)
        {
            byte[] buffer = new byte[4];
            stream.Position = HeaderSize + recordIndex * RecordSize + 20;
            ReadExact(stream, buffer, 4);
            return BitConverter.ToSingle(buffer, 0);
        }

        public static ScidMeta GetMeta(string path)
        {
            using (var stream = new FileStream(
                path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite,
                1024 * 1024, FileOptions.RandomAccess))
            {
                ValidateHeader(stream, path);
                long records = (stream.Length - HeaderSize) / RecordSize;

                var result = new ScidMeta
                {
                    Records = records,
                    Length = stream.Length
                };

                if (records > 0)
                {
                    result.FirstDateTime = ReadDateTimeAt(stream, 0);
                    result.LastDateTime = ReadDateTimeAt(stream, records - 1);
                }

                return result;
            }
        }

        private static long LowerBound(FileStream stream, long count, long value, bool strictGreater)
        {
            long low = 0;
            long high = count;

            while (low < high)
            {
                long mid = low + ((high - low) >> 1);
                long dateTime = ReadDateTimeAt(stream, mid);
                bool moveRight = strictGreater ? dateTime <= value : dateTime < value;

                if (moveRight)
                    low = mid + 1;
                else
                    high = mid;
            }

            return low;
        }

        private static long NearestIndex(FileStream stream, long count, long value)
        {
            long index = LowerBound(stream, count, value, false);

            if (index <= 0)
                return 0;
            if (index >= count)
                return count - 1;

            long before = ReadDateTimeAt(stream, index - 1);
            long after = ReadDateTimeAt(stream, index);

            return Math.Abs(value - before) <= Math.Abs(after - value) ? index - 1 : index;
        }

        public static ScaleInference InferScale(string sourcePath, string targetPath)
        {
            using (var source = new FileStream(
                sourcePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite,
                1024 * 1024, FileOptions.RandomAccess))
            using (var target = new FileStream(
                targetPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite,
                1024 * 1024, FileOptions.RandomAccess))
            {
                ValidateHeader(source, sourcePath);
                ValidateHeader(target, targetPath);

                long sourceCount = (source.Length - HeaderSize) / RecordSize;
                long targetCount = (target.Length - HeaderSize) / RecordSize;

                if (sourceCount == 0 || targetCount == 0)
                    throw new IOException("Scale inference requires non-empty source and target SCID files.");

                long overlapStart = Math.Max(
                    ReadDateTimeAt(source, 0),
                    ReadDateTimeAt(target, 0));

                long overlapEnd = Math.Min(
                    ReadDateTimeAt(source, sourceCount - 1),
                    ReadDateTimeAt(target, targetCount - 1));

                if (overlapEnd <= overlapStart)
                    throw new IOException("No overlapping time range exists for scale inference.");

                var ratios = new List<double>();

                for (int sample = 0; sample < 257; sample++)
                {
                    long requestedTime = overlapStart +
                        (long)(((double)(overlapEnd - overlapStart) * sample) / 256.0);

                    long sourceIndex = NearestIndex(source, sourceCount, requestedTime);
                    long targetIndex = NearestIndex(target, targetCount, requestedTime);

                    double sourcePrice = ReadCloseAt(source, sourceIndex);
                    double targetPrice = ReadCloseAt(target, targetIndex);

                    if (sourcePrice > 0 && targetPrice > 0 &&
                        !Double.IsNaN(sourcePrice) && !Double.IsNaN(targetPrice))
                    {
                        ratios.Add(targetPrice / sourcePrice);
                    }
                }

                if (ratios.Count < 20)
                    throw new IOException("Not enough overlapping price samples to infer a scale.");

                ratios.Sort();
                double median = ratios[ratios.Count / 2];

                double bestFactor = CandidateScales[0];
                double bestDistance = Double.MaxValue;

                foreach (double candidate in CandidateScales)
                {
                    double distance = Math.Abs(Math.Log(candidate / median));
                    if (distance < bestDistance)
                    {
                        bestDistance = distance;
                        bestFactor = candidate;
                    }
                }

                if (Math.Abs(median - bestFactor) / bestFactor > 0.02)
                    throw new IOException(
                        "The observed raw-price ratio is not close enough to a supported power-of-ten scale.");

                return new ScaleInference
                {
                    Factor = bestFactor,
                    MedianRatio = median,
                    Samples = ratios.Count
                };
            }
        }

        private static void ShowProgress(
            long completedBytes,
            long totalBytes,
            ref int nextPercent,
            DateTime started)
        {
            if (totalBytes <= 0)
                return;

            int percent = (int)((completedBytes * 100L) / totalBytes);

            if (percent >= nextPercent || completedBytes >= totalBytes)
            {
                double seconds = Math.Max(0.001, (DateTime.UtcNow - started).TotalSeconds);
                double completedMb = completedBytes / 1048576.0;
                double totalMb = totalBytes / 1048576.0;
                double rate = completedMb / seconds;

                Console.WriteLine(
                    "      {0,3}%  {1,9:0.0} MB / {2,9:0.0} MB   {3,7:0.0} MB/s",
                    Math.Min(100, percent),
                    completedMb,
                    totalMb,
                    rate);

                while (nextPercent <= percent)
                    nextPercent += 5;
            }
        }

        private static void CopyRange(
            FileStream input,
            FileStream output,
            long bytes,
            long totalBytes,
            ref long completedBytes,
            ref int nextPercent,
            DateTime started)
        {
            byte[] buffer = new byte[16 * 1024 * 1024];

            while (bytes > 0)
            {
                int wanted = (int)Math.Min((long)buffer.Length, bytes);
                int read = input.Read(buffer, 0, wanted);

                if (read <= 0)
                    throw new EndOfStreamException();

                output.Write(buffer, 0, read);
                bytes -= read;
                completedBytes += read;

                ShowProgress(completedBytes, totalBytes, ref nextPercent, started);
            }
        }

        public static ConvertResult Convert(
            string sourcePath,
            string targetPath,
            double scale,
            string backupDirectory,
            double tailGuardSeconds)
        {
            DateTime started = DateTime.UtcNow;
            string temporaryPath = targetPath + ".scbridge.tmp";

            if (File.Exists(temporaryPath))
                File.Delete(temporaryPath);

            ScidMeta sourceMeta = GetMeta(sourcePath);

            if (sourceMeta.Records <= 0)
                throw new IOException("The SC Data source contains no records.");

            long tailIndex = 0;
            long tailRecords = 0;
            long tailBytes = 0;

            if (File.Exists(targetPath))
            {
                using (var target = new FileStream(
                    targetPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite,
                    1024 * 1024, FileOptions.RandomAccess))
                {
                    ValidateHeader(target, targetPath);

                    long targetCount = (target.Length - HeaderSize) / RecordSize;
                    long cutoff = sourceMeta.LastDateTime +
                        (long)Math.Round(tailGuardSeconds * 1000000.0);

                    tailIndex = LowerBound(target, targetCount, cutoff, true);
                    tailRecords = targetCount - tailIndex;
                    tailBytes = tailRecords * RecordSize;
                }
            }

            long sourcePayloadBytes = sourceMeta.Records * RecordSize;
            long totalWorkBytes = sourcePayloadBytes + tailBytes;
            long completedBytes = 0;
            int nextPercent = 0;

            try
            {
                using (var input = new FileStream(
                    sourcePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite,
                    16 * 1024 * 1024, FileOptions.SequentialScan))
                using (var output = new FileStream(
                    temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                    16 * 1024 * 1024, FileOptions.SequentialScan))
                {
                    byte[] header = new byte[HeaderSize];
                    ReadExact(input, header, HeaderSize);
                    output.Write(header, 0, HeaderSize);

                    const int RecordsPerChunk = 250000;
                    byte[] buffer = new byte[RecordsPerChunk * RecordSize];

                    long recordsRemaining = sourceMeta.Records;
                    long previousDateTime = Int64.MinValue;

                    while (recordsRemaining > 0)
                    {
                        int recordsThisChunk = (int)Math.Min((long)RecordsPerChunk, recordsRemaining);
                        int bytesThisChunk = recordsThisChunk * RecordSize;

                        ReadExact(input, buffer, bytesThisChunk);

                        for (int record = 0, offset = 0;
                             record < recordsThisChunk;
                             record++, offset += RecordSize)
                        {
                            long dateTime = BitConverter.ToInt64(buffer, offset);

                            if (dateTime < previousDateTime)
                                throw new IOException(
                                    "SC Data source timestamps are not monotonic.");

                            previousDateTime = dateTime;

                            float open = BitConverter.ToSingle(buffer, offset + 8);
                            float high = BitConverter.ToSingle(buffer, offset + 12);
                            float low = BitConverter.ToSingle(buffer, offset + 16);
                            float close = BitConverter.ToSingle(buffer, offset + 20);

                            // Open can be zero or a negative Sierra control marker
                            // for individual/unbundled trade records. Only positive
                            // Open values are prices.
                            if (open > 0)
                            {
                                WriteSingleLittleEndian(
                                    buffer,
                                    offset + 8,
                                    (float)(open * scale));
                            }

                            WriteSingleLittleEndian(
                                buffer,
                                offset + 12,
                                (float)(high * scale));

                            WriteSingleLittleEndian(
                                buffer,
                                offset + 16,
                                (float)(low * scale));

                            WriteSingleLittleEndian(
                                buffer,
                                offset + 20,
                                (float)(close * scale));
                        }

                        output.Write(buffer, 0, bytesThisChunk);
                        recordsRemaining -= recordsThisChunk;
                        completedBytes += bytesThisChunk;

                        ShowProgress(
                            completedBytes,
                            totalWorkBytes,
                            ref nextPercent,
                            started);
                    }

                    if (tailRecords > 0)
                    {
                        using (var target = new FileStream(
                            targetPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite,
                            16 * 1024 * 1024, FileOptions.SequentialScan))
                        {
                            target.Position = HeaderSize + tailIndex * RecordSize;

                            CopyRange(
                                target,
                                output,
                                tailBytes,
                                totalWorkBytes,
                                ref completedBytes,
                                ref nextPercent,
                                started);
                        }
                    }

                    output.Flush(true);
                }

                ScidMeta outputMeta = GetMeta(temporaryPath);
                long expectedRecords = sourceMeta.Records + tailRecords;

                if (outputMeta.Records != expectedRecords)
                    throw new IOException("Output record-count validation failed.");

                if (outputMeta.FirstDateTime != sourceMeta.FirstDateTime)
                    throw new IOException("Output first-timestamp validation failed.");

                long[] sampleIndexes =
                    new long[] { 0, sourceMeta.Records / 2, sourceMeta.Records - 1 };

                using (var source = new FileStream(
                    sourcePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite,
                    1024 * 1024, FileOptions.RandomAccess))
                using (var output = new FileStream(
                    temporaryPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite,
                    1024 * 1024, FileOptions.RandomAccess))
                {
                    long previousIndex = -1;

                    foreach (long index in sampleIndexes)
                    {
                        if (index == previousIndex)
                            continue;

                        ValidateSample(source, output, index, scale);
                        previousIndex = index;
                    }
                }

                if (File.Exists(targetPath))
                {
                    Directory.CreateDirectory(backupDirectory);
                    string backupPath =
                        Path.Combine(backupDirectory, Path.GetFileName(targetPath) + ".bak");

                    if (File.Exists(backupPath))
                        File.Delete(backupPath);

                    File.Replace(temporaryPath, targetPath, backupPath, true);
                }
                else
                {
                    File.Move(temporaryPath, targetPath);
                }

                return new ConvertResult
                {
                    SourceRecords = sourceMeta.Records,
                    TailRecords = tailRecords,
                    OutputRecords = expectedRecords,
                    ElapsedSeconds = (DateTime.UtcNow - started).TotalSeconds
                };
            }
            catch
            {
                if (File.Exists(temporaryPath))
                {
                    try { File.Delete(temporaryPath); }
                    catch { }
                }

                throw;
            }
        }

        private static void ValidateSample(
            FileStream source,
            FileStream output,
            long recordIndex,
            double scale)
        {
            byte[] sourceRecord = new byte[RecordSize];
            byte[] outputRecord = new byte[RecordSize];

            source.Position = HeaderSize + recordIndex * RecordSize;
            output.Position = HeaderSize + recordIndex * RecordSize;

            ReadExact(source, sourceRecord, RecordSize);
            ReadExact(output, outputRecord, RecordSize);

            if (BitConverter.ToInt64(sourceRecord, 0) != BitConverter.ToInt64(outputRecord, 0))
                throw new IOException("Timestamp validation failed.");

            for (int offset = 24; offset <= 36; offset += 4)
            {
                if (BitConverter.ToUInt32(sourceRecord, offset) !=
                    BitConverter.ToUInt32(outputRecord, offset))
                    throw new IOException("Trade/volume field validation failed.");
            }

            float sourceOpen = BitConverter.ToSingle(sourceRecord, 8);

            if (sourceOpen <= 0 &&
                BitConverter.ToInt32(sourceRecord, 8) != BitConverter.ToInt32(outputRecord, 8))
                throw new IOException("A Sierra Open-field control marker changed.");

            float sourceClose = BitConverter.ToSingle(sourceRecord, 20);
            float outputClose = BitConverter.ToSingle(outputRecord, 20);
            float expectedClose = (float)(sourceClose * scale);

            if (Math.Abs(outputClose - expectedClose) > 0.02)
                throw new IOException("Scaled price validation failed.");
        }
    }
}
