// SPDX-License-Identifier: MPL-2.0
using System;
using System.Collections.Generic;
using System.IO;
using System.Globalization;
using System.Text;
using System.IO.Compression;
using System.Security.Cryptography;

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

    public sealed class ScidFileValidation
    {
        public long Records;
        public long FirstDateTime;
        public long LastDateTime;
        public long Length;
        public long WriteTimeUtcTicks;
        public long OutOfOrderRecords;
        public long RichRecords;
        public long ControlOpenRecords;
        public long UnclassifiedVolumeRecords;
        public double RichPercent;
        public double ElapsedSeconds;
    }

    public sealed class ScidPairValidation
    {
        public long SourceRecords;
        public long TargetRecords;
        public long SourceFirstDateTime;
        public long SourceLastDateTime;
        public long TargetFirstDateTime;
        public long TargetLastDateTime;
        public long SourceLength;
        public long TargetLength;
        public long SourceWriteTimeUtcTicks;
        public long TargetWriteTimeUtcTicks;

        public long SourceOutOfOrderRecords;
        public long TargetOutOfOrderRecords;
        public long SourceRichRecords;
        public long TargetRichRecords;
        public long SourceControlOpenRecords;
        public long TargetControlOpenRecords;
        public long SourceUnclassifiedVolumeRecords;
        public long TargetUnclassifiedVolumeRecords;

        public long SourceOverlapSeconds;
        public long TargetOverlapSeconds;
        public long CommonSeconds;
        public long SourceOnlySeconds;
        public long TargetOnlySeconds;
        public long CommonVolumeEqualSeconds;
        public long CommonBidEqualSeconds;
        public long CommonAskEqualSeconds;
        public long CommonLastPriceEqualSeconds;
        public long SourceOverlapVolume;
        public long TargetOverlapVolume;

        public double CommonCoveragePercent;
        public double VolumeMatchPercent;
        public double BidMatchPercent;
        public double AskMatchPercent;
        public double LastPriceMatchPercent;
        public double AggregateVolumeDifferencePercent;
        public double SourceRichPercent;
        public double TargetRichPercent;
        public double ElapsedSeconds;
    }

    public sealed class GzipArchiveResult
    {
        public long OriginalBytes;
        public long ArchiveBytes;
        public string Sha256;
        public double ElapsedSeconds;
    }

    public sealed class ConvertResult
    {
        public long SourceRecords;
        public long SourceRecordsWritten;
        public long TailRecords;
        public long OutputRecords;
        public long HandoffDateTime;
        public int HandoffVerifiedTradeSeconds;
        public double ElapsedSeconds;
        public double ConversionSeconds;
        public double FlushSeconds;
        public double ValidationSeconds;
        public double ReplaceSeconds;

        public long OutOfOrderRecords;
        public long FirstOutOfOrderIndex;
        public long FirstPriorDateTime;
        public long FirstOutOfOrderDateTime;
        public long LargestBackwardMicroseconds;
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

        private static void ReadExact(Stream stream, byte[] buffer, int count)
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

        private static void ValidateSequentialHeader(
            Stream stream,
            long uncompressedLength,
            string label)
        {
            if (uncompressedLength < HeaderSize)
                throw new IOException(
                    Path.GetFileName(label) +
                    ": archived file is too small to be SCID data.");

            if ((uncompressedLength - HeaderSize) % RecordSize != 0)
                throw new IOException(
                    Path.GetFileName(label) +
                    ": archived file length is not aligned to SCID records.");

            byte[] header = new byte[HeaderSize];
            ReadExact(stream, header, HeaderSize);

            if (header[0] != (byte)'S' || header[1] != (byte)'C' ||
                header[2] != (byte)'I' || header[3] != (byte)'D')
                throw new IOException(
                    Path.GetFileName(label) +
                    ": SCID header was not found in archive.");

            int headerSize = BitConverter.ToInt32(header, 4);
            int recordSize = BitConverter.ToInt32(header, 8);

            if (headerSize != HeaderSize || recordSize != RecordSize)
                throw new IOException(
                    Path.GetFileName(label) +
                    ": unsupported archived SCID layout.");
        }

        private static string BytesToHex(byte[] bytes)
        {
            var builder = new StringBuilder(bytes.Length * 2);

            for (int i = 0; i < bytes.Length; i++)
                builder.Append(bytes[i].ToString("x2"));

            return builder.ToString();
        }

        private static string HashDecompressedGzip(
            string archivePath,
            out long uncompressedBytes)
        {
            uncompressedBytes = 0;
            byte[] buffer = new byte[8 * 1024 * 1024];

            using (var input = new FileStream(
                archivePath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                8 * 1024 * 1024,
                FileOptions.SequentialScan))
            using (var gzip = new GZipStream(
                input,
                CompressionMode.Decompress))
            using (var sha = SHA256.Create())
            {
                int read;

                while ((read = gzip.Read(buffer, 0, buffer.Length)) > 0)
                {
                    sha.TransformBlock(
                        buffer,
                        0,
                        read,
                        buffer,
                        0);

                    uncompressedBytes += read;
                }

                sha.TransformFinalBlock(
                    new byte[0],
                    0,
                    0);

                return BytesToHex(sha.Hash);
            }
        }

        public static GzipArchiveResult ArchiveFileGzipVerified(
            string sourcePath,
            string archivePath,
            bool deleteSource,
            bool replaceExisting)
        {
            try
            {
                DateTime started =
                    DateTime.UtcNow;

                var sourceInfo =
                    new FileInfo(sourcePath);

                long sourceLength =
                    sourceInfo.Length;

                DateTime sourceWriteTime =
                    sourceInfo.LastWriteTimeUtc;

                string archiveDirectory =
                    Path.GetDirectoryName(
                        archivePath);

                if (!String.IsNullOrEmpty(
                    archiveDirectory))
                    Directory.CreateDirectory(
                        archiveDirectory);

                string temporaryPath =
                    archivePath + ".tmp";

                if (File.Exists(temporaryPath))
                    File.Delete(temporaryPath);

                byte[] buffer =
                    new byte[1024 * 1024];

                string sourceHash;

                using (var source =
                    new FileStream(
                        sourcePath,
                        FileMode.Open,
                        FileAccess.Read,
                        FileShare.ReadWrite,
                        1024 * 1024,
                        FileOptions.SequentialScan))
                using (var output =
                    new FileStream(
                        temporaryPath,
                        FileMode.CreateNew,
                        FileAccess.Write,
                        FileShare.None,
                        1024 * 1024,
                        FileOptions.SequentialScan))
                using (var sha =
                    SHA256.Create())
                {
                    using (var gzip =
                        new GZipStream(
                            output,
                            CompressionMode.Compress,
                            true))
                    {
                        int read;

                        while ((read =
                            source.Read(
                                buffer,
                                0,
                                buffer.Length)) > 0)
                        {
                            sha.TransformBlock(
                                buffer,
                                0,
                                read,
                                buffer,
                                0);

                            gzip.Write(
                                buffer,
                                0,
                                read);
                        }

                        sha.TransformFinalBlock(
                            new byte[0],
                            0,
                            0);
                    }

                    output.Flush(true);
                    sourceHash =
                        BytesToHex(sha.Hash);
                }

                var sourceInfoAfter =
                    new FileInfo(sourcePath);

                if (sourceInfoAfter.Length !=
                        sourceLength ||
                    sourceInfoAfter.LastWriteTimeUtc !=
                        sourceWriteTime)
                {
                    File.Delete(temporaryPath);

                    throw new IOException(
                        "Archive source changed while it was being compressed.");
                }

                long verifiedBytes;
                string verifiedHash =
                    HashDecompressedGzip(
                        temporaryPath,
                        out verifiedBytes);

                if (verifiedBytes !=
                        sourceLength ||
                    !String.Equals(
                        sourceHash,
                        verifiedHash,
                        StringComparison.OrdinalIgnoreCase))
                {
                    File.Delete(temporaryPath);

                    throw new IOException(
                        "Compressed archive verification failed.");
                }

                if (File.Exists(archivePath))
                {
                    if (!replaceExisting)
                    {
                        long existingBytes;
                        string existingHash =
                            HashDecompressedGzip(
                                archivePath,
                                out existingBytes);

                        if (existingBytes !=
                                sourceLength ||
                            !String.Equals(
                                existingHash,
                                sourceHash,
                                StringComparison.OrdinalIgnoreCase))
                        {
                            File.Delete(
                                temporaryPath);

                            throw new IOException(
                                "An existing archive contains different data.");
                        }

                        File.Delete(
                            temporaryPath);
                    }
                    else
                    {
                        string oldArchive =
                            archivePath +
                            ".old";

                        if (File.Exists(
                            oldArchive))
                            File.Delete(
                                oldArchive);

                        File.Replace(
                            temporaryPath,
                            archivePath,
                            oldArchive,
                            true);

                        if (File.Exists(
                            oldArchive))
                            File.Delete(
                                oldArchive);
                    }
                }
                else
                {
                    File.Move(
                        temporaryPath,
                        archivePath);
                }

                string metadataPath =
                    archivePath + ".meta";

                string metadataTemporary =
                    metadataPath + ".tmp";

                if (File.Exists(
                    metadataTemporary))
                    File.Delete(
                        metadataTemporary);

                string originalName =
                    archivePath.EndsWith(
                        ".gz",
                        StringComparison.OrdinalIgnoreCase)
                    ? Path.GetFileName(
                        archivePath.Substring(
                            0,
                            archivePath.Length - 3))
                    : Path.GetFileName(
                        sourcePath);

                File.WriteAllLines(
                    metadataTemporary,
                    new string[]
                    {
                        "version=1",
                        "original_name=" +
                            originalName,
                        "original_bytes=" +
                            sourceLength.ToString(
                                CultureInfo.InvariantCulture),
                        "original_write_ticks=" +
                            sourceWriteTime.Ticks.ToString(
                                CultureInfo.InvariantCulture),
                        "sha256=" +
                            sourceHash
                    },
                    new UTF8Encoding(false));

                if (File.Exists(metadataPath))
                {
                    string oldMetadata =
                        metadataPath +
                        ".old";

                    if (File.Exists(
                        oldMetadata))
                        File.Delete(
                            oldMetadata);

                    File.Replace(
                        metadataTemporary,
                        metadataPath,
                        oldMetadata,
                        true);

                    if (File.Exists(
                        oldMetadata))
                        File.Delete(
                            oldMetadata);
                }
                else
                {
                    File.Move(
                        metadataTemporary,
                        metadataPath);
                }

                if (deleteSource)
                    File.Delete(
                        sourcePath);

                return new GzipArchiveResult
                {
                    OriginalBytes =
                        sourceLength,
                    ArchiveBytes =
                        new FileInfo(
                            archivePath).Length,
                    Sha256 =
                        sourceHash,
                    ElapsedSeconds =
                        (DateTime.UtcNow -
                            started).TotalSeconds
                };
            }
            catch
            {
                string failedArchiveTemporary =
                    archivePath + ".tmp";

                string failedMetadataTemporary =
                    archivePath +
                    ".meta.tmp";

                try
                {
                    if (File.Exists(
                        failedArchiveTemporary))
                        File.Delete(
                            failedArchiveTemporary);
                }
                catch { }

                try
                {
                    if (File.Exists(
                        failedMetadataTemporary))
                        File.Delete(
                            failedMetadataTemporary);
                }
                catch { }

                throw;
            }
        }

        public static GzipArchiveResult ArchiveScidGzipVerified(
            string sourcePath,
            string archivePath,
            bool deleteSource,
            bool replaceExisting)
        {
            try
            {

                DateTime started = DateTime.UtcNow;

                ScidMeta sourceMeta = GetMeta(sourcePath);
                DateTime originalWriteTime =
                    File.GetLastWriteTimeUtc(sourcePath);

                string archiveDirectory =
                    Path.GetDirectoryName(archivePath);

                if (!String.IsNullOrEmpty(archiveDirectory))
                    Directory.CreateDirectory(archiveDirectory);

                string temporaryPath =
                    archivePath + ".tmp";

                if (File.Exists(temporaryPath))
                    File.Delete(temporaryPath);

                byte[] buffer = new byte[8 * 1024 * 1024];
                string sourceHash;

                using (var source = new FileStream(
                    sourcePath,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.ReadWrite,
                    8 * 1024 * 1024,
                    FileOptions.SequentialScan))
                using (var output = new FileStream(
                    temporaryPath,
                    FileMode.CreateNew,
                    FileAccess.Write,
                    FileShare.None,
                    8 * 1024 * 1024,
                    FileOptions.SequentialScan))
                using (var sha = SHA256.Create())
                {
                    using (var gzip = new GZipStream(
                        output,
                        CompressionMode.Compress,
                        true))
                    {
                        int read;

                        while ((read = source.Read(
                            buffer,
                            0,
                            buffer.Length)) > 0)
                        {
                            sha.TransformBlock(
                                buffer,
                                0,
                                read,
                                buffer,
                                0);

                            gzip.Write(
                                buffer,
                                0,
                                read);
                        }

                        sha.TransformFinalBlock(
                            new byte[0],
                            0,
                            0);
                    }

                    output.Flush(true);
                    sourceHash = BytesToHex(sha.Hash);
                }

                ScidMeta sourceMetaAfter =
                    GetMeta(sourcePath);

                DateTime originalWriteTimeAfter =
                    File.GetLastWriteTimeUtc(sourcePath);

                if (sourceMetaAfter.Length != sourceMeta.Length ||
                    sourceMetaAfter.Records != sourceMeta.Records ||
                    sourceMetaAfter.FirstDateTime != sourceMeta.FirstDateTime ||
                    sourceMetaAfter.LastDateTime != sourceMeta.LastDateTime ||
                    originalWriteTimeAfter != originalWriteTime)
                {
                    File.Delete(temporaryPath);

                    throw new IOException(
                        "Archive source changed while it was being compressed.");
                }

                long verifiedBytes;
                string verifiedHash =
                    HashDecompressedGzip(
                        temporaryPath,
                        out verifiedBytes);

                if (verifiedBytes != sourceMeta.Length ||
                    !String.Equals(
                        sourceHash,
                        verifiedHash,
                        StringComparison.OrdinalIgnoreCase))
                {
                    File.Delete(temporaryPath);

                    throw new IOException(
                        "Compressed archive verification failed.");
                }

                if (File.Exists(archivePath))
                {
                    if (!replaceExisting)
                    {
                        long existingBytes;
                        string existingHash =
                            HashDecompressedGzip(
                                archivePath,
                                out existingBytes);

                        if (existingBytes != sourceMeta.Length ||
                            !String.Equals(
                                existingHash,
                                sourceHash,
                                StringComparison.OrdinalIgnoreCase))
                        {
                            File.Delete(temporaryPath);

                            throw new IOException(
                                "An existing archive contains different data.");
                        }

                        File.Delete(temporaryPath);
                    }
                    else
                    {
                        string oldArchive =
                            archivePath + ".old";

                        if (File.Exists(oldArchive))
                            File.Delete(oldArchive);

                        File.Replace(
                            temporaryPath,
                            archivePath,
                            oldArchive,
                            true);

                        if (File.Exists(oldArchive))
                            File.Delete(oldArchive);
                    }
                }
                else
                {
                    File.Move(
                        temporaryPath,
                        archivePath);
                }

                string metadataPath =
                    archivePath + ".meta";

                string metadataTemporary =
                    metadataPath + ".tmp";

                if (File.Exists(metadataTemporary))
                    File.Delete(metadataTemporary);

                File.WriteAllLines(
                    metadataTemporary,
                    new string[]
                    {
                        "version=1",
                        "original_name=" +
                            (
                                archivePath.EndsWith(
                                    ".gz",
                                    StringComparison.OrdinalIgnoreCase)
                                ? Path.GetFileName(
                                    archivePath.Substring(
                                        0,
                                        archivePath.Length - 3))
                                : Path.GetFileName(sourcePath)
                            ),
                        "original_bytes=" +
                            sourceMeta.Length.ToString(
                                CultureInfo.InvariantCulture),
                        "records=" +
                            sourceMeta.Records.ToString(
                                CultureInfo.InvariantCulture),
                        "first_datetime=" +
                            sourceMeta.FirstDateTime.ToString(
                                CultureInfo.InvariantCulture),
                        "last_datetime=" +
                            sourceMeta.LastDateTime.ToString(
                                CultureInfo.InvariantCulture),
                        "original_write_ticks=" +
                            originalWriteTime.Ticks.ToString(
                                CultureInfo.InvariantCulture),
                        "sha256=" + sourceHash
                    },
                    new UTF8Encoding(false));

                if (File.Exists(metadataPath))
                {
                    string oldMetadata =
                        metadataPath + ".old";

                    if (File.Exists(oldMetadata))
                        File.Delete(oldMetadata);

                    File.Replace(
                        metadataTemporary,
                        metadataPath,
                        oldMetadata,
                        true);

                    if (File.Exists(oldMetadata))
                        File.Delete(oldMetadata);
                }
                else
                {
                    File.Move(
                        metadataTemporary,
                        metadataPath);
                }

                if (deleteSource)
                    File.Delete(sourcePath);

                return new GzipArchiveResult
                {
                    OriginalBytes = sourceMeta.Length,
                    ArchiveBytes =
                        new FileInfo(archivePath).Length,
                    Sha256 = sourceHash,
                    ElapsedSeconds =
                        (DateTime.UtcNow - started).TotalSeconds
                };
                    }
            catch
            {
                string failedArchiveTemporary =
                    archivePath + ".tmp";

                string failedMetadataTemporary =
                    archivePath + ".meta.tmp";

                try
                {
                    if (File.Exists(failedArchiveTemporary))
                        File.Delete(failedArchiveTemporary);
                }
                catch { }

                try
                {
                    if (File.Exists(failedMetadataTemporary))
                        File.Delete(failedMetadataTemporary);
                }
                catch { }

                throw;
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

        public static string FormatScDateTime(long value)
        {
            try
            {
                DateTime epoch =
                    new DateTime(1899, 12, 30, 0, 0, 0, DateTimeKind.Utc);

                return epoch
                    .AddTicks(checked(value * 10L))
                    .ToString("yyyy-MM-dd HH:mm:ss.ffffff 'UTC'");
            }
            catch
            {
                return value.ToString();
            }
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

        private struct SecondAggregate
        {
            public long Second;
            public long Volume;
            public long BidVolume;
            public long AskVolume;
            public float LastClose;
        }

        private static Dictionary<long, SecondAggregate> LoadSecondAggregates(
            FileStream stream,
            long recordCount,
            long firstSecond,
            long lastSecond)
        {
            var result = new Dictionary<long, SecondAggregate>();

            if (recordCount <= 0 || lastSecond < firstSecond)
                return result;

            long firstIndex = LowerBound(
                stream,
                recordCount,
                checked(firstSecond * 1000000L),
                false);

            long afterLastIndex = LowerBound(
                stream,
                recordCount,
                checked((lastSecond + 1L) * 1000000L),
                false);

            long recordsRemaining = afterLastIndex - firstIndex;
            stream.Position = HeaderSize + firstIndex * RecordSize;

            const int RecordsPerChunk = 100000;
            byte[] buffer = new byte[RecordsPerChunk * RecordSize];

            while (recordsRemaining > 0)
            {
                int recordsThisChunk = (int)Math.Min(
                    (long)RecordsPerChunk,
                    recordsRemaining);

                int bytesThisChunk = recordsThisChunk * RecordSize;
                ReadExact(stream, buffer, bytesThisChunk);

                for (int record = 0, offset = 0;
                    record < recordsThisChunk;
                    record++, offset += RecordSize)
                {
                    long second = BitConverter.ToInt64(buffer, offset) / 1000000L;
                    SecondAggregate aggregate;

                    if (!result.TryGetValue(second, out aggregate))
                        aggregate = new SecondAggregate { Second = second };

                    aggregate.Volume += BitConverter.ToUInt32(buffer, offset + 28);
                    aggregate.BidVolume += BitConverter.ToUInt32(buffer, offset + 32);
                    aggregate.AskVolume += BitConverter.ToUInt32(buffer, offset + 36);
                    aggregate.LastClose = BitConverter.ToSingle(buffer, offset + 20);
                    result[second] = aggregate;
                }

                recordsRemaining -= recordsThisChunk;
            }

            return result;
        }

        private static bool HandoffSecondMatches(
            SecondAggregate source,
            SecondAggregate target,
            double scale)
        {
            if (source.Volume != target.Volume ||
                source.BidVolume != target.BidVolume ||
                source.AskVolume != target.AskVolume)
                return false;

            return Math.Abs(
                (double)source.LastClose * scale -
                (double)target.LastClose) <= 0.001;
        }

        private static bool ShouldPreserveTargetTail(
            string sourcePath,
            string targetPath,
            ScidMeta sourceMeta,
            ScidMeta targetMeta,
            double scale)
        {
            if (sourceMeta.Records <= 0 || targetMeta.Records <= 0)
                return false;

            long sourceLastSecond = sourceMeta.LastDateTime / 1000000L;
            long targetLastSecond = targetMeta.LastDateTime / 1000000L;

            if (targetLastSecond > sourceLastSecond)
                return true;
            if (targetLastSecond < sourceLastSecond)
                return false;

            using (var source = new FileStream(
                sourcePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite,
                1024 * 1024, FileOptions.RandomAccess))
            using (var target = new FileStream(
                targetPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite,
                1024 * 1024, FileOptions.RandomAccess))
            {
                ValidateHeader(source, sourcePath);
                ValidateHeader(target, targetPath);

                Dictionary<long, SecondAggregate> sourceSeconds =
                    LoadSecondAggregates(
                        source,
                        sourceMeta.Records,
                        sourceLastSecond,
                        sourceLastSecond);

                Dictionary<long, SecondAggregate> targetSeconds =
                    LoadSecondAggregates(
                        target,
                        targetMeta.Records,
                        targetLastSecond,
                        targetLastSecond);

                SecondAggregate sourceSecond;
                SecondAggregate targetSecond;

                if (!sourceSeconds.TryGetValue(sourceLastSecond, out sourceSecond) ||
                    !targetSeconds.TryGetValue(targetLastSecond, out targetSecond))
                {
                    throw new IOException(
                        "LIVE_MERGE_ENDPOINT_INVALID: the final SCID second could not be aggregated.");
                }

                if (HandoffSecondMatches(sourceSecond, targetSecond, scale))
                    return false;

                return targetSecond.Volume > sourceSecond.Volume;
            }
        }

        private static long FindVerifiedHandoffDateTime(
            string sourcePath,
            string targetPath,
            ScidMeta sourceMeta,
            ScidMeta targetMeta,
            double scale,
            out int verifiedTradeSeconds)
        {
            verifiedTradeSeconds = 0;

            long sourceFirstSecond = sourceMeta.FirstDateTime / 1000000L;
            long sourceLastSecond = sourceMeta.LastDateTime / 1000000L;
            long targetFirstSecond = targetMeta.FirstDateTime / 1000000L;
            long targetLastSecond = targetMeta.LastDateTime / 1000000L;
            long newestSecond = Math.Min(sourceLastSecond, targetLastSecond);
            long oldestPossible = Math.Max(sourceFirstSecond, targetFirstSecond);

            if (newestSecond < oldestPossible)
                return 0;

            int[] windows = new int[] { 300, 3600, 21600 };

            using (var source = new FileStream(
                sourcePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite,
                1024 * 1024, FileOptions.RandomAccess))
            using (var target = new FileStream(
                targetPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite,
                1024 * 1024, FileOptions.RandomAccess))
            {
                ValidateHeader(source, sourcePath);
                ValidateHeader(target, targetPath);

                foreach (int windowSeconds in windows)
                {
                    long firstSecond = Math.Max(
                        oldestPossible,
                        newestSecond - (long)windowSeconds + 1L);

                    Dictionary<long, SecondAggregate> sourceSeconds =
                        LoadSecondAggregates(
                            source,
                            sourceMeta.Records,
                            firstSecond,
                            newestSecond);

                    Dictionary<long, SecondAggregate> targetSeconds =
                        LoadSecondAggregates(
                            target,
                            targetMeta.Records,
                            firstSecond,
                            newestSecond);

                    int run = 0;
                    long newestInRun = 0;

                    for (long second = newestSecond;
                        second >= firstSecond;
                        second--)
                    {
                        SecondAggregate sourceSecond;
                        SecondAggregate targetSecond;
                        bool haveSource = sourceSeconds.TryGetValue(second, out sourceSecond);
                        bool haveTarget = targetSeconds.TryGetValue(second, out targetSecond);

                        if (!haveSource && !haveTarget)
                            continue;

                        if (haveSource && haveTarget &&
                            HandoffSecondMatches(sourceSecond, targetSecond, scale))
                        {
                            if (run == 0)
                                newestInRun = second;

                            run++;

                            if (run >= 3)
                            {
                                verifiedTradeSeconds = run;
                                return checked(newestInRun * 1000000L);
                            }
                        }
                        else
                        {
                            run = 0;
                            newestInRun = 0;
                        }
                    }

                    if (firstSecond == oldestPossible)
                        break;
                }
            }

            return 0;
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

        private struct RawScidRecord
        {
            public long DateTime;
            public float Open;
            public float High;
            public float Low;
            public float Close;
            public uint NumTrades;
            public uint TotalVolume;
            public uint BidVolume;
            public uint AskVolume;
        }

        private sealed class SequentialRecordReader : IDisposable
        {
            private readonly Stream _stream;
            private readonly byte[] _buffer;
            private readonly long _records;
            private long _recordsRead;
            private int _bufferOffset;
            private int _bufferBytes;
            private bool _hasPending;
            private RawScidRecord _pending;
            private long _previousDateTime = Int64.MinValue;

            public long OutOfOrderRecords;
            public long RichRecords;
            public long ControlOpenRecords;
            public long UnclassifiedVolumeRecords;

            public long RecordsRead
            {
                get { return _recordsRead; }
            }

            public long Records
            {
                get { return _records; }
            }

            public SequentialRecordReader(string path)
            {
                var file = new FileStream(
                    path,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.ReadWrite,
                    8 * 1024 * 1024,
                    FileOptions.SequentialScan);

                ValidateHeader(file, path);
                _records =
                    (file.Length - HeaderSize) /
                    RecordSize;

                file.Position = HeaderSize;
                _stream = file;
                _buffer =
                    new byte[100000 * RecordSize];
            }

            public SequentialRecordReader(
                Stream stream,
                long uncompressedLength,
                string label)
            {
                ValidateSequentialHeader(
                    stream,
                    uncompressedLength,
                    label);

                _records =
                    (uncompressedLength - HeaderSize) /
                    RecordSize;

                _stream = stream;
                _buffer =
                    new byte[100000 * RecordSize];
            }

            private bool TryReadRecord(out RawScidRecord record)
            {
                if (_recordsRead >= _records)
                {
                    record = new RawScidRecord();
                    return false;
                }

                if (_bufferOffset >= _bufferBytes)
                {
                    long remaining = _records - _recordsRead;
                    int recordsToRead =
                        (int)Math.Min(100000L, remaining);
                    int bytesToRead = recordsToRead * RecordSize;

                    ReadExact(_stream, _buffer, bytesToRead);
                    _bufferOffset = 0;
                    _bufferBytes = bytesToRead;
                }

                int offset = _bufferOffset;
                record = new RawScidRecord
                {
                    DateTime = BitConverter.ToInt64(_buffer, offset),
                    Open = BitConverter.ToSingle(_buffer, offset + 8),
                    High = BitConverter.ToSingle(_buffer, offset + 12),
                    Low = BitConverter.ToSingle(_buffer, offset + 16),
                    Close = BitConverter.ToSingle(_buffer, offset + 20),
                    NumTrades = BitConverter.ToUInt32(_buffer, offset + 24),
                    TotalVolume = BitConverter.ToUInt32(_buffer, offset + 28),
                    BidVolume = BitConverter.ToUInt32(_buffer, offset + 32),
                    AskVolume = BitConverter.ToUInt32(_buffer, offset + 36)
                };

                _bufferOffset += RecordSize;
                _recordsRead++;

                if (record.DateTime < _previousDateTime)
                    OutOfOrderRecords++;

                _previousDateTime = record.DateTime;

                if (record.High != record.Low)
                    RichRecords++;

                if (record.Open <= 0)
                    ControlOpenRecords++;

                if ((ulong)record.BidVolume + (ulong)record.AskVolume !=
                    (ulong)record.TotalVolume)
                    UnclassifiedVolumeRecords++;

                return true;
            }

            public bool TryReadSecond(out SecondAggregate aggregate)
            {
                RawScidRecord first;

                if (_hasPending)
                {
                    first = _pending;
                    _hasPending = false;
                }
                else if (!TryReadRecord(out first))
                {
                    aggregate = new SecondAggregate();
                    return false;
                }

                long second = first.DateTime / 1000000L;
                long volume = first.TotalVolume;
                long bid = first.BidVolume;
                long ask = first.AskVolume;
                float lastClose = first.Close;

                RawScidRecord record;
                while (TryReadRecord(out record))
                {
                    long recordSecond = record.DateTime / 1000000L;
                    if (recordSecond != second)
                    {
                        _pending = record;
                        _hasPending = true;
                        break;
                    }

                    volume += record.TotalVolume;
                    bid += record.BidVolume;
                    ask += record.AskVolume;
                    lastClose = record.Close;
                }

                aggregate = new SecondAggregate
                {
                    Second = second,
                    Volume = volume,
                    BidVolume = bid,
                    AskVolume = ask,
                    LastClose = lastClose
                };

                return true;
            }

            public void Dispose()
            {
                _stream.Dispose();
            }
        }

        private static double Percent(long numerator, long denominator)
        {
            if (denominator <= 0)
                return 0.0;

            return 100.0 * (double)numerator / (double)denominator;
        }

        public static ScidFileValidation ValidateFile(
            string path,
            string statusPrefix)
        {
            DateTime started = DateTime.UtcNow;
            ScidMeta metaBefore = GetMeta(path);
            DateTime writeBefore = File.GetLastWriteTimeUtc(path);

            if (metaBefore.Records <= 0)
                throw new IOException("SCID validation requires a non-empty file.");

            using (var reader = new SequentialRecordReader(path))
            {
                SecondAggregate aggregate;
                long lastProgressRecords = 0;

                while (reader.TryReadSecond(out aggregate))
                {
                    if (reader.RecordsRead - lastProgressRecords >= 2000000)
                    {
                        lastProgressRecords = reader.RecordsRead;
                        int percent = reader.Records > 0
                            ? (int)Math.Min(99.0,
                                100.0 * reader.RecordsRead / (double)reader.Records)
                            : 0;

                        UpdateStatusLine(
                            statusPrefix +
                            " | VALIDATE " +
                            percent.ToString() + "%");
                    }
                }

                ScidMeta metaAfter = GetMeta(path);
                DateTime writeAfter = File.GetLastWriteTimeUtc(path);

                if (metaAfter.Length != metaBefore.Length ||
                    metaAfter.Records != metaBefore.Records ||
                    metaAfter.FirstDateTime != metaBefore.FirstDateTime ||
                    metaAfter.LastDateTime != metaBefore.LastDateTime ||
                    writeAfter != writeBefore)
                {
                    throw new IOException(
                        "SOURCE_CHANGED_DURING_VALIDATION: the SCID source changed " +
                        "while the preflight scan was running.");
                }

                return new ScidFileValidation
                {
                    Records = metaBefore.Records,
                    FirstDateTime = metaBefore.FirstDateTime,
                    LastDateTime = metaBefore.LastDateTime,
                    Length = metaBefore.Length,
                    WriteTimeUtcTicks = writeBefore.Ticks,
                    OutOfOrderRecords = reader.OutOfOrderRecords,
                    RichRecords = reader.RichRecords,
                    ControlOpenRecords = reader.ControlOpenRecords,
                    UnclassifiedVolumeRecords = reader.UnclassifiedVolumeRecords,
                    RichPercent = Percent(reader.RichRecords, metaBefore.Records),
                    ElapsedSeconds = (DateTime.UtcNow - started).TotalSeconds
                };
            }
        }

        public static ScidPairValidation ValidatePair(
            string sourcePath,
            string targetPath,
            double scale,
            string statusPrefix)
        {
            DateTime started = DateTime.UtcNow;
            ScidMeta sourceMetaBefore = GetMeta(sourcePath);
            ScidMeta targetMetaBefore = GetMeta(targetPath);
            DateTime sourceWriteBefore = File.GetLastWriteTimeUtc(sourcePath);
            DateTime targetWriteBefore = File.GetLastWriteTimeUtc(targetPath);

            if (sourceMetaBefore.Records <= 0 || targetMetaBefore.Records <= 0)
                throw new IOException(
                    "Pair validation requires non-empty SCID source and target files.");

            long targetFirstSecond = targetMetaBefore.FirstDateTime / 1000000L;
            long targetLastSecond = targetMetaBefore.LastDateTime / 1000000L;
            long sourceFirstSecond = sourceMetaBefore.FirstDateTime / 1000000L;
            long sourceLastSecond = sourceMetaBefore.LastDateTime / 1000000L;

            long sourceOverlapSeconds = 0;
            long targetOverlapSeconds = 0;
            long commonSeconds = 0;
            long sourceOnlySeconds = 0;
            long targetOnlySeconds = 0;
            long commonVolumeEqualSeconds = 0;
            long commonBidEqualSeconds = 0;
            long commonAskEqualSeconds = 0;
            long commonLastPriceEqualSeconds = 0;
            long sourceOverlapVolume = 0;
            long targetOverlapVolume = 0;

            using (var source = new SequentialRecordReader(sourcePath))
            using (var target = new SequentialRecordReader(targetPath))
            {
                SecondAggregate sourceSecond;
                SecondAggregate targetSecond;
                bool haveSource = source.TryReadSecond(out sourceSecond);
                bool haveTarget = target.TryReadSecond(out targetSecond);
                long lastProgressRecords = 0;

                while (haveSource || haveTarget)
                {
                    long progressRecords = source.RecordsRead + target.RecordsRead;
                    if (progressRecords - lastProgressRecords >= 2000000)
                    {
                        lastProgressRecords = progressRecords;
                        double denominator =
                            (double)(source.Records + target.Records);
                        int percent = denominator > 0
                            ? (int)Math.Min(99.0,
                                100.0 * progressRecords / denominator)
                            : 0;

                        UpdateStatusLine(
                            statusPrefix +
                            " | VALIDATE " +
                            percent.ToString() + "%");
                    }

                    if (!haveTarget ||
                        (haveSource && sourceSecond.Second < targetSecond.Second))
                    {
                        if (sourceSecond.Second >= targetFirstSecond &&
                            sourceSecond.Second <= targetLastSecond)
                        {
                            sourceOverlapSeconds++;
                            sourceOverlapVolume += sourceSecond.Volume;
                            sourceOnlySeconds++;
                        }

                        haveSource = source.TryReadSecond(out sourceSecond);
                        continue;
                    }

                    if (!haveSource || targetSecond.Second < sourceSecond.Second)
                    {
                        if (targetSecond.Second >= sourceFirstSecond &&
                            targetSecond.Second <= sourceLastSecond)
                        {
                            targetOverlapSeconds++;
                            targetOverlapVolume += targetSecond.Volume;
                            targetOnlySeconds++;
                        }

                        haveTarget = target.TryReadSecond(out targetSecond);
                        continue;
                    }

                    // Both feeds have data in this second.
                    sourceOverlapSeconds++;
                    targetOverlapSeconds++;
                    sourceOverlapVolume += sourceSecond.Volume;
                    targetOverlapVolume += targetSecond.Volume;
                    commonSeconds++;

                    if (sourceSecond.Volume == targetSecond.Volume)
                        commonVolumeEqualSeconds++;
                    if (sourceSecond.BidVolume == targetSecond.BidVolume)
                        commonBidEqualSeconds++;
                    if (sourceSecond.AskVolume == targetSecond.AskVolume)
                        commonAskEqualSeconds++;

                    double scaledClose =
                        (double)sourceSecond.LastClose * scale;

                    if (Math.Abs(scaledClose - (double)targetSecond.LastClose) <= 0.001)
                        commonLastPriceEqualSeconds++;

                    haveSource = source.TryReadSecond(out sourceSecond);
                    haveTarget = target.TryReadSecond(out targetSecond);
                }

                ScidMeta sourceMetaAfter = GetMeta(sourcePath);
                ScidMeta targetMetaAfter = GetMeta(targetPath);
                DateTime sourceWriteAfter = File.GetLastWriteTimeUtc(sourcePath);
                DateTime targetWriteAfter = File.GetLastWriteTimeUtc(targetPath);

                if (sourceMetaAfter.Length != sourceMetaBefore.Length ||
                    sourceMetaAfter.Records != sourceMetaBefore.Records ||
                    sourceMetaAfter.FirstDateTime != sourceMetaBefore.FirstDateTime ||
                    sourceMetaAfter.LastDateTime != sourceMetaBefore.LastDateTime ||
                    sourceWriteAfter != sourceWriteBefore)
                {
                    throw new IOException(
                        "SOURCE_CHANGED_DURING_VALIDATION: the SC Data source changed " +
                        "while the preflight comparison was running.");
                }

                if (targetMetaAfter.Length != targetMetaBefore.Length ||
                    targetMetaAfter.Records != targetMetaBefore.Records ||
                    targetMetaAfter.FirstDateTime != targetMetaBefore.FirstDateTime ||
                    targetMetaAfter.LastDateTime != targetMetaBefore.LastDateTime ||
                    targetWriteAfter != targetWriteBefore)
                {
                    throw new IOException(
                        "TARGET_CHANGED_DURING_VALIDATION: the Rithmic target changed " +
                        "while the preflight comparison was running.");
                }

                long overlapDenominator =
                    Math.Max(sourceOverlapSeconds, targetOverlapSeconds);

                long volumeBase =
                    Math.Max(sourceOverlapVolume, targetOverlapVolume);

                double aggregateVolumeDifferencePercent =
                    volumeBase > 0
                    ? 100.0 * Math.Abs(
                        (double)sourceOverlapVolume -
                        (double)targetOverlapVolume) /
                        (double)volumeBase
                    : 0.0;

                return new ScidPairValidation
                {
                    SourceRecords = sourceMetaBefore.Records,
                    TargetRecords = targetMetaBefore.Records,
                    SourceFirstDateTime = sourceMetaBefore.FirstDateTime,
                    SourceLastDateTime = sourceMetaBefore.LastDateTime,
                    TargetFirstDateTime = targetMetaBefore.FirstDateTime,
                    TargetLastDateTime = targetMetaBefore.LastDateTime,
                    SourceLength = sourceMetaBefore.Length,
                    TargetLength = targetMetaBefore.Length,
                    SourceWriteTimeUtcTicks = sourceWriteBefore.Ticks,
                    TargetWriteTimeUtcTicks = targetWriteBefore.Ticks,

                    SourceOutOfOrderRecords = source.OutOfOrderRecords,
                    TargetOutOfOrderRecords = target.OutOfOrderRecords,
                    SourceRichRecords = source.RichRecords,
                    TargetRichRecords = target.RichRecords,
                    SourceControlOpenRecords = source.ControlOpenRecords,
                    TargetControlOpenRecords = target.ControlOpenRecords,
                    SourceUnclassifiedVolumeRecords = source.UnclassifiedVolumeRecords,
                    TargetUnclassifiedVolumeRecords = target.UnclassifiedVolumeRecords,

                    SourceOverlapSeconds = sourceOverlapSeconds,
                    TargetOverlapSeconds = targetOverlapSeconds,
                    CommonSeconds = commonSeconds,
                    SourceOnlySeconds = sourceOnlySeconds,
                    TargetOnlySeconds = targetOnlySeconds,
                    CommonVolumeEqualSeconds = commonVolumeEqualSeconds,
                    CommonBidEqualSeconds = commonBidEqualSeconds,
                    CommonAskEqualSeconds = commonAskEqualSeconds,
                    CommonLastPriceEqualSeconds = commonLastPriceEqualSeconds,
                    SourceOverlapVolume = sourceOverlapVolume,
                    TargetOverlapVolume = targetOverlapVolume,

                    CommonCoveragePercent =
                        Percent(commonSeconds, overlapDenominator),
                    VolumeMatchPercent =
                        Percent(commonVolumeEqualSeconds, commonSeconds),
                    BidMatchPercent =
                        Percent(commonBidEqualSeconds, commonSeconds),
                    AskMatchPercent =
                        Percent(commonAskEqualSeconds, commonSeconds),
                    LastPriceMatchPercent =
                        Percent(commonLastPriceEqualSeconds, commonSeconds),
                    AggregateVolumeDifferencePercent =
                        aggregateVolumeDifferencePercent,
                    SourceRichPercent =
                        Percent(source.RichRecords, sourceMetaBefore.Records),
                    TargetRichPercent =
                        Percent(target.RichRecords, targetMetaBefore.Records),
                    ElapsedSeconds =
                        (DateTime.UtcNow - started).TotalSeconds
                };
            }
        }

        public static ScidPairValidation ValidatePairGzipTarget(
            string sourcePath,
            string targetArchivePath,
            long targetOriginalLength,
            long targetFirstDateTime,
            long targetLastDateTime,
            double scale,
            string statusPrefix)
        {
            DateTime started = DateTime.UtcNow;
            ScidMeta sourceMetaBefore = GetMeta(sourcePath);
            DateTime sourceWriteBefore =
                File.GetLastWriteTimeUtc(sourcePath);

            long archiveLengthBefore =
                new FileInfo(targetArchivePath).Length;

            DateTime targetWriteBefore =
                File.GetLastWriteTimeUtc(
                    targetArchivePath);

            if (targetOriginalLength < HeaderSize ||
                (targetOriginalLength - HeaderSize) % RecordSize != 0)
                throw new IOException(
                    "Archived Rithmic baseline metadata is invalid.");

            long targetRecords =
                (targetOriginalLength - HeaderSize) /
                RecordSize;

            if (sourceMetaBefore.Records <= 0 ||
                targetRecords <= 0)
                throw new IOException(
                    "Pair validation requires non-empty SCID source and target files.");

            long targetFirstSecond =
                targetFirstDateTime / 1000000L;

            long targetLastSecond =
                targetLastDateTime / 1000000L;
            long sourceFirstSecond = sourceMetaBefore.FirstDateTime / 1000000L;
            long sourceLastSecond = sourceMetaBefore.LastDateTime / 1000000L;

            long sourceOverlapSeconds = 0;
            long targetOverlapSeconds = 0;
            long commonSeconds = 0;
            long sourceOnlySeconds = 0;
            long targetOnlySeconds = 0;
            long commonVolumeEqualSeconds = 0;
            long commonBidEqualSeconds = 0;
            long commonAskEqualSeconds = 0;
            long commonLastPriceEqualSeconds = 0;
            long sourceOverlapVolume = 0;
            long targetOverlapVolume = 0;

            using (var source =
                new SequentialRecordReader(sourcePath))
            using (var archiveInput =
                new FileStream(
                    targetArchivePath,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.Read,
                    8 * 1024 * 1024,
                    FileOptions.SequentialScan))
            using (var gzip =
                new GZipStream(
                    archiveInput,
                    CompressionMode.Decompress))
            using (var target =
                new SequentialRecordReader(
                    gzip,
                    targetOriginalLength,
                    targetArchivePath))
            {
                SecondAggregate sourceSecond;
                SecondAggregate targetSecond;
                bool haveSource = source.TryReadSecond(out sourceSecond);
                bool haveTarget = target.TryReadSecond(out targetSecond);
                long lastProgressRecords = 0;

                while (haveSource || haveTarget)
                {
                    long progressRecords = source.RecordsRead + target.RecordsRead;
                    if (progressRecords - lastProgressRecords >= 2000000)
                    {
                        lastProgressRecords = progressRecords;
                        double denominator =
                            (double)(source.Records + target.Records);
                        int percent = denominator > 0
                            ? (int)Math.Min(99.0,
                                100.0 * progressRecords / denominator)
                            : 0;

                        UpdateStatusLine(
                            statusPrefix +
                            " | VALIDATE " +
                            percent.ToString() + "%");
                    }

                    if (!haveTarget ||
                        (haveSource && sourceSecond.Second < targetSecond.Second))
                    {
                        if (sourceSecond.Second >= targetFirstSecond &&
                            sourceSecond.Second <= targetLastSecond)
                        {
                            sourceOverlapSeconds++;
                            sourceOverlapVolume += sourceSecond.Volume;
                            sourceOnlySeconds++;
                        }

                        haveSource = source.TryReadSecond(out sourceSecond);
                        continue;
                    }

                    if (!haveSource || targetSecond.Second < sourceSecond.Second)
                    {
                        if (targetSecond.Second >= sourceFirstSecond &&
                            targetSecond.Second <= sourceLastSecond)
                        {
                            targetOverlapSeconds++;
                            targetOverlapVolume += targetSecond.Volume;
                            targetOnlySeconds++;
                        }

                        haveTarget = target.TryReadSecond(out targetSecond);
                        continue;
                    }

                    // Both feeds have data in this second.
                    sourceOverlapSeconds++;
                    targetOverlapSeconds++;
                    sourceOverlapVolume += sourceSecond.Volume;
                    targetOverlapVolume += targetSecond.Volume;
                    commonSeconds++;

                    if (sourceSecond.Volume == targetSecond.Volume)
                        commonVolumeEqualSeconds++;
                    if (sourceSecond.BidVolume == targetSecond.BidVolume)
                        commonBidEqualSeconds++;
                    if (sourceSecond.AskVolume == targetSecond.AskVolume)
                        commonAskEqualSeconds++;

                    double scaledClose =
                        (double)sourceSecond.LastClose * scale;

                    if (Math.Abs(scaledClose - (double)targetSecond.LastClose) <= 0.001)
                        commonLastPriceEqualSeconds++;

                    haveSource = source.TryReadSecond(out sourceSecond);
                    haveTarget = target.TryReadSecond(out targetSecond);
                }

                ScidMeta sourceMetaAfter =
                    GetMeta(sourcePath);

                DateTime sourceWriteAfter =
                    File.GetLastWriteTimeUtc(sourcePath);

                long archiveLengthAfter =
                    new FileInfo(targetArchivePath).Length;

                DateTime targetWriteAfter =
                    File.GetLastWriteTimeUtc(
                        targetArchivePath);

                if (sourceMetaAfter.Length != sourceMetaBefore.Length ||
                    sourceMetaAfter.Records != sourceMetaBefore.Records ||
                    sourceMetaAfter.FirstDateTime != sourceMetaBefore.FirstDateTime ||
                    sourceMetaAfter.LastDateTime != sourceMetaBefore.LastDateTime ||
                    sourceWriteAfter != sourceWriteBefore)
                {
                    throw new IOException(
                        "SOURCE_CHANGED_DURING_VALIDATION: the SC Data source changed " +
                        "while the preflight comparison was running.");
                }

                if (archiveLengthAfter !=
                        archiveLengthBefore ||
                    targetWriteAfter !=
                        targetWriteBefore)
                {
                    throw new IOException(
                        "TARGET_CHANGED_DURING_VALIDATION: the archived Rithmic " +
                        "baseline changed while the preflight comparison was running.");
                }

                long overlapDenominator =
                    Math.Max(sourceOverlapSeconds, targetOverlapSeconds);

                long volumeBase =
                    Math.Max(sourceOverlapVolume, targetOverlapVolume);

                double aggregateVolumeDifferencePercent =
                    volumeBase > 0
                    ? 100.0 * Math.Abs(
                        (double)sourceOverlapVolume -
                        (double)targetOverlapVolume) /
                        (double)volumeBase
                    : 0.0;

                return new ScidPairValidation
                {
                    SourceRecords = sourceMetaBefore.Records,
                    TargetRecords = targetRecords,
                    SourceFirstDateTime = sourceMetaBefore.FirstDateTime,
                    SourceLastDateTime = sourceMetaBefore.LastDateTime,
                    TargetFirstDateTime = targetFirstDateTime,
                    TargetLastDateTime = targetLastDateTime,
                    SourceLength = sourceMetaBefore.Length,
                    TargetLength = targetOriginalLength,
                    SourceWriteTimeUtcTicks = sourceWriteBefore.Ticks,
                    TargetWriteTimeUtcTicks = targetWriteBefore.Ticks,

                    SourceOutOfOrderRecords = source.OutOfOrderRecords,
                    TargetOutOfOrderRecords = target.OutOfOrderRecords,
                    SourceRichRecords = source.RichRecords,
                    TargetRichRecords = target.RichRecords,
                    SourceControlOpenRecords = source.ControlOpenRecords,
                    TargetControlOpenRecords = target.ControlOpenRecords,
                    SourceUnclassifiedVolumeRecords = source.UnclassifiedVolumeRecords,
                    TargetUnclassifiedVolumeRecords = target.UnclassifiedVolumeRecords,

                    SourceOverlapSeconds = sourceOverlapSeconds,
                    TargetOverlapSeconds = targetOverlapSeconds,
                    CommonSeconds = commonSeconds,
                    SourceOnlySeconds = sourceOnlySeconds,
                    TargetOnlySeconds = targetOnlySeconds,
                    CommonVolumeEqualSeconds = commonVolumeEqualSeconds,
                    CommonBidEqualSeconds = commonBidEqualSeconds,
                    CommonAskEqualSeconds = commonAskEqualSeconds,
                    CommonLastPriceEqualSeconds = commonLastPriceEqualSeconds,
                    SourceOverlapVolume = sourceOverlapVolume,
                    TargetOverlapVolume = targetOverlapVolume,

                    CommonCoveragePercent =
                        Percent(commonSeconds, overlapDenominator),
                    VolumeMatchPercent =
                        Percent(commonVolumeEqualSeconds, commonSeconds),
                    BidMatchPercent =
                        Percent(commonBidEqualSeconds, commonSeconds),
                    AskMatchPercent =
                        Percent(commonAskEqualSeconds, commonSeconds),
                    LastPriceMatchPercent =
                        Percent(commonLastPriceEqualSeconds, commonSeconds),
                    AggregateVolumeDifferencePercent =
                        aggregateVolumeDifferencePercent,
                    SourceRichPercent =
                        Percent(source.RichRecords, sourceMetaBefore.Records),
                    TargetRichPercent =
                        Percent(target.RichRecords, targetRecords),
                    ElapsedSeconds =
                        (DateTime.UtcNow - started).TotalSeconds
                };
            }
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

        private static int LastStatusLength = 0;

        private static string FitStatusLine(string line)
        {
            int width = 0;

            try
            {
                if (!Console.IsOutputRedirected)
                    width = Math.Max(40, Console.WindowWidth - 1);
            }
            catch
            {
                width = 0;
            }

            if (width > 0 && line.Length > width)
            {
                if (width <= 4)
                    return line.Substring(0, width);

                return line.Substring(0, width - 3) + "...";
            }

            return line;
        }

        public static void UpdateStatusLine(string line)
        {
            line = FitStatusLine(line ?? String.Empty);

            if (Console.IsOutputRedirected)
                return;

            int clearTo = Math.Max(LastStatusLength, line.Length);

            Console.Write(
                "\r" +
                line.PadRight(clearTo));

            Console.Out.Flush();
            LastStatusLength = clearTo;
        }

        public static void CompleteStatusLine(string line)
        {
            // Final result lines are never truncated: they contain exact record
            // totals used for verification. A very narrow console may wrap the
            // line, but no verification data is discarded.
            line = line ?? String.Empty;

            if (Console.IsOutputRedirected)
            {
                Console.WriteLine(line);
                return;
            }

            int clearTo = Math.Max(LastStatusLength, line.Length);

            Console.Write(
                "\r" +
                line.PadRight(clearTo));

            Console.WriteLine();
            Console.Out.Flush();
            LastStatusLength = 0;
        }

        private static void ShowProgress(
            string statusPrefix,
            long completedBytes,
            long totalBytes,
            ref int lastPercent,
            DateTime started)
        {
            if (totalBytes <= 0)
                return;

            int percent = (int)((completedBytes * 100L) / totalBytes);

            if (percent == lastPercent && completedBytes < totalBytes)
                return;

            double seconds = Math.Max(0.001, (DateTime.UtcNow - started).TotalSeconds);
            double completedMb = completedBytes / 1048576.0;
            double totalMb = totalBytes / 1048576.0;
            double rate = completedMb / seconds;

            UpdateStatusLine(
                String.Format(
                    "{0} | CONVERT {1,3}% | {2:0}/{3:0} MB | {4:0} MB/s",
                    statusPrefix,
                    Math.Min(100, percent),
                    completedMb,
                    totalMb,
                    rate));

            lastPercent = percent;
        }

        private static void CopyScidRangeVerified(
            string statusPrefix,
            FileStream input,
            FileStream output,
            long records,
            long minimumDateTime,
            long totalBytes,
            ref long completedBytes,
            ref int lastPercent,
            ref long previousDateTime,
            DateTime started)
        {
            const int RecordsPerChunk = 250000;
            byte[] buffer = new byte[RecordsPerChunk * RecordSize];
            long recordsRemaining = records;

            while (recordsRemaining > 0)
            {
                int recordsThisChunk = (int)Math.Min(
                    (long)RecordsPerChunk,
                    recordsRemaining);

                int bytesThisChunk = recordsThisChunk * RecordSize;
                ReadExact(input, buffer, bytesThisChunk);

                for (int record = 0, offset = 0;
                    record < recordsThisChunk;
                    record++, offset += RecordSize)
                {
                    long dateTime = BitConverter.ToInt64(buffer, offset);

                    if (dateTime < minimumDateTime)
                    {
                        throw new IOException(
                            "LIVE_MERGE_TAIL_BEFORE_HANDOFF: Rithmic tail " +
                            "contains a record before the verified cutover. " +
                            "No target was changed.");
                    }

                    if (dateTime < previousDateTime)
                    {
                        throw new IOException(
                            "LIVE_MERGE_TAIL_OUT_OF_ORDER: Rithmic tail " +
                            "timestamps are not monotonic. No target was changed.");
                    }

                    previousDateTime = dateTime;
                }

                output.Write(buffer, 0, bytesThisChunk);
                recordsRemaining -= recordsThisChunk;
                completedBytes += bytesThisChunk;

                ShowProgress(
                    statusPrefix,
                    completedBytes,
                    totalBytes,
                    ref lastPercent,
                    started);
            }
        }

        public static ConvertResult Convert(
            string sourcePath,
            string targetPath,
            double scale,
            string backupDirectory,
            bool preserveTargetTail,
            bool createRithmicBaseline,
            string statusPrefix)
        {
            DateTime started = DateTime.UtcNow;
            string temporaryPath = targetPath + ".scbridge.tmp";

            if (File.Exists(temporaryPath))
                File.Delete(temporaryPath);

            ScidMeta sourceMeta = GetMeta(sourcePath);
            DateTime sourceWriteTime =
                File.GetLastWriteTimeUtc(sourcePath);

            if (sourceMeta.Records <= 0)
                throw new IOException("The SC Data source contains no records.");

            long sourceRecordsWritten = sourceMeta.Records;
            long tailIndex = 0;
            long tailRecords = 0;
            long tailBytes = 0;
            long handoffDateTime = 0;
            int handoffVerifiedTradeSeconds = 0;

            ScidMeta targetMetaAtStart = null;
            DateTime targetWriteTime = DateTime.MinValue;

            if (preserveTargetTail &&
                File.Exists(targetPath))
            {
                targetMetaAtStart = GetMeta(targetPath);
                targetWriteTime =
                    File.GetLastWriteTimeUtc(targetPath);

                if (targetMetaAtStart.Records > 0 &&
                    ShouldPreserveTargetTail(
                        sourcePath,
                        targetPath,
                        sourceMeta,
                        targetMetaAtStart,
                        scale))
                {
                    handoffDateTime =
                        FindVerifiedHandoffDateTime(
                            sourcePath,
                            targetPath,
                            sourceMeta,
                            targetMetaAtStart,
                            scale,
                            out handoffVerifiedTradeSeconds);

                    if (handoffDateTime <= 0 ||
                        handoffVerifiedTradeSeconds < 3)
                    {
                        throw new IOException(
                            "LIVE_MERGE_HANDOFF_UNVERIFIED: no verified whole-second " +
                            "cutover could be established between SC Data and the " +
                            "Rithmic target. No target was changed.");
                    }

                    using (var source = new FileStream(
                        sourcePath,
                        FileMode.Open,
                        FileAccess.Read,
                        FileShare.ReadWrite,
                        1024 * 1024,
                        FileOptions.RandomAccess))
                    using (var target = new FileStream(
                        targetPath,
                        FileMode.Open,
                        FileAccess.Read,
                        FileShare.ReadWrite,
                        1024 * 1024,
                        FileOptions.RandomAccess))
                    {
                        ValidateHeader(source, sourcePath);
                        ValidateHeader(target, targetPath);

                        sourceRecordsWritten =
                            LowerBound(
                                source,
                                sourceMeta.Records,
                                handoffDateTime,
                                false);

                        tailIndex =
                            LowerBound(
                                target,
                                targetMetaAtStart.Records,
                                handoffDateTime,
                                false);

                        tailRecords =
                            targetMetaAtStart.Records -
                            tailIndex;

                        tailBytes =
                            tailRecords *
                            RecordSize;

                        if (sourceRecordsWritten <= 0 ||
                            tailRecords <= 0)
                        {
                            throw new IOException(
                                "LIVE_MERGE_HANDOFF_INVALID: the verified cutover " +
                                "did not leave both an SC Data prefix and a Rithmic " +
                                "tail. No target was changed.");
                        }

                        long sourceLastWritten = ReadDateTimeAt(
                            source,
                            sourceRecordsWritten - 1);

                        long targetFirstTail = ReadDateTimeAt(
                            target,
                            tailIndex);

                        if (sourceLastWritten >= handoffDateTime ||
                            targetFirstTail < handoffDateTime ||
                            sourceLastWritten >= targetFirstTail)
                        {
                            throw new IOException(
                                "LIVE_MERGE_BOUNDARY_INVALID: source and target " +
                                "records do not form a strict half-open cutover. " +
                                "No target was changed.");
                        }
                    }
                }
            }

            long sourcePayloadBytes =
                sourceRecordsWritten *
                RecordSize;

            long totalWorkBytes =
                sourcePayloadBytes +
                tailBytes;

            long expectedOutputBytes =
                HeaderSize +
                totalWorkBytes;

            string targetRoot =
                Path.GetPathRoot(
                    Path.GetFullPath(
                        targetPath));

            if (!String.IsNullOrEmpty(targetRoot))
            {
                var drive =
                    new DriveInfo(
                        targetRoot);

                long requiredFreeBytes =
                    expectedOutputBytes +
                    (256L * 1024L * 1024L);

                if (drive.AvailableFreeSpace <
                    requiredFreeBytes)
                {
                    throw new IOException(
                        "INSUFFICIENT_DISK_SPACE: " +
                        "safe SCID conversion requires " +
                        requiredFreeBytes.ToString(
                            CultureInfo.InvariantCulture) +
                        " free bytes including reserve; " +
                        drive.AvailableFreeSpace.ToString(
                            CultureInfo.InvariantCulture) +
                        " bytes are available. No target was changed.");
                }
            }

            long completedBytes = 0;
            int lastPercent = -1;

            long outOfOrderRecords = 0;
            long firstOutOfOrderIndex = -1;
            long firstPriorDateTime = 0;
            long firstOutOfOrderDateTime = 0;
            long largestBackwardMicroseconds = 0;

            double conversionSeconds = 0;
            double flushSeconds = 0;
            double validationSeconds = 0;
            double replaceSeconds = 0;

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

                    long recordsRemaining = sourceRecordsWritten;
                    long previousDateTime = Int64.MinValue;
                    long sourceRecordIndex = 0;

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
                            {
                                outOfOrderRecords++;

                                long backward =
                                    previousDateTime - dateTime;

                                if (firstOutOfOrderIndex < 0)
                                {
                                    firstOutOfOrderIndex = sourceRecordIndex;
                                    firstPriorDateTime = previousDateTime;
                                    firstOutOfOrderDateTime = dateTime;
                                }

                                if (backward > largestBackwardMicroseconds)
                                    largestBackwardMicroseconds = backward;
                            }

                            previousDateTime = dateTime;
                            sourceRecordIndex++;

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
                            statusPrefix,
                            completedBytes,
                            totalWorkBytes,
                            ref lastPercent,
                            started);
                    }

                    if (outOfOrderRecords > 0)
                    {
                        throw new IOException(
                            "SOURCE_OUT_OF_ORDER: SC Data source timestamps are " +
                            "not monotonic. No target was changed.");
                    }

                    if (tailRecords > 0)
                    {
                        using (var target = new FileStream(
                            targetPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite,
                            16 * 1024 * 1024, FileOptions.SequentialScan))
                        {
                            target.Position = HeaderSize + tailIndex * RecordSize;

                            CopyScidRangeVerified(
                                statusPrefix,
                                target,
                                output,
                                tailRecords,
                                handoffDateTime,
                                totalWorkBytes,
                                ref completedBytes,
                                ref lastPercent,
                                ref previousDateTime,
                                started);
                        }
                    }

                    DateTime conversionFinished = DateTime.UtcNow;
                    conversionSeconds =
                        (conversionFinished - started).TotalSeconds;

                    UpdateStatusLine(
                        statusPrefix +
                        " | FLUSHING | writing cached data to disk");

                    DateTime flushStarted = DateTime.UtcNow;
                    output.Flush(true);
                    flushSeconds =
                        (DateTime.UtcNow - flushStarted).TotalSeconds;
                }

                ScidMeta sourceMetaAfter =
                    GetMeta(sourcePath);

                DateTime sourceWriteTimeAfter =
                    File.GetLastWriteTimeUtc(sourcePath);

                if (sourceMetaAfter.Length != sourceMeta.Length ||
                    sourceMetaAfter.Records != sourceMeta.Records ||
                    sourceMetaAfter.FirstDateTime != sourceMeta.FirstDateTime ||
                    sourceMetaAfter.LastDateTime != sourceMeta.LastDateTime ||
                    sourceWriteTimeAfter != sourceWriteTime)
                {
                    throw new IOException(
                        "SOURCE_CHANGED_DURING_CONVERSION: " +
                        "the SC Data source changed while it was being converted. " +
                        "The temporary output was discarded.");
                }

                if (tailRecords > 0 &&
                    targetMetaAtStart != null)
                {
                    ScidMeta targetMetaAfter =
                        GetMeta(targetPath);

                    DateTime targetWriteTimeAfter =
                        File.GetLastWriteTimeUtc(targetPath);

                    if (targetMetaAfter.Length !=
                            targetMetaAtStart.Length ||
                        targetMetaAfter.Records !=
                            targetMetaAtStart.Records ||
                        targetMetaAfter.FirstDateTime !=
                            targetMetaAtStart.FirstDateTime ||
                        targetMetaAfter.LastDateTime !=
                            targetMetaAtStart.LastDateTime ||
                        targetWriteTimeAfter !=
                            targetWriteTime)
                    {
                        throw new IOException(
                            "TARGET_CHANGED_DURING_CONVERSION: " +
                            "the Rithmic target changed while its newer records " +
                            "were being preserved. The temporary output was discarded.");
                    }
                }

                UpdateStatusLine(
                    statusPrefix +
                    " | VALIDATE | checking converted SCID");

                DateTime validationStarted = DateTime.UtcNow;

                ScidMeta outputMeta = GetMeta(temporaryPath);
                long expectedRecords =
                    sourceRecordsWritten +
                    tailRecords;

                if (outputMeta.Records != expectedRecords)
                    throw new IOException("Output record-count validation failed.");

                if (outputMeta.FirstDateTime != sourceMeta.FirstDateTime)
                    throw new IOException("Output first-timestamp validation failed.");

                if (tailRecords == 0)
                {
                    if (sourceRecordsWritten != sourceMeta.Records)
                        throw new IOException("Historical replacement source-count validation failed.");

                    if (outputMeta.Length != sourceMeta.Length)
                        throw new IOException("Historical replacement size validation failed.");

                    if (outputMeta.LastDateTime != sourceMeta.LastDateTime)
                        throw new IOException("Historical replacement last-timestamp validation failed.");
                }
                else
                {
                    if (handoffDateTime <= 0)
                        throw new IOException("Live merge handoff validation failed.");

                    if (outputMeta.LastDateTime !=
                        targetMetaAtStart.LastDateTime)
                        throw new IOException("Live merge last-timestamp validation failed.");
                }

                long[] sampleIndexes =
                    sourceRecordsWritten > 0
                    ? new long[] {
                        0,
                        sourceRecordsWritten / 2,
                        sourceRecordsWritten - 1
                    }
                    : new long[0];

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

                validationSeconds =
                    (DateTime.UtcNow - validationStarted).TotalSeconds;

                UpdateStatusLine(
                    statusPrefix +
                    " | REPLACE | updating Rithmic target");

                DateTime replaceStarted = DateTime.UtcNow;

                if (File.Exists(targetPath))
                {
                    Directory.CreateDirectory(backupDirectory);

                    string baselinePath =
                        Path.Combine(
                            backupDirectory,
                            Path.GetFileName(sourcePath) +
                            "__" +
                            Path.GetFileName(targetPath) +
                            ".rithmic-baseline.bak");

                    if (createRithmicBaseline &&
                        !File.Exists(baselinePath))
                    {
                        // Preserve the untouched Rithmic file with same-volume
                        // moves instead of copying a multi-gigabyte SCID.
                        File.Move(targetPath, baselinePath);

                        try
                        {
                            File.Move(temporaryPath, targetPath);
                        }
                        catch
                        {
                            if (!File.Exists(targetPath) &&
                                File.Exists(baselinePath))
                                File.Move(baselinePath, targetPath);

                            throw;
                        }
                    }
                    else
                    {
                        string backupPath =
                            Path.Combine(
                                backupDirectory,
                                Path.GetFileName(targetPath) + ".bak");

                        if (File.Exists(backupPath))
                            File.Delete(backupPath);

                        File.Replace(temporaryPath, targetPath, backupPath, true);
                    }
                }
                else
                {
                    File.Move(temporaryPath, targetPath);
                }

                replaceSeconds =
                    (DateTime.UtcNow - replaceStarted).TotalSeconds;

                return new ConvertResult
                {
                    SourceRecords = sourceMeta.Records,
                    SourceRecordsWritten =
                        sourceRecordsWritten,
                    TailRecords = tailRecords,
                    OutputRecords = expectedRecords,
                    HandoffDateTime =
                        handoffDateTime,
                    HandoffVerifiedTradeSeconds =
                        handoffVerifiedTradeSeconds,
                    ElapsedSeconds = (DateTime.UtcNow - started).TotalSeconds,
                    ConversionSeconds = conversionSeconds,
                    FlushSeconds = flushSeconds,
                    ValidationSeconds = validationSeconds,
                    ReplaceSeconds = replaceSeconds,
                    OutOfOrderRecords = outOfOrderRecords,
                    FirstOutOfOrderIndex = firstOutOfOrderIndex,
                    FirstPriorDateTime = firstPriorDateTime,
                    FirstOutOfOrderDateTime = firstOutOfOrderDateTime,
                    LargestBackwardMicroseconds = largestBackwardMicroseconds
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

    public sealed class DailyMeta
    {
        public long Records;
        public long FirstDateTicks;
        public long LastDateTicks;
        public long Length;
    }

    public sealed class DailySyncResult
    {
        public long SourceRecords;
        public long TargetRecordsBefore;
        public long SourceAppliedRecords;
        public long PreservedTargetRecords;
        public long ReplacedOrDroppedTargetRecords;
        public long OutputRecords;
        public bool PreservedLatestSourceDate;
        public long FirstDateTicks;
        public long LastDateTicks;
        public double ElapsedSeconds;
    }

    public static class DailyBridge
    {
        private static readonly double[] CandidateScales =
            new double[] { 0.0001, 0.001, 0.01, 0.1, 1.0, 10.0, 100.0, 1000.0, 10000.0 };

        private sealed class DailyRecord
        {
            public DateTime Date;
            public decimal Open;
            public decimal High;
            public decimal Low;
            public decimal Close;
            public long Volume;
            public long OpenInterest;
        }

        private static readonly string[] DateFormats =
            new string[] { "yyyy/MM/dd", "yyyy/M/d", "yyyy/MM/d", "yyyy/M/dd" };

        private static List<DailyRecord> ReadRecords(string path)
        {
            if (!File.Exists(path))
                throw new FileNotFoundException("Historical Daily file was not found.", path);

            string[] lines = File.ReadAllLines(path);
            var records = new List<DailyRecord>();

            if (lines.Length == 0)
                return records;

            int lineIndex = 0;
            while (lineIndex < lines.Length &&
                   String.IsNullOrWhiteSpace(lines[lineIndex]))
                lineIndex++;

            if (lineIndex >= lines.Length)
                return records;

            string header = lines[lineIndex].Trim();
            if (!header.StartsWith("Date", StringComparison.OrdinalIgnoreCase))
                throw new IOException(
                    Path.GetFileName(path) +
                    ": Historical Daily header was not recognized.");

            DateTime previousDate = DateTime.MinValue;

            for (lineIndex++; lineIndex < lines.Length; lineIndex++)
            {
                string line = lines[lineIndex];

                if (String.IsNullOrWhiteSpace(line))
                    continue;

                string[] fields = line.Split(',');
                if (fields.Length < 7)
                    throw new IOException(
                        Path.GetFileName(path) +
                        ": Historical Daily record does not contain seven fields at line " +
                        (lineIndex + 1).ToString(CultureInfo.InvariantCulture) + ".");

                DateTime date;
                if (!DateTime.TryParseExact(
                    fields[0].Trim(),
                    DateFormats,
                    CultureInfo.InvariantCulture,
                    DateTimeStyles.None,
                    out date))
                    throw new IOException(
                        Path.GetFileName(path) +
                        ": invalid Historical Daily date at line " +
                        (lineIndex + 1).ToString(CultureInfo.InvariantCulture) + ".");

                if (previousDate != DateTime.MinValue && date <= previousDate)
                    throw new IOException(
                        Path.GetFileName(path) +
                        ": Historical Daily dates are not strictly increasing.");

                decimal open;
                decimal high;
                decimal low;
                decimal close;
                long volume;
                long openInterest;

                if (!Decimal.TryParse(fields[1].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out open) ||
                    !Decimal.TryParse(fields[2].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out high) ||
                    !Decimal.TryParse(fields[3].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out low) ||
                    !Decimal.TryParse(fields[4].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out close) ||
                    !Int64.TryParse(fields[5].Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out volume) ||
                    !Int64.TryParse(fields[6].Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out openInterest))
                    throw new IOException(
                        Path.GetFileName(path) +
                        ": invalid Historical Daily value at line " +
                        (lineIndex + 1).ToString(CultureInfo.InvariantCulture) + ".");

                records.Add(new DailyRecord
                {
                    Date = date,
                    Open = open,
                    High = high,
                    Low = low,
                    Close = close,
                    Volume = volume,
                    OpenInterest = openInterest
                });

                previousDate = date;
            }

            return records;
        }

        private static string FormatRecord(DailyRecord record, decimal priceScale)
        {
            return String.Format(
                CultureInfo.InvariantCulture,
                "{0:yyyy/MM/dd}, {1:0.00000000}, {2:0.00000000}, {3:0.00000000}, {4:0.00000000}, {5}, {6}",
                record.Date,
                record.Open * priceScale,
                record.High * priceScale,
                record.Low * priceScale,
                record.Close * priceScale,
                record.Volume,
                record.OpenInterest);
        }

        public static DailyMeta GetMeta(string path)
        {
            List<DailyRecord> records = ReadRecords(path);

            return new DailyMeta
            {
                Records = records.Count,
                FirstDateTicks = records.Count > 0 ? records[0].Date.Ticks : 0,
                LastDateTicks = records.Count > 0 ? records[records.Count - 1].Date.Ticks : 0,
                Length = new FileInfo(path).Length
            };
        }

        public static ScaleInference InferScale(
            string sourcePath,
            string targetPath)
        {
            List<DailyRecord> source = ReadRecords(sourcePath);
            List<DailyRecord> target = ReadRecords(targetPath);

            if (source.Count == 0 || target.Count == 0)
                throw new IOException(
                    "Daily scale inference requires non-empty source and target files.");

            var targetByDate = new Dictionary<DateTime, DailyRecord>();
            for (int i = 0; i < target.Count; i++)
                targetByDate[target[i].Date] = target[i];

            var ratios = new List<double>();

            for (int i = 0; i < source.Count; i++)
            {
                DailyRecord targetRecord;

                if (!targetByDate.TryGetValue(source[i].Date, out targetRecord))
                    continue;

                double sourcePrice = Convert.ToDouble(source[i].Close);
                double targetPrice = Convert.ToDouble(targetRecord.Close);

                if (sourcePrice > 0 && targetPrice > 0)
                    ratios.Add(targetPrice / sourcePrice);
            }

            if (ratios.Count < 5)
                throw new IOException(
                    "Not enough overlapping Daily records to infer a price scale.");

            ratios.Sort();
            double median = ratios[ratios.Count / 2];

            double bestFactor = CandidateScales[0];
            double bestDistance = Double.MaxValue;

            for (int i = 0; i < CandidateScales.Length; i++)
            {
                double candidate = CandidateScales[i];
                double distance = Math.Abs(Math.Log(candidate / median));

                if (distance < bestDistance)
                {
                    bestDistance = distance;
                    bestFactor = candidate;
                }
            }

            if (Math.Abs(median - bestFactor) / bestFactor > 0.02)
                throw new IOException(
                    "The observed Daily raw-price ratio is not close enough to a supported power-of-ten scale.");

            return new ScaleInference
            {
                Factor = bestFactor,
                MedianRatio = median,
                Samples = ratios.Count
            };
        }

        private static bool RecordMatchesScaledSource(
            DailyRecord source,
            DailyRecord target,
            decimal scale)
        {
            return
                target.Date == source.Date &&
                target.Open == source.Open * scale &&
                target.High == source.High * scale &&
                target.Low == source.Low * scale &&
                target.Close == source.Close * scale &&
                target.Volume == source.Volume &&
                target.OpenInterest == source.OpenInterest;
        }

        public static bool IsSynchronized(
            string sourcePath,
            string targetPath,
            double priceScale)
        {
            if (!File.Exists(sourcePath) || !File.Exists(targetPath))
                return false;

            List<DailyRecord> source = ReadRecords(sourcePath);
            List<DailyRecord> target = ReadRecords(targetPath);

            if (source.Count == 0 || target.Count == 0)
                return false;

            var targetByDate = new Dictionary<DateTime, DailyRecord>();
            for (int i = 0; i < target.Count; i++)
                targetByDate[target[i].Date] = target[i];

            DateTime latestSourceDate =
                source[source.Count - 1].Date;

            bool preserveLatestSourceDate =
                targetByDate.ContainsKey(latestSourceDate);

            decimal scale =
                Convert.ToDecimal(priceScale);

            int newerTargetRecords = 0;
            for (int i = 0; i < target.Count; i++)
            {
                if (target[i].Date > latestSourceDate)
                    newerTargetRecords++;
            }

            int expectedRecords =
                source.Count + newerTargetRecords;

            if (target.Count != expectedRecords)
                return false;

            for (int i = 0; i < source.Count; i++)
            {
                DailyRecord sourceRecord = source[i];
                DailyRecord targetRecord;

                if (!targetByDate.TryGetValue(
                        sourceRecord.Date,
                        out targetRecord))
                    return false;

                // Sync intentionally retains the existing target row for the
                // latest source date when one already exists.
                if (sourceRecord.Date == latestSourceDate &&
                    preserveLatestSourceDate)
                    continue;

                if (!RecordMatchesScaledSource(
                        sourceRecord,
                        targetRecord,
                        scale))
                    return false;
            }

            return true;
        }

        public static DailySyncResult Sync(
            string sourcePath,
            string targetPath,
            double priceScale,
            string backupDirectory)
        {
            DateTime started = DateTime.UtcNow;
            string temporaryPath = targetPath + ".dailybridge.tmp";

            if (File.Exists(temporaryPath))
                File.Delete(temporaryPath);

            List<DailyRecord> source = ReadRecords(sourcePath);
            if (source.Count == 0)
                throw new IOException("The SC Data Historical Daily source contains no records.");

            List<DailyRecord> target = new List<DailyRecord>();

            if (File.Exists(targetPath))
            {
                try
                {
                    target = ReadRecords(targetPath);
                }
                catch (IOException)
                {
                    target = new List<DailyRecord>();
                }
            }

            var targetByDate = new Dictionary<DateTime, DailyRecord>();
            for (int i = 0; i < target.Count; i++)
                targetByDate[target[i].Date] = target[i];

            var output = new Dictionary<DateTime, string>();
            var sourceAppliedDates = new Dictionary<DateTime, bool>();

            DateTime latestSourceDate = source[source.Count - 1].Date;
            bool preserveLatestSourceDate =
                targetByDate.ContainsKey(latestSourceDate);

            decimal scale = Convert.ToDecimal(priceScale);

            for (int i = 0; i < source.Count; i++)
            {
                DailyRecord record = source[i];

                if (record.Date == latestSourceDate &&
                    preserveLatestSourceDate)
                {
                    output[record.Date] =
                        FormatRecord(targetByDate[record.Date], 1m);
                    continue;
                }

                output[record.Date] = FormatRecord(record, scale);
                sourceAppliedDates[record.Date] = true;
            }

            for (int i = 0; i < target.Count; i++)
            {
                DailyRecord record = target[i];

                if (record.Date > latestSourceDate)
                    output[record.Date] = FormatRecord(record, 1m);
            }

            long sourceAppliedRecords = sourceAppliedDates.Count;
            long preservedTargetRecords =
                output.Count - sourceAppliedRecords;

            long replacedOrDroppedTargetRecords =
                target.Count - preservedTargetRecords;

            try
            {
                using (var stream = new FileStream(
                    temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                    64 * 1024, FileOptions.SequentialScan))
                using (var writer = new StreamWriter(
                    stream, Encoding.ASCII, 64 * 1024, true))
                {
                    writer.NewLine = "\r\n";
                    writer.WriteLine("Date, Open, High, Low, Close, Volume, OpenInterest");

                    var outputDates = new List<DateTime>(output.Keys);
                    outputDates.Sort();

                    for (int i = 0; i < outputDates.Count; i++)
                        writer.WriteLine(output[outputDates[i]]);

                    writer.Flush();
                    stream.Flush(true);
                }

                DailyMeta outputMeta = GetMeta(temporaryPath);

                if (outputMeta.Records != output.Count)
                    throw new IOException("Historical Daily output record-count validation failed.");

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

                DailyMeta finalMeta = GetMeta(targetPath);

                if (finalMeta.Records != outputMeta.Records ||
                    finalMeta.FirstDateTicks != outputMeta.FirstDateTicks ||
                    finalMeta.LastDateTicks != outputMeta.LastDateTicks)
                    throw new IOException("Historical Daily post-replacement validation failed.");

                return new DailySyncResult
                {
                    SourceRecords = source.Count,
                    TargetRecordsBefore = target.Count,
                    SourceAppliedRecords = sourceAppliedRecords,
                    PreservedTargetRecords = preservedTargetRecords,
                    ReplacedOrDroppedTargetRecords =
                        replacedOrDroppedTargetRecords,
                    OutputRecords = finalMeta.Records,
                    PreservedLatestSourceDate = preserveLatestSourceDate,
                    FirstDateTicks = finalMeta.FirstDateTicks,
                    LastDateTicks = finalMeta.LastDateTicks,
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
    }

}
