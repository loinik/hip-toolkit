using System.Buffers.Binary;
using System.Text;

namespace HIPToolkit;

/// <summary>
/// CVTX conversation text (AUTOTEXT.cif and friends) — a type-3 CIF whose
/// body is an IFF text table instead of Lua. Mirrors CIF::parseCVTX /
/// buildCVTX in Sources/Core/CIFArchive.cpp:
///
///   "DATA" BE32 size
///     "TEXT" "CVTX" BE32 size        (size counts bytes after it)
///       LE16 count
///       count × { char name[33] (NUL-padded); LE16 len; char text[len] }
/// </summary>
internal static class Cvtx
{
    private const int NameSize   = 33;
    private const int HeaderSize = 48;

    // "CIF FILE HerInteractive" + 00 03 00 00 00 (same 28 bytes as CIFArchive.cpp MAGIC)
    private static readonly byte[] CifMagic =
        [.. "CIF FILE HerInteractive"u8, 0x00, 0x03, 0x00, 0x00, 0x00];

    public record Entry(byte[] Name, byte[] Text);

    public static bool IsBody(byte[] body) =>
        body.Length >= 22 &&
        body.AsSpan(0, 4).SequenceEqual("DATA"u8) &&
        body.AsSpan(8, 8).SequenceEqual("TEXTCVTX"u8);

    public static List<Entry> Parse(byte[] body)
    {
        if (!IsBody(body)) throw new InvalidDataException("CVTX: not a DATA/TEXT/CVTX body");
        int end = (int)Math.Min(body.Length, 20L + BinaryPrimitives.ReadUInt32BigEndian(body.AsSpan(16)));
        int p = 20;
        int count = BinaryPrimitives.ReadUInt16LittleEndian(body.AsSpan(p));
        p += 2;

        var entries = new List<Entry>(count);
        for (int i = 0; i < count; i++)
        {
            if (p + NameSize + 2 > end)
                throw new InvalidDataException($"CVTX: truncated at entry {i}");
            var nameField = body.AsSpan(p, NameSize);
            int nul = nameField.IndexOf((byte)0);
            var name = nameField[..(nul < 0 ? NameSize : nul)].ToArray();
            p += NameSize;
            int len = BinaryPrimitives.ReadUInt16LittleEndian(body.AsSpan(p));
            p += 2;
            if (p + len > end)
                throw new InvalidDataException($"CVTX: text overruns chunk at \"{Encoding.Latin1.GetString(name)}\"");
            entries.Add(new Entry(name, body.AsSpan(p, len).ToArray()));
            p += len;
        }
        return entries;
    }

    /// Entries → complete CIF file (type 3). Byte-identical to the original
    /// for an unedited round trip.
    public static byte[] EncodeCif(IReadOnlyList<Entry> entries)
    {
        if (entries.Count > 0xFFFF) throw new InvalidDataException("CVTX: too many entries (max 65535)");
        var payload = new MemoryStream();
        Span<byte> u16 = stackalloc byte[2];
        BinaryPrimitives.WriteUInt16LittleEndian(u16, (ushort)entries.Count);
        payload.Write(u16);
        foreach (var e in entries)
        {
            var nameStr = Encoding.Latin1.GetString(e.Name);
            if (e.Name.Length >= NameSize)
                throw new InvalidDataException($"CVTX: name longer than 32 bytes: \"{nameStr}\"");
            if (e.Text.Length > 0xFFFF)
                throw new InvalidDataException($"CVTX: text longer than 65535 bytes at \"{nameStr}\"");
            var nameField = new byte[NameSize];
            e.Name.CopyTo(nameField, 0);
            payload.Write(nameField);
            BinaryPrimitives.WriteUInt16LittleEndian(u16, (ushort)e.Text.Length);
            payload.Write(u16);
            payload.Write(e.Text);
        }

        int bodySize = (int)payload.Length + 20;
        var cif = new byte[HeaderSize + bodySize];
        CifMagic.CopyTo(cif, 0);
        BinaryPrimitives.WriteUInt32LittleEndian(cif.AsSpan(28), 3);   // FileType::Lua
        BinaryPrimitives.WriteUInt32LittleEndian(cif.AsSpan(44), (uint)bodySize);
        var body = cif.AsSpan(HeaderSize);
        "DATA"u8.CopyTo(body);
        BinaryPrimitives.WriteUInt32BigEndian(body[4..], (uint)payload.Length + 12);
        "TEXTCVTX"u8.CopyTo(body[8..]);
        BinaryPrimitives.WriteUInt32BigEndian(body[16..], (uint)payload.Length);
        payload.ToArray().CopyTo(body[20..]);
        return cif;
    }

    // ── CSV (UTF-8 with BOM, CRLF; header: name,"text (<code page>)") ──

    private const string DefaultEncoding = "windows-1252";

    private static string CsvField(string s) =>
        s.IndexOfAny([',', ';', '"', '\r', '\n']) < 0 ? s : "\"" + s.Replace("\"", "\"\"") + "\"";

    // RFC 4180 rows; quoted fields may hold separators, "" and line breaks.
    private static List<List<string>> CsvRows(string src, char sep)
    {
        var rows  = new List<List<string>>();
        var row   = new List<string>();
        var field = new StringBuilder();
        bool quoted = false;
        for (int i = 0; i < src.Length; i++)
        {
            char c = src[i];
            if (quoted)
            {
                if (c != '"') field.Append(c);
                else if (i + 1 < src.Length && src[i + 1] == '"') { field.Append('"'); i++; }
                else quoted = false;
            }
            else if (c == '"') quoted = true;
            else if (c == sep) { row.Add(field.ToString()); field.Clear(); }
            else if (c is '\r' or '\n')
            {
                if (c == '\r' && i + 1 < src.Length && src[i + 1] == '\n') i++;
                row.Add(field.ToString()); field.Clear();
                rows.Add(row); row = [];
            }
            else field.Append(c);
        }
        if (field.Length > 0 || row.Count > 0) { row.Add(field.ToString()); rows.Add(row); }
        return rows;
    }

    /// CVTX body → CSV file bytes. The detected game code page is recorded in
    /// the header so the table opens cleanly in Excel / Sheets.
    public static byte[] BodyToCsv(byte[] body)
    {
        var entries = Parse(body);
        var all = entries.SelectMany(e => e.Text).ToArray();
        var (encName, _, _) = HIPInterop.DetectSingleByteEncoding(all);
        if (encName == "utf-8") encName = DefaultEncoding;   // pure ASCII
        var enc = HIPInterop.EncodingFromName(encName) ?? Encoding.GetEncoding(1252);

        var sb = new StringBuilder();
        sb.Append($"name,text ({encName})\r\n");
        foreach (var e in entries)
            sb.Append(CsvField(Encoding.Latin1.GetString(e.Name))).Append(',')
              .Append(CsvField(enc.GetString(e.Text))).Append("\r\n");
        return [.. Encoding.UTF8.GetPreamble(), .. Encoding.UTF8.GetBytes(sb.ToString())];
    }

    /// CVTX CSV → complete CIF. Accepts ',' or ';' separators, UTF-8 (with or
    /// without BOM) or the header's code page (Excel's plain "CSV" save).
    /// Fails on characters the code page cannot represent instead of writing '?'.
    public static byte[] CsvToCif(byte[] csv)
    {
        int bom = csv.Length >= 3 && csv[0] == 0xEF && csv[1] == 0xBB && csv[2] == 0xBF ? 3 : 0;
        int eol = Array.FindIndex(csv, bom, b => b is (byte)'\r' or (byte)'\n');
        var header = Encoding.Latin1.GetString(csv, bom, (eol < 0 ? csv.Length : eol) - bom);
        char sep = header.Contains(';') && !header.Contains(',') ? ';' : ',';
        var cols = CsvRows(header, sep).FirstOrDefault() ?? [];
        if (cols.Count < 2 || !cols[0].Equals("name", StringComparison.OrdinalIgnoreCase)
            || !cols[1].StartsWith("text", StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException($"Not a CVTX CSV: expected header \"name,text ({DefaultEncoding})\"");

        var encName = DefaultEncoding;
        int open = cols[1].IndexOf('('), close = cols[1].LastIndexOf(')');
        if (open >= 0 && close > open) encName = cols[1][(open + 1)..close].Trim();
        var baseEnc = HIPInterop.EncodingFromName(encName);
        if (baseEnc == null || baseEnc.CodePage == 65001)
            throw new InvalidDataException($"CVTX CSV: unknown encoding \"{encName}\"");
        var enc      = Encoding.GetEncoding(baseEnc.CodePage, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback);
        var name1252 = Encoding.GetEncoding(1252, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback);

        string src;
        try { src = new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(csv, bom, csv.Length - bom); }
        catch (DecoderFallbackException)
        {
            try { src = enc.GetString(csv, bom, csv.Length - bom); }
            catch (DecoderFallbackException) { throw new InvalidDataException($"CVTX CSV: file is neither UTF-8 nor {encName}"); }
        }

        var rows = CsvRows(src, sep);
        var entries = new List<Entry>(rows.Count);
        for (int r = 1; r < rows.Count; r++)
        {
            var row = rows[r];
            if (row.Count == 1 && row[0].Length == 0) continue;   // blank line
            var name = row[0];
            var text = row.Count > 1 ? row[1] : "";
            byte[] nameBytes, textBytes;
            try { nameBytes = name1252.GetBytes(name); }
            catch (EncoderFallbackException) { throw new InvalidDataException($"CVTX CSV row {r + 1}: name \"{name}\" is not plain Latin text"); }
            try { textBytes = enc.GetBytes(text); }
            catch (EncoderFallbackException) { throw new InvalidDataException($"CVTX CSV row {r + 1} (\"{name}\"): characters not representable in {encName}"); }
            entries.Add(new Entry(nameBytes, textBytes));
        }
        return EncodeCif(entries);
    }
}
